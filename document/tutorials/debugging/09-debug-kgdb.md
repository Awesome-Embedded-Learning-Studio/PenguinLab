---
title: KGDB：让 GDB 停下整个内核
slug: debug-kgdb
difficulty: intermediate
tags: [调试, KGDB, GDB, 断点]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/06-gdb-debug-setup
related:
  - /tutorials/debugging/05-debug-oops
sources:
  - notes: document/notes/linux_kernel_debugging/ch11.md
---

# KGDB：让 GDB 停下整个内核

> 🔨 **整理中** · 机制对照 Linux 6.19（v6.19.9）源码核对过（函数名、数据结构、BRK 立即数、调用链都已 grep 确认）；但具体行号、menuconfig 实际菜单层级、QEMU 串口分配和 GDB 命令输出还没亲手跑过。等我们在 QEMU 上验完，升级成 ✅ 已锤炼。

## 为什么 printk 不够用

我们调试用户态程序时，加个 `printf` 永远只是「事后看尸体」——你能看到它经过这一行，却没法在那一刻停下来翻口袋。`printk`、`ftrace`、`kprobes` 在内核里扮演的就是这个角色：它们是高速摄像机，能记录内核做了什么，但内核照常全速往前跑。等你看完日志想问「那个 `task_struct` 里 `mm` 指针到底指哪」时，现场早就没了。

GDB 给的是另一种交互：**断点 → 停下 → 单步 → 查变量 → 改寄存器 → 继续**。问题在于内核自己占着 CPU，谁来响应 GDB？答案就是 KGDB——把一个极简的 GDB 服务端（stub）塞进内核，让内核在断点处「自我冻结」，通过串口或网络和外部 GDB 对话。

## 原理：内核里长出一个 gdb stub

KGDB 的核心是两层分工，源码就分在几个文件里：

- **`kernel/debug/debug_core.c`**：与架构无关的「调试核心」，管断点表、总线锁、CPU 集结（让所有核一起停下来）、和 GDB 的命令调度。
- **`kernel/debug/gdbstub.c`**：实现 GDB Remote Serial Protocol（RSP）的收发包、寄存器读写、内存读写，把 GDB 发来的 `$g`/`$G`/`$m`/`$M` 报文翻译成对内核内存的操作。
- **`arch/<arch>/kernel/kgdb.c`**：架构相关层，负责异常接管、寄存器布局、单步指令注入。ARM64 对应 `arch/arm64/kernel/kgdb.c`。

打个比方：`debug_core` 是「停机调度员」，`gdbstub` 是「翻译官」，arch 层是「按 CPU 型号定制的手」。三者合起来才构成一个能被 GDB 认作远程目标的 stub。

内部维护的核心数据结构在 `include/linux/kgdb.h`：断点表是个定长数组 `static struct kgdb_bkpt kgdb_break[KGDB_MAX_BREAKPOINTS]`（`debug_core.c:101`），每项记录四个字段——`bpt_addr`（断点地址）、`saved_instr`（被替换走的原始指令字节，`BREAK_INSTR_SIZE` 长度）、`type`（断点类型）、`state`（断点状态）。`kgdb_breakpoint()`（`debug_core.c:1209`）是那个能在任何地方下断的入口——**一个 `noinline` 函数**，不是宏。它在代码里主动陷进 KGDB 的「钩子」：你在自己的代码里写一行 `kgdb_breakpoint();`，内核执行到这就立刻自我冻结，等外部 GDB 连进来。

## 两条路：kgdb 与 kdb

进了 stub 之后有两种「前台」：

- **kgdb**：纯走 GDB 远程协议，外部那个 `aarch64-linux-gnu-gdb` 才是真正的命令解释器。能力最强（条件断点、Python 脚本、漂亮的 `struct` 展开），代价是必须开两个终端、靠串口通信。
- **kdb**：内核内置的简易行调试器，不需要外部 GDB，直接在串口控制台敲 `bp`、`go`、`md`（内存 dump）。轻量、能在没网络只有串口的板子上救命，但语法朴素、没有符号类型推断。kdb 由 `CONFIG_KDB_KDB` 单独提供。

两者共用同一个 `debug_core`，区别只是 `gdbstub.c` 走对外协议、`kdb` 在内核态自己解析命令。生产线上几乎不会上 KGDB（一停全停），它天生属于「开发/调试机」场景。

## 搭建：CONFIG_KGDB + QEMU + kgdbwait

把内核配出来（`make menuconfig`），注意 `KGDB` 在 6.19 是个顶层 `menuconfig`，下面挂的子项都是真实存在的（别找那个不存在的「kernel debugger interface」子项）：

