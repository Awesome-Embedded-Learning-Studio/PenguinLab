---
layout: home
title: 欢迎来到 PenguinLab
description: Linux 内核学习站 — 从 QEMU 到内核原理、驱动开发与嵌入式全栈

hero:
  name: PenguinLab
  text: Linux 内核学习站
  tagline: 从 QEMU 点亮第一颗 ARM64 内核，到调度器、内存、驱动、嵌入式全栈——一篇篇锤炼，ARM32/ARM64/RISC-V/x86_64 四架构通吃。
  actions:
    - theme: brand
      text: 开始学习
      link: /tutorials/foundations/
    - theme: alt
      text: 学习路线图
      link: /roadmap/
    - theme: alt
      text: 基建速查
      link: /guides/
    - theme: alt
      text: 更新日志
      link: /changelogs/
    - theme: alt
      text: GitHub
      link: https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab

features:
  - title: 通识基础
    details: ✅ 8 篇已锤炼——从 WSL2、Mini Config、编译内核、BusyBox rootfs、QEMU 启动、GDB 调试到内核模块与 9p 迭代，一条线打通。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/></svg>'
    link: /tutorials/foundations/
    linkText: 开始阅读

  - title: 内核子系统
    details: 🔨 调度器演进（O(1)→SD/RSDL→CFS→EEVDF→sched_ext）整理中；内存管理、文件系统、网络栈持续铺开。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/></svg>'
    link: /tutorials/kernel/
    linkText: 开始阅读

  - title: 驱动开发
    details: 📚 规划中——字符设备、平台驱动、设备树、中断，主线内核驱动开发完整链条。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22v-5M9 8V2M15 8V2M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/></svg>'
    link: /tutorials/drivers/
    linkText: 敬请期待

  - title: 嵌入式全栈
    details: 📚 规划中——交叉编译、Bootloader、Buildroot、BSP，完整嵌入式 Linux 开发流程。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 12-8.373 8.373a1 1 0 1 1-3-3L12 9"/><path d="m18 15 4-4"/><path d="m21.5 11.5-1.914-1.914A2 2 0 0 1 19 8.172V7l-2.26-2.26a6 6 0 0 0-4.202-1.756L9 2.96l.92.82A6.18 6.18 0 0 1 12 8.4V10l2 2h1.172a2 2 0 0 1 1.414.586L18.5 14.5"/></svg>'
    link: /tutorials/embedded/
    linkText: 敬请期待

  - title: 调试与性能
    details: 📚 规划中——printk、ftrace、perf、eBPF，内核调试和性能分析全栈。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>'
    link: /tutorials/debugging/
    linkText: 敬请期待

  - title: 虚拟化与容器
    details: 📚 规划中——KVM、Namespaces、cgroups，虚拟化和容器背后的内核机制。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5M12 22V12"/></svg>'
    link: /tutorials/virtualization/
    linkText: 敬请期待

  - title: 基建速查
    details: ✅ 五条主线脚本串成一条流水线——内核编译、rootfs、QEMU、模块交叉编译、网站构建，产物约定和常见坑都钉死了。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>'
    link: /guides/
    linkText: 开始阅读

  - title: 更新日志
    details: 每个版本新锤炼了什么、修了什么——这站一直在出东西。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5M12 7v5l4 2"/></svg>'
    link: /changelogs/
    linkText: 查看版本

  - title: 推荐书单
    details: 内核学习路上的推荐书目，配 QEMU ARM 速查手册。
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 7v14M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z"/></svg>'
    link: /booklist
    linkText: 查看书单
---
