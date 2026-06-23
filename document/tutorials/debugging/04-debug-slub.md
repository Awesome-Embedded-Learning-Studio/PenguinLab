---

title: SLUB 调试：红区、毒药与追踪
slug: debug-slub
prerequisites:
  - /tutorials/kernel/mm/02-mm-slab
next:
  - /tutorials/debugging/05-debug-kasan
difficulty: intermediate
tags: [调试, 内存, SLUB, KASAN]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
sources:
  - notes: document/notes/linux_kernel_programming/ch06_2.md
  - notes: document/notes/linux_kernel_programming/ch06_4.md
  - notes: document/notes/linux_kernel_programming/ch06_5.md
---

# SLUB 调试：红区、毒药与追踪

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解(函数/数据结构/数值已逐条核对 `mm/slub.c`、`include/linux/poison.h`、`mm/slab.h`);具体行号与命令输出待 QEMU 亲测核对。

## slab 出了问题最难查

承接 [SLAB/SLUB 分配器](/tutorials/kernel/mm/02-mm-slab) 那篇，我们知道 `kmem_cache` 把固定大小的对象攒成一池反复用，省得走 buddy 那套大动干戈的分配。但这个"反复用"恰恰是它最坑的地方——一个对象这秒是结构体 A，下秒被归还，再下秒可能就分给了别人当结构体 B。

于是内核里最阴间的两类 bug 全砸在 slab 上：

- **越界写(buffer overrun)**：对象只有 64 字节，你写了 80 字节，多出来的 16 字节糊到了隔壁对象头上。隔壁对象的内容莫名其妙变了，但**两个对象本身都"正常活着"**，谁也不 panic，bug 要等很久以后才以八竿子打不着的方式爆出来。
- **释放后使用(UAF, use-after-free)**：`kfree(p)` 之后你又去读 `p`，如果那块内存还没被别人拿走，你读到的还是旧数据，程序"看起来对"——直到某天别人分配走了那块内存，你读到的全是垃圾。

这类 bug 的可怕之处在于：**错误现场会消失**。等你发现隔壁对象坏了，早就过了案发时间，栈都没了。这就是 SLUB 调试要解决的核心矛盾——**在分配/释放的瞬间布下哨兵，让破坏在发生时就报警，而不是等后果蔓延**。

## slub_debug：四个开关一把抓

SLUB 把调试能力拆成四类，用一个启动参数 `slub_debug=` 统一控制，每个能力对应一个字母：

| 字母 | 能力 | 逮什么 bug |
|------|------|-----------|
| `F` | **F**ree sanity(一致性检查) | 释放时基本健全性检查(重复释放、错误指针) |
| `Z` | Red **Z**one(红区) | 越界写 |
| `P` | **P**oison(毒药) | 未初始化读 / UAF 读 |
| `U` | Alloc/free tracking(**U**se trace) | 内存泄漏 |

启动时一行搞定：

```bash
# 给所有 slab cache 开全部四类调试
slub_debug=FZPU

# 只给 kmalloc-64 开，其余不动
slub_debug=FZP,kmalloc-64

# 关掉所有(调试开太大想回退时用)
slub_debug=-,kmalloc-64
```

这四个字母背后对应的不是四个独立子系统，而是 `struct kmem_cache` 上一组 debug 标志位。内核在 `mm/slub.c` 里把 `slub_debug` 字符串解析进全局位掩码，然后每个 cache 创建时根据它来决定 `flags` 里要不要置上 `SLAB_CONSISTENCY_CHECKS`、`SLAB_RED_ZONE`、`SLAB_POISON`、`SLAB_STORE_USER` 这几个标志。**这些标志位会真实改变对象在内存里的布局**——下面逐个讲。

## Red Zone：对象两侧站两个哨兵

`Z` 开的是 Red Zone(红区)。思路特别直白：既然越界写会糊到隔壁对象，那我就在**每个对象的有效区域之后塞一段哨兵字节**，分配器知道这段字节应该是什么值，一旦被改了，就是有人越界了。

在 SLUB 里，Red Zone 不是你想的"红色"，它就是一段固定填充字节，而且**空闲对象和已分配对象填的值不一样**。权威定义在 `include/linux/poison.h:41-42`：

```c
/* include/linux/poison.h */
#define SLUB_RED_INACTIVE	0xbb	/* when obj is inactive */
#define SLUB_RED_ACTIVE		0xcc	/* when obj is active */
```

