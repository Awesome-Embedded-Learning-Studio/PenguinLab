---
title: printk：内核调试的生命线
slug: debug-printk
difficulty: intermediate
tags: [printk, 日志系统, 调试, 动态调试]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related: []
sources:
  - notes: document/notes/linux_kernel_debugging/ch03.md
  - notes: document/notes/linux_kernel_debugging/ch03_2.md
  - notes: document/notes/linux_kernel_debugging/ch03_3.md
  - notes: document/notes/linux_kernel_debugging/ch03_4.md
  - notes: document/notes/linux_kernel_debugging/ch03_5.md
---

# printk：内核调试的生命线

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解，关键函数 / 数据结构 / 字段名都已核对过（`kernel/printk/printk.c`、`include/linux/printk.h`、`kernel/printk/printk_ringbuffer.h`、`include/linux/kern_levels.h`）；具体行号、命令输出和 dmesg 样例还没拿到 QEMU 上亲测，标了「待亲测」的就是这个意思。

## 为什么内核调试离不开 printk

在用户空间，我们想看程序跑到哪了，随手一个 `printf`。但进了内核，这条路断了——**内核里没有 `printf`，也没有 libc**。内核不按用户空间那一套去链接库（不管动态还是静态），它的 `lib/` 目录里那些 API 是直接编译进内核镜像的。

那想确认一个变量、想看代码走到哪一步怎么办？唯一的笨办法就是**插桩**——在代码里埋打印，看输出。而内核里干这件事的瑞士军刀，就是 `printk()`。

它能在几乎所有上下文里安然工作：硬中断、软中断、tasklet、普通进程上下文，甚至持着自旋锁的临界区。这背后是一套精心设计的无锁环形缓冲区，待会深挖。先把它的签名看一眼，跟 `printf` 几乎一模一样：

```c
// include/linux/printk.h
asmlinkage __printf(1, 2) __cold
int _printk(const char *fmt, ...);
```

`printk` 本身是个宏，`#define printk(fmt, ...) printk_index_wrap(_printk, fmt, ##__VA_ARGS__)`，真正干活的实体是 `_printk`（Linux 6.19）。它的实现躺在 `kernel/printk/printk.c`，最终经 `vprintk_default()` → `vprintk_emit()` → `vprintk_store()` 把消息塞进环形缓冲区。

## 八级 loglevel：给消息定个轻重缓急

`printk` 和 `printf` 最显眼的差别，是格式字符串开头要带一个**日志级别**前缀：

```c
printk(KERN_INFO "Hello, kernel debug world\n");
```

注意，`KERN_INFO` 不是第二个参数——C 的字符串拼接把它和后面的字面量合并成了同一个 `fmt`。它本质上是个标记，定义在 `include/linux/kern_levels.h`：

```c
// include/linux/kern_levels.h
#define KERN_SOH       "\001"   /* ASCII Start Of Header */
#define KERN_EMERG     KERN_SOH "0"   /* system is unusable */
#define KERN_ALERT     KERN_SOH "1"   /* action must be taken immediately */
#define KERN_CRIT      KERN_SOH "2"   /* critical conditions */
#define KERN_ERR       KERN_SOH "3"   /* error conditions */
#define KERN_WARNING   KERN_SOH "4"   /* warning conditions */
#define KERN_NOTICE    KERN_SOH "5"   /* normal but significant condition */
#define KERN_INFO      KERN_SOH "6"   /* informational */
#define KERN_DEBUG     KERN_SOH "7"   /* debug-level messages */
```

说白了，`KERN_<FOO>` 就是字符串 `"0"`~`"7"` 前面拼一个值为 `\001` 的控制字符（SOH）。同文件里还有对应的整型宏 `LOGLEVEL_EMERG`(0) … `LOGLEVEL_DEBUG`(7)，后面在模块里打印数字时会用到。

### console_loglevel 决定哪些上控制台

关键问题：一条消息会**同时**刷到屏幕上吗？取决于 **console_loglevel**。在 `kernel/printk/printk.c` 顶部有一个数组：

