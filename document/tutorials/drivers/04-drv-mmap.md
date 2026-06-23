---
title: mmap：把设备内存搬进用户进程
slug: drv-mmap
difficulty: intermediate
tags: [字符设备驱动, mmap, 设备内存映射, 页表]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/drivers/01-drv-chardev
related:
  - /tutorials/drivers/01-drv-chardev
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch03_2.md
---

# mmap：把设备内存搬进用户进程

> 🔨 **整理中** · 本篇机制对照 Linux 6.19（v6.19.9）源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 关于来源，先说句实话

本篇的核心——`remap_pfn_range`、`VM_REMAP_FLAGS`、`.mmap` 回调骨架——是对照 Linux 6.19 源码逐行研读补出来的，不是从某本现成笔记里抄的。能挂上钩的笔记只有 `linux_kernel_device_drivers/ch03_2.md`：它第 115 行拿 `mmap()` 系统调用打过一个比方（"就像 `mmap()` 把内核内存映射给用户空间一样，`ioremap` 把外设 I/O 内存映射给内核空间"），提供了 `ioremap`/MMIO 的上下文，给本篇"内核映射 vs 用户映射"那节做了衔接。但**笔记里没有驱动 `.mmap` 回调的实现素材**，`remap_pfn_range` 那一整套是源码研读补全的。所以读完本篇，建议照着源码自己再核一遍，别把这篇当二手结论吞。

## 用户态要访问设备内存，凭什么还得搭一座桥

上一篇我们走完了字符设备的 `read`/`write`：用户进程发系统调用，内核拷一段缓冲区过去。这套机制对"传个数"完全够用，但一旦你想在用户态**直接啃设备的内存**——比如一帧帧的显示缓冲、一张网卡的环形接收队列——逐字节 `read` 就成了灾难：每取一个字节都得用户态陷进内核再弹回来，还要在内核缓冲区倒一次手，开销大得离谱。

真正高性能的做法是**别让内核搬运数据**：直接把设备的物理内存，原封不动地映射进用户进程的虚拟地址空间。之后用户态拿一个普通指针读写，CPU 自己走 MMU、走页表、直奔硬件，全程不用内核插手。这就是 `mmap` 干的事。

这里有个容易绕晕的点：`mmap` 这个词在两个地方出现。一个是用户态的 `mmap(2)` 系统调用，一个是驱动里实现的 `file_operations.mmap` 回调。用户态调 `mmap`，内核里最终会**调进驱动的 `.mmap`**——驱动负责告诉内核"这块虚拟地址该接哪段物理内存"。本篇讲的，就是驱动这个回调内部那几行代码背后，内核到底替你做了什么。

## 思路：把物理内存接进用户页表

`mmap` 的核心是**改页表**。进程地址空间由一堆 `vm_area_struct`（VMA）描述，每个 VMA 就是一段连续的虚拟地址区间。当用户态对这段地址发读写，MMU 查不到页表项，就缺页异常，正常路径下内核去分配物理页、填进页表。但设备内存不一样——它**本来就存在于物理总线上**（帧缓冲芯片、寄存器组），不需要内核去"分配"，只需要把它的**物理地址**写进页表项，告诉 MMU"这块虚拟地址直接指过去"。

驱动的 `.mmap` 回调签名（Linux 6.19，`include/linux/fs.h:1932`）：

```c
int (*mmap) (struct file *, struct vm_area_struct *);
```

回调拿到的 `vma` 是内核已经建好的空壳——`vm_start`/`vm_end` 是用户态那段虚拟地址的边界，`vm_pgoff` 是用户态 `mmap(2)` 第六个参数（偏移，以页为单位）。驱动要做的就一件事：把 `vma` 这段虚拟地址，跟设备内存的物理页，用页表项连起来。

## remap_pfn_range：往用户页表里塞物理页号

连接虚拟地址和物理页的那个内核函数，叫 `remap_pfn_range()`，定义在 `mm/memory.c:3089`（Linux 6.19，行号待亲测核对）：

```c
int remap_pfn_range(struct vm_area_struct *vma, unsigned long addr,
                    unsigned long pfn, unsigned long size, pgprot_t prot);
```

