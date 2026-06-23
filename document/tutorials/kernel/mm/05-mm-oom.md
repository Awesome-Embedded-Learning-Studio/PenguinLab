---
title: OOM Killer：回收也扛不住时的最后防线
slug: mm-oom
difficulty: intermediate
tags: [内存管理, OOM Killer, 进程管理, 内存压力]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/mm/04-mm-page-reclaim
related:
  - /tutorials/kernel/mm/04-mm-page-reclaim
sources:
  - notes: document/notes/linux_kernel_programming/ch09.md
---

# OOM Killer：回收也扛不住时的最后防线

> 🔨 **整理中** · 这篇是从读书笔记（ch09 §9.4.2/§9.4.3）整理出来的骨架，OOM 的判定逻辑、`oom_score_adj` 调参讲清了；但动手部分（QEMU 上造内存压力真触发一次 OOM、用 `oom_score_adj` 保住指定进程存活、抓 `dmesg` 看 killed 行）还没亲手跑过。等我们在 QEMU 里验过，就升级成 ✅ 已锤炼。

## 回收都来不及了：与其全崩，不如砍一个

上一篇我们聊了内存回收：`kswapd` 在后台默默扫地，水位跌破 `min` 了就触发 direct reclaim，让申请内存的进程阻塞着等回收。这些手段本质都是"挤海绵"——把没人用的 page cache、能丢的 Slab 对象挤出去，换回一点空闲页。

可海绵总有挤干的时候。回收线程拼了老命，连 direct reclaim 都上了，内存还是不够——这时候内核面对的是一个二选一的绝境：**要么整个系统一起死，要么牺牲一个进程换大家活。** 内核选了后者，请出那位冷血杀手——**OOM Killer**（Out-Of-Memory Killer）。

它的逻辑粗暴到让人想哭：**算个分，谁分高谁死。** 发个 `SIGKILL`，那个进程连求饶的机会都没有（`SIGKILL` 无法被捕获或忽略），它占的内存全部释放出来，系统续命。

> 这是 reclaim（含 direct reclaim）全部失败之后的兜底。回收是"挤海绵"，OOM 是"砍人止血"——两个完全不同量级的手段。下一篇我们回头看回收篇就能把这条链路串起来：分配失败 → kswapd → direct reclaim → 还是失败 → OOM。

## oom_score：怎么挑"该牺牲的进程"

杀手不瞎砍，它有一套评分系统，叫 **`oom_score`**。每个进程都有一个分数，**分越高越该死**。判定的核心思路就两条：

1. **占用内存多的优先砍**——这是最实在的释放收益，砍掉一个吃了几个 G 的进程，比砍十个吃几 MB 的小喽啰划算得多。
2. **相对不重要的优先砍**——这是个相对概念，后面 `oom_score_adj` 就是用来微调这一项的。

粗略理解：`oom_score` ≈ 占用内存大小，再做点归一化（按总内存的千分比表达），所以一个吃掉系统一半内存的进程，分数会接近 1000。

具体怎么算、`oom_badness()` 怎么给每个进程打分，核心在 `mm/oom_kill.c`（Linux 6.19），行号待亲测核对。我们这里抓主线：**它综合进程的 RSS（常驻内存）、页表、swap 占用，给出一个分数，然后挑分数最高的那个动手。**

## 执行流程：out_of_memory → select_bad_process → oom_kill_process

把整条调用链画出来，就知道杀手是怎么一步步动手的：

1. **`out_of_memory()`**：OOM 的总入口。回收彻底失败、申请内存的进程已经快被饿死时，内核走到这里。它负责决定"要不要真的开杀"（有些情况会先重试回收）。
2. **`select_bad_process()`**：遍历所有进程，调用 `oom_badness()` 给每个进程打分，挑出分数最高的那个"倒霉蛋"。
3. **`oom_kill_process()`**：拿到受害者后，给它发 `SIGKILL`。进程被杀，它持有的内存（匿名页、页表、Slab 等）被回收。

这三步都在 `mm/oom_kill.c`（Linux 6.19），行号待亲测核对。整个过程是同步的——杀手动手、回收内存，让那个原本卡在分配上的进程终于拿到页，继续跑下去。

> 这也解释了为什么线上服务"莫名其妙"被杀：你的进程吃内存最多，`oom_badness()` 给它打了最高分，杀手毫不留情。日志里常常只剩一行 `Killed`，就是它干的。

