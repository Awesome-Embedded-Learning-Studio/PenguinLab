---
title: Kprobes：在任意函数上插眼
slug: debug-kprobes
difficulty: intermediate
tags: [动态追踪, kprobes, ftrace, 调试]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/debugging/01-debug-printk
sources:
  - notes: document/notes/linux_kernel_debugging/ch04.md
---

# Kprobes：在任意函数上插眼

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 静态埋点不够，要的是运行时插任意函数

上一篇我们聊 `printk`——它是内核调试的祖传手艺，但它有个要命的硬伤：**得重新编译内核（或模块）**。在用户空间改个 `printf` 重编译几秒钟的事，在内核里这意味着停机、意味着那个转瞬即逝的并发 bug 早就溜了。再说，很多发行版内核你根本没源码也没权限重编。

内核其实还有一套更体面的静态机制叫 **tracepoint**：开发者预先在代码里埋好 `trace_*()` 钩子，编译进内核，运行时通过 ftrace 开关。它比 printk 高级，但仍是"开发商配好的家具"——只在开发者**主动埋点**的函数上才有用。你想看的那个冷门函数要是没埋点，tracepoint 也帮不上忙。

我们真正想要的是这种能力：**不动源码、不重编内核、运行时在任意函数入口（甚至任意指令偏移）插一个"眼"，函数流经这里时把寄存器、参数、返回值全抓下来，然后让程序像没事一样继续跑。** 这就是 **kprobes**——内核调试界的瑞士军刀。

## 原理黑盒揭秘：把指令首字节换成断点

很多人觉得"运行时给正在跑的内核插桩"是黑魔法，其实底层朴素得很：**改指令**。把目标函数第一条指令替换成一条 CPU 一看就触发异常的"断点指令"，CPU 一执行就掉进陷阱，kprobes 的异常处理器接管现场。

不同架构的断点指令不同（架构相关层，`arch/<arch>/kernel/.../kprobes.c`）：

- **x86**：`INT3`（`0xCC`），CPU 触发 `#BP` 异常，走 `int3` 处理路径（`arch/x86/kernel/kprobes/core.c`）。
- **ARM64**：`BRK64_OPCODE_KPROBES`，一条 `BRK #imm`，触发同步异常，被 `kprobe_brk_handler()` 接走（`arch/arm64/kernel/probes/kprobes.c`）。
- **RISC-V**：`ebreak` 指令，同样走陷阱。

具体怎么"改指令"？以 ARM64 为例（Linux 6.19），插桩函数 `arch_arm_kprobe()`（`arch/arm64/kernel/probes/kprobes.c:148`）干的事就这么几行：

```c
void __kprobes arch_arm_kprobe(struct kprobe *p)
{
    void *addr = p->addr;
    u32 insn = BRK64_OPCODE_KPROBES;
    aarch64_insn_patch_text(&addr, &insn, 1);  // 把首条指令原地改成 BRK
}
```

`aarch64_insn_patch_text()` 负责"边改边跑"——它要在所有 CPU 上安全地替换一条正在被执行的指令，这就是 kprobes 真正的硬骨头（涉及 IPI、停机补丁、`text_mutex`），但那是另一篇的故事。

### 一条断点指令触发后的完整生命

当一个倒霉进程执行到被改写的那条 `BRK`，CPU 立刻跳进异常向量，最终调用 ARM64 的 `kprobe_brk_handler()`（同文件 `:311`）。这里就是 kprobes 的"前台"：

```c
int __kprobes
kprobe_brk_handler(struct pt_regs *regs, unsigned long esr)
{
    ...
    p = get_kprobe((kprobe_opcode_t *) addr);   // 按 PC 查探针哈希表
    if (cur_kprobe) {
        if (!reenter_kprobe(p, regs, kcb))       // kprobe 套 kprobe：重入处理
            return DBG_HOOK_ERROR;
    } else {
        set_current_kprobe(p);
        kcb->kprobe_status = KPROBE_HIT_ACTIVE;
        if (!p->pre_handler || !p->pre_handler(p, regs))   // ① 调你的 pre_handler
            setup_singlestep(p, regs, kcb, 0);              // ② 单步执行原指令
        else
            reset_current_kprobe();
    }
    return DBG_HOOK_HANDLED;
}
```

