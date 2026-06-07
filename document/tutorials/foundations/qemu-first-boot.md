---
title: "QEMU 首次启动与 boot log 解读"
prerequisites:
  - busybox-rootfs
next:
  - gdb-debug-setup
difficulty: beginner
tags: [qemu, boot, arm64, virt, bootlog]
architectures: [arm64]
kernel_version: "6.19"
---

## 做什么

这篇是整个环境搭建流程的高潮——我们终于要把编译好的内核和构建好的 rootfs 跑起来了。我们会用 QEMU 的 `virt` 机器型号启动 ARM64 内核，然后逐段解读启动日志里的每一行输出到底在说什么。理解 boot log 是内核学习的核心能力之一，因为后续调试驱动、排查问题时你面对的第一手信息就是这些日志。

## 要了解什么

### QEMU virt 机器型号

QEMU 支持 ARM/ARM64 平台上的多种机器型号，从模拟真实开发板（比如 Raspberry Pi、Versatile Express）到纯虚拟机器。我们使用 `virt` 型号，这是 QEMU 推荐用于 ARM64 内核开发的虚拟平台。`virt` 不模拟任何真实的物理 SoC，而是提供一组干净的 VirtIO 设备——通用的虚拟化设备接口，性能好、代码干净、没有历史包袱。

用 `qemu-system-aarch64 -M help` 可以看到 QEMU 支持的所有 ARM64 机器型号，列表很长，从各种 BMC 开发板到 Xilinx Zynq 都有，但我们只关心 `virt`。

### 启动命令

项目提供了 [qemu-run.sh](scripts/qemu-run.sh) 脚本来简化 QEMU 的启动参数，它自动检测编译输出目录里的内核镜像和 rootfs 文件。运行方式很简单：

```bash
./scripts/qemu-run.sh run
```

脚本在启动时会打印检测到的配置信息，让你确认它找到了正确的文件：

```
[INFO] === QEMU ARM System Emulation ===
[INFO] Architecture:     aarch64
[INFO] Machine:          virt
[INFO] CPU:              cortex-a72
[INFO] Memory:           1G
[INFO] SMP:              2
[INFO] Detected QEMU binary: qemu-system-aarch64
[INFO] Auto-detected kernel: .../out/build_latest_arm64/arch/arm64/boot/Image
[INFO] Auto-detected initrd: .../out/build_latest_arm64/rootfs.cpio.gz
```

内核是 `Image`（上一篇编译出来的 ARM64 启动镜像），initrd 是 `rootfs.cpio.gz`（上上篇打包好的 BusyBox 根文件系统），DTB 不需要指定——QEMU virt 机器会自动生成设备树并传给内核。

启动后在 QEMU 的串口终端里按 `Ctrl+A, X` 可以退出。

### Boot Log 逐段解读

内核启动日志是一份时间线，每一行开头的时间戳 `[0.000000]` 表示从内核启动开始经过的秒数。我们来逐段拆解我们实际启动时的输出，理解内核启动的各个阶段。

