---
title: ftrace：内核的瑞士军刀追踪器
slug: debug-ftrace
difficulty: intermediate
tags: [ftrace, 动态追踪, ring buffer, tracepoint]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/debugging/02-debug-kprobes
sources:
  - notes: document/notes/linux_kernel_debugging/ch09.md
---

# ftrace：内核的瑞士军刀追踪器

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 为什么需要 ftrace：静态插桩扛不住

写内核模块的人第一反应都是 `printk`。它能干活，但干不了精细活——你把日志埋进代码、重新编译、重启内核，结果发现"现在想看的是另一个函数"，又得重来一轮。更要命的是 `printk` 走控制台，慢，慢到会**扰动你正在观测的时序**，海森堡 Bug 就这么来了：你看它，它就变样。

我们真正想要的是一台**不重新编译、想看哪看哪、几乎零开销**的内核内窥镜。ftrace 就是这台内窥镜。名字里的 `f` 当年代表 `function`（它最早就是为追踪函数调用图生的），今天它已经长成了一个通用追踪引擎，既能看函数调用，也能看内核预埋的事件，还能测延迟、抓栈深、给 panic 留遗嘱。

## 两大支柱：function tracer + trace events

先把骨架立起来。ftrace 有两根承重柱，看到的内核是两个不同的切面：

- **function tracer**：盯着**函数**。普通 `function` 档位只记**入口**——每个内核函数被调用的瞬间记一行，带上"是谁调的我"（`parent_ip`），平铺成一张列表。视角像"路边盯梢，谁路过记一笔，但只记进门、不记出门，也不画谁叫谁的关系"。想要看出口、画缩进调用图，那是 `function_graph` 档位独门的活，下面单独说。
- **trace events**：盯着**事件**。内核开发者已经在关键节点埋了 tracepoint（比如调度切换、中断进出、系统调用），ftrace 把这些点暴露成事件供你开关。视角像"高速公路上的感应线圈，车一过就抓拍，还带参数值"。

两根柱子共享同一套基础设施：`tracefs`（挂在 `/sys/kernel/tracing`，4.1 起的标准路径，独立于 `debugfs`，生产环境禁了 debugfs 也能用）和它自己的 ring buffer。

> 顺带提一句 `function_graph`：它比普通 `function` 多挂了一对 **entry + return** 钩子（`register_ftrace_graph()`，`kernel/trace/trace_functions_graph.c`），所以能在函数进入时缩进、退出时反缩进，画出真正的调用关系树。普通 `function`（`kernel/trace/trace_functions.c` 的 `function_trace`，`.name = "function"`）只有一个入口回调 `function_trace_call()`，不挂 return，**看不到出口、没有缩进**。把这两者搞混是最常见的入门坑。

## function tracer 原理：编译器埋点 + 运行时打补丁

这是 ftrace 最骚的设计，值得展开讲。

编译内核时，编译器（gcc/clang 的 `-pg`，或 `-mfentry`）会给**每个**函数入口插一条调用指令——历史上叫 `mcount`，现代叫 `fentry`。如果就这么留着，每次函数调用都跳进追踪代码，内核直接慢成蜗牛。所以内核干了一件相当疯狂的事：**运行时改写自己的机器码**，这就是 `CONFIG_DYNAMIC_FTRACE`（动态 ftrace）。

启动早期，`ftrace_init()`（`kernel/trace/ftrace.c`，Linux 6.19）拿到链接器收集好的所有插桩地址表 `__start_mcount_loc[]` ~ `__stop_mcount_loc[]`，交给 `ftrace_process_locs()` 给每个地址建一条记录 `struct dyn_ftrace { unsigned long ip; unsigned long flags; struct dyn_arch_ftrace arch; }`（`include/linux/ftrace.h:757`，`ip` 就是那个 mcount 调用点的地址）。然后关键的一步：把这些调用点**全部改成 `nop`**。从此不追踪时，每个函数入口多一条空指令，开销接近零。

当你 `echo function > current_tracer`，内核要反向把"被选中"的函数入口从 `nop` 改回"跳到 tracer"。这条流水线在 `ftrace_modify_all_code()` → `ftrace_replace_code()`（`kernel/trace/ftrace.c`）里，对每条 `dyn_ftrace` 记录调 `__ftrace_replace_code()`（`ftrace.c:2719`）：

```c
case FTRACE_UPDATE_MAKE_CALL:
    ftrace_bug_type = FTRACE_BUG_CALL;
    return ftrace_make_call(rec, ftrace_addr);
case FTRACE_UPDATE_MAKE_NOP:
    ftrace_bug_type = FTRACE_BUG_NOP;
    return ftrace_make_nop(NULL, rec, ftrace_old_addr);
```