```c
// kernel/printk/printk.c
int console_printk[4] = {
	CONSOLE_LOGLEVEL_DEFAULT,  /* console_loglevel        */
	MESSAGE_LOGLEVEL_DEFAULT,  /* default_message_loglevel*/
	CONSOLE_LOGLEVEL_MIN,      /* minimum_console_loglevel*/
	CONSOLE_LOGLEVEL_DEFAULT,  /* default_console_loglevel*/
};
```

然后 `include/linux/printk.h` 把这四个槽位起了别号，便于按名字访问：

```c
// include/linux/printk.h
extern int console_printk[];
#define console_loglevel          (console_printk[0])
#define default_message_loglevel  (console_printk[1])
#define minimum_console_loglevel  (console_printk[2])
#define default_console_loglevel  (console_printk[3])
```

判断一条消息要不要屏蔽出控制台，源码就一行（`kernel/printk/printk.c` 的 `suppress_message_printing()`）：

```c
return (level >= console_loglevel && !ignore_loglevel);
```

——级别数值**大于等于** `console_loglevel` 的（也就是更不紧急的）就被压在缓冲区里不上屏。`console_loglevel` 默认通常配成 7（`CONSOLE_LOGLEVEL_DEFAULT` 来自 `CONFIG_CONSOLE_LOGLEVEL_DEFAULT`），意思是默认连 `KERN_DEBUG` 都上控制台；但很多发行版会调低，实际只放 `<=` 某个值的。`/proc/sys/kernel/printk` 里那四个数字，就对应 `console_printk[]` 这四个槽位（待亲测核对）：

```
$ cat /proc/sys/kernel/printk
4    4    1    7
```

想临时全开调试，就 `echo 8 > /proc/sys/kernel/printk`（8 大于任何 0~7 的级别，于是全放行）。但这通常是坏主意——内核里 DEBUG 级日志浩如烟海，瞬间刷屏。

## 偷懒封装：pr_* 和 pr_fmt

每次写 `printk(KERN_INFO "...")` 太啰嗦，内核给了一套封装宏（`include/linux/printk.h`），优先用它们。八级 loglevel 正好对应八个 `pr_` 档位，外加一个不换行的 `pr_cont`：

```c
// include/linux/printk.h
#define pr_emerg(fmt, ...)   printk(KERN_EMERG   pr_fmt(fmt), ##__VA_ARGS__)
#define pr_alert(fmt, ...)   printk(KERN_ALERT   pr_fmt(fmt), ##__VA_ARGS__)
#define pr_crit(fmt, ...)    printk(KERN_CRIT    pr_fmt(fmt), ##__VA_ARGS__)
#define pr_err(fmt, ...)     printk(KERN_ERR     pr_fmt(fmt), ##__VA_ARGS__)
#define pr_warn(fmt, ...)    printk(KERN_WARNING pr_fmt(fmt), ##__VA_ARGS__)
#define pr_notice(fmt, ...)  printk(KERN_NOTICE  pr_fmt(fmt), ##__VA_ARGS__)
#define pr_info(fmt, ...)    printk(KERN_INFO    pr_fmt(fmt), ##__VA_ARGS__)
#define pr_cont(fmt, ...)    printk(KERN_CONT    fmt, ##__VA_ARGS__)
```

`pr_debug` 和 `pr_devel` 另有讲究（一个挂动态调试、一个直接编译消除），留到后文「动态调试」一节细讲。注意每个宏里都套了一层 `pr_fmt(fmt)`。`pr_fmt` 是个"元宏"，头文件里默认定义成 `#define pr_fmt(fmt) fmt`（透传）。但只要你在源文件**第一行非注释处**重新定义它，后续所有 `pr_*` 都会被自动套上前缀：

```c
#define pr_fmt(fmt) "%s:%s():%d: " fmt, KBUILD_MODNAME, __func__, __LINE__
```

这一招让每条日志自动带上 `模块名:函数名:行号:`，多模块同时刷日志时能一眼分清谁在说话，调试时救命。另外 `pr_cont()` 是个特殊家伙，它不带换行、把内容**追加**到上一条 `printk` 末尾，用来拼多段式日志。

