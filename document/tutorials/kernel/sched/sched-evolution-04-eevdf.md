---
title: "调度器演进（四）：EEVDF——从虚拟公平到虚拟截止时间"
slug: sched-evolution-eevdf
type: supplementary
supplementary_for:
  - node_id: sched-cfs
    relation: "CFS 的终结者和替代者——从 vruntime 到 virtual deadline"
  - node_id: sched-rt
    relation: "实时调度的公平性维度——延迟与吞吐的分离"
difficulty: advanced
tags: [scheduler, evolution, eevdf, cfs, virtual-deadline, latency]
kernel_versions: ["6.6", "6.7", "6.19", "7.0", "7.1"]
milestones:
  - version: "6.6"
    event: "EEVDF 替代 CFS 成为默认调度策略"
    commit: "5e963f2bd4654a202a8a05aa3a86cb0300b10e6c"
  - year: "2023-03"
    event: "Peter Zijlstra 发布 EEVDF 补丁集"
    reference: "https://lkml.org/lkml/2023/3/6/732"
---

# 调度器演进（四）：EEVDF——从虚拟公平到虚拟截止时间

CFS 跑了 16 年。从 2007 年的 v2.6.23 到 2023 年的 v6.5，红黑树 + vruntime 的组合经受住了从手机到数据中心的考验。16 年里内核开发者给 CFS 打了无数补丁——group scheduling、bandwidth throttle、PELT 负载跟踪——但核心的选任务逻辑一直是"找 vruntime 最小的那个"。

2023 年，Peter Zijlstra——就是 2007 年帮 CFS 做"自适应调度粒度和数学优化"的那位——决定砍掉这棵红黑树的核心逻辑，换成一套基于虚拟截止时间的新算法。这个算法叫 EEVDF (Earliest Eligible Virtual Deadline First)，它不是凭空发明的，而是来自一篇 1995 年的学术论文。

## CFS 的根本缺陷：一个旋钮管两件事

CFS 运行了 16 年，期间社区积累了大量的痛点。但最根本的问题只有一个：**nice 值只能控制 CPU 时间份额，不能控制延迟。**

举个例子：一个音频处理进程和一个视频编码进程，可能需要相同份额的 CPU 时间（相同的 nice 值），但音频进程需要更低的延迟——它不需要更多 CPU 时间，只是需要被调度的频率更高、每次运行的时间更短。在 CFS 里，你没法表达"给我同样多的 CPU，但要更频繁地给我"这个需求。唯一的办法是调低 nice 值给它更多 CPU，但这改变了公平性。

Peter Zijlstra 在 LWN 的采访中说得很直白：

> "如果我们能做到这一点，我们就可以删除一大堆糟糕的启发式代码。"

> "它完全重构了基础调度器、放置、抢占、选择——一切。它们唯一共同点是它们都是基于虚拟时间的调度器。"

