---
title: "调度器演进（五）：sched_ext——BPF 可编程调度器的争议之路"
slug: sched-evolution-sched-ext
type: supplementary
supplementary_for:
  - node_id: sched-overview
    relation: "调度器的未来方向——可编程、可实验、可定制"
  - node_id: sched-cfs
    relation: "CFS/EEVDF 之外：BPF 调度器的架构基础"
difficulty: advanced
tags: [scheduler, evolution, sched-ext, bpf, extensible, controversy]
kernel_versions: ["6.12", "7.0", "7.1"]
milestones:
  - year: "2022-11"
    event: "sched_ext RFC v1 发布到 LKML"
  - year: "2023-03"
    event: "v3 patchset 发布，完整的动机说明"
    reference: "https://lwn.net/Articles/926501/"
  - year: "2024-06"
    event: "Linus Torvalds 介入，要求合并到 6.11"
    reference: "https://lwn.net/Articles/978007/"
  - version: "6.12"
    event: "sched_ext 最终合入主线"
    commit: "f0e1a0643a59bf1f922fa209cec86a170b784f3f"
  - version: "7.0"
    event: "sub-scheduler 架构，允许多个 BPF 调度器共存"
  - version: "7.1-rc"
    event: "sched_ext 继续完善，idle 选择改进"
---

# 调度器演进（五）：sched_ext——BPF 可编程调度器的争议之路

前面四节我们看了 O(1) → SD/RSDL → CFS → EEVDF 的演进主线。每一代调度器都是内核开发者用 C 代码写死在内核里的，改一次要经过漫长的讨论、测试、合入流程，而且一旦合入就影响所有用户。这种保守的节奏在过去 20 年里保护了 Linux 的稳定性，但也带来一个问题：**调度器是内核里最难实验的子系统之一**。

2024 年 10 月，一个叫 sched_ext 的补丁集合入了 Linux 6.12。它的核心思想是：**用 BPF 程序实现调度策略，内核只提供框架和安全性保证**。听起来很美好，但合入过程堪称内核社区近年来最具争议的事件之一——调度子系统维护者 Peter Zijlstra 明确反对，最终是 Linus Torvalds 亲自拍板才推进的。

## 动机：为什么要让 BPF 写调度器

内核调度器的开发周期是以年计的。CFS 从概念到合入用了几个月（得益于 Molnar 的 62 小时），但 EEVDF 从首次补丁到合入用了大约半年，而且 EEVDF 只是改了选任务的算法，没改框架。如果有人想实验一套全新的调度策略——比如专门为游戏优化的、为 HPC 负载设计的、或者干脆就是把某个学术论文的算法拿来试试——在 sched_ext 之前，他们只能 fork 内核，改 C 代码，编译，重启，祈祷不 panic。

sched_ext 的方案是：内核提供一组 BPF 钩子，用户用 BPF 程序实现 `select_cpu()`（选 CPU）、`enqueue()`（入队）、`dispatch()`（分发）等操作。BPF 验证器保证安全性（不会死锁、不会越界、执行时间有上限），如果 BPF 调度器崩溃了，内核自动 fallback 到 EEVDF。这样研究者可以快速迭代，云厂商可以为不同负载定制调度策略，游戏开发者可以专门优化帧率相关的调度行为。

## 争议：Linus 亲自下场

sched_ext 的合入过程并不顺利。最早在 2022 年 11 月，Tejun Heo (Meta) 就把 RFC v1 发到了 LKML。2023 年 1 月发了 v2，3 月发了 v3——v3 附带了一份相当完整的动机说明，解释了为什么 Meta 和 Google 都需要这个功能。