红区逻辑是**双向分值**的：空闲对象的红区是 `0xbb`(`SLUB_RED_INACTIVE`)，对象一旦被分配出去、变成"使用中"，它的红区就被改写成 `0xcc`(`SLUB_RED_ACTIVE`)。`mm/slub.c` 顶部的 Object layout 注释(`mm/slub.c:1350-1387`)把这套布局钉死了：

```
object address
    Bytes of the object to be managed.
    ... 对象体 ...
object + s->object_size
    Padding to reach word boundary. This is also used for Redzoning.
    We fill with 0xbb (SLUB_RED_INACTIVE) for inactive objects and with
    0xcc (SLUB_RED_ACTIVE) for objects in use.
object + s->inuse
    Meta data starts here. (free pointer / tracking / ...)
object + s->size
    Nothing is used beyond s->size.
```

注意红区塞在 `object_size` 到 `inuse` 这段缝隙里(SLUB 为了对齐，对象实际占的格子往往比你申请的大一点)。这段额外开销在 cache 创建时被算进每个对象的 `inuse`/`size`，所以**开了 Red Zone 之后内存占用会涨**。

检查的时机很关键，而且**两个方向各查各的**：

- **分配时**：对象被领走前，`alloc_debug_processing()`(Linux 6.19, `mm/slub.c:1717`) 调 `check_object()` 校验它此刻还应该是空闲态(`SLUB_RED_INACTIVE=0xbb`)，确认没人偷偷写过这块即将交给你的内存。
- **释放时**：对象被还回时，`free_debug_processing()`(Linux 6.19, `mm/slub.c:4309`，内部走 `free_consistency_checks`) 调 `check_object()` 校验它此刻还应该是使用态(`SLUB_RED_ACTIVE=0xcc`)，看你在用它的期间有没有越界糊到红区。

`check_object()`(`mm/slub.c:1448`) 逐字节比对的活儿最终落在 `check_bytes_and_report()`(`mm/slub.c:1318`)：

```c
/* mm/slub.c, 简化自 check_bytes_and_report() */
static u8 *check_bytes_and_report(struct kmem_cache *s, struct slab *slab,
                                  u8 *object, const char *what,
                                  u8 *start, unsigned int value,
                                  unsigned int bytes, bool must_fail)
{
    /* 从 start 开始，期望每个字节 == value，逐字节比对；
       发现不一致就记录 fault 字节、打印详尽报告 */
    ...
}
```

一旦对不上，`check_bytes_and_report()` 立刻打印一份详尽报告：哪个 cache、哪个 slab、对象地址、**哪个字节被改成了什么值**、调用栈。这份报告长这样(待亲测核对)：

```
=============================================================================
BUG kmalloc-64 (Not tainted): Redzone overwritten
INFO: 0xffff...: 6b 6b 6b 6b cc cc cc cc   <- 应该是 cc(RED_ACTIVE)，被写成了 6b
INFO: Slab 0xffff... objects=16 used=1
INFO: Object 0xffff... @offset=64
Call trace:
 [<...>] my_buggy_write+0x20/0x40
```

这个 `cc cc cc cc` 才是案发现场(使用中对象的红区)——你能精确看到越界写从第几个字节开始、被改成了什么。**Red Zone 的精髓在于"延后报警"：你越界的当下未必报，要等释放(或下次分配)那个瞬间才一并清算。** 所以如果你有个对象从来不释放(比如全局静态分配后又越界)，Red Zone 抓不到它，得靠下面的 Poison 或 KASAN。

## Poison：往内存里下毒

`P` 开的是 Poison(毒药)。Red Zone 只盯对象边缘，Poison 把整个对象的内部都盯上，而且它管的是更阴间的问题：**用了没初始化的内存，或用了已经释放的内存**。

Poison 的玩法是"填特定值，读出来要是这个值就说明有问题"。权威定义在 `include/linux/poison.h:45-47`，三个值各司其职：

```c
/* include/linux/poison.h */
#define POISON_INUSE	0x5a	/* for use-uninitialised poisoning */
#define POISON_FREE	0x6b	/* for use-after-free poisoning */
#define POISON_END	0xa5	/* end-byte of poisoning */
```

注意别被名字带偏——这套命名讲的是"填在哪个区域"，对照 `mm/slub.c:1358-1379` 的 Object layout 注释：