完整生命是四步：

1. **断点命中** → 查 `kprobe_table` 哈希表拿到你的 `struct kprobe`。
2. **`pre_handler`** → 在原指令执行**之前**调用你注册的回调，把 `pt_regs`（CPU 寄存器快照）递给你。
3. **单步原指令** → `setup_singlestep()` 把原指令拷贝到一块专门的"执行槽"（insn slot，避免在原位执行又触发自己）单步跑一次，跑完再插一个"二次 BRK"。
4. **`post_handler`** → 单步收尾触发 `kprobe_ss_brk_handler()`（`:355`），它调 `post_kprobe_handler()` 执行你的 post 回调，然后放程序走。

这就是黑盒的全部：**断点替换 → pre → 单步 → post**。注意 `pre_handler` 返回非 0 会跳过单步（"我自己改了执行流，不用单步了"），这是少数高级用法。

### `fault_handler`：handler 出事时的安全网

> ⚠️ **接口已变（Linux 6.19 已删除）**：下面的叙述是给老内核的迁移说明，**6.19 上 `struct kprobe` 已不再有 `fault_handler` 字段**，别再往结构体里填它。

如果你的 handler 代码踩了非法内存（比如解引用了坏指针），会触发 page fault。入口是架构无关的 `kprobe_page_fault()`（`include/linux/kprobes.h:576`）——它先排除用户态、可抢占、当前没在跑 kprobe 这几种情况，确认无误后才调架构相关的 `kprobe_fault_handler()`。

**关键变化**：在较早的内核（commit `ec6aba3d2be1` 之前，约 6.6 之前）里，`struct kprobe` 有一个 `fault_handler` 字段，`kprobe_fault_handler()` 会回调你注册的 handler，由它决定"修好了继续"还是"交给内核默认机制"。但那套"用户态兜底"接口连同 `kprobe_fault_handler_t` typedef 已被移除。现在 6.19 里的 `kprobe_fault_handler()`（如 `arch/arm64/.../kprobes.c:280`、`arch/x86/kernel/kprobes/core.c:1033`）只干一件事：**遇到单步执行期间的 page fault，把指令指针拨回探针地址，让这次 fault 当作普通 page fault 继续走内核默认处理**——它不再回调任何用户态 hook。

也就是说：**6.19 上你的 `pre_handler`/`post_handler` 要是自己访问了坏内存，没有任何用户态兜底可挂，直接走内核默认 page fault 路径**（八成是 oops）。所以 handler 代码必须自己保证安全：别解引用来路不明的指针、别在没校验的情况下读用户态地址。

## `struct kprobe`：那张手术清单

整个机制的"配置单"就一个结构体 `struct kprobe`（`include/linux/kprobes.h:59`）。挑关键字段记（6.19 实有字段，对照源码核对过）：

| 字段 | 作用 |
|:---|:---|
| `symbol_name` | 要"开刀"的函数名，如 `"do_sys_open"`；底层 `_kprobe_addr()` 用 kallsyms 解析成内核虚拟地址，回填进 `addr` |
| `addr` | 解析后的探针地址（你也可以直接填地址） |
| `offset` | 函数内偏移，支持插到函数**中间**的任意指令（CISC 上偏移到指令中间会直接崩，慎用） |
| `pre_handler` | 函数执行**前**的回调，签名 `int (*)(struct kprobe *, struct pt_regs *)` |
| `post_handler` | 函数执行**后**的回调，签名 `void (*)(struct kprobe *, struct pt_regs *, unsigned long)` |
| `opcode` | 被替换掉的原指令（disarm 时写回去） |
| `ainsn` | 架构相关的"指令副本 + 单步信息"，单步执行就靠它 |
| `nmissed` | 被临时 disarm 而漏抓的次数（高频函数会涨） |
| `flags` | 状态位：`KPROBE_FLAG_DISABLED`、`KPROBE_FLAG_GONE`、`KPROBE_FLAG_FTRACE` 等 |

> 老笔记里常见的 `fault_handler` 字段**6.19 已删除**（见上一节），别再写。要兜底就在 handler 里自己写防御性代码。

