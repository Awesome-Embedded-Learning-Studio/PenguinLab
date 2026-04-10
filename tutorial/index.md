# 欢迎来到 PenguinLab

> 30 天嵌入式 Linux 内核学习计划 — 从 QEMU 到真机，从内核解剖到驱动开发

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

- [Day 1-2: 环境搭建与源码树导览](part1/01_环境搭建与源码树导览.md)
- [Day 3-4: Kconfig与Kbuild](part1/02_Kconfig与Kbuild.md)
- [Day 5-6: 内核核心数据结构](part1/03_内核核心数据结构.md)
- [Day 7: QEMU启动实践](part1/04_QEMU启动实践.md)

### Week 2-4: 学习计划

- [Day 8-9: 内核模块基础设计](学习计划/week2/day08-09_内核模块基础设计.md)
- [Day 10-11: 字符设备驱动](学习计划/week2/day10-11_字符设备驱动.md)
- [Day 12-14: Platform Driver与sysfs](学习计划/week2/day12-14_Platform_Driver与sysfs.md)
- [Week 3: DTS, 中断, Clock, 真机](学习计划/week3/week3_DTS_中断_Clock_真机.md)
- [Week 4: BSP, 调优, 综合项目](学习计划/week4/week4_BSP_调优_综合项目.md)

---

## 参考文档

- [推荐书单](参考文档/booklist.md)
- [QEMU ARM 速查手册](参考文档/qemu-reference.md)

---

## 示例代码

- [示例总览](示例代码/README.md)
- [内核数据结构（用户态实现）](示例代码/kernel_base_ds/README.md)
- [内核模块基础](示例代码/kernel_module/README.md)
- [字符设备驱动](示例代码/chardev/README.md)