- `vma`：用户传进来的那段虚拟区。
- `addr`：要开始建映射的虚拟地址，通常是 `vma->vm_start`。
- `pfn`：**物理页帧号**（page frame number）——这才是关键，见下一节。
- `size`：映射多大（字节）。
- `prot`：页保护位（可读、可写、可执行、是否共享），通常直接用 `vma->vm_page_prot`。

返回 0 成功，负数失败。它内部走的是标准的页表遍历——`remap_pfn_range_internal()`（`memory.c:2920`）从 `pgd` 一路 `remap_p4d_range → remap_pud_range → remap_pmd_range`，最底层落在 `remap_pte_range()`（`memory.c:2808`）。这个最底层的函数干的事简单粗暴，一个循环把每一页填进页表：

```c
do {
    BUG_ON(!pte_none(ptep_get(pte)));            /* 这格页表必须是空的 */
    if (!pfn_modify_allowed(pfn, prot)) { err = -EACCES; break; }
    set_pte_at(mm, addr, pte, pte_mkspecial(pfn_pte(pfn, prot)));  /* 填页表项 */
    pfn++;
} while (pte++, addr += PAGE_SIZE, addr != end);
```

`pfn_pte(pfn, prot)` 把"页帧号 + 保护位"组装成一个 PTE，`pte_mkspecial()` 给它打个"special"标记——意思是这页**没有对应的 `struct page`**（设备内存本来就没有 page 描述符），内核的内存管理子系统见到这个标记就知道"别管我，我是设备内存"。`set_pte_at()` 真正把它写进进程页表。这一套干完，用户态那段虚拟地址就跟设备内存连上了。

## pfn vs 物理地址：差一个 PAGE_SHIFT，还要分清内存来源

注意 `remap_pfn_range` 要的不是物理地址，是 **pfn（页帧号）**。两者差一个页内偏移：`pfn = 物理地址 >> PAGE_SHIFT`（`PAGE_SHIFT` 在 4KB 页上是 12）。内核给了换算宏 `phys_to_pfn()`，反过来 `pfn_to_phys()`。

场景分两种，**来源不一样，算法完全不一样**，新手最爱在这里翻车：

1. **映射内核里 `kmalloc`/`__get_free_page` 出来的普通内存**：你手里是内核虚拟地址，先 `virt_to_phys()`（arm64 定义在 `arch/arm64/include/asm/memory.h:362`，第 361 行那个 `#define virt_to_phys virt_to_phys` 只是个别名宏，函数体在下一行）拿物理地址，再 `>> PAGE_SHIFT` 拿页帧号，驱动里常写成 `virt_to_phys(kaddr) >> PAGE_SHIFT`。
2. **映射真正的设备 I/O 内存**（寄存器、帧缓冲，衔接 ch03）：你手里是 `ioremap` 之前的那个**物理/总线地址**，直接 `>> PAGE_SHIFT` 就是 pfn。注意 `ioremap` 返回的是**内核虚拟地址**，不是 pfn 的来源——别拿 `ioremap` 的返回值去算 pfn，那是南辕北辙。

场景 1 那个 `virt_to_phys(kmalloc_buf) >> PAGE_SHIFT` 看着顺手，但有个**可移植性大坑**：`virt_to_phys()` 只对**线性映射（lowmem）地址**成立。`kmalloc`/`__get_free_page` 在 arm64/x86_64 上返回的是线性映射地址，能用；但**如果你拿 `vmalloc` 分配大块内存**，返回的是 vmalloc 区地址，`virt_to_phys()` 公式根本不成立，算出来的 pfn 是错的，映射上去就是野指针。而且 arm64 默认常开 `CONFIG_DEBUG_VIRTUAL`，对 `kmalloc` 内存调 `__virt_to_phys` 会做 bounds 检查，用法不对直接告警甚至 panic。

所以这条老路能走，但要记牢：**`virt_to_phys()` 只认线性映射地址，vmalloc 区/高端内存地址一律不能这么算。**

更关键的是——映射**一页内核 RAM** 时，内核现在更推荐用 `vm_insert_page()`（`memory.c:2470`）。它直接吃一个 `struct page *`，不用你手算 pfn，自动处理 page 描述符。源码里 `vm_insert_page` 的注释自己就说得很直白（`memory.c:2452`）：

