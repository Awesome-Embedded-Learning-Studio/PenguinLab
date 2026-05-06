---
title: QEMU ARM 速查手册
sidebar_position: 11
---

# QEMU ARM 速查手册

本文档是 QEMU ARM 系统模拟的快速参考，配合 `scripts/qemu-run.sh` 脚本使用。

---

## 常用命令

### 查看 QEMU 支持的平台

```bash
# ARM64
qemu-system-aarch64 -M help

# ARM32
qemu-system-arm -M help
```

### 查看支持的 CPU 类型

```bash
qemu-system-aarch64 -cpu help
qemu-system-arm -cpu help
```

### 查看支持的设备

```bash
qemu-system-aarch64 -device help
```

### 直接启动 QEMU（不使用脚本）

```bash
# ARM64 virt
qemu-system-aarch64 \
  -M virt \
  -cpu cortex-a72 \
  -m 1G \
  -smp 2 \
  -kernel Image \
  -nographic \
  -serial mon:stdio

# ARM32 vexpress
qemu-system-arm \
  -M vexpress-a9 \
  -cpu cortex-a9 \
  -m 512M \
  -kernel zImage \
  -dtb vexpress-v2p-ca9.dtb \
  -nographic \
  -serial mon:stdio
```

---

## QEMU virt machine 硬件规格

### ARM64 virt

| 设备 | 类型 | 内核驱动 | 设备节点/备注 |
|------|------|----------|---------------|
| UART | PL011 | amba-pl011 | ttyAMA0 |
| RTC | PL031 | arm-pl031 | |
| 网卡 | VirtIO-net | virtio_net | |
| 存储 | VirtIO-blk | virtio_blk | |
| GPIO | VirtIO-gpio | virtio_gpio | |
| PCI | PCIe host | pcie-port | |
| 中断 | GIC v3/v4 | irq-gic-* | |
| 定时器 | ARMv8 Arch Timer | arch_timer | |

### ARM32 vexpress

| 设备 | 类型 | 内核驱动 | 设备节点 |
|------|------|----------|----------|
| UART | PL011 | amba-pl011 | ttyAMA0 |
| 以太网 | LAN9118 | smsc911x | eth0 |
| 显示 | PL111 CLCD | pl111 | fb0 |
| RTC | PL031 | pl031 | |
| 中断 | GIC | irq-gic | |

---

## 内核配置建议

### ARM64 defconfig

```bash
# 基础配置（包含 VirtIO 支持）
make ARCH=aarch64 defconfig

# 确保 CONFIG_VIRTIO=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

### ARM32 vexpress_defconfig

```bash
make ARCH=arm vexpress_defconfig
```

---

## 串口操作

### QEMU 串口快捷键

| 按键 | 功能 |
|------|------|
| `Ctrl+A, X` | 退出 QEMU |
| `Ctrl+A, C` | 切换到 QEMU monitor |
| `Ctrl+A, Z` | 查看帮助 |

### 在 QEMU monitor 中

```
(qemu) info version      # QEMU 版本
(qemu) info status       # 运行状态
(qemu) info cpus         # CPU 信息
(qemu) info mem          # 内存信息
(qemu) info qtree        # 设备树
(qemu) quit              # 退出
```

---

## 网络配置

### User-mode 网络（默认）

最简单，无需额外配置，但只能从 guest 访问 host，不能反向访问。

```bash
# 启用 user-mode 网络
QEMU_NET=on ./scripts/qemu-run.sh run

# 默认端口转发：2222 → 22
# 可在 guest 内使用 ssh 连接 host: ssh -p 2222 user@10.0.2.2
```

### TAP 网络（高级）

需要配置 TAP 设备和 bridge，可以实现完整的双向网络。

```bash
# 创建 TAP 设备（需要 root）
sudo ip tuntap add dev tap0 mode tap
sudo ip link set tap0 up

# 添加到 bridge
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip link set tap0 master br0

