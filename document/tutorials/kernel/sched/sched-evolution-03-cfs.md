---
title: "调度器演进（三）：CFS 诞生——62 小时重写调度器"
slug: sched-evolution-cfs
type: supplementary
supplementary_for:
  - node_id: sched-cfs
    relation: "CFS 的设计动机、核心数据结构和初始实现"
  - node_id: sched-overview
    relation: "调度器从优先级驱动到公平性驱动的范式转变"
difficulty: intermediate
tags: [scheduler, evolution, cfs, vruntime, rbtree, sched-class]
kernel_versions: ["2.6.23", "2.6.24"]
milestones:
  - version: "2.6.23"
    event: "CFS 替代 O(1) 成为默认调度器"
    commit: "dd41f596cda0d7d6e4a8b139ffdfabcefdd46528"
  - version: "2.6.24"
    event: "Group Scheduling 支持"
---

# 调度器演进（三）：CFS 诞生——62 小时重写调度器

上一节我们聊到 Ingo Molnar 在 62 小时内写出了 CFS 原型。现在我们打开 v2.6.23 的源码，看看这 62 小时到底产出了什么。说实话，第一次读 CFS 的代码时我有点惊讶——它比我想象的要简洁得多。核心逻辑不到 1000 行，但引入了三个影响深远的设计：虚拟运行时间、红黑树、调度类层级。

## 核心问题：怎么定义"公平"

CFS 的出发点是一个看似简单的问题：**两个 nice 值相同的进程，应该获得完全相等的 CPU 时间。** nice 值不同的进程，CPU 时间按权重比例分配。这听起来像废话，但 O(1) 做不到这一点——它的启发式奖励机制总是在破坏这个等式。

CFS 的解决方案是追踪每个任务的**虚拟运行时间 (vruntime)**。不过这里有个细节：v2.6.23 的 CFS 实际上用的字段叫 `fair_key` 和 `wait_runtime`，不是后来大家熟悉的 `vruntime`。我们看 v2.6.23 的 `sched_entity` 结构体：

```c
// include/linux/sched.h (v2.6.23)
struct sched_entity {
	long			wait_runtime;
	unsigned long		delta_fair_run;
	unsigned long		delta_fair_sleep;
	unsigned long		delta_exec;
	s64			fair_key;         // ← 红黑树的排序键
	struct load_weight	load;            // ← nice 值映射的权重
	struct rb_node		run_node;        // ← 红黑树节点
	unsigned int		on_rq;

	u64			exec_start;
	u64			sum_exec_runtime;
	u64			prev_sum_exec_runtime;
	u64			wait_start_fair;
	u64			sleep_start_fair;

#ifdef CONFIG_SCHEDSTATS
	u64			wait_start;
	u64			wait_max;
	s64			sum_wait_runtime;
	u64			sleep_start;
	u64			sleep_max;
	s64			sum_sleep_runtime;
	u64			block_start;
	u64			block_max;
	u64			exec_max;
	unsigned long		wait_runtime_overruns;
	unsigned long		wait_runtime_underruns;
#endif
};
```

`fair_key` 是红黑树的排序键——谁获得的 CPU 时间最少（key 最小），谁就应该下一个运行。`wait_runtime` 追踪任务"欠"多少 CPU 时间或者"多占了"多少。这两个字段后来被统一简化为单个 `vruntime` 字段，但在 v2.6.23 中它们是分开的。

## 红黑树：O(log n) 的公平排序

O(1) 调度器用位图 + 优先级数组实现 O(1) 选择。CFS 用红黑树排序所有可运行任务，按 `fair_key` 排序。选择下一个任务变成了"取红黑树最左节点"，复杂度 O(log n) 插入和删除。

对应的运行队列结构体：

```c
// kernel/sched.c:180 (v2.6.23)
struct cfs_rq {
	struct load_weight load;
	unsigned long nr_running;

	s64 fair_clock;           // ← CFS 的"全局时钟"
	u64 exec_clock;
	s64 wait_runtime;
	u64 sleeper_bonus;
	unsigned long wait_runtime_overruns, wait_runtime_underruns;

	struct rb_root tasks_timeline;    // ← 红黑树根
	struct rb_node *rb_leftmost;      // ← 缓存的最左节点（vruntime 最小）
	struct rb_node *rb_load_balance_curr;

#ifdef CONFIG_FAIR_GROUP_SCHED
	struct sched_entity *curr;
	struct rq *rq;
	struct list_head leaf_cfs_rq_list;
#endif
};
```

`rb_leftmost` 是一个性能优化——红黑树的最左节点就是 `fair_key` 最小的任务，缓存这个指针后选择下一个任务的操作实际上是 O(1)，不需要遍历树。`fair_clock` 是 CFS 的"全局时钟"，类似于后来版本的 `min_vruntime`。

## 调度类：模块化的开始