```c
 * NOTE! Traditionally this was done with "remap_pfn_range()" which
 * took an arbitrary page protection parameter. This doesn't allow
 * that. Your vma protection will have to be set up correctly ...
```

也就是说 `remap_pfn_range` 是"传统做法"，`vm_insert_page` 是现代替代——它唯一的代价是不能像 `remap_pfn_range` 那样塞一个任意的 page protection，VMA 保护位得提前设好。归纳一下怎么选：

| 映射什么 | 推荐函数 |
|:---|:---|
| 一页内核 RAM（有 `struct page`） | `vm_insert_page()`（吃 page，别手算 pfn） |
| 多页连续内核 RAM | `vm_insert_pages()` 或 `vm_insert_page` 循环 |
| 设备 I/O 内存（寄存器、帧缓冲，无 page） | `remap_pfn_range()`（只能走这条，带 `pgprot_noncached`） |

驱动 `.mmap` 里映射**设备内存**的常见骨架（机制示意，非完整可跑代码）：

```c
static int my_mmap(struct file *file, struct vm_area_struct *vma)
{
    /* 设备 I/O 内存：拿到的是物理地址，>> PAGE_SHIFT 得 pfn；待亲测：用真实寄存器物理地址 */
    unsigned long pfn = dev_phys_addr >> PAGE_SHIFT;
    vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);   /* 设备内存要关缓存 */
    return remap_pfn_range(vma, vma->vm_start, pfn,
                           vma->vm_end - vma->vm_start, vma->vm_page_prot);
}
```

映射内核 RAM 的话就把 `remap_pfn_range` 那行换成 `vm_insert_page(vma, vma->vm_start, page)`，别再算 pfn。

## VM_IO / VM_PFNMAP：告诉内核"这是设备内存"

`remap_pfn_range` 最关键的一步，藏在它的 prepare 阶段。`memory.c:3061` 的 `remap_pfn_range_prepare_vma()` 里有一行（`memory.c:3073`）：

```c
vm_flags_set(vma, VM_REMAP_FLAGS);
```

而 `VM_REMAP_FLAGS` 在 `include/linux/mm.h:561` 定义成一坨标志的合集：

```c
#define VM_REMAP_FLAGS (VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP)
```

也就是说，只要你调了 `remap_pfn_range`，内核**自动**给这段 VMA 打上这四个标志（定义在 `mm.h:414-430`）。每个标志都是一行潜台词：

- **`VM_PFNMAP`**（`mm.h:414`）：这段映射是"纯页帧号映射"，**没有 `struct page`**。缺页处理、内存回收、`get_user_pages()` 看到 `VM_PFNMAP` 就走特殊路径——它不会去给这些"页"分配 page、不会换出、不会参与 LRU。`is_cow_mapping()`（`mm.h:1730`，判断 `(VM_SHARED|VM_MAYWRITE)==VM_MAYWRITE`）相关的写时复制逻辑也直接绕开。
- **`VM_IO`**（`mm.h:418`）：这是设备 I/O 内存。内核拿它当三道护身符——**直接拒绝 GUP**（`get_user_pages` 长期 pin 设备内存没意义，也容易出事）；**不进 core dump**（`VM_IO` 的常规后果，避免 dump 时去读设备寄存器触发副作用）；**不参与 swap**（设备内存换出去毫无意义）。
- **`VM_DONTEXPAND`**（`mm.h:422`）：禁止 `mremap` 扩张这段映射。
- **`VM_DONTDUMP`**（`mm.h:430`）：core dump 时跳过这段。

这里要说清楚 `VM_IO` 拒绝 GUP 这件事，**到底发生在哪**。真正动手拒绝的，是 `mm/gup.c:1207` 的 `check_vma_flags()`：

```c
if (vm_flags & (VM_IO | VM_PFNMAP))
    return -EFAULT;
```

这是 `get_user_pages` 走的入口校验，`VM_IO` 和 `VM_PFNMAP` 任一命中就 `return -EFAULT`。`mm/memory.c:2249-2253` 那段**不是拒绝动作本身**——它只是 `vmf_can_call_write_fault()` 附近的一条注释，在 FSDAX/`VM_IO` 与 GUP 不兼容的上下文里点了一句"VM_IO is incompatible to GUP completely (see check_vma_flags)"。读者要找 GUP 的拒绝逻辑，得去 `gup.c` 的 `check_vma_flags`，别按行号在 `memory.c` 里翻。