引用来源：LWN EEVDF 专题 (https://lwn.net/Articles/925371/)

## 1995 年的论文

EEVDF 算法出自 1995 年（有时被引用为 1996 年）的一篇学术论文，标题是 "Earliest Eligible Virtual Deadline First: A Flexible and Accurate Mechanism for Proportional Share Resource Allocation"，作者是 Ion Stoica 和 Hussein Abdel-Wahab，来自 Old Dominion University 计算机科学系。

引用来源：ACM Digital Library (https://dl.acm.org/doi/10.5555/890606)

核心公式非常简洁：

```
vd_i = ve_i + r_i / w_i
```

其中 `vd_i` 是任务 i 的虚拟截止时间 (virtual deadline)，`ve_i` 是虚拟到达时间，`r_i` 是请求的时间片长度，`w_i` 是权重。调度时选择**虚拟截止时间最早**的**合格**任务——"合格"意味着任务的虚拟时间不超前于系统的虚拟时间。

这个公式的妙处在于：`r_i`（时间片长度）和 `w_i`（权重）是独立的旋钮。想要更低延迟？缩短 `r_i`，截止时间就更早，被调度得更频繁，但总 CPU 份额由 `w_i` 单独控制，不会变。

## Commit 5e963f2bd465：大扫除

Peter Zijlstra 的 EEVDF 合入 commit 做了大量删除。我们看这个 commit 实际做了什么。

### 删除全局延迟参数

```diff
// kernel/sched/fair.c — 移除 CFS 的全局调优参数
-unsigned int sysctl_sched_latency			= 6000000ULL;
-static unsigned int normalized_sysctl_sched_latency	= 6000000ULL;
-unsigned int sysctl_sched_idle_min_granularity		= 750000ULL;
-unsigned int sysctl_sched_wakeup_granularity		= 1000000UL;
-static unsigned int normalized_sysctl_sched_wakeup_granularity	= 1000000UL;
```

CFS 的 `sched_latency`（默认 6ms 的目标延迟）和 `wakeup_granularity`（唤醒抢占粒度）全部删除。这些是 CFS 最难调的参数——它们控制"多长时间内所有任务都应该至少跑一次"和"唤醒时允许抢占的最小粒度"，但不同负载下最佳值完全不同。EEVDF 不需要它们了，因为虚拟截止时间自然地解决了延迟问题。

### 删除 buddy 系统

```diff
// include/linux/sched.h — 从 cfs_rq 移除 buddy 指针
 struct cfs_rq {
 	struct sched_entity	*curr;
 	struct sched_entity	*next;
-	struct sched_entity	*last;   // ← 删除
-	struct sched_entity	*skip;   // ← 删除
```

```diff
// kernel/sched/fair.c — 移除 buddy 管理函数
-static void __clear_buddies_last(struct sched_entity *se) { ... }
-static void __clear_buddies_skip(struct sched_entity *se) { ... }
-static void set_last_buddy(struct sched_entity *se) { ... }
-static void set_skip_buddy(struct sched_entity *se) { ... }
```

CFS 的 buddy 系统有三类：`next` buddy 是唤醒时的首选，`last` buddy 是 cache 热度偏好，`skip` buddy 是 yield 时跳过。这又是一套启发式——"刚唤醒的任务可能和当前任务有 cache 亲和性所以优先选它"之类的猜测。EEVDF 的虚拟截止时间使得这些优化不再必要。

### 删除时间片计算

```diff
// kernel/sched/fair.c — 移除 CFS 的按权重比例时间片计算
-static u64 __sched_period(unsigned long nr_running)
-{
-	if (unlikely(nr_running > sched_nr_latency))
-		return nr_running * sysctl_sched_min_granularity;
-	else
-		return sysctl_sched_latency;
-}
-
-static u64 sched_slice(struct cfs_rq *cfs_rq, struct sched_entity *se)
-{
-	// ... 40 行按权重比例计算 ...
-}
```

CFS 的 `sched_slice()` 按 "period × weight / total_weight" 计算每个任务该跑多久。EEVDF 简化为基础粒度 + 虚拟截止时间：

```c
// kernel/sched/fair.c:1029 (v6.6) — EEVDF 的新方案
se->slice = sysctl_sched_base_slice;  // 固定基础粒度
se->deadline = se->vruntime + calc_delta_fair(se->slice, se);  // 虚拟截止时间
```

不再按权重比例算时间片，而是给每个任务一个固定的基础粒度，然后根据权重计算对应的虚拟截止时间。权重高的任务截止时间更早（因为 `r_i / w_i` 更小），自然被调度得更频繁，但每次运行的时间一样长。

### 简化选任务

```diff
// kernel/sched/fair.c — 旧版（CFS + EEVDF feature flag 共存时期）
-static struct sched_entity *
-pick_next_entity(struct cfs_rq *cfs_rq, struct sched_entity *curr)
-{
-	if (sched_feat(EEVDF)) {
-		// ... EEVDF 路径 ...
-		return pick_eevdf(cfs_rq);
-	}
-	// ... 大量 buddy 选择逻辑 ...
-}

// 新版（EEVDF only）
+static struct sched_entity *
+pick_next_entity(struct cfs_rq *cfs_rq, struct sched_entity *curr)
+{
+	if (sched_feat(NEXT_BUDDY) &&
+	    cfs_rq->next && entity_eligible(cfs_rq, cfs_rq->next))
+		return cfs_rq->next;
+
+	return pick_eevdf(cfs_rq);  // ← 直接调用 EEVDF
+}
```

`pick_eevdf()` 的逻辑：找到**虚拟时间不超过当前虚拟时间**（合格）且**虚拟截止时间最早**的任务。这是一个数学上可证明公平的选择策略，不需要任何启发式。

### 删除 sched features

```diff
// kernel/sched/features.h
-SCHED_FEAT(LAST_BUDDY, true)     // 删除
-SCHED_FEAT(ALT_PERIOD, true)     // 删除
-SCHED_FEAT(BASE_SLICE, true)     // 删除
-SCHED_FEAT(EEVDF, true)          // 删除 — 不再是可选 feature，是唯一实现
```

最后一个特别有意思：`EEVDF` 本身曾经是一个可选的 `sched_feature`，可以通过 `sysctl` 关掉退回 CFS。但这个 commit 把它删了——EEVDF 不再是实验性的可选功能，而是**唯一的实现**。

## v6.6 之后的持续演进

EEVDF 合入后并没有停止变化。从 v6.6 到 v7.1-rc，调度器经历了密集的修复和优化：

在 v6.7 到 v6.19 之间，主要做了 lag clamp（限制任务的 lag 值防止极端情况）、zero_vruntime（fork 时新任务的 vruntime 初始化）和 avg_vruntime（队列的平均 vruntime 计算）等修复。v7.0 做了一次 vruntime 算术重做，把 wrapped-signed 问题清理干净，同时简化了抢占模式——现代架构（x86_64、ARM64、RISC-V）上只保留 fully preemptible 和 lazy 两种模式，去掉了 no-preempt 和 voluntary 选项。v7.0 还引入了基于 RSEQ 的时间片扩展机制，让用户空间进程可以请求临时延长 CPU 时间以完成临界区操作。v7.1-rc 引入了 `rel_deadline` 处理 fork 时的 deadline 继承问题，以及 delayed dequeue 修复。

这些后续变化说明 EEVDF 的合入只是一个开始——新算法暴露了 CFS 时代被掩盖的边界条件，清理这些边界条件花了好几个版本。但核心的"虚拟截止时间"选任务逻辑从 v6.6 到 v7.1 一直没变。

## 回头看：公平性的第二次进化

如果我们把视野拉长到整个调度器历史，会发现一个清晰的演进脉络：

O(1) 时代是**优先级驱动 + 启发式**，用 `sleep_avg` 猜谁是交互型任务，给优先级奖励。CFS 时代是**公平驱动 + 单旋钮**，用 vruntime 保证 CPU 时间份额的公平，但延迟和吞吐共享一个 nice 值旋钮。EEVDF 时代是**公平驱动 + 双旋钮**，用虚拟截止时间把延迟和 CPU 份额解耦，不再需要启发式。

每一代都解决了上一代的核心痛点，同时暴露出新的问题。EEVDF 的"新问题"是什么？现在下定论还太早——它才运行了不到三年。但从 v7.0 和 v7.1 的变化密度来看，EEVDF 的边界条件比 CFS 复杂，可能需要更长时间才能完全稳定。

---

## 时间线

| 时间 | 事件 |
|------|------|
| 1995 | Stoica & Abdel-Wahab 发表 EEVDF 论文 |
| 2023-03 | Peter Zijlstra 发布 EEVDF 补丁集到 LKML |
| 2023-05-31 | Commit `5e963f2bd465` — "sched/fair: Commit to EEVDF" |
| 2023-10 (6.6) | EEVDF 替代 CFS 成为默认调度策略 |
| 2023-10 ~ 2025 (6.7-6.19) | 持续修复：lag clamp, zero_vruntime, avg_vruntime |
| 2026-04 (7.0) | vruntime 算术重做，抢占模式简化，RSEQ 时间片扩展 |
| 2026-05 (7.1-rc) | rel_deadline, delayed dequeue 修复 |

## 参考文献

- Commit `5e963f2bd465` (2023-05-31, Peter Zijlstra, "sched/fair: Commit to EEVDF"): `git show 5e963f2bd465` — 本地 `third_party/linux`，包含于 `v6.6-rc1`
- LWN: EEVDF 专题 (2023): https://lwn.net/Articles/925371/
- Kernel 文档: https://docs.kernel.org/scheduler/sched-eevdf.html
- Kernel Internals: https://kernel-internals.org/sched/eevdf/
- LKML: EEVDF 补丁 (2023-03-06): https://lkml.org/lkml/2023/3/6/732
- 学术论文: https://dl.acm.org/doi/10.5555/890606
- Phoronix: Linux 7.0 调度器变化: https://www.phoronix.com/news/Linux-7.0-Scheduler
- Phoronix: Linux 7.1 调度器变化: https://www.phoronix.com/news/Linux-7.1-Scheduler