- **对象体内部**(`object address` 到 `object_size` 之间)：用 **`0x6b`(`POISON_FREE`)** 投毒，并且**末尾一个字节**单独填 **`0xa5`(`POISON_END`)** 当哨兵。对象体整块填 0x6b、收尾加一个 0xa5，是 free 之后的标准姿态。
- **对象之外的 padding/对齐缝隙**：用 **`0x5a`(`POISON_INUSE`)** 填充。

所以**对象内部的毒是 `0x6b`(`POISON_FREE`)，不是 `0x5a`**；`0x5a` 是给对象之外的对齐缝隙用的。这点老资料里经常混。

投毒和校验是**因果分两步**的，方向要记牢：

- **释放时投毒**：`slab_free()` → `free_debug_processing()` → `init_object()`(Linux 6.19, `mm/slub.c:1270`)。`init_object()` 在释放方向拿 `SLUB_RED_INACTIVE` 把红区/对齐缝隙抹回去、把对象体填成 `POISON_FREE(0x6b)`、末字节填 `POISON_END(0xa5)`(`mm/slub.c:1295-1296`)。free 的那一刻，这块内存就被"下了毒"。
- **分配时校验**：`slab_alloc()` 走到 `alloc_debug_processing()` → `check_object()`(`mm/slub.c:1448`)。它把上次 free 时投的毒逐字节比对，**如果毒药值被动过**，就说明上一个使用者在 free 之后还偷偷写过(UAF 的"写后释放"变种)，立刻报 `Poison overwritten`。

> 顺带一提：`set_orig_size()`(`mm/slub.c:860`) 跟投毒没关系，它只干一件事——把这次 `kmalloc` 的**原始请求大小**存进对象元数据(配合 `SLAB_KMALLOC` 做 kmalloc 红区用)。别把它混进投毒叙事。

所以 Poison 能逮两种问题：

1. **UMR(使用未初始化内存)**：你分配了对象却没初始化就拿来用，读到一堆 `0x6b`，逻辑可能就错了。分配器没法直接知道你读没读(所以不直接 oops)，但 `0x6b 6b 6b 6b` 这种特征值出现在你的数据里时，基本就是没初始化的铁证。
2. **UAF 读**：free 之后对象体被填了 `0x6b` 毒药，你再读，读到的就是毒药值，典型征兆是看到一个指针字段是 `0x6b6b6b6b6b6b6b6b`，直接解引用就是 oops。

Poison 比 Red Zone 贵——它每次 alloc/free 都要扫整个对象填值/比对，对象越大越慢。这就是为什么默认不开。

## alloc/free track：给每个对象挂一份案底

`U` 开的是 tracking，SLUB 里对应的标志叫 `SLAB_STORE_USER`。它的活儿是在每个对象的元数据里**存下分配它和释放它的那次调用信息**。这样一旦对象出问题，你能直接看到"谁分配的、谁释放的"，追凶链路完整。

数据结构是 `mm/slub.c:340` 定义的 `struct track`(Linux 6.19)：

```c
/* mm/slub.c:339-348 */
#define TRACK_ADDRS_COUNT 16

struct track {
    unsigned long addr;          /* 触发分配/释放的那一帧 IP */
#ifdef CONFIG_STACKDEPOT
    depot_stack_handle_t handle; /* 指向 stack_depot 里的完整调用栈 */
#endif
    int cpu;                     /* 哪个 CPU 分配/释放的 */
    int pid;                     /* 哪个进程 */
    unsigned long when;          /* jiffies 时间戳 */
};

enum track_item { TRACK_ALLOC, TRACK_FREE };
```

这里有个关键点容易看走眼：`struct track` 里**只存一个 `addr`(单帧)，不是一整条调用栈**。完整的调用栈是 `set_track_prepare()`(`mm/slub.c:1041`) 用一个长度为 `TRACK_ADDRS_COUNT(16)` 的**局部数组** `entries[16]` 抓下来，再 `stack_depot_save()` 进栈仓库(stack depot)，返回的 `handle` 句柄存在 `track->handle` 里。要看完整栈，得拿这个 `handle` 去 stack_depot 反查。换句话说，**完整栈存在 stack_depot，track 上只挂句柄**——别误以为 track 里直接挂着 16 帧数组。