一句话：这四个标志把"普通可换页的匿名内存"和"必须原样直通的设备内存"彻底隔开，内核看到它们就走旁路，绝不用那套针对 RAM 的常规套路去折腾设备。`remap_pfn_range` 之所以"安全"，正是因为它顺手把这些标志钉死了，驱动**不需要**、也**不该**自己去 `vm_flags_set` 这些位。

### 题外话：vmf_insert_pfn 那条路上的另一道防线

上面说 `VM_PFNMAP` 让 COW 逻辑绕开，要补一句——`mm/memory.c:2663` 确实有一行兜底：

```c
BUG_ON((vma->vm_flags & VM_PFNMAP) && is_cow_mapping(vma->vm_flags));
```

但这行**不在 `remap_pfn_range` 这条路上**，它在 `vmf_insert_pfn_prot()`（`memory.c:2651`，底层走 `insert_pfn()`，`memory.c:2567`）里——那是**按需建页表**（page fault 时填一页）的另一套机制。两条路各自把关：`remap_pfn_range` 一次性建表，靠 `VM_REMAP_FLAGS`（含 `VM_IO`，让 `is_cow_mapping` 判为非 COW）规避 COW；`vmf_insert_pfn*` 按需建表，靠这条 `BUG_ON` 兜底。别把它们混成一处。

## 内核映射 vs 用户映射：ioremap 和 mmap 不是一回事

这是最常被新手搞混的一对，把它们摆在一起说清楚（衔接 ch03 笔记）：

| | `ioremap()` | `.mmap` + `remap_pfn_range` |
|:---|:---|:---|
| 谁能用 | **内核态**（驱动代码） | **用户态**（进程） |
| 映射到哪 | 内核虚拟地址空间（vmalloc 区，`0xFFFF...` 开头） | 进程自己的虚拟地址空间 |
| 目标 | 设备 I/O 内存的物理地址 | 设备 I/O 内存的 pfn，或内核 RAM 的 page（`vm_insert_page` 更推荐） |
| 怎么读写 | `ioread32()`/`iowrite32()`（不能解引用） | 普通 C 指针解引用（`*p = ...`） |

ch03 里 `ioremap` 是**把设备内存映射给内核自己**用——驱动拿着那个 `void __iomem *`，用带屏障的 `ioread`/`iowrite` 谨慎访问。而 `mmap` 是**把设备内存映射给用户进程**——这回用户态拿到的是普通指针，可以直接 `*p` 读写，因为映射建立时页表项已经标好了"直通物理地址"。

注意表里那栏"目标"：`mmap` 两类都能映射——设备 I/O 内存的 pfn（这时它和 `ioremap` 接的是同一段物理内存，这就是两者的衔接点），以及内核 RAM 的 page（这时优先用 `vm_insert_page`）。新手别看完表误以为 `mmap` 只能映射 kmalloc 内存。

典型链路：驱动先 `ioremap`（内核态用 `ioread32` 配置寄存器、初始化硬件），同时 `mmap` 把同一段设备内存的 pfn 暴露给用户态（用户态直接读写帧缓冲的像素数据）。两者映射的是**同一段物理内存**，只是接到了两个不同的虚拟地址空间。这层关系理顺了，ch03 和本篇就接上了。

这里有个真实但没讲透的坑：把 `ioremap` 那段设备物理地址直接给 `mmap` 用时，**用户态拿到的页保护必须和设备要求一致**，否则映射即使成功，读到的也是脏数据。寄存器要用 `pgprot_noncached()`（强序、禁缓存），某些帧缓冲可能要 write-combine（`pgprot_writecombine()`）。这套保护位得在 `remap_pfn_range` **之前**设到 `vma->vm_page_prot`——因为 `remap_pfn_range` 默认用 `vma->vm_page_prot` 去填 PTE，你不在它前面把缓存属性改好，它就把带缓存的默认值填进去了，结果就是用户态写进去的值没真正到硬件、读回来的还是缓存里的旧值。

## 动手验证方案（待亲测）

