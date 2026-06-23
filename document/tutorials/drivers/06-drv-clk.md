---
title: 时间与延迟：内核怎么"等"
slug: drv-clk
difficulty: intermediate
tags: [时间管理, 延迟, hrtimer, jiffies]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/drivers/05-drv-irq
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch05.md
  - notes: document/notes/linux_kernel_device_drivers/ch05_1.md
  - notes: document/notes/linux_kernel_device_drivers/ch05_2.md
---

# 时间与延迟：内核怎么"等"

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 驱动为什么要"等"

写驱动时，"等一会儿"是高频需求，归纳起来就三类：**等硬件就绪**（写完命令寄存器，手册要求至少等 5µs 才能读状态）、**周期任务**（每 200ms 采一次传感器）、**超时检测**（发出去的请求 100ms 内没回包就算失败）。用户空间这些事一个 `sleep(1)` 搞定，进程一睡 CPU 就让给别人；可一进内核，"等"立刻分裂成两种截然不同的姿势，选错了不是性能差，是直接死锁。

## 两种延迟的本质：忙等待 vs 休眠

内核对"等"的 API 是按**你能不能让 CPU 调度出去**来分家的，这是生死分界线，不是风格问题。

- **忙等待（busy-wait）**：CPU 原地空转数 cycle，**不发生 `schedule()`**。`*delay()` 系列（`udelay`/`ndelay`/`mdelay`）。打个比方，就像你在 ATM 前死盯着屏幕，后面的人谁都别想动——CPU 被你一个人霸占。
- **休眠（sleep）**：把当前进程状态改成 `TASK_INTERRUPTIBLE`/`TASK_UNINTERRUPTIBLE`，调 `schedule()` 让出 CPU，丢进等待队列，到点再被唤醒。`*sleep()` 系列（`msleep`/`usleep_range`/`ssleep`）。这回是拿号坐椅子上玩手机，柜台让给别人，叫号了再回去。

## 为什么不能任意睡：原子上下文的死结

休眠的代价是**必须能调度**，而调度的前提是当前在**进程上下文**。一旦你处在这几种"原子上下文"里——硬中断、软中断（含 `TIMER_SOFTIRQ`、tasklet）、或者**手里攥着自旋锁**的临界区——`schedule()` 就是禁区。

为什么自旋锁里睡会死锁？自旋锁的语义是"别人想拿这把锁就原地自旋等我放"。你拿着锁睡着了，那个等锁的家伙大概率在别的 CPU 上空转——如果它恰好是个内核核心调度路径上的线程，整个系统就僵住了。所以铁律：**原子上下文只能 `*delay()`，进程上下文才许 `*sleep()`**。内核贴心地埋了 `might_sleep()` 钩子，一旦你在原子上下文踩进会睡眠的代码，会甩一脸堆栈帮你抓虫。

## 忙等待 API：udelay / ndelay / mdelay

三个精度档，核心实现在 `<linux/delay.h>` 与 `<asm-generic/delay.h>`（Linux 6.19）：

| API | 单位 | 备注 |
|:---|:---|:---|
| `ndelay(nsecs)` | 纳秒 | 内部 `DIV_ROUND_UP(x,1000)` 后转 `udelay` |
| `udelay(usecs)` | 微秒 | 这一族的核心 |
| `mdelay(msecs)` | 毫秒 | 宏，大延迟时循环调 `udelay(1000)` |

`udelay` 是这一族的**核心**：`ndelay` 内部 `DIV_ROUND_UP` 后转 `udelay`，`mdelay` 是个宏循环调 `udelay`；真正**架构相关**的是 `udelay` 背后的 `__const_udelay()` / `__delay()`——后者就是个紧凑的空循环（x86 在 `arch/x86/lib/delay.c`）。换句话说，被别人复用的底层入口是 `udelay`，而不是说它有独立的汇编实现而另两个没有。

关键是它们**怎么算准时间**。CPU 频率会变，空循环跑多少圈才等于 1µs？答案是启动时校准出来的 `loops_per_jiffy`（`init/calibrate.c` 的 `calibrate_delay()`，换算成 BogoMIPS）。`udelay()` 的通用实现（`include/asm-generic/delay.h`）本质：把常数 µs 折算成 xloops，交给架构相关的 `__const_udelay()` / `__delay()`。

两个坑：**别用 `udelay(30*1000)` 代替 `mdelay(30)`**——`delay.h` 注释明说 `loops_per_jiffy` 高的机器上几毫秒的 `udelay` 可能溢出，`mdelay` 的宏（`MAX_UDELAY_MS` 通常 5）就是为了防这个；**别在原子上下文里 `mdelay` 秒级等待**，那是把 CPU 拴死空转，纯烧电。

## 休眠 API：msleep / usleep_range / schedule_timeout

进程上下文专用，核心是"设个闹钟 + `schedule()`"。源码在 `kernel/time/sleep_timeout.c`，一目了然。