每个对象旁边(`get_info_end()` 之后)挂着 `ALLOC`/`FREE` 两份 `struct track`(各一份，共 `2 * sizeof(struct track)`)。读取它们的入口是 `get_track()`(`mm/slub.c:1030`)，打印栈的入口是 `print_track()`(`mm/slub.c:1093`) / `print_trailer()`(`mm/slub.c:1172`)。

track 最香的用法不是逐个查对象，而是**逮内存泄漏**：在 `kmem_cache_destroy()` 销毁整个 cache 时，SLUB 会扫一遍所有 slab，对每个**还没被释放的对象**调 `print_tracking()`(`mm/slub.c:1111`)，把它分配时的栈打印出来(`mm/slub.c:8148` 就是这个路径)。于是一个模块卸载、cache 销毁，控制台上哗啦啦列出所有"分配了却没归还"的对象及其分配栈——泄漏点一目了然：

```
INFO: Slab 0xffff... objects=16 used=3
INFO: Object 0xffff... @offset=0, inuse=64
Allocated in my_module_init+0x2c/0x80 age=X cpu=0 pid=123
 [<...>] my_module_init+0x2c/0x80
 [<...>] do_one_initcall+0x...
 [<...>] ...
```

这就是为什么调试内存泄漏时，**先把模块拆出独立 cache(`kmem_cache_create`)再开 `SLAB_STORE_USER`，然后反复 modprobe/rmmod** 是经典套路——rmmod 销毁 cache 那一下，泄漏栈自动浮出来。

## 运行时开关：能查、但不能随便改

启动参数是"全局默认"，但很多时候你已经跑起来了，想看看当前状态。SLUB 给了 sysfs 接口，每个 cache 都有自己的目录：

```
/sys/kernel/slab/<cache-name>/
```

比如 `kmalloc-64` 就是 `/sys/kernel/slab/kmalloc-64/`。里面有一堆文件，关键的几个：

- **`red_zone` / `poison` / `store_user` / `sanity_checks`**：这几个**都是只读的**(`mm/slub.c:9440/9447/9454/9427`，全是 `SLAB_ATTR_RO`)，只能 `cat` 看"当前这个 cache 开了哪些 debug 标志"，**不能 `echo 1 >` 动态开**。一旦写了会失败。SLUB 的设计是：cache 创建时(`slub_debug=` 解析落位)flag 就定死了，运行中不易改。
- **`validate`**：这是唯一一个能写的调试触发(`mm/slub.c:9461-9473`，`SLAB_ATTR`)。`echo 1 > /sys/kernel/slab/<cache>/validate` 会触发一次 `validate_slab_cache()` 全盘扫描——但前提是 `kmem_cache_debug(s)` 已经为真(即这个 cache 本来就开着 debug)；对没开 debug 的 cache 写 1，`validate_store()` 会返回 `-EINVAL` 静默拒绝。这是"主动扫一遍、把潜伏问题逼出来"的开关，不是"开 debug"的开关。
- **`slabs` / `objects` / `object_size`**：看这个 cache 的基本账(也都是只读)。

还有一个老牌工具 `slabinfo`(内核源码 `tools/mm/slabinfo.c`)，它就是读 `/proc/slabinfo` 和 `/sys/kernel/slab/` 把信息整理成人话。最常用的几个参数(`tools/mm/slabinfo.c:111-145` 的 usage)：`slabinfo -t`(或 `--tracking`)吐出各 cache 的分配/释放统计、`slabinfo -v`(或 `--validate`)对开了 debug 的 cache 做一次校验、`slabinfo -r` 看单个 cache 的详细报告。**想在用户态"按调用栈聚合看分配/释放"是用 `slabinfo -t`，不是去 `cat` 某个 sysfs 文件**——6.19 的 `/sys/kernel/slab/<cache>/` 下并没有 `alloc_calls`/`free_calls` 这种文件，那种聚合统计是 slabinfo 工具读 `/proc/slabinfo` + debug 数据后算出来的。

至于"运行时动态开 debug"这件事：6.19 里**没有**给单个 cache 动态打开 red_zone/poison 的 sysfs 写接口。要切 debug 配置，基本就是重启改 `slub_debug=` 启动参数这一条正路。slabinfo 工具自带的 `--debug=FZPU`(对应 `-da`)那套是**给 slabinfo 工具自己看的输出开关**，不会真去改内核里 cache 的 flag——别误以为它能在运行中给 cache 开 debug。