### dev_dbg：写驱动的首选

如果写的是设备驱动，规则要升级——别用 `pr_debug`，用 `dev_dbg`。它的第一个参数是 `struct device *`，能自动把设备名、总线信息塞进日志，多个同类设备并存时是救命稻草。配套的有整套 `dev_emerg / dev_err / dev_warn / dev_notice / dev_info / dev_dbg`。更妙的是 `dev_dbg` 和 `pr_debug` 一样，背后挂着动态调试（见后文）。这条设备上下文元数据在 ringbuffer 里其实有专门位置承载，待会讲 `printk_info` 时会点名。

## 消息去向三处

发出去的字符到底流落何处？和用户空间 `printf` 直接到 `stdout` 不同，内核这套"下水道"分三层：

| 去向 | 说明 | 怎么看 |
|:---|:---|:---|
| **内核环形缓冲区** | 所有 `printk` 的第一站，内存里固定大小的循环队列 | `dmesg`、`/proc/kmsg`、`/dev/kmsg` |
| **控制台** | 级别足够紧急（数值 ≤ `console_loglevel`）时直接刷屏 | 屏幕 / 串口直接看 |
| **持久化日志** | systemd-journald 等守护进程从缓冲区读走落盘 | `/var/log/syslog`（Debian 系）、`journalctl` |

第一站永远是环形缓冲区——这意味着日志先暂存在内存里，**重启就丢**（除非 `pstore` 持久化）。`dmesg` 读的就是这个缓冲区。

## ring buffer 机制深挖：lockless 设计

这是 `printk` 之所以能在任何上下文安全工作的根。早期内核的环形缓冲区是带自旋锁的 `log_buf`，NMI / 持锁路径里打印有死锁风险；Linux 5.10 起换成了一套**无锁（lockless）环形缓冲区**，核心数据结构定义在 `kernel/printk/printk_ringbuffer.h`（Linux 6.19）。

它把"元数据"和"正文"分成两个独立的环：

```c
// kernel/printk/printk_ringbuffer.h
struct printk_ringbuffer {
	struct prb_desc_ring	desc_ring;    /* 描述符环 */
	struct prb_data_ring	text_data_ring; /* 正文数据环 */
	atomic_long_t		fail;
};
```

每条记录的元数据用一个**描述符** `struct prb_desc` 表示，状态用原子变量 `state_var` 编码（同时塞进了描述符 ID 和状态：`desc_miss / desc_reserved / desc_committed / desc_finalized / desc_reusable`）；正文指针存在 `text_blk_lpos` 里：

```c
struct prb_desc {
	atomic_long_t			state_var;
	struct prb_data_blk_lpos	text_blk_lpos;
};
```

描述符配套的 `struct printk_info` 存这条记录的"身份证"——序列号 `seq`、纳秒时间戳 `ts_nsec`、文本长度 `text_len`、`facility`、`level`（只有 3 bit！）、`caller_id`（线程或 CPU 标识），末尾还有一个 `dev_info`：

```c
struct printk_info {
	u64	seq;		/* sequence number */
	u64	ts_nsec;	/* timestamp in nanoseconds */
	u16	text_len;	/* length of text message */
	u8	facility;	/* syslog facility */
	u8	flags:5;	/* internal record flags */
	u8	level:3;	/* syslog level */
	u32	caller_id;	/* thread id or processor id */

	struct dev_printk_info	dev_info;
};
```

这里的 `dev_info`（`struct dev_printk_info`）专门装 `dev_dbg()` 那套设备上下文元数据——前面强调写驱动首选 `dev_dbg` 能自动带设备信息，底座就藏在这儿：`dev_*` 打印时把设备信息填进 `dev_info`，落进 ringbuffer 跟着记录一起存。两个数据环用 `head_lpos`/`tail_lpos`（正文）和 `head_id`/`tail_id`（描述符）做无锁推进，全是 `atomic_long_t`。写入流程在 `vprintk_store()` 里：先 `printk_enter_irqsave()` 防递归、`local_clock()` 取时间戳、`printk_parse_prefix()` 把字符串里的 `\001N` 解析成整数 `level`，然后 `prb_reserve()` 在环里**预留**一块槽位，写完正文再 `prb_commit()` 把描述符状态推进到 committed/finalized。

