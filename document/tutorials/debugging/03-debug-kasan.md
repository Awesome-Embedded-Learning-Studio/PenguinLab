---
title: KASAN：影子内存抓内存破坏
slug: debug-kasan
difficulty: intermediate
tags: [KASAN, 影子内存, 内存调试, UAF]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/debugging/01-debug-printk
  - /tutorials/kernel/mm/02-mm-slab
sources:
  - notes: document/notes/linux_kernel_debugging/ch05.md
---

# KASAN：影子内存抓内存破坏

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 内存 bug 三大恶

写 C 的人大概都有过这种经历：代码明明逻辑没问题，跑得好好的，结果某天凌晨两点给生产环境加了一行无关痛痒的代码，整个系统炸了。罪魁祸首往往是那三类幽灵一样的内存错误：

- **use-after-free（UAF）**：内存都 `kfree` 还回去了，你还攥着老指针往里写——而 Slab 分配器最喜欢把刚释放的对象立刻复用给下一次分配，于是你的"旧指针"正中别人新拿到的内存，数据悄无声息地被串改。
- **buffer-overflow（OOB）**：往数组屁股后面多写一个字节，踩进了 Slab 对象之间的红区，或者更狠的，踩进了下一个对象。
- **wild-pointer**：指针压根没初始化就解引用，指到哪算哪。

这三类 bug 的共性是**隐蔽、难复现**——UAF 往往要等那个对象被重新分配出去才显形，OOB 踩个红区短期内根本不崩。在内核里它们不只是 bug，更是提权漏洞的温床（越界写改了页表就是一次特权提升）。所以内核社区造了一把重炮：**KASAN（Kernel AddressSanitizer）**。

## 核心思路：影子内存

KASAN 的核心机制可以一句话概括：**给每 8 字节真实内存配 1 字节"影子"，记录这 8 字节能不能访问。**

这个映射关系在 `include/linux/kasan.h`（Linux 6.19）里就是这么算的：

```c
static inline void *kasan_mem_to_shadow(const void *addr)
{
	return (void *)((unsigned long)addr >> KASAN_SHADOW_SCALE_SHIFT)
		+ KASAN_SHADOW_OFFSET;
}
```

`KASAN_SHADOW_SCALE_SHIFT` 是 3（因为 2³=8），所以一个地址右移 3 位再加上一个固定的基地址 `KASAN_SHADOW_OFFSET`，就得到它在影子区里对应的那 1 字节。影子区的"配额"比例由此固定：每 8 字节真实内存 → 1 字节影子。

那 1 字节影子到底怎么编码内存的可访问性？答案在 `mm/kasan/kasan.h`：

- 影子值 **0**：这 8 字节全部可访问。
- 影子值 **1~7**：前 N 个字节可访问，剩下 `8-N` 个不可访问（处理 `kmalloc(123)` 这种不是 8 的整数倍的尾巴）。
- 影子值是个**负数**（0xFF 之类）：整块都不可访问，具体值还区分了"为什么不可访问"。

这套魔数全在 `kasan.h` 里钉死（Generic 模式）：

```c
#define KASAN_PAGE_FREE         0xFF  /* freed page */
#define KASAN_PAGE_REDZONE      0xFE  /* redzone for kmalloc_large allocation */
#define KASAN_SLAB_REDZONE      0xFC  /* redzone for slab object */
#define KASAN_SLAB_FREE         0xFB  /* freed slab object */
#define KASAN_SLAB_FREE_META    0xFA  /* freed slab object with free meta */
#define KASAN_GLOBAL_REDZONE    0xF9  /* redzone for global variable */
```

把这套魔数当成一本"罪状词典"：`0xFB` 是"这块 slab 对象已被释放"，`0xFC` 是"这是 slab 对象的红区"。踩进红区就是 OOB，摸了 `0xFB` 就是 UAF——报告怎么定性，全靠查这本词典。

## 编译器插桩：每次访问都查一遍影子

光有影子内存没用，得有人在每次内存访问时去翻这本词典。这件事编译器替你做——开 `CONFIG_KASAN` 后，编译内核会带上 `-fsanitize=kernel-address`，编译器在你**每一条** load/store 指令前面塞一段检查代码。

具体怎么塞？看 `mm/kasan/generic.c`（Linux 6.19）这段宏，它定义了 `__asan_load1/2/4/8/16` 和 `__asan_store1/2/4/8/16` 这一整套函数，正是编译器插桩时调用的入口：

