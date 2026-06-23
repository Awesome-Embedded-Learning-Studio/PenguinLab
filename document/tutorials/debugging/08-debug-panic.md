---
title: panic、Hung Task 与死锁检测
slug: debug-panic
difficulty: intermediate
tags: [panic, 死锁检测, hung_task, lockup]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/debugging/05-debug-oops
related:
  - /tutorials/debugging/05-debug-oops
sources:
  - notes: document/notes/linux_kernel_debugging/ch10.md
  - notes: document/notes/linux_kernel_debugging/ch10_2.md
  - notes: document/notes/linux_kernel_debugging/ch10_3.md
  - notes: document/notes/linux_kernel_debugging/ch10_4.md
  - notes: document/notes/linux_kernel_debugging/ch10_5.md
---

# panic、Hung Task 与死锁检测

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

上一篇我们拆了 oops——内核崩了但还苟着喘气。这一篇讲更狠的两种死法：一种是**干脆不活了**的 panic，另一种是**没死透、但跟死了没两样**的假死（hung task、lockup）。oops 和 panic 的关系是前者可能升级成后者，而升级的开关就藏在本篇里。

## panic：内核的最后遗言

`panic()` 是内核的"放弃治疗"按钮。它的签名在 `include/linux/panic.h`（Linux 6.19）里标得清清楚楚：

```c
void panic(const char *fmt, ...) __noreturn __cold;
```

注意 `__noreturn`——这个函数进去就别想出来。它收一个 printf 风格字符串，把死因吼到日志里，然后让系统停摆。我们模块里能直接调它（导出符号），但更常见的是内核自己在遇到无法恢复的错误时内部触发。

### `vpanic()` 的临终流程

`panic()` 只是个壳，真正的活都在 `vpanic()` 里（`kernel/panic.c`，Linux 6.19）。我们顺着源码走一遍它咽气前的每一步：

1. **`local_irq_disable(); preempt_disable_notrace();`**（`kernel/panic.c`）——先把本 CPU 中断关掉、抢占禁掉。为什么？因为一旦 `panic_cpu` 被设上，后续任何中断处理函数都可能再次调 `panic()`，自己把自己卡死。

2. **抢"第一个到达 panic 的 CPU"名额**：`if (panic_try_start())`。`panic_try_start()` 用 `atomic_try_cmpxchg(&panic_cpu, &old_cpu, this_cpu)` 抢锁，`panic_cpu` 初值是 `PANIC_CPU_INVALID`（`-1`，定义在 `include/linux/panic.h`）。SMP 系统上多核可能同时 panic，只有抢到的那个继续走完临终流程，其他 CPU 调 `panic_smp_self_stop()` 进死循环空转。

3. **`pr_emerg("Kernel panic - not syncing: %s\n", buf);`**（`kernel/panic.c`）——那句经典的"not syncing"就来自这里。意思是：**内存里有一堆脏数据没刷盘，但故意不刷了**。系统状态已经乱了，强行写磁盘反而可能把文件系统搞挂，两害相权取其轻。

4. **`dump_stack()`**（若开了 `CONFIG_DEBUG_BUGVERBOSE`）吐调用栈，这是查死因最重要的线索。

5. **`kgdb_panic(buf)`**——如果使能了 kgdb，先给它一次机会：在停掉其他 CPU 之前让 gdbstub 接进来调试，否则那些 CPU 一停就抓不到现场了（`kernel/panic.c`，源码注释明说了这点）。

6. **`__crash_kexec(NULL)`**——若配置了 kdump 崩溃内核，**默认在 notifier 链和 kmsg_dump 之前**就先切过去让它 dump 内存，这是服务器标准方案。这里有条岔路：若开了 `crash_kexec_post_notifiers`，则改为延后到 notifier 链与 `kmsg_dump` **之后**再调一次 `__crash_kexec(NULL)`——给那些怀疑 kdump 不稳的人留个"先跑通知器、先 dump 日志、再崩"的选项（`kernel/panic.c`，两处 `__crash_kexec` 由该开关二选一）。

7. **`panic_other_cpus_shutdown()`**——若 `panic_print` 里设了 `SYS_INFO_ALL_BT` 位，先调 `panic_trigger_all_cpu_backtrace()`（内部再触发 `trigger_all_cpu_backtrace()`）把所有 CPU 栈拍下来，**再** `smp_send_stop()`（或崩溃路径下的 `crash_smp_send_stop()`）停掉其他 CPU。顺序很关键：CPU 一停就拍不到栈了。

8. **`atomic_notifier_call_chain(&panic_notifier_list, 0, buf);`**——跑 panic 通知器链，给注册的回调最后一次机会做事（见下节）。