CFS 引入的第三个关键设计是 **sched_class** 层级。在 O(1) 时代，实时调度和普通调度的区分散落在 `schedule()` 函数的各个 `if/else` 分支里。CFS 把每种调度策略抽象成独立的 `sched_class` 对象：

```c
// kernel/sched.c:793 (v2.6.23)
#define sched_class_highest (&rt_sched_class)
```

然后在 `sched_init()` 中把三个类串起来：

```c
// kernel/sched.c:6532-6534 (v2.6.23)
rt_sched_class.next = &fair_sched_class;
fair_sched_class.next = &idle_sched_class;
```

调度时从最高优先级的 `sched_class` 开始尝试，如果该类没有可运行的任务就沿链表往下找。这个设计在后续版本中扩展到了 5 个调度类：`stop` → `deadline` → `rt` → `fair` → `idle`。更重要的是，它为 sched_ext (BPF 可扩展调度器) 铺平了道路——sched_ext 本质上就是插入到这个链表中的一个新 `sched_class`。

## 版权头里的人名故事

CFS 的版权头本身就是一个微缩的历史：

```
 *  Copyright (C) 2007 Red Hat, Inc., Ingo Molnar <mingo@redhat.com>
 *  Interactivity improvements by Mike Galbraith
 *  Various enhancements by Dmitry Adamushko
 *  Group scheduling enhancements by Srivatsa Vaddagiri (IBM)
 *  Scaled math optimizations by Thomas Gleixner
 *  Adaptive scheduling granularity, math enhancements by Peter Zijlstra
```

引用来源：`git show v2.6.23:kernel/sched_fair.c` 版权头 (本地 third_party/linux)

注意最后一位——**Peter Zijlstra**，他的邮箱是 `pzijlstr@redhat.com`，2007 年他在 Red Hat 做的是"自适应调度粒度和数学优化"。16 年后，正是他用 EEVDF 替代了 CFS。这个版权头就像一个预言。

## CFS vs O(1)：根本性的范式转变

我们把两代调度器的核心差异放在一起看会更清楚。O(1) 的核心是**优先级驱动**：高优先级先运行，用启发式猜测谁是"重要"的任务。CFS 的核心是**公平驱动**：每个任务按权重获得 CPU 时间份额，不需要猜测，数学保证公平。

选任务的机制也从位图查找变成了红黑树遍历，时间复杂度从 O(1) 变成了 O(log n)。表面上看是退步了，但实际系统中红黑树的 `rb_leftmost` 缓存使得选择操作几乎也是 O(1)，而且这个 trade-off 换来的是完全可预测、可推理的调度行为。

## v2.6.23 只是起点

CFS 在 v2.6.23 合入时还是一个相当简洁的实现。接下来的 16 年里，它经历了大量的增强：group scheduling (v2.6.24)、CFS bandwidth (v3.2)、PELT 负载跟踪 (v3.8)、util_est (v5.7)……但核心的红黑树 + vruntime 框架从 2007 年到 2023 年一直没变。

直到 v6.6，Peter Zijlstra 用 EEVDF 替代了 CFS 的选择逻辑。但即便在 EEVDF 时代，`sched_entity`、`cfs_rq`（虽然名字还叫 `cfs_rq`）、`sched_class` 层级这些 v2.6.23 引入的基础设施依然在用。62 小时的代码，服务了 16 年——这可能是 Linux 内核历史上投入产出比最高的一次重写。

---

## 时间线

| 时间 | 事件 |
|------|------|
| 2007-04-13/14 | Ingo Molnar 发布 CFS 原型到 LKML |
| 2007-07-09 | Commit `dd41f596cda0` — CFS 核心代码 |
| 2007-10 (2.6.23) | CFS 合入主线，替代 O(1) |
| 2008-01 (2.6.24) | Group Scheduling 支持 |
| 2012 (3.2) | CFS Bandwidth |
| 2013 (3.8) | PELT 负载跟踪 |
| 2023 (6.6) | EEVDF 替代 CFS 选择逻辑 |

## 参考文献

- Commit `dd41f596cda0` (2007-07-09, Ingo Molnar, "sched: cfs core code"): `git show dd41f596cda0` — 本地 `third_party/linux`，包含于 `v2.6.23-rc1`
- LKML 原始公告 (2007-04-13/14): https://groups.google.com/g/linux.kernel/c/0dDfW83sEUM
- LWN: EEVDF 文章（确认 CFS 于 2.6.23 合并）: https://lwn.net/Articles/925371/
- IBM Developer: CFS 教程: https://developer.ibm.com/tutorials/l-completely-fair-scheduler/
- 源码: `git show v2.6.23:kernel/sched.c` — `struct cfs_rq` (line 180), `sched_class_highest` (line 793), sched_class chain (lines 6532-6534)
- 源码: `git show v2.6.23:include/linux/sched.h` — `struct sched_entity`
- 源码: `git show v2.6.23:kernel/sched_fair.c` — 版权头及完整 CFS 实现
