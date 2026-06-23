---
title: 页面回收与 kswapd：内存紧张时怎么办
slug: mm-page-reclaim
difficulty: intermediate
tags: [内存管理, 页面回收, kswapd, 水位线]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/mm/01-mm-buddy
related:
  - /tutorials/kernel/mm/01-mm-buddy
  - /tutorials/kernel/mm/05-mm-oom
sources:
  - notes: document/notes/linux_kernel_programming/ch09.md
---

# 页面回收与 kswapd：内存紧张时怎么办

> 🔨 **整理中** · 这篇是从读书笔记（ch09 §9.4）整理出来的骨架，把 kswapd 的水位线机制和后台回收的脉络讲透了；但 `/proc/zoneinfo` 看水位、压测触发 kswapd、抓 vmstat 这几个动手部分还没在 QEMU 里亲测过，命令输出样例都标了"待亲测核对"。等我们跑完，升级成 ✅ 已锤炼。

## 内核内存不能换出，那什么能换

上一篇我们讲过一条铁律：**内核自己用的内存常驻 RAM，绝不会被换到磁盘上**——管理内存的数据结构要是被换出去，想读回来还得用内存，这就是"找眼镜得先戴眼镜"的死锁。那系统内存吃紧的时候，内核总得有点东西能腾出来吧？

能腾的就是**用户侧的两大类页**：

1. **文件页（file-backed pages）**——page cache。你 `read` 一个文件，内核顺手把内容缓在内存里，下次读就不用再跑磁盘。这些页的"原件"就在磁盘文件里，内存里的只是副本。
2. **匿名页（anonymous pages）**——进程的堆、栈这些，磁盘上没有对应文件，属于"无家可归"的内存。要换出它们，得给它们在磁盘上临时安个窝——这就是 **swap**。

这两类页是内核内存回收的"存货"，平时占着 RAM 充缓存，紧张了就得让位。

## 两类页，两种回收手法

回收不是一刀切，得看页"脏不脏"：

- **干净的文件页**：内存里的副本跟磁盘上一模一样（比如只读没改过的 page cache）。**直接丢弃**就完事——下次要用，重新从文件读一遍就行。成本最低。
- **脏的文件页**：被写过、还没回写磁盘的 page cache。**先回写（writeback）到文件，再丢弃**。多一次磁盘 I/O。
- **匿名页**：磁盘上压根没有原件。**写进 swap 分区/文件，再丢弃**。最贵，因为 swap 一般也是磁盘。

所以内核回收时的偏好顺序很自然：**先扔干净文件页（白嫖），再扔脏文件页（得写磁盘），最后才动匿名页（还得走 swap）**。代价从低到高，能省则省。`swappiness` 这个 sysctl 就是调这个偏好的——值越小越不愿意碰匿名页，留给后面亲测时细看。

## zone 的三档水位线

回收不是随性而为，得有规矩触发。规矩就是**每个 zone 都有三档水位线**（注意：是每个 zone 独立一套，不是全局）：

| 水位 | 含义 |
|:---|:---|
| **`WMARK_HIGH`** | 充裕，舒服区 |
| **`WMARK_LOW`** | 有点紧了，该打扫了 |
| **`WMARK_MIN`** | 最低警戒线，不能再低 |

> 这套水位定义在 `include/linux/mmzone.h`（Linux 6.19）的 `enum zone_watermarks`，挂在 `struct zone` 的 `_watermark[NR_WMARK]` 数组里。具体值由 `mm/page_alloc.c` 里的 `setup_per_zone_wmarks()` 根据 zone 大小和 `min_free_kbytes` 算出来。行号待亲测核对。

三档水位把 zone 的空闲内存划成几段，下面两节就是"谁在什么水位被触发"。

## kswapd：后台清洁工

内核里有个专门的内核线程叫 **`kswapd`**，每个 Node 一个，平时睡大觉，干的是后台异步回收的活——**不打扰正在分配内存的人**。它的唤醒与睡眠完全跟着水位走：

1. **空闲跌破 `WMARK_LOW`**：kswapd 被唤醒，开始后台回收——扔 page cache、回写脏页、必要时换出匿名页。
2. **一路回收到 `WMARK_HIGH`**：够了，kswapd 回去睡觉。

注意这里的不对称：**从 low 醒来，回收到 high 才睡**。中间留了 `high - low` 这一段缓冲，免得它刚睡下又被叫醒、来回折腾（这叫 kswapd 的滞回，hysteresis）。这种后台异步回收的好处是：分配内存的进程几乎无感，kswapd 在另一个 CPU 上默默收拾，**不阻塞**你。

> kswapd 的主循环在 `mm/vmscan.c`（Linux 6.19）的 `balance_pgdat()`，由 `kswapd()` 线程函数驱动。行号待亲测核对。

