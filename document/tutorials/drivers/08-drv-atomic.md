---
title: 原子操作、refcount 与内存屏障
slug: drv-atomic
difficulty: intermediate
tags: [原子操作, 引用计数, 内存屏障, 并发同步]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/drivers/07-drv-sync
related:
  - /tutorials/drivers/07-drv-sync
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch07.md
  - notes: document/notes/linux_kernel_device_drivers/ch07_1.md
  - notes: document/notes/linux_kernel_device_drivers/ch07_2.md
---

# 原子操作、refcount 与内存屏障

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 一条 `x++` 为什么会丢更新

写驱动的迟早撞上并发。最朴素的直觉是「共享变量加个锁不就行了」，但锁贵——自旋锁要空转、互斥锁要切上下文。于是内核另有一条路：原子操作。可在这之前，得先看明白一个朴素到容易被忽略的事实——**`x++` 根本不是一条指令**。

```c
int counter = 0;
/* 两个 CPU 同时执行 */
counter++;
```

`counter++` 在汇编里是三步（RMW，Read-Modify-Write）：先把 `counter` 从内存**读**进寄存器，在寄存器里**改**（加 1），再**写**回内存。两个 CPU 同时干这事，时间线可能是这样：CPU A 读到 0、CPU B 也读到 0，各自加成 1，各自写回 1——结果 `counter` 是 1，不是预期的 2。一次更新凭空蒸发了。这就是经典**丢失更新（lost update）**。

加锁当然能解，但代价是把整个 `++` 包进临界区。内核想要的，是一种让「读-改-写」三步像一条指令一样**不可被打断**的东西。这就是 `atomic_t` 存在的理由——靠 CPU 提供的硬件原子指令（x86 的 `lock` 前缀、ARM 的 `ldxr/stxr` 独占加载/存储、RISC-V 的 `lr/sc` 原子预留）把 RMW 拍进一条原子的指令序列。

## `atomic_t`：带原子语义的封装，不是普通 int

先看它长什么样（`include/linux/types.h`，Linux 6.19）：

```c
typedef struct {
    int counter;
} atomic_t;

#define ATOMIC_INIT(i) { (i) }
```

注意它是个**结构体包着一个 int**，而不是裸 `int`。这个封装有两层心思：一是让编译器**阻止你直接写 `v.counter++`**——那一脚下去原子性就没了；二是为架构层按需加调试位、强制缓存行对齐留出空间（具体对齐在各架构 `<asm/atomic.h>` 实现里做，不是这个 typedef 本身的固有属性）。64 位版本是 `atomic64_t`，里头是 `s64 counter`——这个简洁结构体定义在 `#ifdef CONFIG_64BIT` 下（`types.h`），32 位内核另有 `atomic64_t` 实现。

用法是清一色的函数族，**绝不直接碰 `.counter` 字段**：

```c
static atomic_t v = ATOMIC_INIT(0);   /* 静态定义并初始化 */

atomic_set(&v, 4);       /* 设置为 4       */
atomic_add(1, &v);       /* v += 1        */
atomic_inc(&v);          /* v++           */
int val = atomic_read(&v);  /* 读当前值    */
```

真正让 `atomic_t` 强大的，是**条件判断与修改合一**的接口。最经典的是 `atomic_dec_and_test()`——原子地减 1，并判断结果是否为 0，整个动作没人能插一脚：

```c
if (atomic_dec_and_test(&v)) {
    /* 减完正好是 0：我是最后一个引用者，可以 kfree 了 */
    kfree(obj);
}
```

同族还有 `atomic_inc_and_test()`（加完为 0、通常是下溢信号）、`atomic_sub_and_test()`、`atomic_add_negative()`。这些是手写引用计数的老搭档——但下面会讲，现代内核更推荐 `refcount_t`，因为 `atomic_t` 有个致命软肋。

**踩坑提醒**：`atomic_t` 只保证**这一个变量**的操作原子。如果 `struct { atomic_t a; int b; }`，你想让 `a` 和 `b` 保持一致，`atomic_t` 帮不了你，得用自旋锁/互斥锁把这对操作框成一个临界区。它不替代序列化，只是单变量的并发安全计数器。

## 为什么不用 `volatile`

很多人第一反应：既然怕编译器优化、怕并发，那 `volatile` 修饰一下不就行了？这是内核并发里最经典的误解。

`volatile` 的本意是告诉编译器「这个变量可能被硬件/中断/别的线程莫名其妙改掉，别把它缓存进寄存器，每次老老实实去内存读」。它确实**只防编译器优化这一层**。但它有两个硬伤，挡不住 RMW 丢失更新：

