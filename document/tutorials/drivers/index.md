---
title: 驱动开发
description: 字符设备、平台驱动、设备树、中断——主线内核驱动开发
---

# 驱动开发

> 字符设备 → 平台驱动 → 设备树 → 中断，掌握主线内核驱动开发的完整链条。

📚 **规划中**，还没开写。建议先把[通识基础](../foundations/)和[内核子系统](../kernel/)走通，这块会在那之后铺开。

## 计划

- **字符设备**：`file_operations`、`ioctl`、`cdev` 生命周期
- **平台驱动**：probe/remove、总线-设备-驱动模型
- **设备树**：`compatible`、binding 文档、`of_*` 接口
- **中断**：`request_irq`、threaded IRQ、上下半部
