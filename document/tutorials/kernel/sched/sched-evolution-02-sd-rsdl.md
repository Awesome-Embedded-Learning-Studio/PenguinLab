---
title: "调度器演进（二）：SD/RSDL 风波——一位麻醉医生挑战内核权威"
slug: sched-evolution-sd-rsdl
type: supplementary
supplementary_for:
  - node_id: sched-overview
    relation: "O(1) 调度器的替代方案之争，CFS 诞生的直接催化剂"
  - node_id: sched-cfs
    relation: "CFS 的设计动机和前驱——公平性概念的源头"
difficulty: intermediate
tags: [scheduler, evolution, sd, rsdl, con-kolivas, fairness]
kernel_versions: ["2.6.22", "2.6.23"]
milestones:
  - version: "2.6.22"
    event: "O(1) 调度器的交互性启发式问题被广泛诟病"
  - year: "2004"
    event: "Con Kolivas 提出 Staircase 调度器"
    reference: "https://lwn.net/Articles/224865/"
  - year: "2007-03"
    event: "RSDL 发布到 LKML"
    reference: "https://lwn.net/Articles/224865/"
  - year: "2007-04"
    event: "SD (Staircase Deadline) v0.46 发布"
    reference: "https://lwn.net/Articles/230500/"
  - year: "2007-04"
    event: "Ingo Molnar 发布 CFS（基于同样的公平性概念）"
    reference: "https://groups.google.com/g/linux.kernel/c/0dDfW83sEUM"
  - year: "2007-07"
    event: "Con Kolivas 宣布退出内核开发"
  - year: "2009-08"
    event: "Kolivas 发布 BFS (Brain Fuck Scheduler)"
---

# 调度器演进（二）：SD/RSDL 风波——一位麻醉医生挑战内核权威

我们上一节说到 O(1) 调度器的阿喀琉斯之踵是交互性启发式——用 `sleep_avg` 猜测谁是"交互型"任务，给优先级奖励，但参数怎么调都不对。这个痛点不只内核开发者知道，桌面用户感受更深：2005 年前后，Linux 桌面的响应体验跟 Windows XP 比起来确实有差距，拖窗口掉帧、音频断续这些问题困扰着每一个试图把 Linux 当桌面用的人。

有一位澳大利亚的麻醉医生，实在受不了了。

## Con Kolivas：从麻醉师到调度器挑战者

Con Kolivas 的本职工作是麻醉医生，不是全职内核开发者。但他是个硬核 Linux 桌面用户，对交互响应的敏感程度可能比大多数内核开发者都高——毕竟他在手术室里需要系统随时响应，不能卡顿。

2004 年，Kolivas 提出了他的 **Staircase 调度器**。核心思想很简单：不用 `sleep_avg` 之类的启发式猜谁是交互型任务，而是让所有任务按优先级"阶梯"式下降——用完当前优先级的时间配额就降一级，降到最低再回顶部。这样每个任务迟早都能得到 CPU，不会被饿死，也不需要复杂的启发式参数。

这个想法在当时引起了不小的关注。Linus Torvalds 本人对 RSDL（Staircase 的后继版本）的评价是：

> "我同意，部分原因是它显然一直备受好评，但主要是因为它的行为似乎更易于推理，这在带有进程状态历史的交互性增强器中一直非常困难。"