1. **不保证原子性**。`volatile int i; i++;` 仍是三步指令，`volatile` 让你每次都回内存取值，却拦不住两个 CPU 在三条指令的缝隙里互相踩。`counter++` 该丢还是丢。
2. **不充当内存屏障**。C 标准只保证 `volatile` 变量**之间**的访问不被编译器重排，管不了非 `volatile` 变量，更管不了 **CPU 硬件层面的乱序执行**。

内核文档 `Documentation/process/volatile-considered-harmful.rst` 把这点钉得很死：内核里要并发安全，要么用锁，要么用原子操作/`refcount`，要么显式加内存屏障——`volatile` 不是同步原语，它只在 MMIO 寄存器访问那种「每次都得真打在硬件上」的场景才合理。

## `refcount_t`：带溢出/下溢检测的安全计数器

回到那个软肋。拿 `atomic_t` 手搓引用计数，多核疯狂并发下计数可能被 `dec` 成负数（重复释放）或被 `inc` 到回绕（`INT_MAX` → `INT_MIN`）。一旦回绕，`atomic_dec_and_test()` 可能误判为 0 而 `kfree` 一个还有人用的对象——**Use-After-Free（UAF）**，内核安全漏洞的一大温床。

内核为此造了 `refcount_t`（`include/linux/refcount_types.h`）：

```c
typedef struct refcount_struct {
    atomic_t refs;
} refcount_t;
```

里头还是个 `atomic_t`，但**外层包装加了溢出/下溢检测**。核心机制是**饱和（saturation）**。看 `include/linux/refcount.h` 的定义：

```c
#define REFCOUNT_SATURATED   (INT_MIN / 2)   /* 0xc000_0000 */
```

一旦检测到非法状态（下溢、溢出、对 0 加引用），计数被钉死在 `REFCOUNT_SATURATED`，并通过 `refcount_warn_saturate()`（`lib/refcount.c`）打 `WARN_ONCE` 提示具体毛病。枚举 `enum refcount_saturation_type` 把故障分得很细：

```c
enum refcount_saturation_type {
    REFCOUNT_ADD_NOT_ZERO_OVF, /* add_not_zero 溢出 */
    REFCOUNT_ADD_OVF,          /* 溢出        */
    REFCOUNT_ADD_UAF,          /* 对 0 加引用  */
    REFCOUNT_SUB_UAF,          /* 下溢        */
    REFCOUNT_DEC_LEAK,         /* 减到 0 仍调用 dec，泄露 */
};
```

对应的 `WARN` 文案也很直白：`"underflow; use-after-free"`、`"addition on 0; use-after-free"`、`"decrement hit 0; leaking memory"`。饱和值的位置源码头文件有一张 ASCII 图说得很清楚（`refcount.h`）：

```
                           INT_MAX     REFCOUNT_SATURATED   UINT_MAX
0                          (0x7fff_ffff)    (0xc000_0000)    (0xffff_ffff)
+--------------------------------+----------------+----------------+
                                  <---------- bad value! ---------->

(in a signed view of the world, the "bad value" range corresponds to
a negative counter value).
```

也就是说，`REFCOUNT_SATURATED` 故意落在 **`INT_MAX` 与 `UINT_MAX` 之间**（有符号视角看就是负值区），离 0 隔着整整一个 `INT_MAX`——正常计数（`0..INT_MAX`）怎么加减都够不到它，攻击者也难在饱和区里反复腾挪骗过 `dec_and_test`。

接口和 `atomic_t` 几乎一一对应，但语义更安全：

```c
static refcount_t r = REFCOUNT_INIT(1);

refcount_set(&r, 1);

/* 拿引用：原值非 0 才成功加 1，否则对象正在销毁，不能再用 */
if (refcount_inc_not_zero(&r)) { /* ... 拿到引用 ... */ }

/* 放引用：减完为 0 表示自己是最后一个，可释放 */
if (refcount_dec_and_test(&r)) { kfree(obj); }

/* 单纯加/减，违规时会 WARN（inc 遇 0、dec 减到 0 仍继续） */
refcount_inc(&r);
refcount_dec(&r);
```

**代价是性能**。看 `refcount.h` 里 `__refcount_sub_and_test()` 的实现（Linux 6.19，这是 `refcount_dec_and_test` 一路追到底的真实函数体；`__refcount_dec_and_test()` 只是 `i=1` 的一行特化包装）：

```c
bool __refcount_sub_and_test(int i, refcount_t *r, int *oldp)
{
    int old = atomic_fetch_sub_release(i, &r->refs);

    if (oldp)
        *oldp = old;

    if (old > 0 && old == i) {
        smp_acquire__after_ctrl_dep();
        return true;          /* 减完正好是 0，可以 free */
    }

    if (unlikely(old <= 0 || old - i < 0))
        refcount_warn_saturate(r, REFCOUNT_SUB_UAF); /* 下溢报警 */

    return false;
}
```