引用来源：LWN v3 patchset (https://lwn.net/Articles/926501/)

但调度子系统维护者 Peter Zijlstra 一直反对合并。争议的焦点包括：调度器是内核核心，允许 BPF 程序介入是否安全？用户体验是否会被碎片化（每个发行版用不同的 BPF 调度器）？维护负担如何分担？

争论持续了一年多。2024 年 6 月 11 日，Linus Torvalds 终于忍不住了，在邮件列表里明确表态：

> "老实说，我认为没有任何理由再推迟了。整个补丁集是去年内核维护者峰会的主要（私下）讨论话题，我认为在今年即将到来的维护者峰会上进行同样的讨论没有任何价值... 我目前的计划是将其合并到 6.11 中。"

引用来源：LWN 合并公告 (https://lwn.net/Articles/978007/)

Linus 亲自推翻子系统维护者的决定，这在内核社区中极其罕见。即使如此，sched_ext 在 6.11 合入窗口中又出了问题，被暂时撤回。最终在 2024 年 10 月合入 **6.12**。

引用来源：LWN LPC 2024 报告 (https://lwn.net/Articles/991205/)

## 核心开发团队

sched_ext 的核心开发者来自 Meta 和 Google：

- **Tejun Heo** (Meta) — 主要作者和维护者
- **David Vernet** (Meta) — 合著者
- **Josh Don** (Google) — 重要贡献者
- **Barret Rhoden** (Google) — 重要贡献者

引用来源：Commit `f0e1a0643a59` 的 author 和 co-authored-by 行。

## 源码：DSQ 抽象

sched_ext 的核心概念是 **DSQ (Dispatch Queue)**。在 v7.0 的 `kernel/sched/ext.c` 中，调度流程被拆成了几个 BPF 钩子：

```
BPF ops.select_cpu()  →  选择目标 CPU
BPF ops.enqueue()     →  将任务放入某个 DSQ
内核 dispatch          →  从 DSQ 取任务运行
BPF ops.dispatch()    →  从自定义 DSQ 搬运到 local DSQ
```

DSQ 分三种：全局 DSQ（所有 CPU 共享）、per-CPU local DSQ（每个 CPU 独立）、以及 BPF 调度器自定义的任意数量 DSQ。这个抽象非常灵活——你可以实现一个简单的 FIFO 调度器（只用全局 DSQ），也可以实现复杂的分层调度（多层 DSQ + 优先级）。

sched_ext 注册在 `sched_class` 层级的最低位置，只处理 `SCHED_NORMAL`/`SCHED_BATCH` 任务。实时调度类完全不受影响——即使 BPF 调度器出问题了，实时任务依然能按时调度。

## v6.12 → v7.1 的快速演进

sched_ext 合入后，变化速度远超调度器的其他组件：

在 v6.13 到 v6.19 期间，主要做了 cgroup 集成改进、bypass 修复和 BPF kfunc 安全加固。v7.0 是一个大版本——引入了 **sub-scheduler 架构**，允许多个 BPF 调度器共存，每个 cgroup 可以有自己的调度策略。`kernel/sched/` 目录下 sched_ext 相关的文件已经从合入时的 3 个增长到了 5 个（`ext.c`, `ext.h`, `ext_idle.c`, `ext_idle.h`, `ext_internal.h`），而且变化量远超其他调度器文件。v7.1-rc 继续完善 sub-scheduler，改进了 idle 选择逻辑和 BPF kfunc 安全性。

这种变化速度本身就说明了 sched_ext 的定位：它不是一个"写完就稳定"的调度器，而是一个**持续演进的框架**。BPF 生态、调度器研究和生产环境的需求在共同驱动它快速迭代。

引用来源：Phoronix Linux 7.1 sched_ext (https://www.phoronix.com/news/Linux-7.1-sched_ext)

## 回头看：调度器的民主化

如果我们把 O(1) → CFS → EEVDF → sched_ext 的演进串起来看，会发现一个清晰的趋势：**调度策略的定义权正在从内核开发者向用户态转移**。

O(1) 时代，调度策略完全由内核代码决定，用户只能调 nice 值。CFS 引入了 `sched_features` 调试接口，可以开关一些实验性优化。EEVDF 把延迟和 CPU 份额解耦，给了用户更精细的控制。sched_ext 则走得更远——它让用户可以直接用 BPF 程序定义调度策略，不需要改内核代码。

这个趋势和 Linux 内核整体的"BPF 化"是一致的。网络栈有 XDP，跟踪有 BPF trampoline，现在调度器也有了 BPF 接口。内核越来越像一个"提供安全原语的平台"，而具体的策略实现越来越多地转移到用户态。

当然，这种"民主化"不是没有代价的。Peter Zijlstra 的担忧是有道理的——碎片化、安全边界、维护负担都是真实的问题。sched_ext 能不能在保持灵活性的同时避免这些问题，可能需要 5-10 年才能看清楚。

---

## 时间线

| 时间 | 事件 |
|------|------|
| 2022-11 | sched_ext RFC v1 发布到 LKML |
| 2023-01 | RFC v2 |
| 2023-03 | v3 patchset（完整动机说明） |
| 2023-03 ~ 2024-05 | 社区争论，维护者反对 |
| 2024-06-11 | Linus Torvalds 介入，要求合并 |
| 2024-06-18 | Commit `f0e1a0643a59` — sched_ext 实现 |
| 2024-08 | 从 6.11 撤回（出现问题） |
| 2024-09 | LPC 2024 深入讨论 |
| 2024-10 (6.12) | sched_ext 最终合入主线 |
| 2025 (6.13-6.19) | 稳定化和安全加固 |
| 2026-04 (7.0) | sub-scheduler 架构引入 |
| 2026-05 (7.1-rc) | 继续完善 |

## 参考文献

- Commit `f0e1a0643a59` (2024-06-18, Tejun Heo, "sched_ext: Implement BPF extensible scheduler class"): `git show f0e1a0643a59` — 本地 `third_party/linux`，包含于 `v6.12-rc1`
- LWN: v3 patchset (2023): https://lwn.net/Articles/926501/
- LWN: 合并公告 (2024-06): https://lwn.net/Articles/978007/
- LWN: LPC 2024 sched_ext 讨论 (2024-09): https://lwn.net/Articles/991205/
- Kernel 文档: https://www.kernel.org/doc/html/next/scheduler/sched-ext.html
- Phoronix: Linux 7.1 sched_ext 变化: https://www.phoronix.com/news/Linux-7.1-sched_ext
- 源码: `git show v7.0:kernel/sched/ext.c`, `git show v7.0:kernel/sched/ext.h` 等 5 个文件
