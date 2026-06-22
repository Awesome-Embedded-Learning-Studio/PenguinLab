---
title: 调试与性能
description: printk、ftrace、perf、eBPF——内核调试与性能分析全栈
---

# 调试与性能

> printk → ftrace → perf → eBPF，内核调试和性能分析全栈。

📚 **规划中**，还没开写。通识基础里的 [GDB + QEMU 调试](../foundations/06-gdb-debug-setup)已经打底，这里会往运行时调试和性能分析展开。

## 计划

- **printk 与日志**：日志级别、`log_buf`、动态调试
- **ftrace**：tracepoint、function tracer、事件触发
- **perf**：采样、火焰图、cache 分析
- **eBPF**：bcc/bpftrace、内核可观测性
