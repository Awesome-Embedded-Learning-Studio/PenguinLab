# 05-irq — 上半部 + 线程化中断 + workqueue 下半部

> 配套教程：[硬件中断：设备怎么打断 CPU](../../../document/tutorials/drivers/05-drv-irq.md)
> 对应进度节点：`drv-irq`（layer-2）
> 前置示例：[01-chardev_basic](../01-chardev_basic/)

## ⚠️ 这个示例和 01-04 不同

01-04 是 misc 软设备，`insmod` 就能玩。**本例是 platform driver，需要一个真实中断源**——`insmod` 只注册驱动、不会调 `probe`、不会注册 IRQ。要真正触发中断，必须：

1. 设备树里有一个 `compatible = "penguinlab,irq-demo"` 的节点，带 `interrupts` 属性
2. QEMU 上配一个能拉中断线的虚拟设备（virtio-gpio / 自定义 platform 设备），或用 `irq_inject_interrupt()`（需 `CONFIG_GENERIC_IRQ_DEBUGFS`）注入

所以本 example 的定位是：**把中断驱动的 API 骨架和编译验证做实**，完整亲测待设备树/QEMU 设备就绪。

## 这个示例演示什么

- `devm_request_threaded_irq`：一次注册**上半部 + 线程化下半部**
- **上半部 `irq_hardirq`**：中断上下文（`in_irq()` 为真），绝不能睡，只计数 + `schedule_work` + 返回 `IRQ_WAKE_THREAD`
- **线程化 `irq_thread_fn`**：进程上下文（`in_task()` 为真），能 `msleep(10)` 不 panic——线程化中断的铁证
- **workqueue 下半部**：另一种"可睡的下半部"姿势，与线程化中断对比
- `IRQF_ONESHOT`：hardirq 跑完保持屏蔽直到 `thread_fn` 跑完（电平触发防风暴必备）

## 文件

| 文件 | 说明 |
|------|------|
| `irq.c` | platform driver：`probe` 里 `platform_get_irq` + `devm_request_threaded_irq`，上半部/线程化/workqueue 三段 |
| `Makefile` | `obj-m += irq.o`（无用户态程序，靠 `/proc/interrupts` + `dmesg` 验证） |

## 编译

```bash
cd example/mini/05-irq
make             # irq.ko（默认 arm64）
```

## 亲测前提（设备树片段示例）

在 QEMU 的设备树里加一个虚拟设备节点（需配合 qemu-run.sh 的设备树/虚拟设备配置）：

```dts
irq_demo: irq-demo@0 {
    compatible = "penguinlab,irq-demo";
    interrupt-parent = <&gic>;      /* 或对应中断控制器 */
    interrupts = <GIC_SPI N IRQ_TYPE_EDGE_RISING>;   /* 一个空闲的 SPI 号 */
};
```

配好后：

```bash
insmod irq.ko              # probe 被调用, 注册 IRQ, dmesg 见 "registered irq N"
# 触发中断(方式取决于虚拟设备: GPIO 翻转 / irq_inject / 真实外设)
cat /proc/interrupts | grep irq-demo    # 中断计数 +1
dmesg | tail              # 依次见 hardirq -> wake thread -> thread_fn -> bottom half
rmmod irq
```

> dmesg 预期顺序：`hardirq (in_irq=1) ...` → `thread_fn ran (in_task=1) ...`（msleep 不 panic）→ `bottom half (workqueue) in_task=1`。
> 预期输出待真机/QEMU 设备就绪后回填到教程 05-drv-irq.md。
