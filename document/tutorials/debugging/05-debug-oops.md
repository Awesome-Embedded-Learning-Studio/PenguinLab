---
title: Oops：内核崩溃现场解读
slug: debug-oops
difficulty: intermediate
tags: [内核调试, Oops, panic, 栈回溯]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: verified
prerequisites:
  - /tutorials/foundations/06-gdb-debug-setup
related:
  - /tutorials/debugging/01-debug-printk
sources:
  - notes: document/notes/linux_kernel_debugging/ch07.md
---

# Oops：内核崩溃现场解读

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## Oops 到底是什么

写用户态程序，指针乱指顶多 `Segmentation fault`——内核给进程发个 `SIGSEGV`，进程自己死，系统活得好好的。可一旦错误发生在内核代码里——空指针解引用、写只读页、非法指令——事情性质就变了：**这是内核自己在犯错**。内核没有"上层"能给它善后，它要么硬扛着把肇事进程做掉继续跑，要么干脆承认自己活不下去了。这个"承认错误并打印现场"的瞬间，就是 **Oops**。

触发 Oops 的硬件源头通常是一条访存指令撞上了 MMU 的墙。在 ARM64 上，MMU 翻译失败或权限不对，CPU 抛出同步异常（Synchronous Exception），异常向量把控制权交给 `do_mem_abort()`（`arch/arm64/mm/fault.c`）。它根据 ESR（异常综合寄存器）查一张 `fault_info` 表，分派到具体的 fault 处理函数——比如翻译失败走 `do_translation_fault()`、访问标志/权限失败走 `do_page_fault()`。这些处理函数发现"这是内核态、又没有上下文可救"时，才会走到 `__do_kernel_fault()`：它先判断这错能不能救（比如 `copy_from_user` 这种带异常修复表的场景，`fixup_exception()` 直接改寄存器跳走），救不了才打印诊断并调用 `die("Oops", regs, esr)`。所以中间隔了那一层 fault fn，不是 `do_mem_abort` 直接调 `__do_kernel_fault`。

```c
// arch/arm64/mm/fault.c（Linux 6.19）
static void __do_kernel_fault(unsigned long addr, unsigned long esr,
                              struct pt_regs *regs)
{
    if (!is_el1_instruction_abort(esr) && fixup_exception(regs, esr))
        return;                 /* 能修就修，悄悄跳过 */
    /* ... 判定 msg（权限错 / NULL / paging request） ... */
    else if (addr < PAGE_SIZE)
        msg = "NULL pointer dereference";
    /* ... */
    die_kernel_fault(msg, addr, esr, regs);
}
```

注意那个 `addr < PAGE_SIZE` 的判定——这就是为什么报错地址常常是个小于 4096 的怪数字。你写 `oopsie->data = 'x'`，`oopsie` 是 NULL，`data` 在结构体里偏移 `0x30`（48 字节），CPU 真正访问的是 `NULL + 0x30 = 0x30`。**看到一个几十几百的小地址，反射弧就该接上：八成是 NULL 指针访问结构体成员，那数字就是成员的偏移量。**

## Oops vs panic：一念生，一念死

关键区别在 `die()` 收尾怎么走（`arch/arm64/kernel/traps.c`，Linux 6.19）：

```c
void die(const char *str, struct pt_regs *regs, long err)
{
    raw_spin_lock_irqsave(&die_lock, flags);
    oops_enter();
    console_verbose();
    bust_spinlocks(1);
    ret = __die(str, err, regs);      /* 打印现场 */
    if (regs && kexec_should_crash(current))
        crash_kexec(regs);
    bust_spinlocks(0);
    add_taint(TAINT_DIE, LOCKDEP_NOW_UNRELIABLE);
    oops_exit();

    if (in_interrupt())
        panic("%s: Fatal exception in interrupt", str);  /* 中断里崩，必死 */
    if (panic_on_oops)
        panic("%s: Fatal exception", str);               /* 开了开关，必死 */

    raw_spin_unlock_irqrestore(&die_lock, flags);
    if (ret != NOTIFY_STOP)
        make_task_dead(SIGSEGV);                          /* 否则杀进程了事 */
}
```

这里藏着两条命：**Oops 默认能活**——它把肇事进程（`make_task_dead`）做掉，然后系统继续跑。但有两条路会升级成 panic（内核彻底停摆）：一是**在中断上下文里崩了**（`in_interrupt()` 为真，没有进程可背锅，只能死）；二是 `panic_on_oops` 这个开关被打开。