注册/反注册 API：`register_kprobe(&p)` / `unregister_kprobe(&p)`，还有批量版 `register_kprobes`、临时开关 `disable_kprobe`/`enable_kprobe`。注册主流程在 `register_kprobe()`（`kernel/kprobes.c:1634`）里：先 `_kprobe_addr()`（`:1642`）算地址 → `check_kprobe_address_safe()`（`:1658`）查黑名单 → `__register_kprobe()`（`:1597`）把探针挂进 `kprobe_table` 哈希表并 `arm_kprobe()` 写断点。

> **铁律**：模块卸载必须 `unregister_kprobe()`。忘了的话，下次任何代码流经那个地址，内核会去触发一个已经失效的探针回调——直接内核 bug 甚至死机。泄漏的不是内存，是"控制流劫持点"。

### 黑名单：有些函数不能碰

不是所有函数都能探测。kprobes 自己的内部函数（`get_kprobe`、handler 们）要是被探，会无限递归死锁。内核用两道防线：源码里标 `__kprobes` / `nokprobe_inline` 注解，或用宏 `NOKPROBE_SYMBOL(handler_xxx)` 显式把某函数拉黑。查名单：`cat /sys/kernel/debug/kprobes/blacklist`。你写 kprobe 模块时，自己的所有 handler 都该用 `NOKPROBE_SYMBOL()` 保护起来。

## kprobe vs kretprobe：入口眼 vs 出口眼

普通 kprobe 只能看"函数进去时"的样子。但调试时我们常想问：**这函数到底返回了什么？** 这就是 **kretprobe（返回探针）**。

难点在于：函数返回时指令指针已经回到调用者那儿了，普通 post-handler 这会儿想拿返回值得深挖栈，又脏又跟架构强相关。kretprobe 的解法很巧：**在函数入口偷换返回地址。**

`register_kretprobe()`（`kernel/kprobes.c:2178`）做的事——它其实**先在函数入口注册一个普通 kprobe**，把这个 kprobe 的 `pre_handler` 偷偷设成内部函数 `pre_handler_kretprobe`（`:2103`）：

```c
rp->kp.pre_handler = pre_handler_kretprobe;   // 入口 kprobe 的回调
rp->kp.post_handler = NULL;
...
rp->rh = rethook_alloc((void *)rp, kretprobe_rethook_handler, ...);  // 返回钩子
ret = register_kprobe(&rp->kp);
```

函数被调用时，`pre_handler_kretprobe` 调 `rethook_hook()`（`:2120`）——这一步**把栈上的真实返回地址换成 trampoline 地址**并记下原件（具体改地址的脏活在 rethook 机制里，不在 kprobes 核心）。函数真返回时 CPU 跳进 trampoline（ARM64 走 `kretprobe_brk_handler`，`:374`），它最终回到你注册的 `rp->handler`，这时 `pt_regs` 里的返回值寄存器（x86 的 `ax`、ARM64 的 `regs[0]`）还热乎着。你注册的返回回调签名：

```c
int handler(struct kretprobe_instance *ri, struct pt_regs *regs);
```

拿返回值别手抠寄存器，用架构无关宏 `regs_return_value(regs)`。`struct kretprobe` 里 `kp`（内嵌 kprobe）、`handler`（返回回调）、`entry_handler`（入口回调，可选，返回非 0 表示"这次不探了"）、`maxactive`（最多同时探多少个并发实例，默认 `max(10, 2*num_possible_cpus())`，设小了会漏抓、`nmissed` 涨）、`data_size`（per-instance 私有空间大小）。

> **jprobe（跳转探针）已废弃，别用。** 它当年是专门偷函数参数的接口——**4.15 起标记弃用（commit `590c84593045`，加警告但仍可用），4.19 正式删除 API 实现**（commit `4de58696de07` 等一批）。原因很简单：偷参数直接靠 ABI 知识从 `pt_regs` 抠就行（下篇细讲），没必要维护一套复杂接口。维护老内核（<4.19）才可能碰见。

## kprobe events：不写模块，写一行就插桩

写模块、填 `struct kprobe`、编译、insmod——这套"静态 kprobe"每次改个函数名都得重来。现代内核有更优雅的：**kprobe events**，ftrace 的动态事件源。前提是内核开了 `CONFIG_KPROBE_EVENTS=y`（绝大多数发行版默认开）。