内核侧判断要不要走带检查的慢路径，靠的是 `kmem_cache_debug(s)`(`mm/slub.c:252`，是个 `static inline` 内部封装，背后是 `mm/slab.h:490` 的 `kmem_cache_debug_flags()`)。它检查的是 `SLAB_DEBUG_FLAGS`(`mm/slab.h:434`，=`SLAB_RED_ZONE | SLAB_POISON | SLAB_STORE_USER | SLAB_TRACE | SLAB_CONSISTENCY_CHECKS`)。**只要 cache 开着这组标志里的任何一个，alloc/free 就绕过 cmpxchg 快路径，改走 `alloc_debug_processing()`/`free_debug_processing()` 带检查的慢路径**——这就是开 debug 有性能损失的根因。(顺带澄清一个常见误传：6.19 内核里**并没有 `SLAB_MEMCPY` 这个标志**，快慢路径分流的判据就是上面这条 `kmem_cache_debug(s)`，不是某个 memcpy 标志。)

## 和 KASAN 怎么分工

读到这儿你可能会问：这玩意和 KASAN(Address Sanitizer)不都是查内存破坏的吗？

分工是这样的：

- **SLUB debug 轻量、针对性强**：它只管 slab 分配出来的内存，机制简单(填字节、存栈)，开销主要在 alloc/free 路径。适合"我知道大概是 slab 出问题，想低成本长期开着盯"。
- **KASAN 通用、覆盖广但重**：它给**所有**内存(包括 buddy 直接给的 page、栈变量、全局变量)都罩上一层影子内存(shadow memory)，越界/UAF 都能逮，精度更高(能逮单字节越界、读到已释放后又被重用的数据)。代价是内存翻倍影子、每次访存都有插桩检查，性能开销大(典型 2-3 倍 slowdown)。

实战上：**复现阶段用 KASAN** 一把锁死范围(它报警最及时，不依赖 free 时机)；**定位到是 slab cache 后切到 SLUB debug** 长期盯，顺便拿 alloc/free track 查泄漏栈。两者不互斥，可以同时开，只是都开会很慢。

## 动手验证方案(待 QEMU 亲测)

按下面的套路走一遍，把上面讲的机制亲自跑出报告。具体命令输出待亲测后回填。

**1. 启动带 slub_debug 的内核**

在 QEMU 启动参数里给内核传 `slub_debug=FZPU`(或先只开 `ZP` 试水)，观察 dmesg 确认调试已启用：

```bash
# 引导后确认
dmesg | grep -i slub        # 期待看到 SLUB debug 相关行，待亲测核对
cat /sys/kernel/slab/kmalloc-64/red_zone   # 应为 1（只读，确认当前开了 Red Zone）
cat /sys/kernel/slab/kmalloc-64/sanity_checks
```

**2. 写一个故意越界的内核模块**

在 `example/mini/` 下放一个小模块，`kmem_cache_alloc` 一个小对象，然后故意往对象尾巴后面多写几个字节，再 `kmem_cache_free`。预期：free 的瞬间(或下次分配扫描时)，dmesg 喷出 `Redzone overwritten` 报告，带上越界的具体字节(应该是 `0xcc` 那段被改了)和写入栈。

**3. 写一个 UAF 模块**

分配 → 释放 → 把保存的指针再读一次(或写一次)。预期：读到的值是毒药 `0x6b` 系列(对象体 `POISON_FREE`)，或在后续分配扫描时报 `Poison overwritten`(检查末尾的 `0xa5`/`POISON_END` 哨兵是否还在)。

**4. 写一个泄漏模块**

`kmem_cache_create` 一个独立 cache → `kmem_cache_alloc` 几个对象**故意不释放** → `kmem_cache_destroy`。预期：destroy 时 `print_tracking()` 打印每个未释放对象的分配栈，泄漏点直接指向你的 alloc 调用。

每个模块都走 `example/common/Makefile.arch` 多架构编译(arm64/x86_64/riscv)，验证报告在三套架构上行为一致。这部分的模块代码留给你按 mm-slab 篇的套路自己搭，本篇只给验证目标和预期现象——代码归你，机制讲解归我。

## 小结

我们这一篇把 SLUB 调试的四类能力拆到了内核源码层面：

