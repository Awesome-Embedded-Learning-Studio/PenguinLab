---
title: QEMU 启动与调试
description: 用 qemu-run.sh 启动自编内核 + initramfs——环境变量速查、initrd/drive 两种根文件系统、网络、GDB 调试一条龙
maturity: verified
---

# QEMU 启动与调试

## 这个脚本干啥

`scripts/qemu-run.sh` 把「拼一条 QEMU 命令行」封装好了：自动探测内核镜像、initramfs、设备树，按环境变量组装机器/CPU/内存/网络/串口，支持普通启动和 GDB 调试启动。

## 最短启动

前提：内核和 rootfs 都已编好（见 [编译内核](./01-kernel-build)、[制作 rootfs](./02-rootfs)）。

```bash
scripts/qemu-run.sh run
```

它会自动从 `out/build_latest_arm64/` 找到 `Image` 和 `rootfs.cpio.gz`，启动 ARM64 virt 机器，串口直接接到当前终端。看到 `PenguinLab Initramfs` 和 shell 提示符就成了。

退出：**先按 `Ctrl+A`，松开，再按 `X`**。

## 环境变量速查

| 变量 | 默认 | 说明 |
|------|------|------|
| `QEMU_ARCH` | `aarch64` | `arm` / `aarch64` |
| `QEMU_MACHINE` | `virt` | ARM32 可选 `vexpress-a9` / `vexpress-a15` |
| `QEMU_CPU` | `cortex-a72` | ARM32 用 `cortex-a9` 等 |
| `QEMU_MEMORY` | `1G` | 内存 |
| `QEMU_SMP` | `2` | CPU 核数 |
| `QEMU_SERIAL` | `on` | 串口接 stdio |
| `QEMU_NET` | `off` | 打开网络 |
| `QEMU_NET_USER` | `on` | user 模式（端口转发） |
| `QEMU_NET_TAP` | `off` | TAP 模式 |
| `KERNEL_IMAGE` | 自动探测 | 手动指定内核镜像 |
| `INITRD` | 自动探测 | 手动指定 initramfs |
| `ROOTFS` | （无） | 块设备 rootfs（raw/ext4，走 `-drive`） |
| `QEMU_KERNEL_CMDLINE` | 见下 | 内核命令行 |
| `QEMU_EXTRA_OPTS` | （无） | 任意额外 QEMU 参数 |

默认内核命令行：

```
console=ttyAMA0,115200 root=/dev/ram0 rdinit=/init
```

## initrd 模式 vs 块设备模式

脚本对根文件系统有两种接法，**initrd 优先**：

- **initrd（默认）**：探测 `out/build_latest_<arch>/rootfs.cpio.gz`，用 `-initrd` 加载，对应 `root=/dev/ram0 rdinit=/init`。这是最小系统的常态。
- **块设备**：设 `ROOTFS=/path/to/disk.img`，用 `-drive file=...,if=virtio,format=raw` 挂成 virtio 磁盘，适合做完整分区 rootfs 实验。

两者都没设，脚本报错退出。

## 自动探测的路径

不手动指定时，内核和 initrd 都优先从构建输出目录找：

- 内核（ARM64）：`out/build_latest_arm64/arch/arm64/boot/Image`
- 内核（ARM32）：`out/build_latest_arm/arch/arm/boot/zImage`
- initrd：`out/build_latest_<arch>/rootfs.cpio.gz`
- DTB（ARM32 vexpress）：`out/build_latest_arm/arch/arm/boot/dts/vexpress-v2p-ca9.dtb`

ARM64 + virt 机器**不需要 dtb**——QEMU 会现场生成设备树。

## 网络

`QEMU_NET=on` 打开网络，两种模式可并存：

- **user 模式**（默认 `QEMU_NET_USER=on`）：QEMU 自带 NAT，并把宿主机 2222 转发到 Guest 22：

  ```
  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0
  ```

  宿主机 `ssh -p 2222 root@localhost` 就能进 Guest（前提是 rootfs 里跑了 sshd）。

- **TAP 模式**（`QEMU_NET_TAP=on`）：桥接到宿主机 `tap0`，适合需要 Guest 有独立 IP、和宿主机同网段通信的场景，需自行配好 tap 接口。

## 调试模式：GDB 一条龙

```bash
scripts/qemu-run.sh debug
```

它在普通命令基础上加了两样：

- 内核命令行插 `nokaslr`：关掉地址随机化，GDB 断点符号才对得上。
- `-s -S`：`-s` 开 GDB stub 在 **1234 端口**，`-S` 让 CPU 启动即冻结、等 GDB 接入。

宿主机另一边连上去：

```bash
aarch64-linux-gnu-gdb out/build_latest_arm64/vmlinux \
  -ex 'target remote :1234'
```

VSCode 用户配好 `launch.json`（`type=cppdbg`、`miDebuggerServerAddress=localhost:1234`）按 F5 即可。`vmlinux` 是带调试符号的未压缩内核镜像，在构建输出目录根下。

## 常见用法

```bash
# 默认 ARM64 跑
scripts/qemu-run.sh run

# ARM32 vexpress
QEMU_ARCH=arm QEMU_MACHINE=vexpress-a9 scripts/qemu-run.sh run

# 加内存和核数
QEMU_MEMORY=2G QEMU_SMP=4 scripts/qemu-run.sh run

# 开网络
QEMU_NET=on scripts/qemu-run.sh run

# 调试
scripts/qemu-run.sh debug

# 停掉跑飞的实例
scripts/qemu-run.sh stop
```

## 常见坑

- **找不到内核/initrd**：八成是没编，或 `ARCH` 和输出目录对不上（`aarch64`→`arm64`）。先确认 `out/build_latest_arm64/arch/arm64/boot/Image` 存在。
- **串口没输出**：确认 `QEMU_SERIAL=on`（默认就是），且内核命令行 `console=ttyAMA0` 匹配 virt 机器的 PL011 UART。`printk` 偶有「差一次」的延迟——信 `dmesg` buffer，别光盯屏幕。
- **退不出来**：QEMU `-nographic` 模式下，退出是 `Ctrl+A` 然后 `X`，不是 `Ctrl+C`（那只是中断 Guest）。
- **想加 9p 共享目录**：当前脚本还没内置 `-virtfs`，可以先用 `QEMU_EXTRA_OPTS` 手动挂；内核侧的 9p 支持（`CONFIG_NET_9P_VIRTIO`、`CONFIG_9P_FS`）已经是 `=y`，QEMU 那侧配好就能用。完整的 9p 配置会在后续专题展开。
