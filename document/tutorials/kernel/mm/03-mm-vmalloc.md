---
title: vmalloc：只要虚拟连续就行
slug: mm-vmalloc
difficulty: intermediate
tags: [内存管理, vmalloc, 虚拟连续, 大块分配]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/mm/01-mm-buddy
related:
  - /tutorials/kernel/mm/01-mm-buddy
  - /tutorials/kernel/mm/02-mm-slab
sources:
  - notes: document/notes/linux_kernel_programming/ch09.md
---

# vmalloc：只要虚拟连续就行

> 🔨 **整理中** · 这篇是从读书笔记（ch09 §9.2 / §9.3）提炼的骨架，vmalloc 的机制和取舍讲透了；但动手部分（写模块 `vmalloc` 1MB、`cat /proc/vmallocinfo` 看映射）还没在 QEMU 上亲手跑过。等我们验过真实命令输出、行号核对完，就升级成 ✅ 已锤炼。

## 先把两种连续性分清楚

上一篇我们跟着伙伴系统走了一圈，它的招牌是一条铁律：**给出去的内存物理上必须连成一片**。`kmalloc`、`alloc_pages` 全是这条线上的——你要 128KB，它就在物理 RAM 里给你找一块完整连续的 128KB，代价是这条内存贵、稀缺，还容易被外部碎片卡死。

但很多时候我们根本不在乎物理连不连续。比如你要存一个大数组、要加载一个内核模块的映像、要给某个软件逻辑开一大块缓冲——CPU 只需要一个**连续的虚拟地址**能顺序读写就行，至于这一段虚拟地址背后映射到哪几片散落的物理页，软件层面完全感知不到。

这就是 `vmalloc` 的定位：**物理可以散，虚拟必须连**。把 `kmalloc` 想象成买地皮，得是物理上挨着的一整块，适合盖楼（还能拿去给硬件做 DMA）；`vmalloc` 像搞虚拟办公，给你一串连续的门牌号，背后真正的办公室可能散在城市各处——只要快递员（CPU）按门牌号能挨个找到就行。

## vmalloc 怎么做到"虚拟连续、物理散"

秘密在页表。`vmalloc` 在内核的 `vmalloc` 区域（一段专门留出来的虚拟地址空间）里划出一块连续的虚拟地址，然后**一页一页**地从伙伴系统那儿零散地讨物理页（可能 order 0 的散页，东一页西一页），再通过修改页表把这些散落的物理页**映射**到那段连续虚拟地址上。

从 CPU 视角看：虚拟地址是连续递增的，顺着指针走毫无障碍。从物理视角看：真实 RAM 可能这儿一页那儿一页，完全不挨着。代价全摊在页表建立和 TLB 上。

> 核心实现在 `mm/vmalloc.c`（Linux 6.19），入口是 `vmalloc()` 系列，底层靠 `__vmalloc_node_range()` 在 `VMALLOC_START`/`VMALLOC_END` 区间里找洞、再逐页映射。行号待亲测核对。

## 代价：为什么不能随便用 vmalloc

`vmalloc` 不是免费午餐，它有三笔账要算：

1. **TLB 失效多**。因为物理页散落，虚拟地址到物理地址的映射在页表里东跳西跳，TLB（页表缓存）命中率比物理连续的 `kmalloc` 差一截，访问起来更慢。这是它性能上最大的硬伤。
2. **不能直接给 DMA 用**。硬件 DMA 引擎大多只认物理地址（除非有 IOMMU 给你做地址翻译），`vmalloc` 出来的虚拟地址硬件不认。在 x86 上想把 `vmalloc` 内存做 DMA 映射还得 `kmap` 一下，更是慢上加重。
3. **多数情况会睡眠**。`vmalloc` 内部要分配页表、可能要做内存回收，会触发调度，所以**绝不能在中断上下文或持自旋锁时调用**——睡了就死锁。这点和 `GFP_KERNEL` 的纪律一脉相承。

一句话：`vmalloc` 是个"大而慢"的工具，省了连续物理内存的稀缺性，搭上了 TLB 性能和 DMA 能力。

## 什么时候非 vmalloc 不可

那什么场景值得吃这三笔代价？答案是**块够大，而且只要虚拟连续**：

- **模块加载映像**：内核模块 `.ko` 文件加载进内核时，映像放在 `vmalloc` 区域，因为它大、且软件按顺序读，不需要物理连续。
- **超大数组 / 软件缓冲区**：几 MB 到上百 MB 的纯软件缓冲，只要 CPU 能顺序访问，物理散不散无所谓。
- **需要 `vmalloc_to_page()` 的场景**：有些子系统（比如 `vmap`、percpu）就是建立在 vmalloc 区域之上的，天然用 `vmalloc`。
- **大宗内存、允许离散**：当你估算 `kmalloc`（受 `KMALLOC_MAX_SIZE` 和碎片限制）八成要失败，又不需要 DMA，`vmalloc` 是退路。