**阶段一：内核解压与平台初始化（0.000000 - 0.010000）**

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd083]
[    0.000000] Linux version 6.19.9 (charliechen@Charliechen) (aarch64-linux-gnu-gcc (GCC) 15.2.0, GNU ld (GNU Binutils) 2.46.0) #1 SMP PREEMPT Sat May  9 13:22:23 CST 2026
```

第一行告诉我们内核在 CPU 0 上启动，`0x410fd083` 是 CPU 的 MIDR（Main ID Register）值，QEMU 模拟的 cortex-a72 对应这个 ID。第二行是经典的内核版本字符串，包含了编译者、编译器版本、链接器版本、SMP/PREEMPT 标志和编译时间。这些信息看起来像是炫耀，但在排查问题时非常重要——你得确认跑的确实是你编译的那个内核，而不是系统自带的某个版本。

```
[    0.000000] Machine model: linux,dummy-virt
[    0.000000] efi: UEFI not found.
```

`linux,dummy-virt` 是 QEMU virt 机器在设备树里的 `model` 属性值。UEFI not found 是正常的——我们没有配 UEFI 固件，内核直接从 boot loader 跳入启动，走的是传统的 device tree 启动路径。

```
[    0.000000] Kernel command line: console=ttyAMA0,115200 root=/dev/ram0 rdinit=/init
```

这是传给内核的启动参数。`console=ttyAMA0,115200` 指定串口控制台设备为 PL011 UART，波特率 115200；`root=/dev/ram0` 告诉内核根文件系统在内存盘（RAM disk）上；`rdinit=/init` 指定 initramfs 里内核首先执行的用户态程序。

**阶段二：内存与 CPU 初始化（0.000000 - 0.070000）**

```
[    0.000000] Zone ranges:
[    0.000000]   DMA      [mem 0x0000000040000000-0x000000007fffffff]
[    0.000000]   DMA32    empty
[    0.000000]   Normal   empty
```

内核把物理内存划分成不同的 zone。ARM64 的 1GB 内核全部落在 DMA zone（0x40000000-0x7FFFFFFF），因为我们的 QEMU 配了 1GB 内存，起始地址从 0x40000000 开始（virt 机器的 DRAM 基址）。DMA32 和 Normal zone 为空，因为 1GB 的地址范围不需要更高端的 zone。

```
[    0.065793] Detected PIPT I-cache on CPU1
[    0.066669] CPU1: Booted secondary processor 0x0000000001 [0x410fd083]
[    0.070450] smp: Brought up 1 node, 2 CPUs
```

SMP（Symmetric Multiprocessing）子系统把第二个 CPU 核启动起来了。CPU0 是主核（boot CPU），在内核启动的最早期就开始工作；CPU1 是从核（secondary CPU），稍后被 SMP 框架唤醒。两个核都识别为 cortex-a72。

**阶段三：内核子系统初始化（0.070000 - 0.500000）**

这一段日志最长，内核的各个子系统按固定顺序初始化——内存管理、调度器、定时器、中断控制器、时钟、设备模型、网络协议栈等等。每一个 "Registered" 或 "initialized" 都代表一个子系统完成了初始化。

几个值得关注的行：

```
[    0.221730] Serial: AMBA PL011 UART driver
[    0.270233] 9000000.pl011: ttyAMA0 at MMIO 0x9000000 (irq = 13, base_baud = 0) is a PL011 rev1
[    0.273819] printk: console [ttyAMA0] enabled
```

PL011 串口驱动初始化，注册了 `ttyAMA0` 设备。MMIO 地址 `0x9000000` 是 QEMU virt 机器为 PL011 UART 分配的物理地址。从这一刻开始，`printk` 的输出才会真正出现在我们的终端上——在此之前你看到的日志其实是内核先存在 log buffer 里，等串口驱动就绪后才一起刷出来的。

**阶段四：initramfs 解压与用户态启动（0.420000 - 0.990000）**

```
[    0.428951] Unpacking initramfs...
```

内核开始解压我们的 cpio.gz initramfs。它会用 gzip 算法解压，然后按 cpio newc 格式解析文件列表，把每个文件创建到 rootfs 中。

```
[    0.987816] Freeing unused kernel memory: 3264K
[    0.989078] Run /init as init process
```

`Freeing unused kernel memory` 是内核释放 `__init` 段的内存——这些代码只在启动阶段运行一次（比如各种 `__init` 函数），启动完成后就不再需要了，内核把这块内存回收给系统使用。然后内核执行 `/init`，控制权从内核态转到用户态。

```
=== PenguinLab Initramfs ===
Kernel: 6.19.9
Console: /dev/console

Starting shell...

/bin/sh: can't access tty; job control turned off
~ #
```

这是我们的 `/init` 脚本的输出。最后那个 `can't access tty; job control turned off` 不是致命错误——BusyBox 的 shell 在没有真正的 TTY 设备时会关闭 job control（Ctrl+Z、`fg`/`bg` 等），但基本的命令执行不受影响。

到这里，从 QEMU 加载内核镜像到进入 BusyBox shell，总共用了不到 1 秒。这个速度得益于我们精简的 mini config——没有多余的驱动初始化、没有等待硬件探测超时，整个启动链条干净利落。

## 动手试试

1. 运行 `./scripts/qemu-run.sh run`，等待进入 BusyBox shell
2. 在 shell 里运行 `uname -a`，确认内核版本是 6.19.9，架构是 aarch64
3. 运行 `cat /proc/cpuinfo`，看看 QEMU 报告的 CPU 信息
4. 运行 `cat /proc/meminfo`，看看内核报告的内存使用情况
5. 运行 `ls /sys/` 和 `ls /dev/`，确认 sysfs 和 devtmpfs 已正确挂载
6. 按 `Ctrl+A, X` 退出 QEMU

## 延伸阅读

- scripts/qemu-run.sh — 项目的 QEMU 启动脚本，`cmd_run()` 函数展示了完整的启动参数配置
- [QEMU ARM 系统模拟器文档](https://www.qemu.org/docs/master/system/target-arm.html) — QEMU 官方的 ARM/ARM64 仿真参考
- [Speeding up kernel development with QEMU](https://lwn.net/Articles/660404/) — LWN 经典文章，为什么 QEMU 是内核开发的最佳搭档
