---
title: Day 1-2 · 环境搭建与源码树导览
sidebar_position: 1
---

# Day 1–2 · 环境搭建与源码树导览

**预计时长**：1.5 小时 / 天，共 3 小时  
**类型**：实验为主

---

## 做什么

用 WSL2 搭建完整的 ARM 交叉编译环境，拉取 Linux 内核源码，并建立可以跳转任意函数的代码阅读能力。结束时你应该能用一条命令完成 imx6ull 的内核编译，并对源码树的每个顶层目录有基本的空间感。

---

## 要了解什么

### 1. 交叉编译工具链的命名规则

工具链前缀格式：`arch-vendor-os-abi`

- `arm-linux-gnueabihf-gcc`
  - `arm`：目标架构
  - `linux`：目标 OS
  - `gnueabihf`：GNU EABI hard-float（硬浮点，imx6ull 的 Cortex-A7 支持）
- `aarch64-linux-gnu-gcc`：用于 64 位 ARM（H618 的 Cortex-A53）

理解这个命名，以后遇到不同工具链前缀不会懵。

### 2. Linux 内核源码树顶层目录含义

| 目录 | 作用 |
|------|------|
| `arch/` | 体系结构相关代码，`arch/arm/` 是 imx6ull 所在地 |
| `drivers/` | 所有设备驱动，你以后 90% 时间在这里 |
| `kernel/` | 调度器、信号、定时器等核心机制 |
| `mm/` | 内存管理子系统 |
| `fs/` | 文件系统（ext4、proc、sysfs 等） |
| `include/` | 头文件，`include/linux/` 是内核通用接口 |
| `net/` | 网络协议栈 |
| `Documentation/` | 质量很高的官方文档，优先查这里 |
| `tools/` | perf、ftrace 等调试工具的用户态部分 |
| `scripts/` | Kbuild 辅助脚本 |

### 3. 为什么用 git submodule 管理内核源码

PenguinLab 将 Linux 内核源码作为 `third_party/linux` 的 git submodule 管理，固定在 `linux-6.19.y` 分支（当前 v6.19.9）。这样做的好处：

- **版本锁定**：所有练习基于同一个已验证的内核版本，避免版本差异导致教程不匹配
- **项目仓库轻量**：内核源码不在主仓库中，`git clone` 项目本身只需几秒
- **一键更新**：`git submodule update` 即可同步到指定版本

项目提供了 `scripts/linux-submodule.sh` 脚本来管理子模块（init / reset / status）。

### 4. clangd 为什么比 cscope 更适合内核阅读

内核大量使用宏（`container_of`、`module_init` 等），cscope 是纯文本索引，跳不进宏展开。clangd 做真正的 AST 解析，能追踪宏展开后的实际调用目标。

**生成 compile_commands.json**：
- **新内核（推荐）**：使用 `scripts/clang-tools/gen_compile_commands.py`，编译后直接运行即可
- **老内核**：使用 `bear` 拦截编译命令：`bear -- make ...`

---

## 练习

### 练习 1：安装工具链并验证

```bash
# WSL2 Ubuntu 22.04
sudo apt update
sudo apt install -y \
  gcc-arm-linux-gnueabihf \
  g++-arm-linux-gnueabihf \
  gcc-aarch64-linux-gnu \
  make bc bison flex libssl-dev libelf-dev \
  qemu-system-arm qemu-user-static \
  git wget curl python3 cpio \
  clangd

# 验证工具链
arm-linux-gnueabihf-gcc --version
# 预期输出包含 arm-linux-gnueabihf-gcc (Ubuntu ...) 11.x.x
aarch64-linux-gnu-gcc --version
clangd --version
```

### 练习 2：初始化内核源码子模块

```bash
# 从 PenguinLab 项目根目录执行
cd PenguinLab

# 初始化 Linux kernel 子模块（自动拉取 linux-6.19.y）
./scripts/linux-submodule.sh init

# 验证源码树版本
head -4 third_party/linux/Makefile
# 预期输出:
# VERSION = 6
# PATCHLEVEL = 19
# SUBLEVEL = 9

# 查看子模块状态
./scripts/linux-submodule.sh status
```

> **网络不好？** 如果 `git.kernel.org` 速度太慢，可以手动设置镜像：
> ```bash
> cd third_party/linux
> git remote set-url origin https://gitee.com/mirrors/linux_stable.git
> git fetch origin linux-6.19.y
> git checkout origin/linux-6.19.y
> ```

### 练习 3：生成 imx6ull defconfig 并浏览 menuconfig

