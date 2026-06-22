---
title: 虚拟化与容器
description: KVM、Namespaces、cgroups——虚拟化和容器的内核基础
---

# 虚拟化与容器

> KVM、Namespaces、cgroups——理解虚拟化和容器背后的内核机制。

📚 **规划中**，还没开写。本站用 QEMU 跑内核，天然适合讲 KVM；容器部分会从 namespace + cgroup 的内核原语讲起。

## 计划

- **KVM**：虚拟化扩展、vCPU、影子页表/EPT
- **Namespaces**：pid/net/mnt/uts/ipc/user
- **cgroups**：v1 vs v2、CPU/内存/IO 子系统
- **容器运行时**：runc、OCI 规范与内核的接口
