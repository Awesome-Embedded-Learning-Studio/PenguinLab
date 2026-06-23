---
title: Slab 分配器：内核怎么管小对象
slug: mm-slab
difficulty: intermediate
tags: [内存管理, Slab 分配器, kmalloc, 对象池]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/mm/01-mm-buddy
related:
  - /tutorials/kernel/mm/01-mm-buddy
sources:
  - notes: document/notes/linux_kernel_programming/ch08.md
  - notes: document/notes/linux_kernel_programming/ch09.md
---

# Slab 分配器：内核怎么管小对象

> 🔨 **整理中** · 这篇是从读书笔记（ch08 §8.5/§8.6、ch09 §9.1）整理出来的骨架，核心机制讲透了；但动手部分（QEMU 上 `cat /proc/slabinfo` 看缓存清单、写模块对比 `kmalloc` 与 `kmem_cache_alloc` 的实际开销和槽位）还没亲手跑过。等我们在 QEMU 里验过，就升级成 ✅ 已锤炼。

## 伙伴系统的盲区：要几十字节却被塞一整页

上一篇我们陪伙伴系统锯了一上午木头，结论很扎心：它只认 2 的幂，最小交易单位是 4KB 一页，非 2 的幂请求会被向上取整浪费。可这还不是它最尴尬的地方——它真正管不了的是**零碎小对象**。

想象一下，内核里到处都是几十字节到几百字节的小结构：一个网络包的 `sk_buff`、一个文件的 `inode`、一个目录项的 `dentry`。这些家伙生命周期短、分配释放极其频繁。如果每次都找伙伴系统要，会是什么光景？你要 192 字节，伙伴系统甩给你 4KB 一整页——**剩下 3904 字节就这么空着**，内部碎片率高得离谱，光是初始化和回收一整页的开销都够这个小对象分配几十次了。

所以内核在伙伴系统上面又搭了一层楼，这就是 **Slab 分配器**：它专门干"把一整页木头锯成小木条零售"的活。承接 buddy 篇，这篇讲上层。

## Slab 的核心思想：对象池化 + 复用

Slab 的设计初衷其实就两条，说穿了都很朴素：

1. **对象池化**：内核里有些结构（`task_struct`、`inode`、`dentry`）被成千上万次地分配释放。与其每次都现造一个、用完拆一个，不如**预先批量造好一池子放着**，要的时候直接拿一个现成的，用完扔回池子。省掉的不是一点内存，是反复构造/析构那套开销。
2. **按规格切页**：把一整页 4KB 提前切成若干个固定大小的"槽位"（比如 192 字节一槽），小对象按需领槽，一个页能塞下二十个 `sk_buff` 头，内部碎片瞬间从 ~95% 压到几个百分点。

还有个常被忽略的红利：**Slab 分配出来的内存是物理连续、且按 CPU 缓存行对齐的**。这对高频网络/存储路径很要命——对齐意味着少踩伪共享（False Sharing），缓存命中率高出一截。

## 实现沿革：SLAB/SLOB 已退场，今天只剩 SLUB

Slab 这个概念在内核历史上先后有过三套具体实现，了解这段沿革能帮你读懂老资料——但别误以为今天还有得选：

- **SLAB**：最早的那套（从 Solaris 借鉴来的），设计精巧但**数据结构复杂**、对 NUMA 多节点管理开销大，元数据占内存不少。**已在 6.5 从主线移除**。
- **SLUB**：**今天唯一的实现**。它把 SLAB 那套复杂的 per-CPU 队列和元数据大幅精简，代码更少、性能更好、碎片更少。你编 6.19 用的就是它，没有别的选项。
- **SLOB**：曾经给**嵌入式、内存极小**设备用的精简版，连 SLUB 都嫌重时上它，代价是分配效率低。**已在 6.4 从主线移除**。

所以现在 `mm/` 下只剩一个 `slub.c`（外加面向极小内存的 `SLUB_TINY` 配置）。早年资料里"通过 `CONFIG_SLAB`/`CONFIG_SLUB`/`CONFIG_SLOB` 三选一"的说法已经彻底过时——今天只剩 SLUB 一条路。好在三者从来共用同一套上层 API（`kmalloc`、`kmem_cache_create` 等），不管底下跑哪个，你写代码的方式都一样。

## 核心数据对象：kmem_cache 与 slab 页

Slab 的世界有两个关键角色：

- **`struct kmem_cache`**：代表"**一种类型**的专用缓存"。你可以理解为一个池子只装一种货——比如 `task_struct` 有自己的 `kmem_cache`，`inode` 有自己的，互不串。每个 `kmem_cache` 记着这种对象的大小、对齐、构造函数、还有底下挂着的一堆 slab 页。对外 API 集中在 `include/linux/slab.h`，而 `struct kmem_cache` 的定义本身在 `mm/slab.h`（内核内部头，6.19，行号待亲测核对）。
- **slab 页**：`kmem_cache` 真正存货的物理载体——它向伙伴系统要来的整页，被切成一个个等大的槽位。对象就躺在槽位里。

一个 `kmem_cache` 底下挂很多 slab 页，每个页切成 N 个对象槽，分配就是在某个有空位的页里找个空槽，释放就是把槽标记为空。

## 两层 API：通用 kmalloc vs 专用 kmem_cache

内核对外暴露两层 Slab 接口，选哪层看你的需求：

**通用层——`kmalloc` 家族**（按大小临时挑坑位）：

```c
void *kmalloc(size_t size, gfp_t flags);   /* 不清零，内容是垃圾 */
void *kzalloc(size_t size, gfp_t flags);   /* 推荐用这个，清零版 */
void kfree(const void *objp);              /* kfree(NULL) 安全 */
```