```c
#define DEFINE_ASAN_LOAD_STORE(size)                                    \
	void __asan_load##size(void *addr)                                 \
	{                                                                  \
		check_region_inline(addr, size, false, _RET_IP_);             \
	}                                                                  \
	...
DEFINE_ASAN_LOAD_STORE(1);
DEFINE_ASAN_LOAD_STORE(2);
DEFINE_ASAN_LOAD_STORE(4);
DEFINE_ASAN_LOAD_STORE(8);
DEFINE_ASAN_LOAD_STORE(16);
```

也就是说，你写一行 `*p = 1`，编译器把它改写成"先调用 `__asan_store1(p)` 检查，再真正写"。检查的核心是 `check_region_inline()`（`generic.c`）：它先做两个早退守卫——`kasan_enabled()` 没打开就直接放行、`size == 0` 的零长度访问也直接放行；过了守卫再依次检查三件事：地址有没有回绕（`addr + size < addr`）、有没有对应的影子元数据（`addr_has_metadata()`）、以及 `memory_is_poisoned()` 返回什么。任一项报红就调 `kasan_report()` 当场翻车。

插桩有两种风味（`CONFIG_KASAN_OUTLINE` 默认 vs `CONFIG_KASAN_INLINE`）：Outline 是插一个真正的函数调用（上面那些 `__asan_load*`），内核镜像小、稍慢；Inline 是把检查逻辑直接内联展开，镜像膨胀但快 1.1~2 倍。典型的镜像换速度权衡。

## 三种模式：Generic / SW_TAGS / HW_TAGS

KASAN 不是铁板一块，它有三档火力，区别在于"怎么给内存打可访问性标记"：

| 模式 | 昵称 | 内存/CPU 开销 | 架构限制 |
|:---|:---|:---|:---|
| Generic | 通用版 | 高 / 中 | x86_64、ARM64、RISC-V、甚至 32 位 ARM |
| SW_TAGS | 软件标签版 | 中 / 低 | 仅 ARM64 |
| HW_TAGS | 硬件标签版(MTE) | 低 / 极低 | 仅 ARM64（v8.5+ MTE） |

- **Generic**：就是上面讲的"软件影子内存 + 插桩查影子"，最重也最狠，调试首选，所有 64 位架构通吃。
- **SW_TAGS**：不用整块影子区，改用指针高位塞个 tag、内存里也塞 tag，访问时比较两 tag 是否匹配。轻量很多，但只 ARM64。
- **HW_TAGS**：依赖 ARM64 的 MTE 硬件，把 tag 检查交给 CPU 硬件做，开销低到敢在生产环境开。

为什么 tag 系只认 ARM64？因为 Android。几亿台手机没法都开着 Generic KASAN 跑，Google 急需"线上也能低开销抓内存错误"的能力，于是把 MTE 推上了标准。这是商业驱动，不是技术偏心。

Generic 的代价在配置菜单 help 里写得很直白：**吃掉约 1/8 物理内存，分配开销约 ×1.5，整体性能慢约 ×3**。所以 KASAN 只用于调试内核，绝不进发行版默认内核。

## 报告怎么读

KASAN 抓到 bug 时会甩出一份报告（`kasan_report()` 触发），开头长这样（待亲测核对）：

```
BUG: KASAN: slab-out-of-bounds in kmalloc_oob_right+0x159/0x260 [test_kasan]
Write of size 1 at addr ffff8880316a45fb by task kunit_try_catch/1206
```

关键看三点：

1. **bug 类型**（`slab-out-of-bounds` / `slab-use-after-free` / `double-free` 等）——这是怎么定性的？答案在 `mm/kasan/report_generic.c` 的 `get_shadow_bug_type()`：它读出第一个出问题的影子字节，对着那张魔数词典查——影子是 `KASAN_SLAB_REDZONE`(0xFC) 就判 `slab-out-of-bounds`，是 `KASAN_SLAB_FREE`(0xFB) 就判 `slab-use-after-free`。**报告怎么定性，完全由踩中的那个影子魔数决定。**
2. **访问类型 + 地址 + 大小**：是读还是写、写了几个字节、写在哪个地址。
3. **调用栈**：当前访问栈，以及（如果开了 `CONFIG_STACKTRACE`）这块内存**何时分配、何时释放**的栈。UAF 定位全靠这两个历史栈。

报告里还会打印一段影子内存 dump，行首的 `>` 指着出问题那个字节，`^` 在下面标出来：

```
>ffff8880318ad980: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03
                  ^
```