9. **`sys_info(panic_print); kmsg_dump_desc(KMSG_DUMP_PANIC, buf);`**——按位掩码打印系统信息、dump 内核日志。

10. **结尾的死循环**：`pr_emerg("---[ end Kernel panic ...]---"); suppress_printk = 1;`，然后 `for (i = 0; ; i += PANIC_TIMER_STEP)` 永远空转，里面周期性调 `panic_blink()`——告诉你"是内核死了，不是显示器坏了"。`suppress_printk = 1` 是为了锁死屏幕画面，防止后面的日志把关键诊断滚没。

> 关于 `panic_blink()`：它默认是 `no_blink`（啥也不干），x86 上 i8042 键盘驱动（`drivers/input/serio/i8042.c`）在 init 时会把它换成 `i8042_panic_blink()`，靠拨键盘 LED 来"闪烁"。所以"键盘灯闪"这个体感是 x86 + i8042 才有的，别的架构不一定。

## panic 通知器链：挂钩到内核的死亡瞬间

`kernel/panic.c` 里有一行关键定义：

```c
ATOMIC_NOTIFIER_HEAD(panic_notifier_list);
EXPORT_SYMBOL(panic_notifier_list);
```

这是一条**原子通知器链**——回调跑在原子上下文，**绝对不能睡眠**。Panic 时系统已经极度脆弱，中断可能关了、调度停了，你要是在回调里 `kmalloc(GFP_KERNEL)` 或拿信号量，系统会卡死在你手里，连 kdump 都生成不了。这个纪律内核源码注释里都标了：某些 panic_notifier 可能让崩溃内核更不稳定，增加 kdump 失败风险。

### `notifier_block`：挂钩用的"身份证"

定义在 `include/linux/notifier.h`（Linux 6.19）：

```c
struct notifier_block {
    notifier_fn_t notifier_call;
    struct notifier_block __rcu *next;
    int priority;     // 数字越大越早被调
};
```

注册用 `atomic_notifier_chain_register(&panic_notifier_list, &my_nb)`（注意：`atomic_notifier_chain_register` 是 **GPL-only** 符号，模块 LICENSE 必须是 `GPL` 或 `Dual MIT/GPL`，否则符号未定义编不过）。回调签名是 `int (*notifier_fn_t)(struct notifier_block *nb, unsigned long action, void *data)`，返回 `NOTIFY_OK` / `NOTIFY_DONE` / `NOTIFY_STOP` / `NOTIFY_BAD`。

**一个活生生的例子就挂在 `kernel/hung_task.c` 里**——`hung_task_init()` 用 `subsys_initcall` 跑起来时，第一件事就是：

```c
atomic_notifier_chain_register(&panic_notifier_list, &panic_block);
```

对应的 `panic_block.notifier_call = hung_task_panic`，它只做一件事：`did_panic = 1;`。这样 hung task 检测器一旦发现系统已 panic，就不再多嘴报新的卡死任务，避免在尸体上做多余的动作。这就是"挂钩做最后一点必要的事"的范本——极简、不睡眠。

## Hung Task：抓 D 状态睡死的任务

CPU 还在转、没 panic，但有个进程在 `TASK_UNINTERRUPTIBLE`（`ps` 里的 `D` 状态）赖着不醒，超过 120 秒——这就是 Hung Task。怎么抓？内核养了一条叫 `khungtaskd` 的看门狗线程。

### 线程主体：`watchdog()`

`kernel/hung_task.c` 的 `hung_task_init()` 用 `kthread_run(watchdog, NULL, "khungtaskd")` 起了这个线程。线程函数 `watchdog()` 是个无限循环：算出下次该醒的时间 `t = hung_timeout_jiffies(...)`，`schedule_timeout_interruptible(t)` 睡过去，醒来后调 `check_hung_uninterruptible_tasks(timeout)` 巡视。默认间隔（`hung_task_check_interval_secs` 为 0 时）就等于超时时间 120 秒。

### 怎么判定一个任务"卡住"：`task_is_hung()`

核心判断在 `task_is_hung()`（`kernel/hung_task.c`，Linux 6.19）：

```c
unsigned long switch_count = t->nvcsw + t->nivcsw;  // 自愿+非自愿切换次数
unsigned int state = READ_ONCE(t->__state);

if (!(state & TASK_UNINTERRUPTIBLE) ||
    (state & (TASK_WAKEKILL | TASK_NOLOAD | TASK_FROZEN)))
    return false;                    // 只管真正的 D 状态
...
if (switch_count != t->last_switch_count) {   // 期间发生过调度→还活着
    t->last_switch_count = switch_count;
    t->last_switch_time = jiffies;
    return false;
}
if (time_is_after_jiffies(t->last_switch_time + timeout * HZ))
    return false;                    // 还没超时
return true;
```