内核预造了一组通用缓存：`kmalloc-8`、`kmalloc-16`、`kmalloc-32`……一直到 `kmalloc-8192`（6.x 下还会再有更大的）。你调 `kmalloc(20, ...)`，它挑一个能装下 20 字节的最小坑（32 字节槽）给你。**`kzalloc` 推荐**：省心，又防未初始化内存泄漏。

**专用层——`kmem_cache` 系列**（为高频结构自建缓存）：

```c
struct kmem_cache *kmem_cache_create(const char *name,
                                     unsigned int size,
                                     unsigned int align,
                                     slab_flags_t flags,
                                     void (*ctor)(void *));
void *kmem_cache_alloc(struct kmem_cache *s, gfp_t gfpflags);
void  kmem_cache_free(struct kmem_cache *s, void *objp);
void  kmem_cache_destroy(struct kmem_cache *s);
```

这是一套"建厂→生产→关停"的流程，三步缺一不可，下一节展开。

## 为什么 task_struct、inode 要自建缓存

你可能会问：通用 `kmalloc` 不是挺好用的吗，为啥内核还要给 `task_struct` 这些结构单独开缓存？因为"**通用的往往是低效的**"——三个理由：

1. **减少碎片**：通用缓存按固定档位（32/64/96...）给坑，你要 328 字节它可能塞你进 512 的坑，白浪费 184 字节。自建缓存按你结构体实际大小切页，碎片压到最低。
2. **对齐可控**：`SLAB_HWCACHE_ALIGN` 能保证对象起始落在缓存行边界，热门字段还能凑到同一个缓存行里，多核性能更稳。
3. **构造回调**：`kmem_cache_create` 可以挂个 `ctor` 构造函数。内核预分配对象时自动调它初始化，省得每次 `alloc` 完还得手动 `memset`/填字段——透着一股 C++ 面向对象的味道。

所以 `task_struct`、`inode`、`dentry`、`sk_buff`、`mm_struct` 这些高频家伙，内核启动时都给它们各自建好了专用 `kmem_cache`，你可以 `/proc/slabinfo` 里亲眼看到这份清单。

> 还有个真实的"内碎片"坑：你 `kmem_cache_create` 指定 `size=328`，但内核为了对齐和元数据，**实际给的槽位可能是 448 字节**。`kmem_cache_size()` 会告诉你实际开了多大。嵌入式抠字节到极致的场景，这笔账必须算进去。

## 动手：亲测 /proc/slabinfo 与 kmalloc vs kmem_cache_alloc

这是本篇唯一还没在 QEMU 上跑通的部分，列个验证方案，等亲测后回填真实输出。

**方案一：看缓存清单**

```bash
cat /proc/slabinfo | head
slabtop -o | head        # 按占用排序看，更直观
```

> ⚠️ **待亲测核对**：上面命令在 6.19 + QEMU ARM64 上的真实输出还没记。预期会看到 `task_struct`、`inode_cache`、`dentry`、`kmalloc-192` 等一长串条目，每条带 `active_objs / num_objs / objsize` 几列。我们会把真实输出贴进来，再解释每列含义。

**方案二：写模块对比 kmalloc 与 kmem_cache_alloc**

骨架目标（完整实战代码留到亲测阶段，不在本篇铺）：

- 定义一个 ~328 字节的 `struct myctx`，模块 init 里用 `kmem_cache_create` 建专用缓存，`SLAB_POISON | SLAB_RED_ZONE | SLAB_HWCACHE_ALIGN` 全开做调试。
- 对比两路分配：一路 `kmalloc(sizeof(myctx))`，一路 `kmem_cache_alloc`，各自用 `ksize()`/`kmem_cache_size()` 打印实际槽位大小，观察"内碎片"差距。
- 挂个 `ctor`，打印它被调的次数——你只 `alloc` 一次，`ctor` 可能被调 **18 次**（内核预填充批次），这是 Slab 池化的直接证据。
- 用完 `kmem_cache_free` + `kmem_cache_destroy` 配对，验证"还有对象没还回来就销毁"会失败。

> ⚠️ **待亲测**：实际模块代码、QEMU 上的 `dmesg` 输出、`ctor` 18 次的批次现象，都留到亲测阶段补齐并沉淀到 `example/mini/`。本篇只立方案。

## 小结

Slab 是伙伴系统之上的小对象零售层，核心就两招：**对象池化复用**（省构造/析构开销）和**按规格切页**（压内部碎片）。6.x 只剩 **SLUB** 一种实现，对外两层 API——通用 `kmalloc`/`kzalloc` 按大小挑坑，专用 `kmem_cache_create`/`alloc`/`free`/`destroy` 给高频结构自建缓存。

记住三件事：**自建缓存能减碎片、控对齐、挂构造回调**；**实际槽位常比指定 size 大**（内碎片代价）；**`ctor` 会被预分配批量调用**。下一篇我们继续往大块内存走——`vmalloc` 和那个让人手心出汗的 OOM Killer。

## 延伸阅读

- 源码：`mm/slub.c`（Linux 6.19 唯一实现）；`mm/slab_common.c` 看 `kmem_cache_create`；`mm/slab.h` 看 `struct kmem_cache` 的定义；`include/linux/slab.h` 是对外 API 头。
- kernel.org：[Memory Management guide](https://docs.kernel.org/admin-guide/mm/index.html)、[Slab allocators 文档](https://docs.kernel.org/core-api/mm-api.html)。
- 进一步（持续铺开）：`vmalloc`、`kvmalloc`、页面回收与 OOM Killer。