### 序列号：读者排序的锚

每条记录有一个单调递增的 `u64 seq`。读者（`dmesg`、journald）就靠 `seq` 排序、判断"我读到哪了""有没有丢消息"。由于是环形，旧记录会被覆盖——但 `seq` 一直涨，所以读者能精确知道中间被冲掉了哪几条，而不是被糊弄过去。描述符环的初始化有专门的 bootstrap 技巧（`last_finalized_seq`、`DESC0_ID` 等），保证第一时刻读者也看得见合法状态。

## 为什么中断/原子上下文也能用 printk

答案就在上面这套无锁设计里。写入路径走的是原子操作（`atomic_long_t` 的 CAS）加上一把**可重入的 CPU 级自旋锁**（`printk_cpu_sync_get_irqsave()`，见 `include/linux/printk.h`），它在**同一个 CPU 上可重入**——所以 NMI 里再次进入 `printk` 不会死锁。真正可能阻塞的"刷到物理控制台"那一步，被**推迟**了：`vprintk_emit()` 只负责把消息存进 ringbuffer，然后把"有活要干"的信号（`wake_up_klogd()` / `defer_console_output()`）丢给专门的 kthread / irq work 去慢慢刷。于是中断里调 `printk` 只是往内存里写几个字节，绝不让 CPU 停下来等串口（旧内核那套 console_lock 直接打印会把系统拖死的坑，就是这么绕开的）。

> 顺带一提：还有 `_printk_deferred()`（`include/linux/printk.h` 里声明、`kernel/printk/printk.c` 实现）专给调度器等"连唤醒都不方便"的路径用，它连 console 唤醒都延后，由 irq work 兜底。

## 限速 ratelimit：防炸屏

在高频路径（中断、定时器回调）里裸跑 `printk` 会出三件事：缓冲区瞬间被冲满、旧日志被覆盖、CPU 全力以赴在吐串口导致**活锁**。内核的对策是限速。核心是 `__ratelimit()`，配套宏 `printk_ratelimited()`（`include/linux/printk.h`）：

```c
#define printk_ratelimited(fmt, ...)                       \
({                                                          \
	static DEFINE_RATELIMIT_STATE(_rs,                      \
		DEFAULT_RATELIMIT_INTERVAL,                         \
		DEFAULT_RATELIMIT_BURST);                           \
	if (__ratelimit(&_rs))                                   \
		printk(fmt, ##__VA_ARGS__);                          \
})
```

两个默认值（`include/linux/ratelimit_types.h`）：`DEFAULT_RATELIMIT_INTERVAL` = `5 * HZ`（5 秒窗口），`DEFAULT_RATELIMIT_BURST` = 10（窗口内允许 10 条突发）。也就是**5 秒内最多放 10 条，多出来的全部丢弃**。

超量时 `__ratelimit` 会顺手打一句抑制提示，告诉你吞了多少。注意这句提示在 6.19 下的长相：`lib/ratelimit.c` 里是 `printk_deferred(KERN_WARNING "%s: %d callbacks suppressed\n", func, m)`，而 `func` 来自 `include/linux/ratelimit_types.h` 的 `#define __ratelimit(state) ___ratelimit(state, __func__)`——它解析成**调用者的函数名**。所以如果你的模块 init 函数叫 `ratelimit_test_init`，抑制信息就是 `ratelimit_test_init: 40 callbacks suppressed` 这样。笔记里那种 `kernel: __ratelimit: 40 callbacks suppressed` 是旧内核的写法（当时前缀固定成 `__ratelimit`），6.19 起改成了调用者函数名。

封装好的 `pr_info_ratelimited / pr_err_ratelimited / dev_err_ratelimited` 等都应该直接用；头文件里明确警告**别用共享状态的 `printk_ratelimit()`**（它所有调用点共用一个 ratelimit 状态，会互相干扰），每个 `_ratelimited` 宏各自 `static DEFINE_RATELIMIT_STATE`，互不干扰。