`ftrace_make_call/make_nop` 是**架构相关**的（x86 在 `arch/x86/kernel/ftrace.c`，arm64 在 `arch/arm64/kernel/ftrace.c`），干的就是往 `rec->ip` 那几个字节写指令。判断"这个函数要不要改"靠的是过滤哈希：`struct ftrace_ops` 里挂着 `struct ftrace_ops_hash { filter_hash; notrace_hash; }`（`include/linux/ftrace.h`），`set_ftrace_filter` 写进去的函数名最终落到 `filter_hash` 里，`__ftrace_hash_rec_update()` 据此更新每条记录的引用计数。

> 选 tracer 的入口是 `tracing_set_tracer()`（`kernel/trace/trace.c:215`），写 `current_tracer` 时触发。所以 `echo function_graph > current_tracer` 不是"换了个开关"，而是触发了全系统范围的机器码改写——这就是为什么它"听话且急躁"：一写就开始。

## trace events：tracepoint 是地基

function tracer 看的是"函数被调了"，但你不知道**传入的参数是多少**。要看参数，得用事件。

事件的地基是 **tracepoint**——开发者在内核源码里用 `TRACE_EVENT()` 宏静态埋下的点（比如 `include/trace/events/sched.h` 里的 `sched_switch`）。tracepoint 本身只是基础设施，默认几乎零开销（基于 jump_label）。ftrace 把它"激活"成一个可记录的事件：你在 `/sys/kernel/tracing/events/` 下能看到所有事件，按子系统分目录（`sched/`、`net/`、`irq/`……）。

这里要分清两根柱子各自的"开关"和"过滤"，别把它们混成一回事：

- **`set_ftrace_filter` 是 function tracer 的过滤**：配合 `current_tracer=function` / `function_graph` 用，控制"盯哪些函数"。可以 Glob 匹配（`echo 'tcp_*' > set_ftrace_filter`），也可以写索引号（`grep -n tcp available_filter_functions`）省掉字符串匹配开销。它**不会开启事件**——它只在 function tracer 已经生效时，缩小被记录的函数范围。
- **`set_event` 是 tracepoint 事件的开关**：控制"记录哪些事件"。`echo 'net:* sock:* syscalls:*' > set_event` 一次开一整个子系统的事件。这跟 `set_ftrace_filter` 服务的是完全不同的两根柱子（函数 vs 事件），别把两者并称为"开启事件的两种方式"。

事件视角的代价和收益在 ch09 笔记里讲得很直白：**失去** function_graph 那种缩进调用图（调用栈被拍扁），**得到**每一行的参数值（buffer 指针、标志位、PID）。调试"为什么参数错了导致丢包"时，参数值比调用图更致命。

> 补一句呼应 `02-debug-kprobes`：kprobe/uprobe 动态打出来的事件也能挂进同一个 `events/` 框架（`events/kprobes/`、`events/uprobes/`），和静态 tracepoint 事件走同一套 ring buffer 和 trigger 机制。所以 kprobes 不只是断点调试工具，它还是 ftrace 事件的数据源之一。

## tracer 家族：不止 function

`available_tracers` 文件列出当前内核能用的档位。几个代表的源码落点（Linux 6.19，`.name` 字段已核对）：

- `function` / `function_graph`：`kernel/trace/trace_functions.c`（`function_trace`，`.name = "function"`）、`kernel/trace/trace_functions_graph.c`（`function_graph`，`.name = "function_graph"`）。
- `wakeup` / `wakeup_rt` / `wakeup_dl`：`kernel/trace/trace_sched_wakeup.c`，测"从被唤醒到真正跑起来"的调度延迟。
- `irqsoff` / `preemptoff` / `preemptirqsoff`：`kernel/trace/trace_irqsoff.c`，抓"谁把中断/抢占关太久"，对实时性敏感的嵌入式驱动是抓鬼利器。
- `hwlat`、`blk`、`mmiotrace`、`nop`：硬件延迟、块设备、内存映射 IO、空操作（默认）。

切换 tracer 和开头讲的 patching 是一套机制：选了 `irqsoff`，内核就只关心"中断开关"那几个状态位的变化，记录每段中断关闭的时长，`max_latency` 字段（`struct trace_array`，`kernel/trace/trace.h`）记下历史最坏值。

## ring buffer：每 CPU 一个的环形账本