`panic_on_oops` 定义在 `kernel/panic.c` 第 56 行（`int panic_on_oops = IS_ENABLED(CONFIG_PANIC_ON_OOPS);`），初始值跟 `CONFIG_PANIC_ON_OOPS` 走，但运行时可以通过 `/proc/sys/kernel/panic_on_oops` 临时改。想逼内核一崩就死（方便抓第一现场的完整 dump），`echo 1 > /proc/sys/kernel/panic_on_oops`；想让它苟着让你看现场又不重启，就保持 0。

为什么中断里必死？因为中断没有进程上下文，`current` 指向的只是那个倒霉蛋——当时恰好被中断抢占的进程，它对这次崩溃一无所知，杀它毫无意义，整个内核状态已经不可信，只能 panic 保平安。

## Oops 输出逐段解读

以 ARM64 为例，Oops 大致长这样（待亲测核对）：

```
Internal error: Oops: 96000046 [#1] SMP
CPU: 0 PID: 16 Comm: kworker/0:1 Tainted: G        OE
pc : do_the_work+0x68/0x94 [oops_tryv2]
lr : process_one_work+0x1a7/0x360
sp : ffff8000800dbe90
pstate: 60400009 (nZCv ... +PAN +UAO ...)
x29: ffff8000800dbe90 x28: ...
...
Call trace:
 do_the_work+0x68/0x94 [oops_tryv2]
 process_one_work+0x1a7/0x360
 worker_thread+0x4d/0x3f0
 ...
Code: a9bf7bfd 910003fd f9000f80 (e5c3201c)
---[ end trace 0000000000000000 ]---
```

**第一行**（`Internal error: ...`）来自 `__die()`：`pr_emerg("Internal error: %s: %016lx [#%d] " S_SMP "\n", str, err, ++die_counter)`。那个 `[#1]` 是 `die_counter`——本次开机第几次 Oops。`err` 是 ESR 值，要查 ARM 架构手册（ARM ARM）才能解出来。

**`pc`/`lr`/`sp`/`pstate`** 来自 `__show_regs()`（`arch/arm64/kernel/process.c`）：内核态下 `pc` 用 `%pS` 格式直接解出"函数名+偏移"，这就是我们定位源码的钥匙。`pc` 是崩在哪儿，`lr`（x30）是返回地址（谁调进来的），`sp` 是栈顶，`pstate` 是处理器状态（`print_pstate` 把它的位拆成 `nPAN +UAO` 这种人类可读字母）。

**`Tainted`** 一栏是"内核污染"状态，由 `add_taint()` 累积。这里有个反直觉的点：最前面那个 `G` **不是一个污染标志**，恰恰相反——它是"干净基线字符"。`kernel/panic.c:646` 里 `TAINT_FLAG(PROPRIETARY_MODULE, 'P', 'G')` 的语义是：`c_true`（这一位置位时打印）是 `P`，`c_false`（未置位时打印）是 `G`。所以 `G` 表示第 0 位（`TAINT_PROPRIETARY_MODULE`）没置位——你这内核没加载私有闭源模块，还算干净。真正能被打出来的污染三件套是 `O`（`TAINT_OOT_MODULE`，树外模块）、`E`（`TAINT_UNSIGNED_MODULE`，未签名模块），再加上 Oops 自己触发的 `D`（`TAINT_DIE`）。要是看到 `P`（私有闭源）或 `F`（`TAINT_FORCED_MODULE`，强制加载），上游开发者基本会拒收 bug 报告。

**`Code:`** 那行是崩点附近的机器码字节，由 `dump_kernel_instr()`（`arch/arm64/kernel/traps.c`）打印。ARM64 的格式是把崩点那条指令**用圆括号**括起来：`dump_kernel_instr` 在 `arch/arm64/kernel/traps.c:166` 用的是 `i == 0 ? "(%08x) " : "%08x "`，所以你看到的是 `(e5c3201c)` 这种被圆括号包着的字，旁边是它前后各几条不带括号的指令。**注意这跟 x86 Oops 里常见的尖括号 `<...>` 不是一回事**——那是 x86 `Code:` dump 的格式（把触发指令包成 `<48>`），架构之间别张冠李戴。人眼看不懂这些字节没关系，内核自带 `scripts/decodecode` 能把它反汇编出来。

**`Call trace`** 是栈回溯，最底下是最早调用的函数。行首带 `?` 的是回溯算法觉得"不太可靠、可能是栈上残留数据"。**末尾那行 `---[ end trace ...]---`** 来自 `oops_exit()` 里的 `print_oops_end_marker()`（`kernel/panic.c:852`，`pr_warn("---[ end trace %016llx ]---\n", 0ULL)`）——看到它说明整个 Oops 打印流程走完了。

## `dump_stack()` 怎么把栈走出来的