`msleep(unsigned int msecs)`（第 313 行）的真身就三行：

```c
void msleep(unsigned int msecs)
{
    unsigned long timeout = msecs_to_jiffies(msecs);
    while (timeout)
        timeout = schedule_timeout_uninterruptible(timeout);
}
```

而 `schedule_timeout_uninterruptible()` 干的事是 `__set_current_state(TASK_UNINTERRUPTIBLE)` 然后 `schedule_timeout()`。`schedule_timeout()`（第 61 行）的机理值得逐字看：它在**栈上**建一个 `struct process_timer`（内嵌 `timer_list`），把过期时间设成 `timeout + jiffies`，`add_timer()` 挂上，然后 `schedule()` 让出 CPU；闹钟回调 `process_timeout()` 调 `wake_up_process()` 把你摇醒，醒来再 `timer_delete_sync()` 收拾掉栈上定时器。所以 `msleep` 是**基于 jiffies/timer wheel** 的，精度受 `HZ` 限制（timer wheel 还允许最多 12.5% 的 slack，文档里写得很清楚）。

`msleep_interruptible()`（第 334 行）状态改成 `TASK_INTERRUPTIBLE`，可被信号打断，返回**剩余毫秒数**——符合 UNIX"提供机制不给策略"的哲学，需要响应 `Ctrl+C` 的驱动该用它。

`usleep_range(min, max)` 走的是另一条路——**hrtimer**。它的实现 `usleep_range_state()`（第 362 行）算出绝对过期时间 `exp = ktime_get() + min`，设 `delta = (max-min)` 纳秒的 slack，然后 `schedule_hrtimeout_range(&exp, delta, HRTIMER_MODE_ABS)`。**给个范围**不是矫情：这让内核能把多个 hrtimer 合并到同一个中断里唤醒，少打扰 CPU 的深度省电状态（C-states）。`checkpatch` 见到 `usleep_range(x, x)`（min==max）甚至会发 WARNING，让你留点余量。

经验法则（与笔记 ch05_1 对齐）：`≤10µs` 用 `udelay`；`10µs–20ms` 用 `usleep_range`；`>20ms` 用 `msleep`；`>1s` 用 `ssleep`（`msleep(s*1000)` 的薄封装）。注意这条分界随 `HZ` 变化（典型 `HZ=250/1000` 下的经验值），不是硬切线。

**懒得记这一串阈值？** 6.19 给了个 `fsleep(usecs)`（`include/linux/delay.h:127`），它内部按 **25% slack 上限**自动选最佳机制：`≤10µs` 走 `udelay`、中等延迟走 `usleep_range`、长延迟走 `msleep`（`delay.h:110-135` 注释即其分支逻辑）。也就是说，上面那条经验法则的本质，就是 `fsleep` 的内部分支。非精确时序场景直接用 `fsleep` 最省心——文档里也把它列为"拿不准就上它"的首选。

## 高精度定时器 hrtimer：纳秒级闹钟

`usleep_range` 底层就是 hrtimer。当你需要**自己设周期闹钟**（不是睡一觉），就用 `struct hrtimer`（`include/linux/hrtimer.h`）。它取代了老 `timer_list` 的精度痛点：`timer_list` 基于 jiffies（`HZ=1000` 时精度才 1ms），hrtimer 是**纳秒级**，在 `CONFIG_HIGH_RES_TIMERS` 下脱离 tick 真正高精度。

核心模式 `enum hrtimer_mode`（第 35 行）：`HRTIMER_MODE_ABS`（绝对时间）/ `HRTIMER_MODE_REL`（相对现在），还能 `| _SOFT`（软中断回调）或 `| _HARD`（**即便在 `PREEMPT_RT` 上也强制硬中断**，这是它的语义，见 `hrtimer.h:32` 注释）。

典型用法四步：

1. `hrtimer_setup(&timer, callback, CLOCK_MONOTONIC, HRTIMER_MODE_REL)`——绑定回调，签名 `enum hrtimer_restart (*function)(struct hrtimer *)`。
2. `hrtimer_start(&timer, ns_to_ktime(200*1000000ULL), HRTIMER_MODE_REL)`——启动，传 `ktime_t`。
3. 回调里想周期触发就返回 `HRTIMER_RESTART` 并 `hrtimer_forward(timer, now, interval)` 推进过期点；一次性就返回 `HRTIMER_NORESTART`。
4. 收尾 `hrtimer_cancel(&timer)`。