# 使用 TAP 网络
QEMU_NET=on QEMU_NET_TAP=on QEMU_TAP_IF=tap0 ./scripts/qemu-run.sh run
```

---

## GDB 调试

### 启动 QEMU 等待 GDB 连接

```bash
qemu-system-aarch64 -M virt -cpu cortex-a72 -kernel Image -s -S
# -s: shorthand for -gdb tcp::1234
# -S: freeze CPU at startup
```

### 连接 GDB

```bash
aarch64-linux-gnu-gdb vmlinux
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
```

### 常用 GDB 命令

```
(gdb) info registers        # 查看寄存器
(gdb) bt                    # backtrace
(gdb) thread apply all bt   # 所有线程的 backtrace
(gdb) x/10i $pc             # 查看当前指令
(gdb) disassemble           # 反汇编当前函数
```

---

## 内核启动参数

### 常用参数

| 参数 | 作用 |
|------|------|
| `console=ttyAMA0,115200` | 串口控制台 |
| `earlyprintk=serial,ttyAMA0` | 早期串口输出 |
| `root=/dev/vda` | 根设备 |
| `rootfstype=ext4` | 根文件系统类型 |
| `ro` | 只读挂载根 |
| `rw` | 读写挂载根 |
| `debug` | 启用内核调试输出 |
| `quiet` | 减少启动信息 |
| `ignore_loglevel` | 忽略日志级别限制 |

### 设置方法

```bash
# 通过环境变量
QEMU_KERNEL_CMDLINE="console=ttyAMA0 debug" ./scripts/qemu-run.sh run

# 或者修改脚本中的默认值
```

---

## 故障排查

### QEMU 启动失败

1. **检查 QEMU 是否安装**
   ```bash
   qemu-system-aarch64 --version
   qemu-system-arm --version
   ```

2. **检查内核镜像是否存在**
   ```bash
   ls -lh out/build_latest/arch/arm64/boot/Image
   ```

3. **增加调试输出**
   ```bash
   qemu-system-aarch64 -d int,cpu_reset  # 显示执行日志
   ```

### 内核启动卡住

1. **查看最后一条日志** - 确定卡在哪里
2. **检查 CONFIG_SERIAL_AMBA_PL011_CONSOLE** - 是否启用
3. **尝试更简单的 cmdline** - 去掉可能导致问题的参数

### 设备不工作

1. **查看设备树**
   ```bash
   # 在 QEMU monitor 中
   (qemu) info qtree
   ```

2. **检查内核配置**
   ```bash
   # 确保相关驱动已编译
   grep VIRTIO .config
   ```

---

## 与 Rockchip 硬件的差异

| 特性 | QEMU virt | Rockchip RK3399 | 迁移建议 |
|------|-----------|-----------------|----------|
| CPU | cortex-a72 | 2×A72 + 4×A53 | SMP 配置模拟多核 |
| 串口 | ttyAMA0 | ttyS0~4 | 修改 cmdline |
| 网卡 | virtio-net | r8169/fec | 驱动接口不同 |
| 存储 | virtio-blk | dw-mmc/SD | 需要真实硬件测试 |
| GPIO | virtio-gpio | pinctrl-gpio | 代码结构类似 |
| I2C | virtio-i2c | rk-i2c | 驱动框架相同 |
| 电源 | (无) | rk-pm | 需要真机 |

**学习建议**：
- 在 QEMU 中学习**内核框架**和**子系统**
- 在真机上测试**硬件相关**的驱动和 BSP 代码

---

## 参考资料

- [QEMU 官方文档 - System Emulation](https://www.qemu.org/docs/master/system/index.html)
- [QEMU ARM 平台文档](https://qemu-project.gitlab.io/qemu/system/arm/index.html)
- [Linux 内核 QEMU 文档](https://www.kernel.org/doc/html/latest/virt/kvm/kvm-usage.html)
- [QEMU virt machine 设备树](https://qemu-project.gitlab.io/qemu/system/arm/virt.html)
