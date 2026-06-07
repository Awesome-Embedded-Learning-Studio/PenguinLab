---
title: "调度器演进（一）：O(1) 调度器——从遍历到位图的跨越"
slug: sched-evolution-o1
type: supplementary
supplementary_for:
  - node_id: sched-overview
    relation: "调度器概述的历史背景，理解现代调度器为什么要放弃优先级数组"
difficulty: intermediate
tags: [scheduler, evolution, o1-scheduler, priority-array]
kernel_versions: ["2.5", "2.6.0", "2.6.11", "2.6.22"]
milestones:
  - version: "2.5"
    event: "O(1) 调度器在 2.5 开发系列中引入"
    reference: "https://lkml.org/lkml/2002/1/3/287"
  - version: "2.6.0"
    event: "O(1) 调度器随 2.6.0 稳定版发布"
  - version: "2.6.22"
    event: "O(1) 调度器的最后一个完整版本"
  - version: "2.6.23"
    event: "CFS 替代 O(1)"
    commit: "dd41f596cda0d7d6e4a8b139ffdfabcefdd46528"
---

# 调度器演进（一）：O(1) 调度器——从遍历到位图的跨越

我们现在打开任意一台 Linux 机器，`ps aux` 随便一跑就是上百个进程，调度器要在毫秒级别做出下一个该运行谁的决定，而且这个决定不能因为进程多了就变慢。这件事在今天看来理所当然，但在 Linux 2.4 时代，它根本不是这样的——调度器选下一个任务的时间复杂度是 O(n)，进程越多越慢，而且所有 CPU 共享一把全局锁。

2002 年初，Ingo Molnar 站出来说：这不行，得改。于是就有了 O(1) 调度器。

## O(n) 时代到底有多糟糕

要理解 O(1) 为什么是一个突破，我们得先感受一下它的前驱有多痛苦。早期 Linux 调度器用 `goodness()` 函数给每个可运行进程打分，然后选分数最高的。听起来很直觉，但问题在于：每次调度决策都要**遍历整个可运行队列**。几百个进程还好，几千个进程的时候，每次时钟中断都要扫一遍队列重新计算优先级，这在大型服务器上已经是性能瓶颈了。

更致命的是，整个系统只有**一个全局运行队列**，用一把自旋锁保护。多 CPU 系统上，CPU A 想调度，CPU B 也想调度，俩人抢同一把锁——这在 SMP 越来越普及的 2002 年是难以接受的。

2002 年 1 月 3 日，Ingo Molnar 在 LKML 上发布了 O(1) 调度器的公告，标题是 `[announce] [patch] ultra-scalable O(1) SMP and ...`。这个补丁的目标很明确：**不管有多少进程、多少 CPU，调度决策的时间复杂度必须是常数**。

## 核心设计：优先级数组 + 双缓冲

O(1) 调度器的秘密武器是一个叫 `prio_array` 的数据结构。我们直接看 v2.6.11 的源码，这是最早可用 tag 中 O(1) 的完整实现：

```c
// kernel/sched.c:185 (v2.6.11)
struct prio_array {
	unsigned int nr_active;
	unsigned long bitmap[BITMAP_SIZE];
	struct list_head queue[MAX_PRIO];
};
```

就三个字段，但设计非常精妙。`bitmap` 是一张位图，每一位对应一个优先级——如果第 N 位是 1，说明优先级为 N 的链表上有任务。`sched_find_first_bit()` 可以在硬件指令级别（x86 上是 `bsf` 指令）**常量时间**找到最高优先级的位，然后直接从对应的 `queue[N]` 链表头上取任务。这就是 O(1) 的来源：不遍历，直接定位。

光有优先级数组还不够，O(1) 还需要一个机制来处理时间片耗尽的情况。这里用了一个很聪明的"双缓冲"设计——每个 CPU 的运行队列里有两个 `prio_array`：`active` 和 `expired`。正在运行的任务挂在 `active` 数组里，时间片用完的任务被移到 `expired` 数组。当 `active` 为空时，两个指针一交换，`expired` 变成新的 `active`，整个过程 O(1)：

```c
// kernel/sched.c:198 (v2.6.11) — 简化，省略了统计和 NUMA 相关字段
struct runqueue {
	spinlock_t lock;
	unsigned long nr_running;
	unsigned long long nr_switches;
	task_t *curr, *idle;
	prio_array_t *active, *expired, arrays[2];  // ← 双缓冲的核心
	int best_expired_prio;
	// ...
};
```

注意 `arrays[2]` 是实际存储，`active` 和 `expired` 只是指针，指来指去就行。这在数据结构课上叫"双缓冲"，在调度器里它保证了一个非常关键的性质：**任务用完时间片后不需要立即重新排序，攒到一批再翻转**。

调度核心流程读起来也很干净。我们看 `schedule()` 函数的关键路径：

```c
// kernel/sched.c:2662 (v2.6.11) — 简化版
asmlinkage void __sched schedule(void)
{
	// ... 前置处理：关抢占、获取当前任务 ...

	array = rq->active;
	if (unlikely(!array->nr_active)) {
		// active 数组空了，交换 active 和 expired
		rq->active = rq->expired;
		rq->expired = array;
		array = rq->active;
	}

	// O(1) 选任务：位图找最高优先级
	idx = sched_find_first_bit(array->bitmap);
	queue = array->queue + idx;
	next = list_entry(queue->next, task_t, run_list);
	// ... 上下文切换 ...
}
```

