# Day 7 · QEMU 跑起来

**预计时长**：2 小时
**类型**：实验为主
**前置条件**：完成 Day 1–6，已成功交叉编译内核

---

## 做什么

让交叉编译的 ARM 内核在 QEMU 中完整启动，理解从 zImage/Image 到 shell 的全过程。PenguinLab 项目提供了统一的 QEMU 启动脚本和 rootfs 构建脚本，本节将综合使用它们。

结束时你应该：
- 能用一条命令启动 ARM32 / ARM64 内核
- 看懂内核启动日志的关键节点
- 能用 GDB 远程调试内核代码

---

## 要了解什么

### 1. QEMU 在嵌入式开发中的角色

QEMU 在嵌入式 Linux 开发中有三个核心价值：

- **快速验证**：无需真机即可验证内核配置和驱动修改
- **调试能力**：通过 GDB 远程调试内核代码（单步跟踪 `start_kernel`）
- **快速迭代**：从修改代码到看到结果，无需刷写固件

**局限性**：
- QEMU virt 是虚拟平台，外设为 VirtIO 通用设备，不能测试硬件特定驱动
- 无法验证真实时序和性能
- 某些子系统（如 DMA engine、特定中断控制器）行为可能不同

### 2. ARM32 vs ARM64 在 QEMU 中的差异

| 特性 | ARM32 (vexpress-a9) | ARM64 (virt) |
|------|---------------------|--------------|
| 内核镜像 | zImage（压缩） | Image（未压缩） |
| DTB | 需要 `-dtb` 参数 | QEMU 自动生成（可选） |
| 串口 | ttyAMA0 (PL011) | ttyAMA0 (PL011) |
| defconfig | vexpress_defconfig | defconfig |
| 推荐用途 | imx6ull 开发对照 | 通用 ARM64 开发/学习 |

### 3. 最小 rootfs 的构成

一个能让内核启动到 shell 的最小 initramfs 需要：
- **BusyBox**：提供 sh、ls、cat 等基本命令
- **/init 脚本**：内核启动后第一个执行的用户态程序
- **挂载点**：/proc、/sys、/dev

PenguinLab 的 `scripts/rootfs-minimal-maker.sh` 自动完成 BusyBox 交叉编译和 rootfs 打包。

### 4. QEMU virt machine 与真实硬件对比

| 特性 | QEMU virt | Rockchip RK3399 | 说明 |
|------|-----------|-----------------|------|
| CPU | cortex-a72 | 2×A72 + 4×A53 | 可模拟 A72 大核 |
| 串口 | ttyAMA0 (PL011) | ttyS2 (UART2) | 设备节点不同 |
| 网络 | virtio-net | r8169/fec | VirtIO 通用驱动 |
| 存储 | virtio-blk | dw-mmc/EMMC | 虚拟块设备 |
| GPIO | virtio-gpio | rk gpio | 驱动接口不同 |

**关键区别**：
- virt machine 是**虚拟平台**，外设都是 VirtIO 通用设备
- 真实开发板有**专用外设**（GPU、NPU、专用 GPIO 控制器）
- 内核启动到**shell 阶段**之前，流程基本一致
- 适合学习**核心子系统**（调度器、内存管理、驱动框架），不适合 BSP 特定代码

---

## 练习

### 练习 1：编译 ARM64 内核 + rootfs

```bash
# 1. 配置并编译 ARM64 内核
ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- \
  LINUX_DEFCONFIG=defconfig \
  ./scripts/linux-action-scripts.sh config_and_build

# 2. 编译 BusyBox 并制作最小 rootfs
ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- \
  ./scripts/rootfs-minimal-maker.sh

# 3. 验证产物
ls out/build_latest_arm64/arch/arm64/boot/Image
ls out/rootfs_arm64/
```

> **说明**：`linux-action-scripts.sh` 会将 `aarch64` 映射为内核的 `arm64` 架构，构建输出到 `out/build_latest_arm64/`。

### 练习 2：一键启动 QEMU

```bash
# 启动 ARM64 virt（默认配置）
./scripts/qemu-run.sh run
```

成功的话，你会看到内核启动日志滚动，最终进入 BusyBox ash shell：

```
/ #
```

**退出 QEMU**：按 `Ctrl+A`，松开后再按 `X`

- [ ] 确认看到 `Linux version 6.19.9` 的启动日志
- [ ] 确认进入了 BusyBox shell

### 练习 3：ARM32 vexpress 启动

```bash
# 1. 编译 ARM32 内核（vexpress）
LINUX_DEFCONFIG=vexpress_defconfig \
  ./scripts/linux-action-scripts.sh config_and_build

# 2. 编译 ARM32 rootfs
./scripts/rootfs-minimal-maker.sh

# 3. 启动 vexpress-a9
QEMU_ARCH=arm QEMU_MACHINE=vexpress-a9 ./scripts/qemu-run.sh run
```

- [ ] 对比 ARM32 和 ARM64 的启动日志差异
- [ ] 注意 ARM32 需要 DTB 文件，ARM64 virt 不需要手动指定

### 练习 4：理解启动日志

在 QEMU shell 中执行：

```bash
# 查看 boot 日志
dmesg | head -50
```

找到这些关键节点：

| 日志关键字 | 含义 |
|------------|------|
| `Linux version 6.19.9` | 内核版本和编译信息 |
| `Memory: ... available` | 物理内存初始化完成 |
| `CPU: ...` | CPU 检测和特性 |
| `clk: ...` | 时钟子系统初始化 |
| `NET: Registered PF_INET` | 网络协议栈注册 |
| `VFS: Mounted rootfs` | 根文件系统挂载 |
| `Freeing unused kernel memory` | 释放 init 段内存（内核初始化结束） |