```
Kernel hacking  --->
  [*] Kernel debugging                         # DEBUG_KERNEL
  [*] Compile the kernel with debug info       # CONFIG_DEBUG_INFO，GDB 要符号
  [*] KGDB: kernel debugger                    # CONFIG_KGDB（顶层 menuconfig）
      <*>   KGDB: use kgdb over the serial console  # CONFIG_KGDB_SERIAL_CONSOLE
      [*]   KGDB: use kprobe blocklist to prohibit unsafe breakpoints  # CONFIG_KGDB_HONOUR_BLOCKLIST（默认 y）
      [*]   KGDB: internal test suite          # CONFIG_KGDB_TESTS（可选）
      [*]   KGDB_KDB: include kdb frontend for kgdb  # CONFIG_KGDB_KDB（要用 kdb 才开）
```

> ⚠️ **务必开着 `KGDB_HONOUR_BLOCKLIST`**（`lib/Kconfig.kgdb`，默认 `y`）。它让 KGDB 借 kprobe 黑名单识别出那些「下断会自己把自己搞死」的函数（比如调试 trap 处理路径上被调用的函数），否则你在不安全的函数下断会触发递归 trap，整台机当场死透。

QEMU 启动时给一条专用串口并告诉内核「开机就在 KGDB 处停住等连接」，关键是 `kgdbwait` 这个内核参数：

```bash
qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1G \
  -kernel arch/arm64/boot/Image \
  -append "console=ttyAMA0 kgdboc=ttyAMA0 kgdbwait nokasnr" \
  -serial mon:stdio -nographic
```

`kgdboc=ttyAMA0` 把 KGDB 绑到这个串口（`kgdb` over `console`），`kgdbwait` 让内核初始化到某处就主动 `kgdb_breakpoint()` 挂起自己，`nokaslr` 是为了让 GDB 的符号地址和实际运行地址对得上（KASLR 一开，断点地址全得靠重定位）。

外部另开终端连进去：

```bash
aarch64-linux-gnu-gdb vmlinux
(gdb) target remote /dev/pts/3      # 视 QEMU 的串口分配而定，待亲测核对
(gdb) b do_sys_openat2
(gdb) c
```

> 命令输出样例（待亲测核对）：
> ```
> Remote debugging using /dev/pts/3
> 0xffff800080010000 in cpu_resume ()
> (gdb)
> ```

## debug_core 的断点机制：怎么让 CPU 真的停下来

光有数据结构不顶用，得让 CPU 执行到某地址时触发异常。`debug_core.c:1209` 的 `kgdb_breakpoint()` 是入口：它是 `noinline void kgdb_breakpoint(void)`，体内调用架构相关的 `arch_kgdb_breakpoint()`——在 ARM64 上（`arch/arm64/include/asm/kgdb.h:19`）是个 `static inline` 函数，体内就一句汇编 `asm ("brk %0" : : "I" (KGDB_COMPILED_DBG_BRK_IMM))`，一执行就陷进异常。注意它**是函数不是宏**，别去源码里找 `#define kgdb_breakpoint`。

异常处理路径在 arch 层分两步。ARM64 上 BRK 指令陷进 EL1 异常后，由 `arch/arm64/kernel/debug-monitors.c` 的 `call_el1_break_hook()`（`debug-monitors.c:210`）统一分发：它从 ESR 的 ISS comment 字段里用 `esr_brk_comment(esr)` 提取出 BRK 指令编码的立即数，命中 KGDB 的专属立即数就调对应的 handler——动态断点立即数 `KGDB_DYN_DBG_BRK_IMM`（`0x400`）调 `kgdb_brk_handler()`，编译期断点立即数 `KGDB_COMPILED_DBG_BRK_IMM`（`0x401`）调 `kgdb_compiled_brk_handler()`（两个 handler 都在 `arch/arm64/kernel/kgdb.c:237/244`）。这些 handler 再调 `kgdb_handle_exception()`，后者进到 `debug_core.c` 的核心 `kgdb_cpu_enter()`（`debug_core.c:571`），它干三件事：

1. **停机**：通过 IPI（核间中断）通知其它 CPU 进入集结，全部冻结，避免一边调试一边别的核还在改内存。ARM64 的 `kgdb_roundup_cpus()`（`arch/arm64/kernel/smp.c:940`）给每个在线 CPU 发一条**专用核间中断 `IPI_KGDB_ROUNDUP`**（`smp.c:824` 的 ipi_types 表里登记为「KGDB roundup interrupts」）把它们喊停。
2. **快照现场**：寄存器现场经 `pt_regs_to_gdb_regs()`（`gdbstub.c:340`）快照进 `gdb_regs[]` 缓冲；硬件断点的临时关闭/恢复走 `arch_kgdb_ops`（`struct kgdb_arch`，`include/linux/kgdb.h:261`）里的 `disable_hw_break` / `remove_all_hw_break` / `correct_hw_break` 等回调。
3. **进命令循环**：调用 `gdb_serial_stub()`（在 `gdbstub.c:955`）等待 GDB 报文，解析 `$?`/`$g`/`$m` 并回包，直到收到 `$c`（continue）才退出循环、恢复其它 CPU、返回被断点打断的现场。

恢复时 stub 把原指令字节写回去、单步执行原指令、再把断点指令重新填上——这套「填—单步—重填」就是软件断点跨越断点处的标准手法。