整个 `Call trace` 的幕后功臣是栈回溯。ARM64 的函数调用约定里，每个函数进来都会执行 prologue：把返回地址 `lr` 存进当前栈帧、把上一帧的 `fp`（x29）压栈，然后把新的 `fp` 指向本帧。这样所有栈帧就串成了一条**以 fp 为指针的链表**。

回溯的起点在 `arch/arm64/kernel/stacktrace.c`：对于当前崩溃的任务，`state->common.fp = regs->regs[29]`、`state->common.pc = regs->pc`（`stacktrace.c:86-87`）——也就是拿崩溃那一瞬的 x29 和 pc 作种子。然后顺着 `fp` 链一帧一帧往上爬：每读一个 `fp`，就拿到上一层 `fp` 和那条 `lr`（返回地址），`lr` 就是调用者里"调用点下一条指令"的地址，于是 `Call trace` 里就多出一行。

`dump_stack()` 本体（`lib/dump_stack.c`）做的事很简单：先 `dump_stack_print_info` 打个头，然后 `show_stack(NULL, NULL, log_lvl)`（`dump_stack.c:93-94`）——后者最终走到架构的回溯器把整条链吐出来。所以你手动 `dump_stack()` 和 Oops 里看到的 `Call trace`，走的是**同一套机制**。

**这有个大坑**：fp 链要成立，编译时必须保留帧指针。在 ARM64 上，解栈靠的是 `arch/arm64/kernel/stacktrace.c` 这套帧指针解栈器，编译期靠顶层 `Makefile:925` 全局开的 `-fno-omit-frame-pointer` 保留 fp（开了 `CONFIG_FUNCTION_TRACER` 时那行会被 `-fomit-frame-pointer` 覆盖回去，但那是另一个话题）。注意 `CONFIG_UNWINDER_FRAME_POINTER` 和基于 ORC/dwarf 的解栈器**都是 x86 的概念**——`arch/arm64/Kconfig` 里压根没有 `UNWINDER_*` 选项，别在 ARM64 语境下搬这些配置名。要是某些函数（比如内联、汇编、或被 `-O2` 优化掉帧指针的）没乖乖建栈帧，链就断了，`Call trace` 在那处就会断档或出现一堆 `?`。这也是为什么内核调试构建会强开 `-fno-omit-frame-pointer -Og`。

## 把地址钉回源码行

有了 `pc : do_the_work+0x68/0x94 [oops_tryv2]`，那个 `+0x68` 就是命门。三把刀，挑顺手的用：

**`addr2line`（最轻）**：直接地址转文件:行号。模块崩了喂 `.ko` 或 `.o`，内核崩了喂带调试符号的 `vmlinux`。

```bash
# 待亲测核对
addr2line -e ./oops_tryv2.ko -p -f 0x68
# 输出形如: do_the_work at oops_tryv2.c:62
```

**`gdb list *符号+偏移`（最直观）**：GDB 懂 ELF/DWARF，会顺便把上下文源码列出来，`=>` 指着那行。

```bash
# 待亲测核对
$ gdb -q ./oops_tryv2.ko
(gdb) list *do_the_work+0x68
```

**`objdump -dS`（最底层）**：把整段反汇编连同 C 源码混排出来，适合看汇编层面的把戏。如果模块还活在内存里，`sudo grep oops_tryv2 /proc/modules` 拿到加载基址，配 `--adjust-vma=基址` 让左侧地址和运行时对齐，再拿崩点的绝对地址去 grep。

> ⚠️ **待亲测**：下面的汇编示意是整理时的占位，偏移口径全文统一用 `0x30`（48）这套（对应 NULL 指针 + 结构体成员偏移 48 字节）。QEMU ARM64 跑出来的真实字节、真实指令会替换这一段，不会混 x86/ARM32 两套笔记数据。

```
; 假设崩点指令把 'x' 写进结构体成员（偏移 0x30=48）
; 具体寄存器分配与字节码待亲测核对
strb  w2, [x3, #48]   ; x3=0(NULL) -> 写 0+48，炸
```

这条 `strb`（待亲测核对真实指令）就是把 `'x'` 存进 `[x3, #0x30]`，而 x3 在上一条被置成 0——汇编当场破案。

**KASLR 的坑**：开了内核地址随机化（`CONFIG_RANDOMIZE_BASE`）时，Oops 里的地址是"随机化后的绝对地址"，而 `vmlinux` 符号是"编译时的相对地址"，`addr2line` 直接喂会对不上号。两条路：启动参数加 `nokaslr` 关掉，或者用内核源码树里的 `scripts/faddr2line`（它处理"符号+偏移"形式，绕开绝对地址问题）。前提永远是**二进制带调试符号**——模块 Makefile 开 `-g`、内核开 `CONFIG_DEBUG_INFO=y`，否则上面全是空谈。

