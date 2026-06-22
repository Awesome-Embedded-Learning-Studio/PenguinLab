---
title: 内核子系统
description: 调度器、内存管理、文件系统、网络栈——内核核心原理
maturity: drafting
---

# 内核子系统

> 深入内核核心原理：调度器、内存管理、文件系统、网络栈。🔨 调度器演进系列整理中，其余持续铺开。

## 调度器 🔨 整理中

- 🔨 [演进（一）：O(1) 调度器——从遍历到位图的跨越](./sched/sched-evolution-01-o1)
- 🔨 [演进（二）：SD/RSDL 风波——一位麻醉医生挑战内核权威](./sched/sched-evolution-02-sd-rsdl)
- 🔨 [演进（三）：CFS 诞生——62 小时重写调度器](./sched/sched-evolution-03-cfs)
- 🔨 [演进（四）：EEVDF——从虚拟公平到虚拟截止时间](./sched/sched-evolution-04-eevdf)
- 🔨 [演进（五）：sched_ext——BPF 可编程调度器的争议之路](./sched/sched-evolution-05-sched-ext)

## 内存管理 🔨 整理中

- 🔨 [伙伴系统：内核怎么管物理页](./mm/mm-buddy)

Slab/Slub、vmalloc、页面回收、OOM 持续铺开。

## 文件系统 📚 规划中

VFS、Ext4、页缓存、写时复制。

## 网络栈 📚 规划中

socket 层、TCP/IP 协议栈、Netfilter、XDP。