## 实战：透视一个内核数据结构

连上之后，KGDB 和调用户态程序几乎一样，只是你在读内核地址。我们在 `do_sys_openat2` 下断——注意 6.19 的签名是 `static int do_sys_openat2(int dfd, const char __user *filename, struct open_how *how)`（`fs/open.c:1415`），这里 `filename` 是个**用户态裸字符串指针**（`const char __user *`），不是 `struct filename *`，所以别敲 `p filename->name`（会报错）：

```gdb
(gdb) b do_sys_openat2
(gdb) c
Breakpoint 1, do_sys_openat2 (dfd=-100, filename=..., how=...) at fs/open.c:1415
(gdb) p filename        # 看用户态传进来的路径字符串（__user 指针，需 GDB 主动读）
(gdb) p how->flags      # 看用户到底想用什么 flag 打开文件
(gdb) p *current        # 当前进程的 task_struct，整张摊开
(gdb) bt                # 谁调的它
(gdb) stepi             # 单步一条机器指令
```

> 想看 `struct filename *`（内核内部那个封装了路径字符串、引用计数、审计信息的结构体），得把断点挪到 `do_sys_openat2` 内部 `getname()` 拿到 `tmp` 之后的位置——`struct filename *tmp` 是 `do_sys_openat2` 里的局部变量（`fs/open.c:1417`）。在 `do_filp_open` 或 `getname_flags` 上断也行，那里能直接 `p tmp->name`。

最爽的是 `p *current`：GDB 借 `DEBUG_INFO` 把 `task_struct` 的字段全展开，`mm`、`pid`、`comm`、`fs` 一览无余。这是 `printk` 永远给不了的「现场快照」。

## 和 kprobes 的边界

很多人会把 KGDB 和 kprobes/eBPF 搞混，它们的本质区别是「停不停机」：

- **kprobes / ftrace / eBPF**：探针命中后跑一段处理函数就放行，内核继续全速跑，**生产环境可用**，开销在纳秒到微秒级。
- **KGDB**：命中就冻结整个系统，**生产慎用**（一停可能几十秒，watchdog、网络心跳全超时），属于开发机的专属工具。

需要「持续观测、低打扰」用 kprobes；需要「这一刻我得翻遍所有寄存器和数据结构」才上 KGDB。

## 小结

KGDB 的价值不在「比 printk 强一点」，而在于它把 GDB 那套交互式调试能力**整体搬进了内核**：靠 `debug_core.c` 做停机调度、`gdbstub.c` 说 RSP 协议、arch 层接管 BRK 异常，三者合起来让内核在断点处自我冻结，把现场完整交给外部 GDB。代价是全局停机，所以它和 kprobes 各占一个生态位——一个管「交互深挖」，一个管「线上观测」。

## 动手验证方案（待亲测）

1. 按 QEMU + `kgdbwait` 把 6.19 内核拉起来，确认开机后卡在等待连接状态（命令输出待亲测）。
2. 用 `aarch64-linux-gnu-gdb vmlinux` 连上，`info threads` 应能看到多个 CPU 的栈（验证 `IPI_KGDB_ROUNDUP` 集结成功）。
3. 在 `do_sys_openat2` 下断点，触发一次 `cat /etc/hostname`，命中后 `p *current` 摊开 `task_struct`，记录 `comm`、`pid`、`mm->pgd` 字段（输出待亲测核对）。
4. 单步几条 `stepi`，观察 PC 移动，再 `c` 恢复，确认系统正常继续启动。

## 延伸阅读

- 源码（Linux 6.19）：
  - `kernel/debug/debug_core.c` — 停机调度、断点表 `kgdb_break`、`kgdb_cpu_enter()`、`kgdb_breakpoint()`
  - `kernel/debug/gdbstub.c` — GDB Remote Serial Protocol 实现、`gdb_serial_stub()`
  - `arch/arm64/kernel/kgdb.c` — ARM64 BRK handler（`kgdb_brk_handler`/`kgdb_compiled_brk_handler`）、`kgdb_arch_init()` 注册 die notifier
  - `arch/arm64/kernel/debug-monitors.c` — `call_el1_break_hook()` 按 BRK 立即数分流
  - `include/linux/kgdb.h` — `struct kgdb_bkpt`、`struct kgdb_arch`/`arch_kgdb_ops`、`kgdb_breakpoint()` 接口
- 官方文档（6.19 KGDB 文档已归入 process/debugging，不再在 dev-tools 下）：
  - [docs.kernel.org/process/debugging/kgdb.html](https://docs.kernel.org/process/debugging/kgdb.html) — KGDB/kdb 使用手册（配置参数、kdb 命令表）
  - [docs.kernel.org/process/debugging/index.html](https://docs.kernel.org/process/debugging/index.html) — 内核调试建议总览（KGDB 在此 toctree 下）
  - [docs.kernel.org/dev-tools/index.html](https://docs.kernel.org/dev-tools/index.html) — dev-tools 总览（KGDB/kdb 现归 process/debugging）"