这里 `03` 就是"前 3 字节可访问，后 5 字节不可访问"——正是 `kmalloc(123)` 那块内存的尾巴（123 = 15×8 + 3），测试用例故意写第 123 字节踩出去了。报告里还顺带告诉你这块内存"allocated / freed"状态、归属哪个 cache、buggy 地址在对象左边还是右边多少字节（`describe_object_addr()`），把现场交代得明明白白。

## quarantine：隔离区，UAF 的命门

KASAN 抓 UAF 的命门在于一件事：**释放的对象不能马上被复用。** 想想就懂——如果 `kfree` 之后对象立刻还回 freelist 被别人拿走，UAF 触发时影子值可能已经被新分配"擦干净"重写成 0 了，KASAN 就抓瞎。

所以 Generic KASAN 搞了个**隔离区（quarantine）**：`kfree` 时不立刻把对象还回 slab freelist，而是先扣在隔离区里一段时间，让"释放"这个状态（影子值 `KASAN_SLAB_FREE`）多活一会儿，给后续的越界访问一个被抓现行的时间窗口。

代码在 `mm/kasan/quarantine.c`（Linux 6.19）。释放流程里（`mm/kasan/common.c` 的 `__kasan_slab_free()`）先把对象毒化（`poison_slab_object()` 把影子写成 `KASAN_SLAB_FREE`），再调 `kasan_quarantine_put()` 把它塞进隔离区：

```c
bool kasan_quarantine_put(struct kmem_cache *cache, void *object)
{
	...
	q = this_cpu_ptr(&cpu_quarantine);          /* 先进每 CPU 队列 */
	qlist_put(q, &meta->quarantine_link, cache->size);
	if (unlikely(q->bytes > QUARANTINE_PERCPU_SIZE)) {
		qlist_move_all(q, &temp);
		raw_spin_lock(&quarantine_lock);
		qlist_move_all(&temp, &global_quarantine[quarantine_tail]); /* 攒够再倒进全局批次数组 */
		...
```

隔离区是两层结构：每 CPU 一个本地队列（`cpu_quarantine`），攒够 1MB（`QUARANTINE_PERCPU_SIZE`）再搬到全局的批次数组（`global_quarantine[]`，FIFO 轮转）。对象在里面以 `kasan_free_meta.quarantine_link` 串成单链表（`struct qlist_node`）。当隔离区总大小超过上限（物理内存的 1/32，`QUARANTINE_FRACTION`），`kasan_quarantine_reduce()` 就从最老那一批开始，调 `qlink_free()` 把对象真正还回 slab（`___cache_free()`）。

> ⚠️ **待亲测**：这套"延迟回收"机制到底让 UAF 窗口撑多久，需要在开了 KASAN 的内核上跑 UAF 用例、观察影子值从 `KASAN_SLAB_FREE` 翻回 0 的时机来验证。注意 tag 系模式（SW_TAGS/HW_TAGS）**不用隔离区**——它们靠 tag 不匹配直接抓，`kasan_quarantine_put()` 在那俩模式下是个空壳。

## UBSAN：抓未定义行为

KASAN 抓的是内存访问越界/UAF，但有一类 bug 它抓不到：**C 语言的未定义行为（UB）**——整数溢出、除零、位移越界、静态数组下标越界。这是 UBSAN（Undefined Behavior Sanitizer）的地盘。

UBSAN 同样是编译时插桩（`-fsanitize=undefined` 等），但插桩位置和检查逻辑不同。它最擅长的是**静态数组索引边界**——内核里 `CONFIG_UBSAN_BOUNDS` 负责这块，编译器能根据数组声明大小生成下标检查代码。越界时报告长这样（待亲测核对）：

```
array-index-out-of-bounds in <path>.c:<line>
index 13 is out of range for type 'char [10]'
```

UBSAN 的盲区也明确：**纯指针运算**它看不见（因为它靠的是数组声明的类型信息，指针算术丢了这层信息），而这恰恰是 KASAN 的强项——KASAN 对所有基于指针的访问一视同仁。所以**KASAN 和 UBSAN 是互补的**，调试内核通常两个都开。

额外提醒：内核和模块必须用**同一个编译器**编（别拿 GCC 编内核、Clang 编模块），ABI 不一致会让 KASAN 直接失效。而有些全局变量的"左越界"只有 **Clang 11+** 才抓得到（GCC 在全局红区处理上有历史坑），所以调试关键路径时 Clang 是更稳的选择。