反过来，如果块不大（几 KB），老老实实 `kmalloc`——快、物理连续、省心。

## vmalloc 全家桶 API

`vmalloc` 有一串变体，挑对工具能少踩坑：

| API | 功能 | 返回 |
|:---|:---|:---|
| `void *vmalloc(unsigned long size)` | 分配虚拟连续内存 | 虚拟地址 |
| `void *vzalloc(unsigned long size)` | 同上，但**清零**（`z` = zero） | 虚拟地址 |
| `void vfree(const void *addr)` | 释放，可睡眠，**别在原子上下文调** | — |
| `void *vmalloc_32(unsigned long size)` | 只从 32 位可寻址的物理页分配 | 虚拟地址 |
| `void *vmalloc_user(unsigned long size)` | 分配可映射到用户空间的（`VM_USERMAP`） | 虚拟地址 |

还有个"偷懒但聪明"的混合体值得单独说：**`kvmalloc(size, flags)`**。它的逻辑是先试着 `kmalloc`（快且物理连续），失败了自动回退到 `vmalloc`。对那些"我不想纠结到底该用哪个"的中等大小请求，这就是福音。配套释放用 **`kvfree()`**，它会自己判断当初走的是哪条路。

> API 声明见 `include/linux/vmalloc.h`（Linux 6.19）。签名以源码头文件为准，行号待亲测核对。

## 决策树：kmalloc vs vmalloc vs alloc_pages

脑子里的分配器多了就容易卡壳，贴一张决策图在显示器旁：

1. **给 DMA 硬件用？** → 别用这些，走 DMA 专用 API（`dma_alloc_coherent`）。
2. **给软件逻辑用，很小（几 KB 内）？** → 首选 `kmalloc()` / `kzalloc()`，最快最省事。
3. **中等（1MB~4MB）且不在乎物理连续？** → `kvmalloc()`，让它自己选。
4. **中等且必须物理连续？** → 硬上 `kmalloc`（小心失败）或底层 `__get_free_pages()`。
5. **巨大（超过 4MB）？** → 基本只能 `vmalloc()`。
6. **频繁分配释放同一结构体？** → 自定义 Slab 缓存（`kmem_cache_create`）。

**性能陷阱提醒**：别因为"`vmalloc` 能给大内存"就把小内存也全换成它。`kmalloc` 是从内存池直接拿，飞快；`vmalloc` 要改页表、处理 TLB，慢得多。默认永远首选 `kmalloc`，只有它真的给不出来时才退一步求 `vmalloc` / `kvmalloc`。

## 动手待亲测：模块里 vmalloc 1MB

我们计划在 `example/mini/` 下开一个模块，`vmalloc(1MB)` 一块、再 `vzalloc(1MB)` 一块对比清零效果，然后 `cat /proc/vmallocinfo` 看映射——`vmallocinfo` 是 vmalloc 区域的账本，每一行对应一段 vmalloc 映射，会列出地址范围、大小、调用者（caller），能让我们亲眼看到"虚拟连续、物理散"这件事落在哪里。

验证方案（**待亲测核对**，输出是占位样例）：

```bash
# 加载模块后看 vmalloc 区域的映射
cat /proc/vmallocinfo | grep <module_name>
# 期望看到类似这样一行（数字/调用者为占位，待亲测替换）：
# 0xffff000010000000-0xffff000010100000 1048576 <caller_module_init>+0x.../0x... pages=256 vmalloc
```

观察点有三：一是 `pages=256` 印证 1MB = 256 个 4KB 页；二是地址范围是连续的虚拟区间；三是对照 `print_hex_dump_bytes` 打出来的内容，`vmalloc` 出来的是脏数据（不清零）、`vzalloc` 出来全 0。等 QEMU 跑完，把真实输出和 `mm/vmalloc.c` 的关键行号补进来，这块就从"待亲测"变"已验证"。

## 小结

`vmalloc` 是内核给"大块、只要虚拟连续"场景准备的退路：靠改页表把散落的物理页缝成一段连续虚拟地址，省下了物理连续的稀缺性，代价是 TLB 性能、DMA 能力和原子上下文的禁忌。记住决策的优先级——**默认 `kmalloc`，中等块用 `kvmalloc` 省心，巨大且不需 DMA 才退守 `vmalloc`**——你就不会在四个分配器之间犯选择困难症了。

## 延伸阅读

- 源码：`mm/vmalloc.c`（Linux 6.19），vmalloc 核心实现；`include/linux/vmalloc.h` 看 API 声明。
- kernel.org 文档索引：[Memory Management guide](https://docs.kernel.org/admin-guide/mm/index.html)、[Memory Allocation APIs](https://docs.kernel.org/core-api/memory-allocation.html)。
- 进一步（持续铺开）：Slab 分配器（上一篇）、`kvmalloc` 的回退逻辑、DMA 一致性内存分配。