`atomic_fetch_sub_release` 拿到旧值后还得做范围检查、必要时调 `refcount_warn_saturate`——比裸 `atomic_dec` 多一串判断。所以结论很明确：**只做纯统计标志位，用 `atomic_t` 就够；涉及对象生命周期管理，必须 `refcount_t`。**

## 内存屏障：挡住 CPU 和编译器的「手快」

讲完「值的并发安全」，还有一个更阴险的问题——**顺序**。先灌一个反直觉的事实：**你在 C 代码里写的顺序，不一定是内存里实际发生的顺序。**

两个元凶：编译器为了性能会**重排指令**，CPU 为了流水线效率会**乱序执行**。单核无伤大雅，可一旦跨核通信——尤其是跟 DMA 控制器、网卡这类「死脑筋」的硬件打交道——顺序错了就是灾难。

经典模式是 **flag + data**：CPU A 先写数据，再写一个标志位通知 CPU B「数据好了」；CPU B 轮询标志位，看到 1 就去读数据。

```c
/* CPU A */
data = 42;
flag  = 1;

/* CPU B */
while (flag != 1) ;
printk("%d\n", data);   /* 期望读到 42 */
```

逻辑上无懈可击。可 CPU B 可能先看到 `flag == 1`、再去读 `data` 时却读到旧值——因为 CPU A 那两条 `store` 在硬件层面被重排了，或者两条 `load` 在 B 这边被重排了。**没有屏障，"先写 data 后写 flag" 只是你的美好愿望。**

内核给的武器是内存屏障宏。看 `include/asm-generic/barrier.h`（Linux 6.19）：

```c
#define mb()    do { kcsan_mb();  __mb();  } while (0)   /* 全屏障 */
#define rmb()   do { kcsan_rmb(); __rmb(); } while (0)   /* 读屏障 */
#define wmb()   do { kcsan_wmb(); __wmb(); } while (0)   /* 写屏障 */
```

- **`wmb()`**（Write Memory Barrier）：屏障**之前**的所有写，必须全部落地、对其他观察者可见，之后才允许屏障之后的写发生。填 DMA 描述符时用它——先把地址、选项这些铺垫写完，再让标志位「拍板」生效。
- **`rmb()`**（Read Memory Barrier）：屏障之前的读必须先完成，才能执行后面的读。读标志位后、读数据前插一道。
- **`mb()`**：读写都挡，最重。

回到 Realtek 8139 网卡驱动的真实例子（`drivers/net/ethernet/realtek/8139cp.c`，`cp_start_xmit`）。发一个包要先填 DMA 描述符 `struct cp_desc { opts1; opts2; addr; }`，再置位 `opts1` 的「有效」位让硬件开干：

```c
txd->opts2 = opts2;
txd->addr  = cpu_to_le64(mapping);   /* 货架号 */

wmb();                                /* 钉子：铺垫必须先落地 */

opts1 |= eor | len | FirstFrag | LastFrag;
txd->opts1 = cpu_to_le32(opts1);      /* 拍板：让硬件开干 */

wmb();                                /* 再一道：有效位立刻对硬件可见 */
```

两道 `wmb()` 各司其职：第一道保住数据依赖（地址不能被重排到标志位之后），第二道保证命令立刻生效。少了它们，x86 上可能「运气好」不出事（x86 内存模型强，硬件本来就有不少顺序保证），但代码一旦移植到 ARM 或 RISC-V，或换块更挑剔的网卡，就会收获凌晨三点负载高峰才复现的灵异 Bug。**这种跨内存模型的坑，屏障是你唯一的保险。**

## `smp_*` 屏障 vs 非 smp 屏障

你会注意到屏障分两套：`wmb()/rmb()/mb()` 和 `smp_wmb()/smp_rmb()/smp_mb()`。区别在**作用域**：

- **`wmb()/rmb()/mb()`**：**总是生效**，连单核（UP）也挡，主要给**与硬件设备/DMA 通信**用——因为设备根本不关心你几核，它只按内存里字面顺序读。
- **`smp_wmb()/smp_rmb()/smp_mb()`**：**只在 SMP（多核）编译时才插真屏障**。看 `barrier.h` 的真实结构——它俩由 `CONFIG_SMP` 二选一，不是背靠背连续两个 `#ifndef`：

