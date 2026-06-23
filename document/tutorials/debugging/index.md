---
title: 调试与性能
description: printk、ftrace、perf、eBPF——内核调试与性能分析全栈
---

# 调试与性能

> printk → ftrace → perf → eBPF，内核调试和性能分析全栈。

🔨 **整理中**。通识基础里的 [GDB + QEMU 调试](../foundations/06-gdb-debug-setup)打底，这里往运行时调试展开。

## 调试工具 🔨 整理中

- 🔨 [printk：内核调试的生命线](./01-debug-printk)
- 🔨 [Kprobes：在任意函数上插眼](./02-debug-kprobes)
- 🔨 [KASAN：影子内存抓内存破坏](./03-debug-kasan)
- 🔨 [SLUB 调试：红区、毒药与追踪](./04-debug-slub)
- 🔨 [Oops：内核崩溃现场解读](./05-debug-oops)
- 🔨 [ftrace：内核的瑞士军刀追踪器](./06-debug-ftrace)
- 🔨 [KCSAN：抓并发里的数据竞争](./07-debug-kcsan)
- 🔨 [panic、Hung Task 与死锁检测](./08-debug-panic)
- 🔨 [KGDB：让 GDB 停下整个内核](./09-debug-kgdb)

## 持续铺开

- **perf**：采样、火焰图、cache 分析
- **eBPF**：bcc/bpftrace、内核可观测性
- lockdep、trace-cmd、crash 工具