## 中断上下文：Oops 打不出来怎么办

前面说过，中断里崩必然 panic。但真正的坑是：panic 时控制台可能已经锁死，**屏幕黑掉、键盘失灵，`dmesg` 根本敲不出来**——内核的遗言打印了，却没人收得到。

这要靠一条不依赖显卡的备用通道把日志"走私"出来：

- **串口控制台**：QEMU/真机加一根虚拟或物理串口，启动参数 `console=ttyS0 console=tty0 ignore_loglevel`。内核 `printk` 会把日志同时往串口灌，宿主机用文件接住。`ignore_loglevel` 是关键——别让日志级别过滤把救命信息挡了。
- **`netconsole`**：把 `printk` 内容封装成 UDP 包轰到局域网另一台机器，靠 `netcat -u -l 6666` 接。网卡还活着就能收，连物理串口都省了。配置时目标 MAC 地址最好硬编码（panic 时 ARP 路由可能已乱）。
- **`pstore`/`ramoops`**：把 panic 日志写进一块保留内存，重启后从 `/sys/fs/pstore/` 读出来。这是"死机重启后还想看现场"的正解。

捕获后看中断 Oops，会发现 `Call trace` 被 `<IRQ> ... </IRQ>` 分成两截——上半截是中断栈上的路径，下半截是被打断的进程原本的栈。而 `Comm` 字段显示的进程（比如 `insmod` 甚至 `swapper/0`）多半是个**背锅侠**：它只是中断发生时 `current` 碰巧指向的那个倒霉进程，跟崩溃的真凶无关。别被它误导。

## die → panic 的完整生命线

把这条链串起来，从一条非法访存指令到屏幕上红字，内核内部走过的路是：

1. **MMU 翻译失败** → CPU 抛同步异常 → 异常向量进 `do_mem_abort()`（`arch/arm64/mm/fault.c`）。
2. `do_mem_abort` 按 ESR 查 `fault_info` 表分派 → 翻译失败走 `do_translation_fault`、权限/访问标志走 `do_page_fault` → 后者判定"内核态无上下文可救"走到 `__do_kernel_fault()` → 判定 NULL/只读/缺页等具体 msg。
3. `__do_kernel_fault` 调 `die_kernel_fault()`：打印 `Unable to handle kernel ... at virtual address`、`show_pte`、再调 `die("Oops", regs, esr)`。
4. `die()`（`arch/arm64/kernel/traps.c:206`）：加锁、`oops_enter()`（关掉锁调试、标记不可信）、`console_verbose()`（强制把日志级别调到最详）、`bust_spinlocks(1)`（让 printk 在 panic 途中也能硬输出）、`__die()` 打印 ESR/模块/寄存器/`Code`、`oops_exit()`（打 `---[ end trace ]---`、触发 `kmsg_dump(KMSG_DUMP_OOPS)`）。
5. 收尾分叉：中断上下文 → `panic("Fatal exception in interrupt")`；`panic_on_oops` 开 → `panic("Fatal exception")`；否则 `make_task_dead(SIGSEGV)` 杀进程了事。

`panic()` 本体在 `kernel/panic.c`（实现在 `vpanic()`，第 429 行起；`panic()` 第 622 行只是 `va_start`/`vpanic` 的薄包装）：它先抢 `panic_cpu`（`panic_try_start()` 只允许一个 CPU 跑 panic 代码，其他 `panic_smp_self_stop` 自停）、`local_irq_disable`、`pr_emerg("Kernel panic - not syncing: ...")`（第 483 行）、视情况 `dump_stack()`、尝试 `crash_kexec`（kdump）、跑 `panic_notifier`、`kmsg_dump(KMSG_DUMP_PANIC)`、最后死循环。中间那条 `if (test_taint(TAINT_DIE) || oops_in_progress > 1)`（第 487 行）是为了**避免 panic 嵌套在 Oops 里时重复打栈**——源码注释原话就是"Avoid nested stack-dumping if a panic occurs during oops processing"，已经打过一次了，别再打。

## 动手试试（2026-06-27 已亲测）

代码落在 `example/mini/07-debug-oops/`（模块名 `oops`）。QEMU ARM64 + Linux 6.19 上 `insmod oops.ko trigger=1` 触发，以下都是真实 Oops 现场。