## 保护重要进程：oom_score_adj

杀手无情，但不是没法管。关键服务（sshd、数据库主进程、监控 agent）被杀一场灾难。内核给了我们一个手动加权旋钮：**`oom_score_adj`**。

- **范围**：`-1000` 到 `1000`。
- **`-1000`**：**绝对免疫**，这个进程永不被 OOM 砍。生产环境保命首选。
- **`1000`**：反过来——优先砍它（想自杀或者搞"自爆替死鬼"时用）。
- 中间值则是在 `oom_badness()` 算出的原始分基础上做偏移。

```bash
# 保护 SSH 守护进程，让 OOM 永远别动它
echo -1000 > /proc/$(pidof sshd)/oom_score_adj
```

> ⚠️ **待亲测核对**：上面这条是整理时的参考用法。我们会拿到 QEMU ARM64 上：先把某个吃内存的测试进程 `oom_score_adj` 设成 `-1000`，再造内存压力触发 OOM，看它是不是真活下来了——把 `-1000` 的"免死金牌"亲眼验一遍。

**旧接口 `oom_adj`**：早期内核用的是 `/proc/<pid>/oom_adj`，范围 `-17` 到 `15`，`-17` 等价于现在的 `-1000`。现在它被 `oom_score_adj` 取代了，内核为了兼容还留着，但官方文档明确建议用新的。新代码别碰 `oom_adj`。

## 查看与调参：/proc 下的两个文件

跟 OOM 打交道，就这两个文件：

| 文件 | 作用 | 可读/可写 |
|:---|:---|:---|
| `/proc/<pid>/oom_score` | 当前进程的 OOM 分数（越高越该死） | 只读 |
| `/proc/<pid>/oom_score_adj` | 手动加权，`-1000` 免死 / `1000` 优先砍 | 可读写 |

排查"为什么偏偏杀了我的进程"的标准动作：`cat /proc/<pid>/oom_score` 看它分有多高；想保住它就往 `oom_score_adj` 写 `-1000`。

## 动手待亲测

> 这部分是验证方案占位，还没在 QEMU 上跑过，跑通后会补真实输出、真实 dmesg、真实存活截图，升级成正式实战。

**验证目标一：造内存压力，真触发一次 OOM**
- 在 QEMU ARM64 里起一个故意吃内存的进程（比如一段不断 `malloc` 不 `free` 的死循环，或用 stress 工具）。
- 也可以直接用 SysRq 强制走一遍 OOM 评估路径（命令待亲测核对）：
  ```bash
  echo f > /proc/sysrq-trigger
  ```
- 观察：`dmesg` 里应该出现 OOM Killer 的判决日志（被打分的进程列表、最终被 `SIGKILL` 的受害者），系统是否恢复。

**验证目标二：用 oom_score_adj 保住指定进程**
- 起两个吃内存进程 A、B，A 比较重要。
- `echo -1000 > /proc/$(pidof A)/oom_score_adj`。
- 再造压力触发 OOM，期望看到：B 被杀、A 活着。
- 把 A 的 `oom_score_adj` 改回 0，重复一次，这次该轮到分数更高的那个被杀——验证旋钮真的有效。

## 小结

OOM Killer 是内存管理的最后防线：回收（kswapd + direct reclaim）全部失败后，内核宁杀一进程也不让全系统崩。它靠 `oom_badness()` 给每个进程算 `oom_score`（吃内存越多分越高），挑最高分那个发 `SIGKILL`，`out_of_memory → select_bad_process → oom_kill_process` 三步走完。

想保住关键进程，就往 `/proc/<pid>/oom_score_adj` 写 `-1000`，那是张免死金牌（旧接口 `oom_adj` 已废弃，别用）。下一篇回头看回收篇，就能把"分配失败 → 回收 → OOM"这条保命链路彻底串起来。

## 延伸阅读

- 源码：`mm/oom_kill.c`（Linux 6.19），OOM Killer 核心（`out_of_memory` / `select_bad_process` / `oom_kill_process` / `oom_badness`）；`include/linux/oom.h` 看相关数据结构与接口。
- kernel.org：[Memory Management guide](https://docs.kernel.org/admin-guide/mm/index.html)（稳定文档索引页，OOM 相关条目在其中）。
- 进一步（持续铺开）：页面回收与水位线（`kswapd` / direct reclaim）、swap 与 OOM 的联动、cgroup 内存控制器下的 OOM（memory cgroup OOM killer）。