核心思想：把"探针"抽象成"事件"。你往 tracefs 的 `kprobe_events` 文件写一行配置，内核就帮你建一个动态 kprobe，输出进统一的 trace buffer。看它的源码（`kernel/trace/trace_kprobe.c`）就懂了——所谓"动态事件"底层就是一个 `struct trace_kprobe`（`:59`），里面套了个 `struct kretprobe rp`（`rp.kp` 当普通 kprobe 用）：

```c
struct trace_kprobe {
    struct dyn_event   devent;
    struct kretprobe   rp;        /* Use rp.kp for kprobe use */
    unsigned long __percpu *nhit;
    const char         *symbol;
    struct trace_probe tp;
};
```

创建逻辑（`:294` 附近）根据你是 kprobe 还是 kretprobe，把回调设成 `kprobe_dispatcher` 或 `kretprobe_dispatcher`（这俩负责把现场写进 trace buffer）。也就是说：**kprobe events 不是新机制，它就是把你本来要手写的"注册 + 回调填 buffer"这套活儿，换成写一行字符串、由内核代办。**

> **别误以为所有 kprobe 使用者都往 `kprobe_events` 写。** 三条路径要分清：① `perf probe`（`tools/perf/util/probe-file.c`）确实会写 `kprobe_events` 这个用户态文件；② eBPF / perf 的 **单点** kprobe attach 走 `perf_event_open()`（`PERF_TYPE_PROBE`），内核侧 `perf_kprobe_init()` 最终调 `create_local_trace_kprobe()`（`kernel/trace/trace_kprobe.c:1914`）——这是**内核内路径，复用了 trace_kprobe 的构建逻辑，但不经过用户态 `kprobe_events` 文件**；③ eBPF 更新的 **kprobe_multi link**（`BPF_LINK_TYPE_KPROBE_MULTI`）基于 **fprobe** 机制（`struct bpf_kprobe_multi_link` 里直接内嵌 `struct fprobe fp`，见 `kernel/trace/bpf_trace.c`），**连 trace_kprobe 都不碰**。一句话：能往文件里写的是 perf probe，eBPF 另有两条更直接的内核路径。

一行插桩的语法：

```
p:<事件名> <函数> [参数抓取...]
```

`p:` 是 kprobe，`r:` 是 kretprobe。建、开、看、关、删五步走：

```bash
cd /sys/kernel/tracing
echo 'p:myopen do_sys_open' >> kprobe_events        # 建
echo 1 > events/kprobes/myopen/enable                # 开
cat trace_pipe                                       # 看（实时流）
echo 0 > events/kprobes/myopen/enable                # 关
echo '-:myopen' >> kprobe_events                     # 删（减号 = 删除）
```

抓参数是它的杀手锏。`do_sys_open(int dfd, const char __user *filename, int flags, umode_t mode)` 第二个参数是文件名，x86_64 上在 `%si`，ARM64 上在 `regs[1]`，ARM-32 在 `%r1`（ABI 不同，见下表）。x86_64 抓文件名：

```bash
echo 'p:myopen do_sys_open file=+0(%si):string' >> kprobe_events
```

> ⚠️ **待亲测**：上面这串在 x86_64 上 OK，但搬到 ARM 上会报 `write error: Invalid argument`——因为 ARM 没 `%si`。ARM-32 得写 `+0(%r1):string`。这是 ABI（应用二进制接口）的差异，参数传递规则是架构定的：

| 架构 | 前 N 个参数寄存器 | 返回值 |
|:---|:---|:---|
| x86_64 | RDI, RSI, RDX, RCX, R8, R9 | RAX |
| ARM-32 | R0, R1, R2, R3 | R0 |
| ARM64 | X0~X7 | X0 |

这条"跨架构的坑"我们打算在 QEMU（arm64 + x86_64）上各跑一遍亲测，记下真实输出再补进来。

## 与 ftrace/trace_event 的关系

理清这三者的层级很关键：