```bash
# 使用项目脚本（推荐）
LINUX_DEFCONFIG=imx_v6_v7_defconfig \
  ./scripts/linux-action-scripts.sh config

# 或手动执行等效命令
cd third_party/linux
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- imx_v6_v7_defconfig

# 打开图形化配置菜单（需要 libncurses-dev）
sudo apt install -y libncurses-dev
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- menuconfig
```

**在 menuconfig 中做以下探索（不修改，只看）：**
- 进入 `General setup` → 看 `CONFIG_LOCALVERSION`
- 进入 `Device Drivers` → 感受驱动的分类层级
- 进入 `Kernel hacking` → 找到 `ftrace` 和 `kprobes` 选项

按 `?` 可以查看每个选项的帮助说明，按 `/` 可以搜索。

### 练习 4：完整编译一次内核

```bash
# 使用项目脚本（推荐，自动检测 CPU 核数）
./scripts/linux-action-scripts.sh build

# 或手动执行等效命令
cd third_party/linux
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) zImage dtbs modules

# 编译成功后确认产物存在
ls -lh out/build_latest_arm/arch/arm/boot/zImage
ls out/build_latest_arm/arch/arm/boot/dts/nxp/imx/imx6ull*.dtb
```

编译时间：WSL2 8 核约 5–10 分钟。观察编译输出，注意 `CC`（编译）、`LD`（链接）、`DTC`（编译设备树）的区别。

> **说明**：脚本将构建产物输出到 `out/build_latest_arm/`，保持内核源码树干净。DTB 文件在 6.19 内核中遵循厂商子目录结构（`nxp/imx/`）。

### 练习 5：搭建代码阅读环境（clangd）

PenguinLab 已配置好 `.clangd` 文件，自动过滤不兼容的 ARM 编译器标志。你只需生成 `compile_commands.json`。

**方法一：使用内核自带的 gen_compile_commands.py（推荐）**

```bash
# 先完成一次编译（生成 .cmd 文件）—— 如果练习 4 已完成可跳过
./scripts/linux-action-scripts.sh build

# 使用内核脚本生成 compile_commands.json
cd third_party/linux
python3 scripts/clang-tools/gen_compile_commands.py
cd ../..

# 在 VSCode 中打开项目（WSL 扩展 + clangd 扩展）
code .
```

**方法二：使用 bear（备用方案）**

```bash
sudo apt install -y bear
cd third_party/linux
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- clean
bear -- make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) zImage
cd ../..
```

**验证 clangd 工作**：在 VSCode 中打开 `third_party/linux/drivers/leds/leds-gpio.c`，把鼠标悬停在 `platform_driver_register` 上，能跳转到定义则成功。

### 练习 6：源码树探索任务

完成以下探索，每项写一句话的理解记录：

- [ ] 找到 imx6ull 的顶层 DTS 文件位置（提示：`arch/arm/boot/dts/nxp/imx/`）
- [ ] 找到 `container_of` 宏的定义（提示：`include/linux/container_of.h`）
- [ ] 找到 `module_init` 宏展开路径（提示：`include/linux/module.h`）
- [ ] 在 `drivers/gpio/` 下找一个最简单的 GPIO 驱动（看行数最少的那个）
- [ ] 查看 `Documentation/driver-api/` 下有哪些子系统文档

### 练习 7：QEMU 启动预览

编译好的内核可以在 QEMU 中运行验证。QEMU 的详细使用将在 Day 7 专门讲解，这里先快速验证 ARM64 编译结果：

```bash
# 编译 ARM64 内核
ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- \
  LINUX_DEFCONFIG=defconfig \
  ./scripts/linux-action-scripts.sh config_and_build

# 快速启动验证
./scripts/qemu-run.sh run
```

如果看到内核启动日志输出，说明环境搭建成功！

详细用法（ARM32/ARM64、rootfs 构建、GDB 调试、启动参数）见 [Day 7: QEMU 启动实践](/part1/day07-qemu)。

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| 《Linux 内核设计与实现》Robert Love 著，陈莉君译 | 第 1–2 章 | 内核简介与起步，快速建立全局观 |
| *Linux Kernel Development*, 3rd Ed. (Robert Love) | Ch.1–2 | 英文原版，豆瓣评分 9.1 |
| 《深入 Linux 内核架构》Wolfgang Mauerer 著 | 第 1 章 | 比 LKD 更厚重，适合作参考书 |
| 内核官方文档 | `Documentation/kbuild/llvm.rst` | clangd + 内核的官方说明 |
| kernel.org 交叉编译指南 | https://www.kernel.org/doc/html/latest/kbuild/index.html | Kbuild 完整文档 |