```c
#ifdef CONFIG_SMP

#ifndef smp_mb
#define smp_mb() do { kcsan_mb();  __smp_mb(); } while (0)
#endif
#ifndef smp_rmb
#define smp_rmb() do { kcsan_rmb(); __smp_rmb(); } while (0)
#endif
#ifndef smp_wmb
#define smp_wmb() do { kcsan_wmb(); __smp_wmb(); } while (0)
#endif

#else /* !CONFIG_SMP */

#ifndef smp_mb
#define smp_mb() barrier()
#endif
#ifndef smp_rmb
#define smp_rmb() barrier()
#endif
#ifndef smp_wmb
#define smp_wmb() barrier()   /* UP 上退化成编译器屏障，不挡 CPU */
#endif

#endif /* CONFIG_SMP */
```

因为单核上 CPU 乱序只会被中断看见，而中断返回和单核执行流之间的顺序约束，靠编译器屏障（`barrier()`，即 `asm volatile("" ::: "memory")`）就够。多核才需要真正插硬件屏障指令。

**规则**：纯软件的多核通信用 `smp_*`；跟硬件/DMA 打交道用不带 `smp_` 的那套。

## 动手验证方案（待亲测）

> ⚠️ **待亲测**：以下方案我们会在 QEMU（arm64 / x86_64）上跑模块验证，记下真实命令与 `dmesg` 输出后再补。

1. **`atomic_inc` 不丢更新**：起 N 个内核线程（`kthread_run`）各自对同一个 `atomic_t` 做 M 次 `atomic_inc`，结束读 `atomic_read`，应严格等于 `N * M`。换成裸 `int` 的 `counter++` 作对照，看更新丢失。
2. **`refcount_t` 溢出/下溢报警**：构造重复 `refcount_dec` 或对 0 `refcount_inc`，`dmesg` 应出现 `"refcount_t: underflow; use-after-free"` 之类 `WARN`，且计数被钉在 `REFCOUNT_SATURATED`。
3. **屏障保 flag/data 顺序**：起生产者/消费者线程，不带屏障跑大量迭代观察乱序导致的脏读；加 `smp_wmb()/smp_rmb()` 后消失。

模块源码与 `Makefile`（多架构，参考 `example/common/Makefile.arch`）验证通过后，落到 `example/mini/atomic-refcount-barrier/`。

## 小结

这一篇串起了一条线：**原子操作保「值」，内存屏障保「顺序」，`refcount_t` 在原子之上再加一层「生命周期安全」。**

- `atomic_t` 是带原子语义的封装（`include/linux/types.h`），靠硬件 RMW 指令让 `inc/dec/add` 不可打断，但只保护单个变量、不替代序列化；`atomic64_t` 的简洁结构体定义在 `#ifdef CONFIG_64BIT` 下。
- `volatile` 只防编译器优化，**既不保证原子性也不充当内存屏障**，不是同步原语。
- `refcount_t`（`include/linux/refcount_types.h` + `include/linux/refcount.h`）针对引用计数加饱和检测，下溢/溢出会 `WARN` 并钉死在 `REFCOUNT_SATURATED`（落在 `INT_MAX` 与 `UINT_MAX` 之间、有符号视角的负值区），代价是比 `atomic_t` 略慢——做生命周期管理必须用它。
- 内存屏障（`include/asm-generic/barrier.h`）：`wmb()`/`rmb()`/`mb()` 总生效（给硬件/DMA 用），`smp_*` 系列由 `CONFIG_SMP` 决定——SMP 编译插真屏障，UP 退化成 `barrier()`（只挡编译器）；这套机制挡住编译器重排和 CPU 乱序，保住 flag/data 模式的顺序。

## 延伸阅读

- 源码（Linux 6.19）：
  - `include/linux/types.h`、`include/linux/refcount_types.h` —— `atomic_t` / `atomic64_t` / `refcount_t` 类型定义。
  - `include/linux/atomic.h`、`include/linux/atomic/atomic-instrumented.h` —— 原子操作接口与 acquire/release/relaxed 变体。
  - `include/linux/refcount.h`、`lib/refcount.c` —— `refcount_*` 实现、饱和与 `refcount_warn_saturate()`。
  - `include/asm-generic/barrier.h` —— `mb/rmb/wmb` 与 `smp_*` 屏障宏。
- kernel.org 文档：
  - [Core API — Memory Barriers](https://docs.kernel.org/core-api/wrappers/memory-barriers.html)：内存屏障权威长文（Howells/McKenney/Deacon/Zijlstra 合著）。这个在线页面就是源码树 `Documentation/memory-barriers.txt` 的全文渲染（`.rst` 只是 `.. include::` 薄包装），看哪个都一样。
  - `Documentation/process/volatile-considered-harmful.rst`（为什么不要拿 `volatile` 当同步手段）。