回调上下文要警惕——这里要把"显式 flag"和"默认行为"分开看。**默认**（不或 `_SOFT` 也不或 `_HARD`）时，在**非 RT 内核**上回调跑在**硬中断**上下文：`__hrtimer_setup()` 里 `softtimer = !!(mode & HRTIMER_MODE_SOFT)`，不带 `_SOFT` 就是 `is_soft=false`，从而选中硬中断的 `clock_base`（`kernel/time/hrtimer.c:1607-1650`）；而 `PREEMPT_RT` 内核则**除非显式 `_HARD`，一律降级到软中断**（`hrtimer.c:1621`，注释明说"RT 上回调可能调 `spin_lock` 等会睡的函数"）。所以上面示例用的 `HRTIMER_MODE_REL`，在非 RT 内核上此刻就是硬中断上下文。结论不变：**默认回调绝对不能睡**；要干可能阻塞的活，要么或上 `_SOFT` 走软中断，要么干脆丢工作队列。

## 时间来源：jiffies 与 ktime_get_*

打表测延迟需要一把尺子。两套时间源：

- **jiffies**：全局变量，每个时钟中断（tick）加 1，**全局粗粒度**（`HZ=250` 时一格 4ms）。`msecs_to_jiffies()` / `jiffies_to_msecs()` 做单位换算，`timer_list.expires` 就用它。
- **ktime_get_\* 系列**（`include/linux/timekeeping.h`）：**纳秒级**。`ktime_get_ns()` 单调时钟、`ktime_get_real_ns()` 墙钟时间（自 Epoch，会随 NTP 跳）、`ktime_get_boottime_ns()` 含挂机睡眠时间。打表就用 `ktime_get_ns()` 包前后相减。

## 动手验证方案（待亲测）

写个内核模块，在 `init` 里依次打表，看真实延迟和标称值的偏差：

- **忙等待精度**：`ktime_get_ns()` 包住 `udelay(10)`、`mdelay(2)`，对比预期——`*delay()` 常常**偏短**（`asm-generic/delay.h` 注释列了三大原因：`loops_per_jiffy` 算低了、cache 影响、CPU 变频）。
- **休眠精度**：包住 `msleep(20)`、`usleep_range(5000,5500)`，预期会**偏长**——唤醒要调度延迟，醒了还得排队等 CPU。
- **hrtimer 周期回调**：起一个 `HRTIMER_MODE_REL` 的 hrtimer，回调里 `hrtimer_forward` + 返回 `HRTIMER_RESTART`，`ktime_get_ns()` 打每次回调间隔，对照 200ms 标称。

> ⚠️ **待亲测**：以上为验证方案与预期，命令输出（`dmesg` 时间戳、实际 ns 数）会在 QEMU ARM64 上跑过后回填真实数据。落地代码放 `example/mini/{descriptive-name}/`，include `../../common/Makefile.arch` 走多架构编译。

## 小结

内核里"等"的纪律一句话：**上下文决定一切**。原子上下文（中断/持自旋锁）只能 `udelay` 类忙等待，进程上下文才许 `msleep`/`usleep_range` 休眠让出 CPU。底层两条腿：忙等待靠启动时校准的 `loops_per_jiffy`（BogoMIPS），休眠靠 `schedule_timeout()`（栈上 `timer_list` + `schedule()`）或 `schedule_hrtimeout_range()`（hrtimer）。需要周期闹钟用 `struct hrtimer`，纳秒级；打表测延迟用 `ktime_get_ns()`。记不住阈值就用 `fsleep()` 让内核替你挑。记住内核延迟永远是"至少"这么久而非"精确"这么久——硬实时不是标准 Linux 的活。

## 延伸阅读

- 源码（Linux 6.19）：`include/linux/delay.h`（`mdelay` 宏、`ndelay`、`usleep_range`/`fsleep`/`ssleep` 的内联实现与注释）、`include/asm-generic/delay.h`（`udelay`/`ndelay` 的 `__always_inline` 实现、`__const_udelay`/`__delay` 声明、偏短三因注释）、`kernel/time/sleep_timeout.c`（`schedule_timeout`/`msleep`/`msleep_interruptible`/`usleep_range_state`）、`include/linux/hrtimer.h`（`struct hrtimer`、`enum hrtimer_mode`/`hrtimer_restart`）、`kernel/time/hrtimer.c`（`__hrtimer_setup` 的 soft/hard 与 RT 降级逻辑）、`include/linux/timekeeping.h`（`ktime_get_*`）、`init/calibrate.c`（`loops_per_jiffy` 校准）。
- 文档：[Timers 子系统总索引](https://docs.kernel.org/timers/index.html)（6.19 下含 highres/hpet/hrtimers/no_hz/timekeeping/delay_sleep_functions 六篇）、[delay/sleep 函数选型（delay_sleep_functions.rst）](https://docs.kernel.org/timers/delay_sleep_functions.rst)（讲怎么选 `*delay`/`usleep_range`/`*sleep`/`fsleep`，含 `fsleep` 文档建议）、[高精度定时器 hrtimers.rst](https://docs.kernel.org/timers/hrtimers.html)。
- 进一步（后续铺开）：`timer_list` 软中断定时器、内核线程（`kthread_run`）、工作队列（`schedule_work`）——把"稍后做"的活推迟到进程上下文。