function tracer 和 trace events 记下来的东西，都写进 ftrace 自己的 ring buffer。**注意它和 printk 的 ringbuffer 不是同一个东西**——printk 那套是给控制台/log 用的，ftrace 这套是为高速并发写优化的。

核心数据结构是 `struct trace_array`（`kernel/trace/trace.h:331`），里面嵌着一个 `struct array_buffer array_buffer` 字段（`trace.h:334`）；`struct array_buffer`（`trace.h:217`）内部用一个 `struct trace_buffer *buffer` 指针（`trace.h:219`）指向底层每 CPU 一个的 ring buffer 子 buffer。这样不同核写自己那块，不用全局锁，只在读 `trace` 文件时才合并。（另一个字段 `max_buffer`，`trace.h:347`，是给快照 trigger 用的，下面会讲。）

写入的快路径是 `__trace_buffer_lock_reserve()`（`kernel/trace/trace.c:1072`）：先 `ring_buffer_lock_reserve()` 预留一段，填事件头，再 `__buffer_unlock_commit()`（`trace.c:1115`）提交。读完 `trace` 文件里的内容**不会清空** buffer（那是快照），要清空 `echo > trace`；想边跑边看用 `trace_pipe`（流式，读走即清）。

## trigger：事件之间互相串通

这是 ftrace 最巧妙的组合技：**一个点发生时，去开/关另一个东西**。但要分清两套 trigger，别张冠李戴：

**第一套是 function trigger**（写到 `set_ftrace_filter`）。比如你只想看某个 bug 出现前那一段，可以让 ftrace 平时开着跑，一碰到某个函数就自动 `traceoff` 刹车。语法是 filter command：

```bash
echo '<function>:<command>:<parameter>' > set_ftrace_filter
# 例：碰到 my_buggy_func 就关跟踪
echo 'my_buggy_func:traceoff' >> set_ftrace_filter
```

底层实现走的是 **`struct ftrace_func_command` + `struct ftrace_probe_ops` + `register_ftrace_command()`**：`traceon/traceoff/stacktrace/dump/cpudump` 这几个命令实现在 `kernel/trace/trace_functions.c`（`ftrace_traceon_cmd`/`ftrace_traceoff_cmd`/`ftrace_stacktrace_cmd` 等，`ftrace_traceon`/`ftrace_traceoff`/`ftrace_stacktrace` 是对应的 probe 回调），而 `mod`（只跟某模块）命令实现在 `kernel/trace/ftrace.c`（`ftrace_mod_cmd`，`ftrace.c:5221`）。所以你到 `trace_events_trigger.c` 里去找 `traceoff` 会扑空——它根本不在那。

**第二套是 event trigger**（写到 `events/<subsys>/<event>/trigger`）。这是挂在**具体事件**上的 trigger，命令是 `enable_event`/`disable_event`/`snapshot`/`stacktrace` 等，作用对象是事件而非函数。这套的底层实现才是 **`struct event_trigger_data` + `event_triggers_call()`**（`kernel/trace/trace_events_trigger.c:124`）——事件触发时，内核沿着挂在它身上的 trigger 链逐个调用 ops。

> **注意坑**：function trigger 的 filter command 只控制运行时开关（traceon/traceoff 之类），**不改变"哪些函数被跟踪"这个集合**——过滤函数名还是 `set_ftrace_filter` 本职的活。而"碰到某事件就 `snapshot`（把 buffer 快照存到 `max_buffer`）"这种，得用 event trigger 写到 `events/.../trigger`，而不是写到 `set_ftrace_filter`。

## 前端工具：trace-cmd / KernelShark / perf-tools

裸 ftrace 配置起来繁琐得让人想骂街（追踪一个 ping 要写同步握手脚本抢 PID）。所以原作者 Steven Rostedt 写了 `trace-cmd`，设计风格像 git——一堆子命令：

```bash
sudo trace-cmd reset                                   # 清场
sudo trace-cmd record -p function_graph -F sleep 1     # 录制
sudo trace-cmd report -l > sleep1.txt                  # 出报告
sudo trace-cmd record -e net -e sock -F ping -c1 host  # 只录网络事件
```

它底层还是操作 ftrace，但把"同步、过滤、抓取、格式化"全包了，产物是二进制 `trace.dat`。`KernelShark` 是 `trace.dat` 的 GUI 前端，上下双栏（图形 + 列表）、双 Marker 量时差、按 CPU/Task/Event 过滤，看唤醒延迟的"空心绿条"一目了然。Brendan Gregg 的 `perf-tools` 则是一堆 bash 脚本，`opensnoop`、`funcslower`、`execsnoop` 之类，本质就是 raw ftrace 的封装（其源码值得读，`funcgraph` 就是一段包装 `function_graph` 的 shell）。