关键思路：**看上下文切换计数 `last_switch_count` 有没有变**。一个 D 状态任务如果在这段时间内一次都没被调度过（`switch_count` 没变），且超过 `timeout * HZ` 个 jiffies，就算卡死。注意它特意跳过 `TASK_KILLABLE`（带 `TASK_WAKEKILL`/`TASK_NOLOAD`）和 `TASK_FROZEN`——这些状态本来就该长时间睡，不是故障。

### 报告与升级：`check_hung_task()`

判定卡死后，`check_hung_task()` 打出那条标志性的 `INFO: task %s:%d blocked for more than %ld seconds.`，调 `sched_show_task(t)` 吐栈。`sysctl_hung_task_warnings` 默认 10，报满 10 次就闭嘴（设 `-1` 可无限报，避免持续性死锁后期日志被吞）。若 `sysctl_hung_task_panic` 被设上，`check_hung_uninterruptible_tasks()` 末尾直接 `panic("hung_task: blocked tasks")`——这就是"警告升级为处决"，HA 集群常用。

### 关键 sysctl（都在 `hung_task_sysctls` 表里注册到 `/proc/sys/kernel/`）

- `hung_task_timeout_secs`：判定阈值，默认 120，设 0 关闭。
- `hung_task_warnings`：最多报几次，默认 10，`-1` 无限。
- `hung_task_panic`：是否升级成 panic，默认 0。
- `hung_task_check_count`：一次最多扫几个任务（性能优化），初值取自 `PID_MAX_LIMIT`——64 位上约 420 万（`4 * 1024 * 1024`），`CONFIG_BASE_SMALL` 或 32 位平台上这个值会小得多（量级到几万）。
- `hung_task_all_cpu_backtrace`：设 1 则向所有 CPU 发 NMI 拍栈，帮你找出谁占着锁不放。

## Lockup：CPU 还在转但逻辑卡死

Hung Task 是"任务睡死"，lockup 是"CPU 疯跑不调度"。分两种：

**Soft Lockup**：任务在内核态死循环，霸占 CPU 不让调度器插手，但**中断还开着**。官方文档把阈值定义为内核态连续跑超过 20 秒——正好是 `watchdog_thresh`（默认 10）的两倍。检测代码在 `kernel/watchdog.c` 的 `watchdog_timer_fn()`，靠一个 hrtimer（周期 `2*watchdog_thresh/5`，默认 4 秒）驱动计时。

**Hard Lockup**：任务不仅死循环，还**关了中断**（典型场景：持着 `spin_lock_irqsave()` 死循环）。此时普通时钟中断都进不来，hrtimer 那套失灵。怎么检测？靠 **NMI（不可屏蔽中断）**——NMI 的定义就是"中断关了我也照样进来"，它利用硬件性能计数器周期性检查 CPU 是否还活着。这就是为什么 hard lockup 检测依赖 NMI watchdog，且**虚拟机通常没这东西**（`kernel.nmi_watchdog = 0`）。没有 NMI perf event 的平台还有个备选的 **buddy 检测器**：每个 CPU 让另一个 CPU 当"伙伴"代为盯梢，连续 3 个 hrtimer 周期没等到心跳就算死锁——代价是若所有 CPU 一起锁住它也发现不了。默认阈值 10 秒。

相关 sysctl：`watchdog_thresh`（阈值）、`softlockup_panic` / `hardlockup_panic`（是否升级 panic）、`softlockup_all_cpu_backtrace` / `hardlockup_all_cpu_backtrace`（全场拍栈）。

RCU 也有类似的 **RCU CPU Stall**——一个宽限期迟迟过不去就报警。这里有个常被笔记记错的点：单次检查周期默认 `CONFIG_RCU_CPU_STALL_TIMEOUT` 是 **21 秒**（`kernel/rcu/Kconfig.debug`，range 3..300），不是 60 秒；首个 stall 警告大约在宽限期超过 21 秒后就吐出来（`record_gp_stall_check_time()` 设的 `jiffies_stall`），而**后续**每轮重复警告的间隔才是 `3 * rcu_jiffies_till_stall_check()`（约 63 秒，`kernel/rcu/tree_stall.h`）。别把"60 秒"挂在 CONFIG 名下。

## 升级开关：oops/warn 什么时候变 panic

`panic.c` 里几个全局变量就是这些开关，都通过 `kern_panic_table` 注册成 sysctl，也可走启动参数：

