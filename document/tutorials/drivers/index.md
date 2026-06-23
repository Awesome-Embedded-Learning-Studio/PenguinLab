---
title: 驱动开发
description: 字符设备、平台驱动、设备树、中断——主线内核驱动开发
---

# 驱动开发

> 字符设备 → 平台驱动 → 设备树 → 中断，掌握主线内核驱动开发的完整链条。

🔨 **整理中**。建议先把[通识基础](../foundations/)和[内核子系统](../kernel/)走通。

## 字符设备与中断 🔨 整理中

- 🔨 [字符设备驱动：用户态通往内核的门](./01-drv-chardev)
- 🔨 [ioctl：结构化的内核-用户命令通道](./02-drv-ioctl)
- 🔨 [poll/select：驱动怎么告诉用户“数据来了”](./03-drv-poll)
- 🔨 [mmap：把设备内存搬进用户进程](./04-drv-mmap)
- 🔨 [硬件中断：设备怎么打断 CPU](./05-drv-irq)
- 🔨 [时间与延迟：内核怎么“等”](./06-drv-clk)
- 🔨 [mutex 与 spinlock：保护临界区的两把锁](./07-drv-sync)
- 🔨 [原子操作、refcount 与内存屏障](./08-drv-atomic)
- 🔨 [RCU：读多写少的无锁魔法](./09-drv-rcu)

## 持续铺开

- **平台驱动**：probe/remove、总线-设备-驱动模型
- **设备树**：`compatible`、binding 文档、`of_*` 接口