阈值还能在运行时调：`/proc/sys/kernel/printk_ratelimit`（窗口，秒）和 `/proc/sys/kernel/printk_ratelimit_burst`（突发条数）。真要更狠地高频打印，就该换 `trace_printk()`——它只写 trace buffer、不走 console，开销几乎为零（ftrace 篇再细讲）。

## 动态调试 dynamic-debug

`pr_debug()` 平时有个尴尬：它要么受 `DEBUG` 宏控制（编译时开关，开了铺天盖地、关了彻底静默），要么……能不能**运行时**开关任意一行？能。这就是 Dynamic Debug。

前提是内核开了 `CONFIG_DYNAMIC_DEBUG`。看 `pr_debug` 的三态定义（`include/linux/printk.h`）：开了 `CONFIG_DYNAMIC_DEBUG`，`pr_debug` 就被重定向成 `dynamic_pr_debug()`；否则看 `DEBUG`，再否则 `no_printk`（编译期消除）：

```c
#if defined(CONFIG_DYNAMIC_DEBUG) || \
    (defined(CONFIG_DYNAMIC_DEBUG_CORE) && defined(DYNAMIC_DEBUG_MODULE))
#define pr_debug(fmt, ...)  dynamic_pr_debug(fmt, ##__VA_ARGS__)
#elif defined(DEBUG)
#define pr_debug(fmt, ...)  printk(KERN_DEBUG pr_fmt(fmt), ##__VA_ARGS__)
#else
#define pr_debug(fmt, ...)  no_printk(KERN_DEBUG pr_fmt(fmt), ##__VA_ARGS__)
#endif
```

`dynamic_pr_debug` 背后每个打印点都被编译进一个 `struct _ddebug` 描述符，里头有个 `flags` 位域。决定要不要真打印的就一位 `_DPRINTK_FLAGS_PRINT (1<<0)`（`include/linux/dynamic_debug.h`），用 `DYNAMIC_DEBUG_BRANCH(descriptor)` 做分支预测：

```c
#define _DPRINTK_FLAGS_PRINT  (1<<0) /* printk() a message using the format */
// ...
likely(descriptor.flags & _DPRINTK_FLAGS_PRINT)
```

控制文件内核会**同时**创建两份：一份在 debugfs（`/sys/kernel/debug/dynamic_debug/control`，需要 debugfs 已挂载才能访问），一份在 procfs（`/proc/dynamic_debug/control`，始终可用）——`lib/dynamic_debug.c` 的 `dynamic_debug_init_control()` 里两条路径是各自独立建的，procfs 那份并不是"debugfs 没挂才落到"的备胎。生产环境要是没挂 debugfs，直接用 `/proc/dynamic_debug/control` 即可。

控制文件列出**所有**动态调试打印点，每行格式 `filename:lineno [module]function flags format`，`flags` 默认是 `=_`（全关）。往里 echo 命令就能改：

```bash
# 打开 miscdrv_rdwr 模块所有打印
echo -n "module miscdrv_rdwr +p" > /proc/dynamic_debug/control
```

flags 字母表（日常调试用 `p/f/l/m/t` 这五个就够了，6.19 还多了 `s`、`d` 等更细的标记）：`p`(print 开)、`f`(函数名)、`l`(行号)、`m`(模块名)、`t`(线程 ID)、`s`(源文件名，`_DPRINTK_FLAGS_INCL_SOURCENAME`，6.19 新增)、`d`(调用栈，`_DPRINTK_FLAGS_INCL_STACK`，6.19 新增)；操作符 `=`(设)、`+`(加)、`-`(去)。match spec 还有 `file`/`func`/`line`/`format`，多个之间是与关系：

```bash
# 只开 snd 驱动里、函数名含 ctl、行号 <600 的点
echo -n "module snd func *ctl* line 1-600 +p" > /proc/dynamic_debug/control
```