> ⚠️ **待亲测**：下面是验证思路，命令输出和最终代码待 QEMU 亲测后填实。

最小验证目标：写一个字符设备驱动，在 `init` 里 `__get_free_page`（或 `alloc_page`）一页内核内存并填上特征值；实现 `.mmap`，用 `vm_insert_page`（RAM 页，更现代）或 `remap_pfn_range`（I/O 内存）把它映射出去；用户态 `mmap(2)` 后用指针读，应看到内核填的值，再写回一个值、内核读出来确认双向通。

验证点 checklist：

- [ ] 用户态读到内核预设的魔数 → 映射建立成功。
- [ ] 用户态写入后，内核侧读到 → 双向连通。
- [ ] `cat /proc/<pid>/smaps` 看这段 VMA，确认打上了 `io`/`pfnmap` 等标志（印证 `VM_IO`/`VM_PFNMAP`）。
- [ ] 多架构编译：参照 `example/common/Makefile.arch`，arm64/x86_64/riscv 三套都过。

踩坑预警：映射设备寄存器时**务必用 `pgprot_noncached()` 关掉缓存**（普通 RAM 不用），而且要在调 `remap_pfn_range` **之前**设好 `vma->vm_page_prot`——否则 CPU 缓存会让你的写操作"消失"：写进去的值没真正到硬件，读回来的还是缓存里的旧值。这块等亲测时重点记。

## 小结

`mmap` 把设备内存直接搬进用户进程，绕开了 `read`/`write` 的逐字节搬运。驱动的 `.mmap` 回调调 `remap_pfn_range()`（`mm/memory.c:3089`），它把一串物理页帧号逐页 `set_pte_at` 进用户页表，并自动给 VMA 打上 `VM_REMAP_FLAGS`（`VM_IO|VM_PFNMAP|VM_DONTEXPAND|VM_DONTDUMP`）——这套标志把设备内存和普通 RAM 彻底隔开，禁止换页、禁止 core dump、拒绝 GUP（拒绝动作在 `mm/gup.c:1207` 的 `check_vfa_flags`，不是 `memory.c` 里那条注释）。映射内核 RAM 单页时优先用 `vm_insert_page()`（吃 page、不用算 pfn），`remap_pfn_range` 留给设备 I/O 内存。要分清：`ioremap` 是内核态映射设备内存（配 `ioread`/`iowrite`），`mmap` 是把同样的物理内存暴露给用户态（用普通指针）——两者常在同一个驱动里配合出现，但映射设备寄存器时务必先 `pgprot_noncached()` 设好 `vma->vm_page_prot`。

## 延伸阅读

- 源码：`mm/memory.c`（Linux 6.19）——`remap_pfn_range()`（`3089`）及其内部 `remap_pfn_range_internal`（`2920`）/`remap_pte_range`（`2808`）、`remap_pfn_range_prepare_vma`（`3061`）、`vm_insert_page()`（`2470`，注释 `2452` 点名它是 `remap_pfn_range` 的现代替代）。
- 源码：`mm/gup.c:1207`——`check_vma_flags()` 里 `VM_IO|VM_PFNMAP` 拒绝 GUP 的真实发生地（`mm/memory.c:2249-2253` 只是条点名的注释，不是拒绝动作）。
- 源码：`include/linux/mm.h`——`VM_REMAP_FLAGS`（`561`）、`VM_IO`/`VM_PFNMAP`/`VM_DONTEXPAND`/`VM_DONTDUMP`（`414-430`）、`is_cow_mapping()`（`1730`）。
- 源码：`arch/arm64/include/asm/memory.h:362`——`virt_to_phys()` 函数体（361 是别名宏）。
- 内核源码注释：`mm/memory.c` 中 `vmf_insert_pfn_prot()`（`2651`）及其 `BUG_ON(... VM_PFNMAP && is_cow_mapping ...)`（`2663`），按需建表那条路上对 COW 的兜底，与 `remap_pfn_range` 一次性建表分属两条路。
- 进一步（持续铺开）：`vmf_insert_pfn` 按需建页表 vs `remap_pfn_range` 一次性建表；`fault` 回调与写时复制；DMA 一致性与 `pgprot_noncached`/`pgprot_writecombine`。