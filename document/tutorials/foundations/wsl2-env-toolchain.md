---
title: "WSL2 环境摸底与交叉编译工具链"
prerequisites: []
next:
  - kernel-mini-config
difficulty: beginner
tags: [wsl2, cross-compile, toolchain, arm64]
architectures: [arm64]
kernel_version: "6.19"
---

## Welcome Kernel！

这是注定一场极端漫长的路程，Linux作为一个演化了几十年的操作系统，复杂度可以堪称人类历史上软件工程的顶峰了！千里之行始于足下。我们就从这一篇文章开始我们的路途！

## 做什么

笔者是在WSL2上开始这套基于自己学习路程的部分开发的教程，所以，其他真实物理机的发行版，可能也许需要一定的修改。笔者的WSL2上跑的发行版是Arch Linux。只是用的习惯了！所以请原谅，如果你是Ubuntu/Debain系的朋友可能需要调整一下指令！

我们要在 WSL2 里搭建一套完整的 Linux 内核开发环境。具体来说，我们需要确认 WSL2 能不能胜任这项工作，然后安装交叉编译工具链，为后续编译 ARM64 内核做好准备。完成这篇之后，我们会有一个"确认可用"的开发环境，工具链就位，随时可以开始配内核、编译、跑 QEMU。

## 要了解什么

### 为什么选 WSL2

我们得先回答一个问题：为什么不直接在物理机上搞内核开发？答案很简单——我们编译出来的 ARM64 内核根本没法在 x86 宿主机上跑，它必须在一个模拟器（QEMU）里面执行。WSL2 提供了一个完整的 Linux 环境，同时又是 Windows 的一个轻量级虚拟机，这让我们既能享受 Linux 工具链的便利，又不用担心搞崩宿主系统——因为真正运行我们编译出来的内核的是 QEMU，它被完全隔离在 WSL2 之内。就算内核写炸了、驱动崩了、rootfs 搞烂了，最坏的结果不过是 QEMU 进程挂掉，宿主机纹丝不动。

### 摸清 WSL2 的能力

在动手装任何东西之前，我们先花几分钟搞清楚手上这台机器到底是什么水平。先看内核版本和基本系统信息：

```bash
uname -a
# Linux Charliechen 6.6.87.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC ... x86_64 GNU/Linux
```

注意那个 `-microsoft-standard-WSL2` 后缀——这就是 WSL2 自带的 Linux 内核，跟我们后续要编译的 ARM64 内核完全是两回事。这个内核只是我们的"宿主系统"，真正要学习和折腾的目标内核将在 QEMU 里运行。

接着看一下 CPU 和虚拟化能力：

```bash
cat /proc/cpuinfo | head -20
# processor    : 0
# model name   : AMD Ryzen 7 5800H with Radeon Graphics
# cpu cores    : 7
# ...
```

这里有一个关键检查项——`/dev/kvm` 是否存在。KVM（Kernel-based Virtual Machine）是 Linux 内核自带的虚拟化加速器，如果 WSL2 支持 KVM，QEMU 就能用硬件虚拟化大幅提升运行速度；如果不存在，QEMU 也能跑，只是纯软件模拟，会慢不少。从 Windows 11 22H2 开始，WSL2 开始支持嵌套虚拟化，`/dev/kvm` 有很大概率是存在的：

```bash
ls /dev/kvm
# /dev/kvm  ← 存在，QEMU 可以用硬件加速
```

我们这台机器的底子相当不错——AMD Ryzen 7 5800H，7 核 14 线程，KVM 可用，编译内核的并行度 (`-j14`) 完全拉得开。

再看看发行版信息，因为这直接影响包管理命令：

```bash
cat /etc/os-release
# NAME="Arch Linux"
# PRETTY_NAME="Arch Linux"
# ID=arch
# ...
```

我们用的是 Arch Linux（rolling release），包管理器是 `pacman` 而不是 `apt`。如果你用的是 Ubuntu/Debian 系的 WSL2，后面安装软件的命令会不一样，我会在对应位置标注两种写法。

### 交叉编译工具链：在 x86 上造 ARM 的轮子

接下来我们装交叉编译工具链。为什么叫"交叉"编译？因为我们的宿主机是 x86_64 架构，但目标平台是 ARM64——编译器跑在 x86 上，但它生成的机器码是给 ARM 执行的。这就像你在一个国家的工厂里生产另一个国家标准的产品，工具本身得做适配。

安装工具链本身很简单，一行命令的事：

```bash
# Arch Linux
pacman -S aarch64-linux-gnu-gcc   # ARM64 交叉编译器

# Ubuntu / Debian
sudo apt install gcc-aarch64-linux-gnu   # ARM64 交叉编译器
```

装完之后验证一下：

```bash
aarch64-linux-gnu-gcc --version
# aarch64-linux-gnu-gcc (GCC) 15.2.0
# Copyright (C) 2025 Free Software Foundation, Inc.
# ...
```

看到版本号就说明工具链就位了。现在我们来理解一下这个看起来很长的名字到底在说什么——`aarch64-linux-gnu-gcc` 的命名规则是 `<架构>-<厂商>-<操作系统>-<ABI>-<工具>`，其中 `aarch64` 是 ARM64 的官方架构名称（ARM 公司定义的），`linux` 表示目标系统是 Linux，`gnu` 表示使用 GNU C 库（glibc），最后的 `gcc` 就是我们熟悉的 C 编译器。这套命名规则在整个交叉编译工具链里是一致的，比如 `aarch64-linux-gnu-ld` 是链接器，`aarch64-linux-gnu-objdump` 是反汇编器，`aarch64-linux-gnu-gdb` 是调试器——它们共享同一个前缀。