## 动手验证方案（待亲测）

> ⚠️ 这部分我们还没在 QEMU 上亲手跑过，先给方案，跑过就升级成已锤炼。

1. **配调试内核**：`make ARCH=arm64 menuconfig`，在 `Kernel hacking → Memory Debugging` 开 `CONFIG_KASAN=y`（Generic 模式）、`CONFIG_STACKTRACE=y`；顺手开 `CONFIG_KASAN_KUNIT_TEST=m`（内核自带测试模块，**6.19 里测试源码已和 KASAN 核心同目录**，就在 `mm/kasan/kasan_test_c.c`，实测 76 个故意写坏的用例）。
2. **编出来烧进 QEMU**，启动时留意 `KernelAddressSanitizer initialized (generic)` 这行（`kasan_init_generic()` 打印），看到它就说明影子区已就绪、运行时检查已由内部的 `kasan_enable()` 启用——这是初始化时自动打开的，没有需要你手动拨的开关。
3. **跑自带测试**：6.19 的测试模块已经改名叫 `kasan_test`（不再是 5.10 时代的 `test_kasan`），直接 `modprobe kasan_test` 加载。它是一个 KUnit suite，注册名是 `kasan`，所以也可以不靠 modprobe、用内置 KUnit 触发：启动参数加 `kunit.filter=suite=kasan`，或加载模块后 `echo "suite=kasan" > /sys/kernel/debug/kunit/run`。然后 `dmesg` 看每条 `BUG: KASAN: ...` 报告，逐条对照上面讲的"影子魔数 → bug 类型"词典核验。
4. **自己写 UAF/OOB 模块**：在 `example/mini/` 下写一个 `kmalloc` 一块内存、释放后故意再写、或故意写越界的模块，观察 KASAN 报告格式，验证隔离区是否让"释放"状态多撑了一会儿。

## 小结

KASAN 的全部魔法就是一句话：**影子内存 + 编译器插桩**。每 8 字节真实内存配 1 字节影子，影子值编码"能不能访问、为什么不能"；编译器给每条 load/store 插入检查（Generic 模式下就是 `__asan_load*`/`__asan_store*` → `check_region_inline()` → `memory_is_poisoned()`），影子说有毒就 `kasan_report()`。三种模式里 Generic 最重最狠，SW_TAGS/HW_TAGS 走 tag 路线只认 ARM64；quarantine 隔离区靠延迟回收让 UAF 的"释放"状态多活一会儿，是 Generic 抓 UAF 的命门。UBSAN 补 KASAN 的盲区（纯指针运算抓不到的整数溢出、静态数组越界），两者互补。代价是约 1/8 内存 + ~3 倍减速，只用于调试内核。

## 延伸阅读

- 源码（Linux 6.19）：
  - `mm/kasan/generic.c` —— Generic 模式的影子检查 `memory_is_poisoned*()`、`check_region_inline()`（含 `kasan_enabled()`/零长度早退守卫）、插桩入口 `__asan_load*`/`__asan_store*`，以及 `kasan_init_generic()` 打印初始化日志。
  - `mm/kasan/common.c` —— 分配/释放插桩 `__kasan_slab_alloc()`/`__kasan_slab_free()`、毒化 `poison_slab_object()`。
  - `mm/kasan/quarantine.c` —— 隔离区两层队列 `kasan_quarantine_put()`/`kasan_quarantine_reduce()`、`qlink_free()` → `___cache_free()` 真正还回 slab。
  - `mm/kasan/report_generic.c` —— bug 类型定性 `get_shadow_bug_type()`（影子魔数词典，`slab-out-of-bounds`/`slab-use-after-free`/`wild-memory-access`）。
  - `mm/kasan/kasan.h` —— 影子魔数定义 `KASAN_*`、`struct kasan_track` / `kasan_alloc_meta` / `kasan_free_meta`。
  - `mm/kasan/kasan_test_c.c` —— 6.19 的 KASAN KUnit 测试（76 个故意写坏的用例），随 `kasan_test.ko` 构建，suite 名 `kasan`。
  - `include/linux/kasan.h` —— 影子地址映射 `kasan_mem_to_shadow()`。
- kernel.org：[KASAN 文档索引](https://docs.kernel.org/dev-tools/kasan/index.html)。
- 笔记：`document/notes/linux_kernel_debugging/ch05.md` 及其子章 ch05_3~ch05_7（笔记基于较早内核，模块名/测试位置/用例数以本文 6.19 核对为准）。