- [ ] 记录内核从启动到 shell 的秒数（看日志时间戳）
- [ ] 找到 `start_kernel` 是在哪一行打印的
- [ ] 找到 init 进程启动的日志行（搜索 `Run /init` 或 `Starting init`）

### 练习 5：自定义内核启动参数

```bash
# 开启全部调试输出
QEMU_KERNEL_CMDLINE="console=ttyAMA0,115200 debug ignore_loglevel" \
  ./scripts/qemu-run.sh run

# 安静模式（只看关键信息）
QEMU_KERNEL_CMDLINE="console=ttyAMA0 quiet" ./scripts/qemu-run.sh run

# 最大调试（含早期启动信息）
QEMU_KERNEL_CMDLINE="console=ttyAMA0,115200 earlyprintk=serial,ttyAMA0 debug loglevel=10" \
  ./scripts/qemu-run.sh run
```

- [ ] 用 `quiet` 模式启动，对比正常模式的日志行数

### 练习 6：网络与 QEMU 交互

```bash
# 启用 user-mode 网络（端口转发 2222→22）
QEMU_NET=on ./scripts/qemu-run.sh run

# 在 QEMU shell 中配置网络：
ifconfig eth0 10.0.2.15
ping -c 3 10.0.2.2   # ping QEMU 虚拟网关（即 host）
```

> **user-mode 网络**：QEMU 内置的 SLIRP 网络栈，无需 root 权限，不需要 TAP/bridge 配置。适合开发调试，性能较低。

### 练习 7：GDB 远程调试内核（高级）

```bash
# 终端 1：启动 QEMU，等待 GDB 连接（-s 监听 1234 端口，-S 启动时暂停）
QEMU_EXTRA_OPTS="-s -S" ./scripts/qemu-run.sh run

# 终端 2：启动 GDB
aarch64-linux-gnu-gdb third_party/linux/vmlinux
```

GDB 命令：

```gdb
(gdb) target remote :1234          # 连接 QEMU
(gdb) break start_kernel           # 在 start_kernel 设断点
(gdb) continue                     # 继续执行，会在 start_kernel 停下
(gdb) bt                           # 查看调用栈
(gdb) list                         # 查看源码
(gdb) next                         # 单步（不进入函数）
(gdb) step                         # 单步（进入函数）
(gdb) print init_task              # 查看内核变量
```

- [ ] 在 `start_kernel` 设置断点，查看完整调用栈
- [ ] 单步执行到 `setup_arch`，观察架构初始化流程
- [ ] 尝试在 `rest_init` 设断点（这是内核初始化的最后阶段）

> **提示**：如果 `vmlinux` 不在 `third_party/linux/` 下，检查构建输出目录 `out/build_latest_arm64/vmlinux`。

### 练习 8：QEMU monitor 命令

在 QEMU 运行时按 `Ctrl+A`，松开后按 `C`，进入 QEMU monitor：

```
(qemu) info version       # QEMU 版本
(qemu) info status        # 虚拟机状态
(qemu) info cpus          # CPU 信息
(qemu) info mem           # 内存映射
(qemu) info qtree         # 设备树
(qemu) info qdm           # 设备模型列表
(qemu) quit               # 退出
```

从 monitor 回到 guest shell：再按 `Ctrl+A`，松开后按 `C`。

- [ ] 用 `info qtree` 查看 virt machine 的设备层级

---

## 项目脚本参考

### qemu-run.sh 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `QEMU_ARCH` | aarch64 | 架构：`arm` 或 `aarch64` |
| `QEMU_MACHINE` | virt | 机器类型：`virt`、`vexpress-a9` |
| `QEMU_CPU` | cortex-a72 | CPU 型号 |
| `QEMU_MEMORY` | 1G | 内存大小 |
| `QEMU_SMP` | 2 | CPU 核数 |
| `QEMU_NET` | off | 网络：`on` 或 `off` |
| `KERNEL_IMAGE` | 自动检测 | 内核镜像路径 |
| `DTB_FILE` | 自动检测 | 设备树文件（ARM32 需要） |
| `ROOTFS` | 自动检测 | initramfs 路径 |
| `QEMU_KERNEL_CMDLINE` | `console=ttyAMA0,...` | 内核启动参数 |
| `QEMU_EXTRA_OPTS` | 无 | 额外 QEMU 参数（如 `-s -S`） |

### 常用启动组合速查

```bash
# ARM64 默认（推荐）
./scripts/qemu-run.sh run

# ARM64 4核 2G 内存
QEMU_MEMORY=2G QEMU_SMP=4 ./scripts/qemu-run.sh run

# ARM32 vexpress
QEMU_ARCH=arm QEMU_MACHINE=vexpress-a9 ./scripts/qemu-run.sh run

# 带网络 + GDB 调试
QEMU_NET=on QEMU_EXTRA_OPTS="-s -S" ./scripts/qemu-run.sh run
```

### 其他 QEMU 命令

```bash
# 查看所有支持的 machine 类型
qemu-system-aarch64 -M help

# 查看支持的 CPU 类型
qemu-system-aarch64 -cpu help

# 查看所有支持的设备
qemu-system-aarch64 -device help
```

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| QEMU 速查手册 | [`document/qemu-reference.md`](../document/qemu-reference.md) | 完整的 QEMU 命令、网络、GDB 参考 |
| QEMU 官方文档 | https://www.qemu.org/docs/master/system/target-arm.html | ARM 系统模拟官方文档 |
| 内核文档 | `Documentation/admin-guide/kernel-parameters.rst` | 全部内核启动参数参考 |
| 《Linux 内核设计与实现》Robert Love | 第 16 章 | 内核调试技术 |