调试启动早期阶段（initcall）则不能事后写控制文件，得在 cmdline 里预先塞 `dyndbg="file drivers/usb/* +pflmt"`，或 modprobe 配置里 `options mydriver dyndbg=+pmflt`。配套的救命 boot 参数还有 `ignore_loglevel`（无视级别全吐）、`initcall_debug`（打印每个 initcall 的耗时和返回值，查启动卡死神器）。

## 动手试试

> 以下是验证方案，等在 QEMU ARM64 上实跑后填真实输出。

- 写一个内核模块，init 函数里依次 `pr_emerg`…`pr_debug` 各打一条，配 `pr_fmt` 自动加 `模块名:函数名:行号` 前缀；`insmod` 后 `dmesg` 观察各级别，确认 `KERN_DEBUG` 默认是否上屏、改 `console_loglevel` 后是否变化（待亲测核对）。
- `cat /proc/sys/kernel/printk` 记下四个数字，对照本文 `console_printk[4]` 的含义；`echo 8 > /proc/sys/kernel/printk` 后再 `insmod`，看 DEBUG 是否冒出来（待亲测）。
- 写一个限速模块，循环里 `pr_info_ratelimited` 打 60 条，观察末尾的抑制信息（默认 5 秒 / 10 条突发）。在 6.19 下这条信息形如 `<调用者函数名>: N callbacks suppressed`，不是笔记里那种 `__ratelimit: ...` 前缀——具体函数名和被吞条数待亲测核对。
- 若内核开了 `CONFIG_DYNAMIC_DEBUG`：`grep 自己模块 /proc/dynamic_debug/control` 看到打印点，`echo -n "module xxx +p"` 开启后触发设备操作，对比开关前后 `dmesg`（待亲测）。

## 小结

`printk` 之所以是内核调试的生命线，不是因为它"像 `printf`"，而是因为它背后有一套**无锁环形缓冲区**（`printk_ringbuffer`：`desc_ring` 管元数据、`text_data_ring` 管正文，原子操作 + CPU 级可重入锁推进 `head/tail`），才让它在中断、NMI、持锁上下文都能安全地往内存里塞一条带 `seq` 序列号的记录。日志流向三层：环形缓冲区（`dmesg` 看）→ 控制台（`console_loglevel` 卡阈值，判定就一行 `level >= console_loglevel`）→ 持久化（journald 落盘）。

工程纪律就四条：用 `pr_*` / `dev_*` 封装别裸 `printk`；`pr_fmt` 统一前缀；高频路径用 `_ratelimited`（默认 5 秒 10 条，6.19 抑制信息前缀是调用者函数名）或干脆 `trace_printk`；要运行时按需开关就走 Dynamic Debug（`/proc/dynamic_debug/control` + `+p` flags）。

## 延伸阅读

- 源码（Linux 6.19）：`kernel/printk/printk.c`（`printk` 主战场，`vprintk_store` / `vprintk_emit` / `console_printk[]`）、`kernel/printk/printk_ringbuffer.h`（lockless 环形缓冲数据结构、`struct printk_info` 含 `dev_info`）、`include/linux/printk.h`（`pr_*` 封装、`pr_fmt`、ratelimit 宏）、`include/linux/kern_levels.h`（八级 `KERN_*` / `LOGLEVEL_*`）、`lib/ratelimit.c`（`___ratelimit` 及 `%s: %d callbacks suppressed` 抑制提示）、`include/linux/ratelimit_types.h`（`__ratelimit` 宏解析 `__func__`、默认窗口/突发值）、`include/linux/dynamic_debug.h`（动态调试 flags，6.19 含 `s`/`d`）、`lib/dynamic_debug.c`（控制文件解析、debugfs+procfs 双创建）。
- docs.kernel.org：[Dynamic Debug](https://docs.kernel.org/admin-guide/dynamic-debug-howto.html)、[printk formats（格式说明符全集）](https://docs.kernel.org/core-api/printk-formats.html)、[kernel parameters](https://docs.kernel.org/admin-guide/kernel-parameters.html)（`ignore_loglevel` / `dyndbg` / `initcall_debug`）。