---
title: 嵌入式全栈
description: 交叉编译、Bootloader、Buildroot、BSP——完整嵌入式 Linux 流程
---

# 嵌入式全栈

> 交叉编译 → Bootloader → Buildroot → BSP，完整的嵌入式 Linux 开发流程。

📚 **规划中**，还没开写。本站的所有实践基于 QEMU（ARM32/ARM64/RISC-V/x86_64），嵌入式全栈会从 QEMU 虚拟平台起步，再迁移到真板。

## 计划

- **交叉编译**：工具链构建、sysroot、多架构
- **Bootloader**：U-Boot 移植与启动流程
- **Buildroot / Yocto**：整套 rootfs 自动构建
- **BSP**：板级支持包、设备树定制