- **kprobes** 是最底层的能力——改指令、陷异常、调回调，纯机制。
- **trace_event / ftrace events** 是上面那层"框架"——它定义了"事件"这个统一抽象（预置的 tracepoint + 动态的 kprobe/uprobe events），所有事件共享同一套 trace buffer、`enable`/`filter`/`format` 接口。这也是为什么你 `echo` 进 `kprobe_events` 后，新出现的 `events/kprobes/myopen/` 目录跟预置 tracepoint 的目录结构一模一样。
- **perf / eBPF** 是更上层的"使用者"——它们各自有 attach 路径（见上一节的三条路径区分），不一定都落到 `kprobe_events` 文件上。

所以"kprobe events 是 ftrace 的动态事件源"这句话，源码上的证据就是 `trace_kprobe.c` 把 `struct kretprobe` 包进 `trace_kprobe` 并注册成 `dyn_event`。

## 动手待亲测（占位）

本篇聚焦讲机制，完整的 `example/mini` 代码留到配套篇。这里先给两个验证方案，等 QEMU 亲测后补真实输出。

**方案 A：kprobe 模块插桩 `do_sys_open`。** 写一个最小模块：`static struct kprobe kp`，填 `symbol_name="do_sys_open"` + `pre_handler`（打印 `regs` 里第二个参数寄存器），`init` 里 `register_kprobe`、`exit` 里 `unregister_kprobe`。insmod 后在系统里 `cat` 一个文件触发，看 dmesg。

**方案 B：kprobe events 动态插 `kernel_clone`。** 不写代码，直接：

```bash
echo 'p:myclone kernel_clone' >> /sys/kernel/tracing/kprobe_events
echo 1 > /sys/kernel/tracing/events/kprobes/myclone/enable
cat /sys/kernel/tracing/trace_pipe   # 然后随便起个进程
```

> ⚠️ **待亲测**：以上命令与输出待在 QEMU ARM64/x86_64 上亲测核对后填入真实结果。

## 小结

kprobes 让我们在不重编内核的前提下，运行时在任意函数上插眼。它的黑盒就一句：**把首条指令换成断点（x86 `INT3`/ARM64 `BRK`/RISC-V `ebreak`），CPU 陷异常 → `pre_handler` → 单步原指令 → `post_handler`**。普通 kprobe 看入口、kretprobe 靠偷换返回地址看出口（trampoline 机制）。嫌写模块麻烦就用 kprobe events——往 `kprobe_events` 写一行，底层照样是 `struct trace_kprobe` 注册 kprobe。记住几条红线：**反注册不能忘**；**黑名单函数（含你自己的 handler，用 `NOKPROBE_SYMBOL` 保护）不能探**；还有一条容易踩的——**6.19 已删掉 `fault_handler` 这个用户态兜底，handler 自己访问坏内存没有 hook 可挂，会直接走默认 page fault**，所以 handler 必须自己写防御性代码。

## 延伸阅读

- 源码（Linux 6.19）：`kernel/kprobes.c`（核心：`register_kprobe`、`__register_kprobe`、`pre_handler_kretprobe`、`register_kretprobe`、`kretprobe_rethook_handler`）、`include/linux/kprobes.h`（`struct kprobe`/`struct kretprobe`/`kprobe_page_fault`；注意 6.19 已无 `fault_handler` 字段与 `kprobe_fault_handler_t` typedef）。
- 架构层：`arch/arm64/kernel/probes/kprobes.c`（`arch_arm_kprobe`、`kprobe_brk_handler`、`kprobe_ss_brk_handler`、`kretprobe_brk_handler`、`kprobe_fault_handler`）、`arch/x86/kernel/kprobes/core.c`（`INT3` 单步路径、`kprobe_fault_handler`）、RISC-V 在 `arch/riscv/kernel/probes/`。
- 事件层：`kernel/trace/trace_kprobe.c`（kprobe events 的创建与 dispatcher、`create_local_trace_kprobe`）、`kernel/trace/fprobe.c`（eBPF kprobe_multi 底层的 fprobe 机制）。
- 内核文档：[Kprobes concepts](https://docs.kernel.org/trace/kprobes.html)、[Kprobe-based Event Tracing](https://docs.kernel.org/trace/kprobetrace.html)、[Ftrace 索引页](https://docs.kernel.org/trace/index.html)。