逻辑非常线性：检查 active 是否为空 → 空则翻转 → 位图找最高优先级 → 从链表取任务。没有遍历，没有排序，每一步都是 O(1)。

## Per-CPU 运行队列：锁竞争的终结

另一个关键决策是把运行队列从全局变成 per-CPU。每个 CPU 有自己的 `runqueue`，有自己的 `active`/`expired` 数组，调度时只锁自己的队列。这样一来，不同 CPU 可以完全并行地做调度决策，不会互相卡。

这个设计在今天看来是标配（CFS 也是 per-CPU 的 `cfs_rq`），但在 2002 年这是一个相当大胆的架构决策。它意味着负载均衡变成了一个独立的问题——某个 CPU 空了，得从别的 CPU "偷"任务过来，这就有了后面的 `load_balance()` 和调度域 (sched_domain) 机制。但至少调度核心路径上，锁竞争的问题彻底解决了。

## 交互性启发式：O(1) 的阿喀琉斯之踵

到这里 O(1) 的数据结构设计堪称教科书级别。但调度器不只是选下一个任务那么简单——桌面用户需要交互响应流畅，音频播放不能断续，鼠标拖窗口不能掉帧。O(1) 怎么处理这些需求？答案是**启发式**：

```c
// kernel/sched.c:91 (v2.6.11)
#define INTERACTIVE_DELTA	  2
```

O(1) 用 `sleep_avg` 追踪任务的睡眠时间，睡眠越多的任务被认为是"交互型"的，给它优先级奖励。`INTERACTIVE_DELTA`、`MAX_BONUS`、`TASK_INTERACTIVE` 这堆宏和参数，全是为了猜测谁是交互型任务而设计的。

问题是，这些启发式参数非常难调。不同负载下的"最佳"参数完全不同——桌面办公、音频处理、游戏、编译内核，每个场景都想要不同的交互性策略。内核邮件列表里关于这些参数的争论从来没有停过，有人觉得桌面太卡，有人觉得音频断续，还有人抱怨后台编译抢了太多 CPU。

这套启发式的脆弱性，直接催生了后面的两段故事：Con Kolivas 的 SD/RSDL，以及 Ingo Molnar 的 CFS。它们都试图解决同一个问题——**放弃猜谁是交互型任务，改用数学上可证明的公平性机制**。

## 回头看：O(1) 留下了什么

O(1) 调度器在 2007 年被 CFS 替代，运行了大约 5 年。从今天的视角看，它的优先级数组 + 位图设计早已不在，但它引入的几个关键架构决策一直延续到了今天：

**Per-CPU 运行队列**至今仍是 Linux 调度器的基本架构。CFS 的 `cfs_rq` 是 per-CPU 的，EEVDF 也是，sched_ext 的 DSQ 也是。O(1) 是第一个把这个模式确定下来的调度器。

**调度类 (sched_class) 的雏形**也在 O(1) 时代出现——虽然那时候还没有正式的 `struct sched_class` 抽象，但实时调度和普通调度的区分已经有了。v2.6.23 的 CFS 才把这个抽象正式化。

但 O(1) 最大的遗产，反倒是它暴露出来的问题：**用启发式做调度决策是走不通的**。这个教训如此深刻，以至于从 CFS 到 EEVDF 到 sched_ext，每一代调度器的核心设计目标之一都是"减少/消除启发式参数"。EEVDF 的 commit message 里 Peter Zijlstra 明确说了"如果我们能做到这一点，我们就可以删除一大堆糟糕的启发式代码"。

从某种意义上说，正是 O(1) 的成功（数据结构设计）和失败（交互性启发式）共同定义了后续 20 年调度器演进的方向。

---

## 时间线

| 时间 | 事件 |
|------|------|
| 2002-01-03 | Ingo Molnar 在 LKML 发布 O(1) 调度器公告 |
| 2002 (2.5 系列) | O(1) 进入开发内核 |
| 2003-12 (2.6.0) | O(1) 随 2.6.0 稳定版发布 |
| 2004 | Con Kolivas 提出 Staircase 调度器，挑战 O(1) 的交互性设计 |
| 2007-04 | SD/RSDL 和 CFS 同时竞逐替代 O(1) |
| 2007-07 | Commit `dd41f596cda0` — CFS 核心代码合入 |
| 2007-10 (2.6.23) | CFS 替代 O(1)，O(1) 时代落幕 |

## 参考文献

- Ingo Molnar 的 O(1) 公告 (LKML, 2002-01-03): https://lkml.org/lkml/2002/1/3/287
- O(1) scheduler 概述 (Grokipedia): https://grokipedia.com/page/O(1)_scheduler
- CFS 合入 commit `dd41f596cda0` (2007-07-09, Ingo Molnar): `git show dd41f596cda0` — 本地 `third_party/linux`
- 源码参考: `git show v2.6.11:kernel/sched.c` — `struct prio_array` (line 185), `struct runqueue` (line 198), `schedule()` (line 2662)
