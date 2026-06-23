---
title: mutex 与 spinlock：保护临界区的两把锁
slug: drv-sync
difficulty: intermediate
tags: [同步, 自旋锁, 互斥锁, 并发]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/drivers/05-drv-irq
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch06.md
---

# mutex 与 spinlock：保护临界区的两把锁

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 并发从哪来：不只是多核，还有中断和抢占

我们写用户态程序时，一个进程的代码流通常是单线的——除非你显式开多线程。可一旦进了内核，这个"单线"的幻觉瞬间破灭：**同一时刻，真的有多个执行流在物理并行地跑，还会随时被打断。** 并发不是我们设计的，是被硬件硬塞进来的麻烦。

并发来源主要有三个：

1. **SMP 多核**：现在的芯片——哪怕树莓派——都是多核的。CPU 0 在执行你的驱动 `write`，CPU 1 同时在执行另一个进程的 `read`，两条流物理并行，都去碰同一个共享数据。
2. **中断**：进程上下文正在改一个计数器，硬件中断来了，同一个 CPU 上跳去跑中断处理程序，中断处理程序也想改这个计数器。
3. **内核抢占**（`CONFIG_PREEMPTION`）：进程 A 持有共享数据正在算，被高优先级进程 B 抢占，B 也来碰这份数据。

把这三个凑齐，就得到了"数据竞争"的温床。

## 临界区与数据竞争

不是所有代码都需要保护，只有**访问共享可写数据**的那段才危险。这种代码段叫**临界区**（critical section）。

数据竞争长什么样？看一行最朴素的 `count++`。C 代码看起来是一条语句，汇编层面却是"读 `count` → 加 1 → 写回 `count`"三步。两个 CPU 同时读到旧值（比如 100），各自加 1 写回 101——本该是 102，结果少了 1。这就是经典的"更新丢失"。

要根治它，得让这段"读-改-写"变成**原子**的——要么做完，要么没做，中间谁也插不进来。这就是**原子性**。而要保证原子性，最直接的工具就是**互斥**（mutual exclusion）：进厕所锁门，别人在外面排队。

内核里实现互斥，主要靠两把脾气截然不同的锁：**mutex** 和 **spinlock**。

## 两把锁的分野：能不能睡眠

mutex 和 spinlock 的根本区别只有一句话：**抢不到锁时，你是去睡觉，还是原地打转？**

- **mutex（互斥锁）**：抢不到就**睡觉**（schedule 出去，把 CPU 让给别人），等锁主人释放了再把你唤醒。代价是上下文切换开销，好处是不烧 CPU。它要求持有者在**进程上下文**——因为睡觉是进程才能干的事。
- **spinlock（自旋锁）**：抢不到就**原地打转**（一个紧凑循环反复试探锁有没有释放），CPU 一直在那空转。代价是烧 CPU cycles，好处是不用上下文切换、可以在任何上下文（包括中断）用。但要求临界区**极短**，且**绝对不能睡眠**。

这就引出一句选择口诀，背下来就够用八成场景：

> **临界区能不能睡眠？能睡 → mutex；不能睡（中断里、或持锁路径）→ spinlock。**

## mutex：竞争时睡觉排队

mutex 在内核里是 `struct mutex`（`include/linux/mutex_types.h`，Linux 6.19）。它的核心字段长这样：

```c
struct mutex {
    atomic_long_t       owner;      // 持锁 task 指针 + 低几位标志
    raw_spinlock_t      wait_lock;  // 保护 wait_list 的自旋锁
    struct list_head    wait_list;  // 等待者队列
    struct optimistic_spin_queue osq; // 乐观自旋的 MCS 排队锁
    ...
};
```

注意它把"谁持有锁"和"有没有人等"压进了一个 `atomic_long_t owner`——低位复用成标志位（`MUTEX_FLAG_WAITERS`、`HANDOFF`、`PICKUP`），高位存持锁者 `task_struct *`。这是为了快速路径能靠一条原子 `cmpxchg` 拿锁。

### 快速路径：无竞争时一条原子指令

`mutex_lock()`（`kernel/locking/mutex.c:285`）的实现分快慢两路。第一行就是 `might_sleep()`——这就是 mutex 的"自我宣告"：它会在调度器面前喊一嗓子"我可能要睡"，配合 `CONFIG_DEBUG_ATOMIC_SLEEP` 把在原子上下文误用 mutex 的情况当场揪出来。

```c
void __sched mutex_lock(struct mutex *lock)
{
    might_sleep();
    if (!__mutex_trylock_fast(lock))
        __mutex_lock_slowpath(lock);
}
```

`__mutex_trylock_fast()`（mutex.c:152）是乐观尝试：用 `atomic_long_try_cmpxchg_acquire(&lock->owner, &zero, curr)`，把 owner 从 0 原子地换成"当前 task 指针"。没人竞争时这一条指令就拿到锁了，开销极小。

### 慢速路径：先乐观自旋，不行再睡