- **`panic_on_oops`**（默认取 `CONFIG_PANIC_ON_OOPS`）：设 1 则任何 oops 直接升级 panic。关键业务系统常用（宁可死也不许带病跑）。
- **`panic_on_warn`**：设 1 则任何 `WARN_ON()` 都变 panic。开发期抓隐患利器，但慎用。`check_panic_on_warn()` 里还会看 `warn_limit`——累计警告次数（`warn_count`）超过 `warn_limit` 也 panic。
- **`panic_timeout`**（`/proc/sys/kernel/panic`，启动参数 `panic=N`）：panic 后 N 秒自动重启，`0` 表示永远挂起。嵌入式无人值守设备常用。
- **`panic_print`**（位掩码）：控制 panic 时额外打印什么。注意 6.19 里它已标记 **deprecated**，设它会吐一行 `pr_info_once` 提示改用 `panic_sys_info` 和 `panic_console_replay`。

一行魔法的 SysRq 崩溃触发（配合 `panic_on_oops`），笔记里实测过：

```bash
echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/sysrq
echo c > /proc/sysrq-trigger     # c = 强制崩溃（crashdump，若配置了的话）
```

## 动手验证（待亲测）

QEMU 上我们要验三件事，命令输出都待亲测核对：

1. **制造 panic 看 `vpanic()` 流程**：写个 `letspanic` 模块，`init` 里直接 `panic("...")`。配合 `netconsole` 把日志发到宿主机（系统僵死时本地控制台刷不出来），核对 `Kernel panic - not syncing:` / `---[ end Kernel panic ]---` 两行，以及 `dump_stack` 输出。
2. **自定义 panic handler**：写模块定义 `struct notifier_block`，`init` 里 `atomic_notifier_chain_register(&panic_notifier_list, &nb)`，回调里 `pr_emerg` 打一条标记。先 insmod handler 模块，再触发 SysRq 崩溃，在 netconsole 里核对我们的回调确实在 `panic_notifier_list` 链上被调到了。注意 LICENSE 必须 `GPL`。
3. **自旋锁死锁看 hung task 报告**：写内核线程持 `spin_lock_irqsave()` 死循环（先留至少一个核维持响应）。把 `hung_task_timeout_secs` 调到 10（缩短等待），核对 `INFO: task ... blocked for more than ... seconds.` 和 `sched_show_task` 的栈。再试 `echo 1 > /proc/sys/kernel/hung_task_all_cpu_backtrace`，看所有 CPU 的 NMI 栈回溯。

## 小结

内核的"死法"分两类：**真死**（panic，`panic()` 走完临终流程进死循环）和**假死**（lockup / hung task，CPU 或任务卡住但系统还在）。整套检测体系的核心数据结构和函数都钉在源码里：`panic_notifier_list` 通知器链 + `notifier_block` 挂钩、`khungtaskd` 线程 + `task_is_hung()` 的 `last_switch_count` 判定、`watchdog_timer_fn()` 的 hrtimer + NMI 双保险。`panic_on_oops` / `panic_on_warn` / `*_panic` 这组开关决定"警告升不升级成处决"，`*_timeout_secs` 决定"等多久才报警"。把这些机制读穿，你下次看到黑屏或假死，就知道是该翻 `khungtaskd` 的报告、还是 NMI 的栈、还是 panic 的遗言。

## 延伸阅读

- 源码：`kernel/panic.c`（Linux 6.19），`vpanic()` / `panic_notifier_list` / `kern_panic_table`；`kernel/hung_task.c`，`watchdog()` / `task_is_hung()` / `check_hung_task()`；`kernel/watchdog.c`，`watchdog_timer_fn()`（soft/hard lockup，hrtimer 周期 `2*watchdog_thresh/5`）；`kernel/rcu/tree_stall.h`，`rcu_jiffies_till_stall_check()`（默认 21 秒、后续 3×≈63 秒）；`include/linux/panic.h`、`include/linux/notifier.h`（`notifier_block`）。
- kernel.org 文档：[kernel.org admin-guide sysctl/kernel](https://docs.kernel.org/admin-guide/sysctl/kernel.html)（`panic` / `hung_*` / `watchdog_*` 各项）、[Magic SysRq key](https://docs.kernel.org/admin-guide/sysrq.html)、[Softlockup / hardlockup detector (aka nmi_watchdog)](https://docs.kernel.org/admin-guide/lockup-watchdogs.html)。
- 笔记：`document/notes/linux_kernel_debugging/ch10_*.md`（panic 流程、自定义 handler、lockup、hung task 四节）。
