---
title: 伙伴系统：内核怎么管物理页
slug: mm-buddy
difficulty: intermediate
tags: [内存管理, 伙伴系统, 页面分配器]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/03-kernel-build
related:
  - /tutorials/foundations/07-kernel-module-hello
sources:
  - notes: document/notes/linux_kernel_programming/ch08.md
  - notes: document/notes/linux_kernel_programming/ch07.md
---

# 伙伴系统：内核怎么管物理页

> 🔨 **整理中** · 这篇是从读书笔记（ch07/ch08）整理出来的骨架，核心机制讲透了；但动手部分（QEMU 上看 `/proc/buddyinfo`、写模块验证 `alloc_pages`）还没亲手跑过。等我们在 QEMU 里验过，就升级成 ✅ 已锤炼。

## 内核为什么要专门管物理页

在用户空间，我们要内存就 `malloc`，用完 `free`，背后怎么分配是 glibc 和内核的事。可一旦进了内核——写模块、写驱动——就得直接面对一个更硬的问题：**物理内存怎么分。**

先刻一条铁律：**内核内存不会被换到磁盘上。** 用户进程内存不够可以扔 swap，内核不行——管理内存的数据结构要是被换出去了，想读回来还得用内存，这就成了"为了找眼镜得先戴上眼镜"的死锁。所以内核内存常驻 RAM，**浪费内核内存比浪费用户内存代价大得多**。

那内核在这块常驻 RAM 上怎么做分配？两层楼：底层是**伙伴系统**（页面分配器，只做大宗页块交易），上层是 **Slab 分配器**（专管小对象）。这篇讲底层——伙伴系统。

## 物理内存的三层组织：Node → Zone → Page

内核不把物理内存看作一整块 RAM，而是三层结构：

1. **Node（节点）**：NUMA 架构的概念——多路服务器上每个 CPU 挂在自己最近的内存控制器上，访问"本地"内存快、"远程"慢。即便你的 PC 是 UMA（统一内存），内核为了代码通用也假装它有 Node 0。
2. **Zone（区域）**：每个 Node 划成几个 Zone，主要是给老硬件擦屁股——`DMA`（ISA 设备只能寻址低 16MB）、`DMA32`（低 4GB）、`Normal`（普通）、`HighMem`（32 位高端内存痛点，64 位不需要了）。
3. **Page（页帧）**：物理内存最小单位，每页对应一个 `struct page`，页大小通常 4KB。

这套结构待会儿用 `/proc/buddyinfo` 就能看到。

## 伙伴系统的核心：`free_area[MAX_ORDER]`

页面分配器的核心数据结构在每个 `struct zone` 里：一个数组 `free_area[MAX_ORDER]`。这就是伙伴系统的空闲链表。

`MAX_ORDER` 在 x86 和 ARM 上通常是 11，意思是 11 条链表（order 0 到 10），每条挂着不同大小的**物理连续**页块：

| Order | 页数 | 大小（4KB 页） |
|:---:|:---:|:---:|
| 0 | 1 | 4 KB |
| 1 | 2 | 8 KB |
| 2 | 4 | 16 KB |
| ... | ... | ... |
| 10 | 1024 | 4 MB |

"伙伴"的来历：把一个 order N 的块对半切，得到两个 order N-1 的块——它俩就是"伙伴"。反过来，一对伙伴都空闲就合并回一个 order N 的块。这就是伙伴系统**反碎片**的魔法：靠不断合并，尽量保住大块连续内存。

> 核心分配逻辑在 `mm/page_alloc.c`（Linux 6.19）的 `__alloc_pages()` 系列。行号待亲测核对。

## 一个分配请求的一生

假设驱动要 128KB。128KB / 4KB = 32 页，32 = 2⁵，分配器去 order 5 链表找：

1. order 5 有货 → 直接拿走，完事。
2. order 5 没货 → 去 order 6 找，找到一块 256KB 的，切成两个 128KB 伙伴。
3. 一半给你，另一半挂回 order 5 留下次用。

释放反向走：一块释放，看它的伙伴是不是也空闲，是就合并成更高 order，一路合上去，直到伙伴不空闲或到顶。

## 内部碎片：132KB 的坑