1. **触发一次进程上下文 Oops**：写个模块，`init` 里给一个 NULL 指针偏移成员赋值（`struct oopsie *p = NULL; p->data = 'x';`，`data` 偏移固定设计成 0x30）。`insmod oops.ko trigger=1` 后 `dmesg` 抓到完整 Oops，关键现场逐段对照上文：

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000030
...
pc : oopsdemo_init+0x3c/0xfdc [oops]
...
Code: 91012000 97ffffeb d2800600 52800f01 (39000001)
...
Tainted: G  O
```

几个对号入座的点：

- **`0000000000000030`**：正是 `NULL + 0x30`——NULL 指针加结构体成员 `data` 的 0x30 偏移，前文"看到几十几百的小地址就反射弧接上 NULL 指针访问成员，那数字就是偏移量"这条经验，这条 `0x30` 就是活证。
- **`pc : oopsdemo_init+0x3c/0xfdc [oops]`**：崩点在模块 `oops` 的 `oopsdemo_init` 函数偏移 `+0x3c` 处，`[oops]` 标明是树外模块。拿这个偏移喂 `addr2line -e oops.ko -p -f 0x3c` 就能钉回源码行。
- **`Code: ... (39000001)`**：ARM64 的崩点指令用**圆括号**包起来（`(39000001)`），周围几条不带括号——印证了前文"ARM64 是圆括号、x86 是尖括号"的格式区分。这条 `0x39000001` 就是 `strb w1, [x0]` 类的访存指令，把 `'x'` 写进 `[x0(=NULL) + 0x30]`，当场炸。
- **`Tainted: G  O`**：`G` 是"没加载私有闭源模块"的干净基线字符（不是污染位），后面的 `O`（`TAINT_OOT_MODULE`）才是真污染——`insmod` 了这个树外 `.ko`，内核被打了 `O` 标记，上游会据此拒收 bug 报告。

2. **`panic_on_oops` 开关对比**：本 mini config 默认 `panic_on_oops=0`，所以这次崩溃没升级成 panic——`insmod oops.ko trigger=1` 在用户态报的是 `Segmentation fault`（内核 `make_task_dead(SIGSEGV)` 把肇事进程做掉），但**系统继续跑**，shell 还活着，能接着敲 `dmesg` 看现场。`echo 1 > /proc/sys/kernel/panic_on_oops` 再触发则会直接 panic 停摆。

## 小结

Oops 是内核"承认自己犯错"的瞬间：MMU 拦下非法访存 → `do_mem_abort` 按 ESR 分派 fault fn → `__do_kernel_fault` → `die()` 打印现场 → 根据"是否在中断/`panic_on_oops`"决定是杀进程苟活还是 panic 死透。学会读那段日志——`pc` 偏移、`Code` 字节（ARM64 是圆括号、x86 是尖括号）、`Call trace`、`Tainted` 标记（记住 `G` 是干净基线不是污染位）——再配 `addr2line`/`gdb`/`objdump` 三板斧，冷冰冰的十六进制就能还原成具体源码行。中断上下文是最大坑，备好串口/`netconsole`/`pstore` 三条走私通道，才不会让内核的遗言石沉大海。

## 延伸阅读

- 源码（Linux 6.19）：`kernel/panic.c`（`panic_on_oops` 第 56 行、`vpanic()` 第 429 行起、`oops_enter/exit`、`print_oops_end_marker` 第 850 行、`taint_flags` 表第 645 行）、`arch/arm64/kernel/traps.c`（`die()`/`__die()`/`dump_kernel_instr`）、`arch/arm64/mm/fault.c`（`do_mem_abort`/`__do_kernel_fault`/`die_kernel_fault`）、`arch/arm64/kernel/stacktrace.c`（fp 链解栈）、`arch/arm64/kernel/process.c`（`__show_regs`/`print_pstate`）、`lib/dump_stack.c`。
- ARM ESR 解码（正文反复说"err 是 ESR 值要查架构手册"的入口）：内核源码侧速查 `arch/arm64/include/asm/esr.h`（`ESR_ELx_*` 位定义与 `esr_to_fault_info`）；权威定义见 ARM Architecture Reference Manual 的 ESR_ELx 描述。
- kernel.org 文档：[kernel-parameters.txt](https://docs.kernel.org/admin-guide/kernel-parameters.html)（查 `panic_on_oops`、`nokaslr`、`ignore_loglevel`）、[ramoops / pstore](https://docs.kernel.org/admin-guide/ramoops.html)、[netconsole](https://docs.kernel.org/networking/netconsole.html)。
- 内核自带脚本：`scripts/decodecode`（反汇编 `Code:` 字节）、`scripts/faddr2line`（KASLR 友好的符号+偏移定位）、`scripts/checkstack.pl`（静态栈深度检查）。