引用来源：LWN 对 RSDL 的报道 (https://lwn.net/Articles/224865/)

注意 Linus 说的关键词——"更易于推理" (easier to reason about)。这正是 O(1) 启发式的根本问题：参数多、行为难预测、改一个地方另一个地方就崩。

## RSDL → SD：公平性的第一次正式尝试

2007 年 3 月，Kolivas 发布了 **RSDL** (Rotating Staircase Deadline)，几周后重命名为 **SD** (Staircase Deadline)。核心机制叫"小旋转" (minor rotation)：

当一个任务的优先级配额耗尽时，它不是简单地被降级，而是**所有任务一起旋转**——这保证了即使最低优先级的任务也能在确定的时间内得到 CPU。更重要的是，RSDL/SD **完全不用交互性启发式**。睡眠的任务自然获得优先级提升，因为它们没有消耗 CPU 时间，不需要额外的奖励机制。

这种"自然公平"的设计在桌面上效果很好。社区测试普遍反馈 RSDL 比 O(1) 的桌面体验流畅得多。

SD 进入了 Andrew Morton 的 `-mm` 树（内核的实验分支）进行测试。看起来合入主线只是时间问题。

然后事情急转直下。

## 62 小时的回应

2007 年 4 月 13 日（UTC）/ 4 月 14 日（欧洲时区清晨），Ingo Molnar——就是五年前写 O(1) 调度器的那位——在 LKML 上发布了一个全新的调度器：**CFS (Completely Fair Scheduler)**。

Molnar 自己说的：

> "我在本周三早上 8 点开始编写 CFS 补丁的第一行代码，62 小时后，即周五晚上 10 点，将其发布到 LKML。"

引用来源：LKML 原帖 (https://groups.google.com/g/linux.kernel/c/0dDfW83sEUM)

Molnar 把 CFS 描述为"Linux 任务调度器的完全重写"，并明确指出它基于与 RSDL/SD **"相同的基本公平概念"**，但采用了"完全不同的方法和实现"。

这个时间点非常微妙。SD 刚刚获得社区好评、进入 `-mm` 树不到一个月，CFS 就出现了。而且 CFS 采用了同样的"公平性"核心理念，只是用红黑树 + 虚拟运行时间 (vruntime) 来实现，而不是 Kolivas 的阶梯下降机制。

接下来的 2007 年 4 月到 5 月，SD 和 CFS 在 LKML 上进行了激烈的争论。SD 达到了 v0.46，CFS 达到了 v6。两方各有支持者，争论的焦点不仅仅是技术实现，还涉及维护者权威、社区治理等更深层次的问题。

最终，CFS 被选中合并到 2.6.23。SD 没有合入主线。

## Kolivas 的退出

这段经历对 Kolivas 的打击是深远的。2007 年 7 月，他宣布停止内核开发。

根据维基百科（引用 APC 杂志的采访）和多个独立来源的报道，Kolivas 表达了"对主线内核开发过程某些方面的挫败感，认为这些过程没有给予桌面交互性足够的优先级，此外，黑客行为也损害了他的健康、工作和家庭。"

引用来源：
- Wikipedia: Con Kolivas (https://en.wikipedia.org/wiki/Con_Kolivas)
- Hacker News 讨论 (https://news.ycombinator.com/item?id=36545)

Reddit 上的讨论指出："尽管他主要保持礼貌的语气，但很明显，他在 Linux 调度器开发方面受到的待遇让他感到非常不快。"

引用来源：Reddit r/programming (https://www.reddit.com/r/programming/comments/2986i/)

事情到这里还没完。2009 年 8 月 31 日，Kolivas 回归了，发布了 **BFS (Brain Fuck Scheduler)**——名字就带着一股情绪。BFS 专为桌面/多核设计，代码简洁（不到 6000 行），不打算合入主线。它后来演变为 MuQSS (Multiple Queue Skiplist Scheduler)，直到 2021 年 Kolivas 才考虑结束 `-ck` 补丁集的维护。

## 回头看：公平性胜出了

SD/RSDL 的故事有一个值得深思的结局：虽然 Kolivas 的代码没有合入主线，但他倡导的核心理念——**用数学上的公平性替代启发式猜测**——被 CFS 完全继承并发扬光大。从 CFS 的 vruntime 到 EEVDF 的虚拟截止时间，再到 sched_ext 的 BPF 可编程公平策略，"公平性优于启发式"这个思想贯穿了 Linux 调度器后 O(1) 时代的全部演进。

Kolivas 在 2004-2007 年间做的事情，本质上是第一个把"公平调度"从学术概念变成可工作的内核实现的人。他走了阶梯下降的路线，Molnar 走了红黑树 + vruntime 的路线，但出发点是一样的。

在内核社区的历史上，这是一个罕见的案例：一个外部贡献者的核心洞察被采纳了，但他的实现被替换了。对于技术本身来说，这是好事——CFS 的实现确实更适合大规模部署。对于 Kolivas 个人来说，这个过程显然不够公平。

---

## 时间线

| 时间 | 事件 |
|------|------|
| 2004 | Con Kolivas 提出 Staircase 调度器 |
| 2007-03 | RSDL 发布到 LKML |
| 2007-04 | SD (Staircase Deadline) 发布，进入 `-mm` 树 |
| 2007-04-13/14 | Ingo Molnar 在 62 小时内写出 CFS 原型并发布到 LKML |
| 2007-04 ~ 05 | SD v0.46 vs CFS v6，LKML 激烈争论 |
| 2007-07 | Kolivas 宣布退出内核开发 |
| 2007-10 (2.6.23) | CFS 合入主线 |
| 2009-08-31 | Kolivas 发布 BFS (Brain Fuck Scheduler) |
| 2021 | Kolivas 考虑结束 MuQSS/-ck 补丁集 |

## 参考文献

- LWN: RSDL 报道 (2007): https://lwn.net/Articles/224865/
- LKML: SD v0.40 发布: https://lwn.net/Articles/230500/
- 博客: 2007 调度器之战 (Frederic's Blog, 2007-04-28): https://blog.frehi.be/2007/04/28/linux-kernel-the-battle-of-the-cpu-schedulers/
- LKML: CFS 原始公告 (Ingo Molnar, 2007-04-13/14): https://groups.google.com/g/linux.kernel/c/0dDfW83sEUM
- Wikipedia: Con Kolivas: https://en.wikipedia.org/wiki/Con_Kolivas
- Reddit: "Why I quit" 讨论: https://www.reddit.com/r/programming/comments/2986i/
- Hacker News 讨论: https://news.ycombinator.com/item?id=36545