竞争来了怎么办？内核不会立刻让你睡觉——先尝试**乐观自旋**（`mutex_optimistic_spin`，mutex.c:444）：如果锁主人此刻正在另一个 CPU 上跑，它八成马上就放，那我也跟着转几圈 `cpu_relax()`，省一次上下文切换。多个自旋者用 `osq`（MCS 排队锁）排成一队，避免一堆人挤着抢。要是主人也被抢占了、或调度器提示该让 CPU 了，就老老实实走慢速路径。

真正的睡觉发生在 `__mutex_lock_common()`（mutex.c:577）里：把自己塞进 `wait_list`（FIFO 排队），设状态 `set_current_state(TASK_UNINTERRUPTIBLE)`，然后调 `schedule_preempt_disabled()`（mutex.c:692）——**这一句就是"把 CPU 让出去睡觉"**。等锁主人 `mutex_unlock()` 唤醒它，它再被调度回来重新尝试拿锁。

### 解锁

`mutex_unlock()`（mutex.c:546）同样先试快速路径 `__mutex_unlock_fast()`——用 `cmpxchg_release` 把 owner 清零。但要是 `wait_list` 里有人排队（owner 带 `WAITERS` 标志），就得走慢速路径 `__mutex_unlock_slowpath()`（mutex.c:931）：从 `wait_list` 取出第一个等待者，塞进 `wake_q` 唤醒队列，最后通过 `wake_q` 把它叫醒。

```c
mutex_lock(&m);      /* 抢不到就睡 */
/* 临界区：可改共享数据、可调用会阻塞的函数 */
mutex_unlock(&m);
```

mutex 还派生出几个变体：`mutex_lock_interruptible()`（被信号打断时返回 `-EINTR`）、`mutex_lock_killable()`（只被致命信号打断）、`mutex_trylock()`（拿不到立刻返回 0，不睡）。中断处理程序里**不能用** mutex——ISR 不能睡觉。

## spinlock：竞争时 CPU 空转

spinlock 的核心是 `spinlock_t`（在非 RT 内核里它就包了个 `raw_spinlock_t`，`include/linux/spinlock.h:349` 的 `spin_lock` 直接转调 `raw_spin_lock(&lock->rlock)`）。

竞争时的"原地打转"长什么样？看 `kernel/locking/spinlock.c:67` 的 `BUILD_LOCK_OPS` 宏生成的 `__raw_spin_lock`：

```c
for (;;) {
    preempt_disable();                       /* 拿锁必先关抢占 */
    if (likely(do_raw_spin_trylock(lock)))   /* 试原子拿锁 */
        break;
    preempt_enable();                        /* 没拿到，放掉抢占计数 */
    arch_spin_relax(&lock->raw_lock);        /* cpu_relax() 空转一下 */
}
```

关键就这几步：`preempt_disable()` → 试拿锁（`do_raw_spin_trylock` 最终调架构的 `arch_spin_lock`，比如 x86 的 `lock cmpxchg`、ARM64 的 `ldaxr/stxr` 原子指令）→ 拿到就 `break`，没拿到就 `preempt_enable()` 让一下、`cpu_relax()` 省点功耗，再来一轮。

注意一个细节：**自旋循环里每轮都 `preempt_disable`/`preempt_enable`**。为什么？因为持有自旋锁时不能被抢占——被抢走了，等锁的别的 CPU 只能干转到地老天荒。所以一旦真正拿到锁，`preempt_disable` 就一直生效到 `spin_unlock`。这也解释了下面那条铁律的根源。

### spinlock 的铁律：临界区绝对不能睡眠

这条比 mutex 严苛得多。持着 spinlock 时，你**不能**做任何可能引发调度的事：不能 `msleep`、不能 `kmalloc(GFP_KERNEL)`、不能 `copy_from_user`（可能缺页换页）、不能 `mutex_lock`（mutex 会睡觉）。

原因就在上面那个 `preempt_disable()`——拿锁时抢占被关了，进程当前所在 CPU 不会切走，别的 CPU 上等这把锁的人还能靠"空转"等到你放锁。可你要是在锁里睡了，调度器要把你换出去——但你 `preempt_count` 还是非零、还处于"原子上下文"，调度器一检测到这种矛盾，就会炸出内核最著名的告警之一：**"scheduling while atomic"**，轻则 dump 栈，重则直接 panic。

> 比喻：mutex 像去银行取号排队，你可以坐着刷手机（睡觉），叫到号再上。spinlock 像在高速收费站的人工通道，你踩着刹车原地怠速等前面那辆走——你不能熄火下车吃饭（睡觉），不然后面整条队都卡死，你的车还堵在窗口。

## 中断里的锁：spin_lock_irqsave 防重入死锁

最让人头疼的场景：进程上下文拿着 spinlock 改数据，**同一 CPU** 上一个中断打进来，中断处理程序也要改这数据，也去拿这把锁——**死锁**。中断处理程序会一直空转等锁，可锁的主人（被中断的进程）根本没机会运行放锁，因为它被中断抢占了。

解决办法：拿锁的同时**关掉本地 CPU 的中断**，保证临界区执行期间不会被本 CPU 的中断打断。内核给了一族带 `irq` 后缀的 API，最推荐通用写法是 `spin_lock_irqsave`（`include/linux/spinlock.h:379` 的宏 → `kernel/locking/spinlock.c:160` 的 `_raw_spin_lock_irqsave`）：