- **Red Zone(Z)**：对象红区填**两个不同值**——空闲对象填 `0xbb`(`SLUB_RED_INACTIVE`)、使用中对象填 `0xcc`(`SLUB_RED_ACTIVE`)，`check_object()`/`check_bytes_and_report()` 在 alloc/free 两个方向分别校验，逮越界写。
- **Poison(P)**：对象体投 `0x6b`(`POISON_FREE`)、末字节加 `0xa5`(`POISON_END`)哨兵、对象外的对齐缝隙填 `0x5a`(`POISON_INUSE`)。投毒在 `init_object()` 的 free 路径、校验在 `check_object()` 的 alloc 路径，逮 UMR/UAF。
- **Tracking(U)**：`struct track`(`addr` + `stack_depot handle` + `cpu`/`pid`/`when`)，完整栈存 stack_depot、track 上只挂句柄。`SLAB_STORE_USER` 标志开启，`kmem_cache_destroy` 时 `print_tracking()` 打印泄漏栈。
- **Sanity(F)**：`SLAB_CONSISTENCY_CHECKS`，释放时基本健全性检查(重复释放等)。

它们都挂在 `struct kmem_cache` 的 flags 上，由 cache 创建路径根据 `slub_debug` 解析结果落位，运行时通过 `/sys/kernel/slab/<cache>/`(只读查标志 + `validate` 主动扫描)和 `slabinfo` 工具观测；快慢路径分流的判据是 `kmem_cache_debug(s)`(`SLAB_DEBUG_FLAGS`)。和 KASAN 一个轻量针对、一个通用沉重，搭配着用。

## 延伸阅读

- 内核源码(Linux 6.19)：
  - `mm/slub.c` —— SLUB 主实现。`Object layout` 注释块(`mm/slub.c:1350-1387`)讲清了红区/毒药/padding 各填什么值；`init_object()`(`mm/slub.c:1270`，投毒)、`check_object()`(`mm/slub.c:1448`)/`check_bytes_and_report()`(`mm/slub.c:1318`，红区与毒药校验)、`alloc_debug_processing()`(`mm/slub.c:1717`)/`free_debug_processing()`(`mm/slub.c:4309`，慢路径)、`get_track()`(`mm/slub.c:1030`)/`set_track()`(`mm/slub.c:1074`)/`print_track()`(`mm/slub.c:1093`)/`print_tracking()`(`mm/slub.c:1111`，追踪)都在这里；`struct track` 定义在 `mm/slub.c:340`。快慢路径判据 `kmem_cache_debug(s)` 在 `mm/slub.c:252`。
  - `include/linux/poison.h` —— 毒药常量权威出处：`SLUB_RED_INACTIVE(0xbb)`/`SLUB_RED_ACTIVE(0xcc)`(`poison.h:41-42`)、`POISON_INUSE(0x5a)`/`POISON_FREE(0x6b)`/`POISON_END(0xa5)`(`poison.h:45-47`)。
  - `include/linux/slab.h` —— `SLAB_RED_ZONE`/`SLAB_POISON`/`SLAB_STORE_USER`/`SLAB_CONSISTENCY_CHECKS` 标志位定义(这些标志确实在此头文件)；`slub_debug=` 字符串到 flag 的解析在 `mm/slub.c`。
  - `mm/slab.h` —— `kmem_cache_debug_flags()`(`mm/slab.h:490`)、`SLAB_DEBUG_FLAGS`(`mm/slab.h:434`)。注意：`kmem_cache_debug(s)` 是 `mm/slub.c` 的 `static inline` 内部封装，**不是** `include/linux/slab.h` 的导出 API，别去头文件里找。
  - `tools/mm/slabinfo.c` —— slabinfo 工具源码(`-t` 看分配/释放统计、`-v` 校验、`-r` 详细报告)。6.x 起 slabinfo.c 从 `tools/vm/` 迁到了 `tools/mm/`，老资料里写的 `tools/vm/slabinfo.c` 已过时。
- 官方文档：
  - [kernel.org 开发工具总索引](https://docs.kernel.org/dev-tools/index.html) —— 含 SLUB debug、KASAN、kmemleak 入口。
  - [kernel.org KASAN 文档](https://docs.kernel.org/dev-tools/kasan.html) —— 对照 SLUB debug 理解分工。
- 站内：
  - [SLAB/SLUB 分配器](/tutorials/kernel/mm/02-mm-slab) —— 本篇前置，看 `kmem_cache` 基本运作。
  - [printk 调试输出](/tutorials/debugging/01-debug-printk) —— 报告怎么读、怎么控制日志级别。"