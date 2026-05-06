---
slug: /
title: 欢迎来到 PenguinLab
description: Linux 内核学习站 — 从 QEMU 到真机，从内核解剖到驱动开发
---

# 欢迎来到 PenguinLab

> Linux 内核学习站 — 从 QEMU 到真机，从内核解剖到驱动开发

---

## 学习路线

| 周次 | 主题 | 里程碑 |
|------|------|--------|
| Week 1 | 内核解剖 & 构建体系 | QEMU 跑起来交叉编译的 ARM 内核 |
| Week 2 | 内核模块 & 字符驱动 | 完整字符设备驱动 + 用户态测试程序 |
| Week 3 | DTS 深度 & 中断子系统 | 驱动在 imx6ull 真机上跑通 |
| Week 4 | BSP 实战 & 性能调优 | H618 内核定制 + I2C 综合驱动 |

---

## 教程

### Week 1: 内核解剖与构建体系

- [Day 1-2: 环境搭建与源码树导览](/part1/day01-02-setup)
- [Day 3-4: Kconfig与Kbuild](/part1/day03-04-kconfig)
- [Day 5-6: 内核核心数据结构](/part1/day05-06-data-structs)
- [Day 7: QEMU启动实践](/part1/day07-qemu)

---

## 参考文档

- [推荐书单](/booklist)
- [QEMU ARM 速查手册](/qemu-reference)

---

## 示例代码

- [示例总览](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/tree/main/example)
- [内核数据结构（用户态实现）](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/tree/main/example/kernel_base_ds)
- [内核模块基础](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/tree/main/example/kernel_module)
- [字符设备驱动](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/tree/main/example/chardev)