## 动手试试（待亲测）

> ⚠️ 以下命令均在 QEMU ARM64/x86_64 上**待亲测核对**输出，先给方案。

**实验一：function_graph 看一秒内核**

```bash
cd /sys/kernel/tracing
echo 0 > tracing_on
echo function_graph > current_tracer
echo 1 > tracing_on ; sleep 1 ; echo 0 > tracing_on
cp trace /tmp/trc.txt        # trace 文件大小故意显示为 0，是伪文件
wc -l /tmp/trc.txt           # 待亲测：预计几万行
```

function_graph 的输出每行前头有一串"上下文密码"（像 `d.h2`），用来标记这一笔发生在什么上下文：大致是 `.`=进程上下文、`h`=硬中断、`s`=软中断之类，`d` 之类的字母表示调度相关标志。具体每个位置的字母含义，以及要开启哪个 option 才能让这列完整出现，**待 QEMU 亲测核对**（笔记 ch09_4 提到需要额外开某个 latency 相关 option 才出现完整上下文列，开关名待亲测确认，不在这里凭记忆写死）。

**实验二：trace-cmd 录一次系统调用**

```bash
sudo trace-cmd record -e syscalls -F ls
sudo trace-cmd report -l > syscall.txt
# 待亲测：确认能看到 openat/read/write 等事件的参数值
```

实验二是**事件视角**（不是 function_graph），所以验证清单就聚焦 syscalls 事件参数值本身：能不能看到 `openat` 的 filename、`read` 的 fd 和字节数、`write` 的内容指针。别在这一节里去找 `d.h2` 那一列——那是 function_graph 才有的东西。

验证清单（跨两个实验）：tracefs 是否挂载（`mount | grep tracefs`）、`CONFIG_FTRACE=y`（`zcat /proc/config.gz | grep FTRACE`，具体配置项待亲测核对）、实验一能读出 function_graph 的上下文密码列、实验二能看到 syscall 事件的参数值。

## 小结

ftrace 的精髓是**动态**：编译器埋点 + 运行时打补丁，让"想看哪看哪、不看零开销"成为可能。两根柱子要分清：function tracer 看**函数入口**（平铺列表，普通 `function` 不画调用图、不看出口；`function_graph` 才缩进出调用树），trace events 看**事件参数**（靠 tracepoint + `set_event`）。各自的开关也别混——`set_ftrace_filter` 是函数过滤，`set_event` 是事件开关。数据都进每 CPU 独立的 ring buffer（`trace_array.array_buffer.buffer`），trigger 分两套（`set_ftrace_filter` 里的 function trigger 走 `ftrace_func_command`/`ftrace_probe_ops`，`events/.../trigger` 里的 event trigger 走 `event_trigger_data`/`event_triggers_call`），trace-cmd/KernelShark 把繁琐手工活自动化。记住：`current_tracer` 一改就是全系统机器码改写，所以它"听话且急躁"。

## 延伸阅读

- 源码（Linux 6.19）：`kernel/trace/ftrace.c`（动态 patching、`ftrace_init`、`ftrace_replace_code`、`__ftrace_replace_code`、`ftrace_mod_cmd`）；`kernel/trace/trace.c`（ring buffer、`tracing_set_tracer`、`__trace_buffer_lock_reserve`）；`include/linux/ftrace.h`（`ftrace_ops`、`dyn_ftrace`、`ftrace_make_call/make_nop` 签名）；`kernel/trace/trace.h`（`trace_array`、`array_buffer`、`max_buffer`）；`kernel/trace/trace_functions.c`（`function` tracer + `traceon/traceoff/stacktrace` 等 function trigger）；`kernel/trace/trace_events_trigger.c`（`event_trigger_data` + `event_triggers_call`，event trigger）；`kernel/trace/trace_functions_graph.c`、`trace_irqsoff.c`、`trace_sched_wakeup.c`（各 tracer）。
- docs.kernel.org：[ftrace — Function Tracer](https://docs.kernel.org/trace/ftrace.html)、[Linux Tracing Technologies](https://docs.kernel.org/trace/index.html)、[Tracepoints](https://docs.kernel.org/trace/tracepoints.html)。
- trace-cmd / KernelShark：<https://www.trace-cmd.org/>、<https://kernelshark.org/Documentation.html>。