## direct reclaim：分配者自己上手

但要是内存掉得太快，kswapd 来不及打扫呢？比如某个进程一口气要一大块，空闲内存直接跌破 `WMARK_MIN`——这时候就顾不上后台了。**正在分配内存的那个进程自己被拉去干回收的活**，这叫 **direct reclaim（直接回收）**。

区别一目了然：

- **kswapd**：后台、异步、别的线程干、不阻塞你。
- **direct reclaim**：前台、同步、你自己干、**分配被卡住直到回收出内存**。

direct reclaim 是慢路径，直接影响延迟——你的 `malloc` / `alloc_pages` 会突然变慢，因为它得停下来先扫一轮 LRU、回写、换出，才能拿到页。所以系统调优的一个核心目标就是**尽量别让空闲内存跌破 low**，把回收的活都甩给 kswapd，别逼分配者亲自上阵。

## PG_reclaim 与 shrink：机制概览

那"回收"具体在扫什么？这里只点一下骨架，LRU 的细节留给亲测篇：

- 内核给每个 zone 维护 **LRU 链表**（活跃/非活跃，文件页/匿名页各一组），靠 `PG_active`、`PG_referenced` 这些页标志位判断"这页最近还用不用"。
- 回收的核心入口是 `mm/vmscan.c` 的 `shrink_lruvec()` 一族函数，它们遍历 LRU、按代价挑页、该丢的丢、该回写的回写、该换出的换出。
- 页被打上 **`PG_reclaim`** 标志表示"这页被选中要走 writeback"。具体怎么打分、怎么换出，等亲测篇配合 `/proc/vmstat` 的 `pgscan_kswapd_*` / `pgsteal_*` 计数器展开。

这篇的目标是把"为什么要回收、谁触发、什么时候阻塞"这层心智模型立起来，LRU 深水区不在这篇的射程内。

## 动手待亲测（验证方案占位）

下面这几步是我们打算在 QEMU 上验的，现在只列方案，输出都标了"待亲测核对"：

1. **看水位线**：`cat /proc/zoneinfo`，找每个 zone 的 `min` / `low` / `high` 三行，核对它们跟 `min_free_kbytes` 的关系。
2. **压测触发 kswapd**：用一个吃内存的进程（比如 `stress` 或手写小程序）把 Normal zone 的空闲压到 low 以下，同时开第二个终端盯 `vmstat 1`，看 `si`/`so`（swap in/out）和 kswapd 相关计数有没有动。
3. **抓 direct reclaim**：更激进地压到 min 以下，观察分配延迟的变化（`/proc/vmstat` 里的 `allocstall_*` 计数器，正是 direct reclaim 拖慢分配的痕迹）。

```
# 待亲测核对 —— 下面是参考样例，QEMU ARM64 上真实输出待补
$ cat /proc/zoneinfo | grep -E "Node|zone|min|low|high"
Node 0, zone   DMA
        min      16
        low      20
        high     24
Node 0, zone   Normal
        min      4096
        low      5120
        high     6144
```

> ⚠️ **待亲测**：上面的数字是整理时的参考样例。我们会拿到 QEMU ARM64 上跑一遍，把真实的水位值、`vmstat` 输出、压测前后的对比记下来，再决定要不要配一个 `example/mini` 验证模块。

## 小结

页面回收是内核内存管理的"续命机制"：内核内存不换出，但**文件页和匿名页**可以——干净文件页直接丢、脏文件页先回写、匿名页写 swap，代价从低到高。触发靠**每个 zone 的三档水位线**（high / low / min）：**kswapd** 在跌破 low 时后台异步回收、回到 high 睡觉，不打扰分配者；一旦跌破 min，分配者就得亲自上阵做 **direct reclaim**，付出延迟代价。

记住一个调优直觉：**尽量把回收的活留给 kswapd**——别让系统闲到跌破 min，否则你的分配请求会被同步回收拖慢。至于 LRU 怎么挑页、`swappiness` 怎么调，那是亲测篇的活。

## 延伸阅读

- 源码：`mm/vmscan.c`（Linux 6.19），kswapd 主循环与 `shrink_*` 回收族；`mm/page_alloc.c` 的 `setup_per_zone_wmarks()` 看水位怎么算；`include/linux/mmzone.h` 看 `enum zone_watermarks` 与 `struct zone`。
- kernel.org：[Memory Management guide](https://docs.kernel.org/admin-guide/mm/index.html)（管理员视角，含 `/proc/zoneinfo`、kswapd、`swappiness` 条目）。
- 进一步（持续铺开）：OOM Killer（`/proc/<pid>/oom_score_adj`）、LRU 与 `PG_reclaim` 深挖。