```c
unsigned long flags;
spin_lock_irqsave(&lock, flags);   /* 关中断 + 存旧中断状态到 flags + 拿锁 */
/* 临界区 */
spin_unlock_irqrestore(&lock, flags); /* 还原中断状态 + 放锁 */
```

为什么用 `_irqsave` 而不是更简单的 `_irq`？因为 `_irq` 版本解锁时**无条件开中断**——要是你这段代码本来就是在"中断本就关着"的环境里被调用的（比如某层嵌套中断处理），解锁时把中断强行打开，就破坏了外层的约定。`_irqsave` 把进入前的中断状态存进 `flags`，解锁时原样还原，无副作用。**不确定就用 `_irqsave`，永远安全。**

还有个 `_bh` 变体：只防软中断/底半部（`local_bh_disable()`），不防硬件中断，用于跟 tasklet/softirq 共享数据时。

## 单核 + 抢占：spin_lock 本质是关抢占

有人会问：单核（UP）系统上，spinlock 还"自旋"个什么劲？只有一个 CPU，锁主人没放锁，等待者根本跑不起来，转给谁看？

答案是：**在非抢占的 UP 上，自旋那部分逻辑被编译器优化掉了**，`spin_lock` 基本退化成 `preempt_disable()`。但开了抢占的 UP 上，关抢占是实打实有用的——防止被抢占。而 `spin_lock_irqsave` 里的关中断逻辑，在 UP 上依然有意义（防中断重入）。

所以工程铁律是：**作为驱动开发者，别管 UP 还是 SMP，一律按 SMP 的逻辑写、一律用标准 API。** 内核会替你处理单核细节。

### Local locks（5.8+）

到了 5.8，内核引入了 `local_lock_t`（`include/linux/local_lock_internal.h`），给"关抢占 + 关中断"这套组合一个有名字、可被 lockdep 追踪的封装。它在非 debug 构建里基本是空的（就是 `preempt_disable`/`local_irq` 的马甲），但在 `CONFIG_DEBUG_LOCK_ALLOC` 下会记录 owner 和 dep_map，让 lockdep 能查出"在原子上下文睡觉"这类隐蔽 bug。普通驱动暂时用不上，知道有这么个东西、知道它和 PREEMPT_RT 实时内核关系密切即可。

## 动手待亲测（占位，QEMU 上验过再补真实输出）

两个最小验证方案，等我们拿到 QEMU ARM64 上跑一遍记下真实输出：

1. **mutex vs spinlock 对比模块**：开一个内核线程持 `mutex_lock` 然后 `msleep(100)`——能正常睡醒，证明 mutex 临界区可睡眠。换成 `spin_lock` + `msleep`——触发 `scheduling while atomic` 报错/dump，证明 spinlock 临界区不能睡。观察 `dmesg`。
2. **故意持锁睡眠触发死锁**：写一个 ISR 用普通 `spin_lock` 拿一把进程上下文正持有的锁，确认死锁/挂起现象，再改成 `spin_lock_irqsave` 复现"正常工作"。

> ⚠️ 上面两段是计划方案，真实命令输出和 `dmesg` 报错栈待 QEMU 亲测后回填，届时升级为 ✅ 已锤炼。

## 小结

并发的根是 SMP 多核 + 中断 + 抢占，它们让"读-改-写"不再是原子的，数据竞争就这么来。保护临界区有两把锁：**mutex** 抢不到就睡觉（靠 `owner` 原子量快速路径 + `wait_list` 排队睡眠 + 乐观自旋优化），只能在进程上下文用；**spinlock** 抢不到就 CPU 空转（`preempt_disable` + 原子试锁 + `cpu_relax`），任何上下文都能用，但临界区**绝对不能睡眠**，否则 "scheduling while atomic"。

选择口诀一句话：**能睡用 mutex，不能睡（中断/持锁路径）用 spinlock**。当中断和进程上下文共享数据时，spinlock 必须配 `spin_lock_irqsave`/`spin_unlock_irqrestore`——拿锁同时关中断并保存状态，防中断重入死锁。

## 延伸阅读

- 源码（Linux 6.19）：
  - `kernel/locking/mutex.c` — mutex 的快慢路径、乐观自旋、等待队列（`mutex_lock` at mutex.c:285，`__mutex_lock_common` at mutex.c:577）。
  - `kernel/locking/spinlock.c` — `BUILD_LOCK_OPS` 生成的自旋循环（spinlock.c:67），`_raw_spin_lock_irqsave`（spinlock.c:160）。
  - `include/linux/mutex_types.h` — `struct mutex` 定义；`include/linux/spinlock.h` — `spin_lock` 等内联封装；`include/linux/local_lock_internal.h` — local_lock 实现。
- kernel.org 文档：[Locking types and docs](https://docs.kernel.org/locking/index.html)、[Kernel API / locking](https://docs.kernel.org/core-api/kernel-api.html)。