### ARCH 和 CROSS_COMPILE：内核构建系统的两个关键变量

内核的构建系统（Kbuild）通过两个环境变量来控制交叉编译：`ARCH` 指定目标架构，`CROSS_COMPILE` 指定工具链前缀。

关于这个事情，笔者建议，Linux Documentation是任何一个学习内核的朋友要开始熟悉的。笔者很乐意从Documentation上摘抄内容，毕竟文档站的权威性总是远远大于自己找LLM胡言乱语瞎编乱造，对不对？

> URL: https://www.kernel.org/doc/html/latest/kbuild/kbuild.html

找到ARCH和CROSS_COMPILE的介绍。

```text
ARCH
Set ARCH to the architecture to be built.

In most cases the name of the architecture is the same as the directory name found in the arch/ directory.

But some architectures such as x86 and sparc have aliases.

x86: i386 for 32 bit, x86_64 for 64 bit

parisc: parisc64 for 64 bit

sparc: sparc32 for 32 bit, sparc64 for 64 bit

CROSS_COMPILE
Specify an optional fixed part of the binutils filename. CROSS_COMPILE can be a part of the filename or the full path.

CROSS_COMPILE is also used for ccache in some setups.
```

嗯？英文你看不懂？没关系。翻译软件请经常开，笔者这次帮你代劳一下：

```text
ARCH
将 ARCH 设置为要构建的架构。在大多数情况下，架构名称与 arch/ 目录中的目录名称相同。但某些架构如 x86 和 sparc 有别名。

- x86：32 位使用 i386，64 位使用 x86_64
- parisc：64 位使用 parisc64
- sparc：32 位使用 sparc32，64 位使用 sparc64

CROSS_COMPILE
- 指定 binutils 文件名的可选固定部分。CROSS_COMPILE 可以是文件名的一部分或完整路径。在某些设置中，CROSS_COMPILE 也用于 ccache。
```

这里有一个很容易踩的坑——`ARCH` 的值和工具链前缀的命名并不总是一一对应。对于 ARM64 来说，内核构建系统用的架构名是 `arm64`，但工具链前缀是 `aarch64-linux-gnu-`，两者不一样。这是历史原因造成的，ARM64 架构在内核社区一直叫 `arm64`，而工具链这边用的是 ARM 官方定义的 `aarch64` 名称。项目的 [linux-action-scripts.sh](scripts/linux-action-scripts.sh) 第 69-72 行专门做了这个映射，把用户传入的 `aarch64` 或 `arm64` 统一转成 Kbuild 认的 `arm64`。

`CROSS_COMPILE` 更有意思——它不是一个完整的命令名，而是一个前缀。内核构建系统会自动在这个前缀后面拼接 `gcc`、`ld`、`objcopy` 等后缀来找到对应的工具。也就是说，当你设置 `CROSS_COMPILE=aarch64-linux-gnu-` 时，make 会去找 `aarch64-linux-gnu-gcc`、`aarch64-linux-gnu-ld`、`aarch64-linux-gnu-objcopy` 等一系列工具。如果 `CROSS_COMPILE` 是空字符串，make 就直接用本机的 `gcc`、`ld` 等——这就是为什么忘记设这个变量的时候，内核会编译成 x86 架构的，因为这个空字符串前缀导致构建系统用了宿主机的编译器。

一个推荐的做法是把这两个变量 export 到当前 shell 里，这样后面所有 make 命令都不用重复写了：

```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
```

除了工具链之外，编译内核还需要一些辅助工具（bison、flex 等）。Ubuntu/Debian 下一行搞定：

```bash
# Ubuntu / Debian, UnAuthorized Commands，这部分我没验证
sudo apt install build-essential libncurses-dev bison flex libssl-dev libelf-dev
```

Arch Linux 用户一般这些工具已经通过 base-devel 组装好了，如果没有就 `pacman -S base-devel` 补齐。

## 动手试试

笔者是这样玩的！您也一起来试试吧！

1. 在你的 WSL2 终端里依次运行 `uname -r`、`cat /proc/version`、`ls /dev/kvm`，记录你的环境信息
2. 安装 ARM64 交叉编译器并验证 `aarch64-linux-gnu-gcc --version` 能输出版本号
3. 在终端里 export `ARCH=arm64` 和 `CROSS_COMPILE=aarch64-linux-gnu-`，然后运行 `echo $ARCH` 和 `echo $CROSS_COMPILE` 确认变量已生效
4. 如果你对 RISC-V 也感兴趣，可以顺便装 `gcc-riscv64-linux-gnu`（Arch: `pacman -S riscv64-linux-gnu-gcc`），后续的练习会支持多架构

## 延伸阅读

- [Kbuild 内核构建系统文档](https://www.kernel.org/doc/html/latest/kbuild/kbuild.html) — kernel.org 对 `ARCH`、`CROSS_COMPILE` 等变量的官方定义
- [Linux 内核构建说明](https://docs.kernel.org/admin-guide/README.html) — 内核源码根目录 README 的网页版
- [交叉编译 Debian/Ubuntu 实战](https://jensd.be/1126/linux/cross-compiling-for-arm-or-aarch64-on-debian-or-ubuntu) — Ubuntu 系环境下的交叉编译教程