伙伴系统只认 2 的幂。你要 **132KB**——不是 2 的幂，下一个能装下它的盒子是 order 7（256KB）。结果：申请 132KB，内核给你 256KB，**剩下 124KB 就这么浪费了**。

这就是"锯木头"的代价，叫**内部碎片**。内核给了 `alloc_pages_exact()` / `free_pages_exact()` 缓解（多分配一点再把多余还回去），但止不住根上的浪费。

经验法则：**需要接近 2 的幂的大块时，想想内部碎片；零碎小对象别找伙伴系统，那是 Slab 的活。**

## `/proc/buddyinfo`：仓库账本

`/proc/buddyinfo` 是伙伴系统的库存清单，每列对应一个 order 上的空闲块数量：

```
Node 0, zone      DMA      3      2      4      3      3      1   0   0   1   1   3
Node 0, zone    DMA32  31306  10918   1373    942    505    196  48  16   4   0   0
Node 0, zone   Normal  49135   7455   1917    535    237     89  19   3   0   0   0
```

从左到右是 order 0 到 10。order 10 那列要是 0，说明系统里已经找不到一块 4MB 连续物理内存了——哪怕总空闲内存还很多，因为它们碎成了小块。这是伙伴系统最头疼的**外部碎片**。

> ⚠️ **待亲测**：上面这段输出是整理时的参考样例。我们会拿到 QEMU ARM64 上 `cat /proc/buddyinfo` 跑一遍记下真实输出，再写个模块用 `alloc_pages` 分几页、观察对应 order 的数字变化——把"分配请求的一生"亲眼看到。

## 页面分配器 API 速查

这些 API 名字里都带 `page` 或 `free_page`：

| API | 功能 | 返回 |
|:---|:---|:---|
| `__get_free_page(gfp)` | 分配 1 页 | 内核逻辑地址 |
| `__get_free_pages(gfp, order)` | 分配 2^order 页 | 内核逻辑地址 |
| `get_zeroed_page(gfp)` | 分配 1 页并清零 | 内核逻辑地址 |
| `alloc_page(gfp)` | 分配 1 页 | `struct page *` |
| `alloc_pages(gfp, order)` | 分配 2^order 页 | `struct page *` |

**关键区别**：`__get_free_page` 返回**地址**（直接能用），`alloc_page` 返回**页描述符** `struct page *`（要 `page_address()` 换成地址）。释放一定配对：`alloc_page` 拿的就用 `__free_pages` 还，别把 `page` 指针当地址塞给 `free_pages`——经典翻车点。

## GFP 标志：告诉内核你的底线

每个分配函数都有 `gfp_mask` 参数（`GFP_KERNEL`、`GFP_ATOMIC` 等），这是你跟内核签的"生死契约"：

- **`GFP_KERNEL`**：你在**进程上下文**（模块 init、系统调用实现），**允许睡眠**。内存不够内核可以去回收、甚至做 I/O，你等着。
- **`GFP_ATOMIC`**：你在**原子上下文**（中断处理 ISR、持自旋锁），**绝对不能睡眠**。内存不够就直接失败返回，不许调度。

违反这条规矩直接死锁或 panic：持着自旋锁时用 `GFP_KERNEL`，内核尝试睡眠 → 调度器混乱 → 系统挂。所以**中断/持锁里只能 `GFP_ATOMIC`**。

## 小结

伙伴系统是内核物理内存管理的地基：`zone` 里挂 11 条 `free_area` 链表，按 2 的幂管理页块，靠分裂与合并对抗碎片。它只做大宗页块交易，零碎小对象交给上层 Slab（下一篇）。

记住两件事：**内部碎片**（非 2 的幂请求会被向上取整浪费）和 **GFP 上下文纪律**（原子上下文只能 `GFP_ATOMIC`）。

## 延伸阅读

- 源码：`mm/page_alloc.c`（Linux 6.19），伙伴系统核心；`include/linux/mmzone.h` 看 `struct zone` / `free_area`。
- kernel.org：[Memory Management guide](https://docs.kernel.org/admin-guide/mm/index.html)、[mm 页分配器](https://docs.kernel.org/core-api/mm-api.html)。
- 进一步（持续铺开）：Slab 分配器、vmalloc、页面回收与 OOM。
