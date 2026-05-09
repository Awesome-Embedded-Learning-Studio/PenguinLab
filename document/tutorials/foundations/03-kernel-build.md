---
title: "编译你的第一个 ARM64 内核"
slug: kernel-build
prerequisites:
  - kernel-mini-config
next:
  - busybox-rootfs
difficulty: beginner
tags: [kernel-build, arm64, kbuild, make]
architectures: [arm64]
kernel_version: "6.19"
---

## 做什么

这篇我们就干一件事——把上一份精心配置的 mini config 编译成一颗能跑的 ARM64 内核。编译本身只是一行 make 命令，但内核构建系统的输出信息非常丰富，值得花时间理解一下每行输出到底在说什么。完成之后我们会得到一个 `Image` 文件——这就是 ARM64 的内核启动镜像，后续 QEMU 会加载它来启动系统。

## 要了解什么

### 发起编译

确认你已经完成了上一篇的三步配置流程，`out/build_latest_arm64/.config` 存在且内容正确。然后在 `third_party/linux/` 目录下执行：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 -j$(nproc)
```

`-j$(nproc)` 会自动使用所有可用的 CPU 核心进行并行编译。我们的 14 线程机器上，一次 mini config 编译大约 3-5 分钟；如果用 `defconfig` 的 952 项配置，时间会翻倍甚至更多。

编译过程中你会看到大量输出在终端里飞速滚动，每一行前面都有一个短标签。如果你觉得这些标签像天书，完全没关系——因为接下来我们就来拆解它们。

### 编译输出标签速查

内核构建系统为每种操作定义了一个缩写标签，由 `scripts/Makefile.*` 里的 `quiet_cmd_*` 变量控制。默认模式下（不加 `V=` 参数），make 只显示这些缩写而不是完整的命令行，目的是让输出更紧凑可读。

首先是最核心的编译类标签。**CC** 是你见到最多的，代表 C 编译器把 `.c` 源文件编译成 `.o` 目标文件；如果后面跟着 `[M]`，说明这个文件被编译为可加载模块（`.ko`）而不是内建到内核主体中。**AS** 是汇编器，处理 `.S` 汇编源文件——ARM64 的启动代码、中断处理、上下文切换等关键路径很多都是汇编写的。**LD** 是链接器，把多个 `.o` 文件链接成一个更大的目标，同样 `[M]` 表示链接的是模块。**AR** 是归档器，把一批 `.o` 文件打包成 `.a` 静态库——内核源码里每个子目录最终都会产出一个 `built-in.a`，里面包含了该目录下所有需要内建到内核的目标文件。

然后是宿主机工具类。**HOSTCC** 和 **HOSTLD** 分别编译和链接运行在宿主机（我们的 x86_64 WSL2）上的辅助工具。这些工具不是给目标板用的，而是内核构建过程本身需要的一些小工具，比如生成内核符号表、处理设备树等。你可能还会看到 **HOSTCXX**，那是编译 C++ 宿主机工具（比如 KConfig 的 Qt 图形界面配置工具）。

生成和检查类的标签也经常出现。**GEN** 表示生成各种中间文件，比如 `asm-offsets`（汇编和 C 之间的常量桥接）、`autoconf.h`（把 `.config` 转成 C 头文件）。**CHK** 和 **UPD** 是一对搭档——`CHK` 检查某个文件的内容是否需要重新生成，如果检查发现内容变了，就跟着一行 `UPD` 表示实际更新了文件。

设备树相关的标签在 ARM 平台上很常见。**DTC** 是 Device Tree Compiler，把 `.dts` 源文件编译成 `.dtb` 二进制 blob。设备树是 ARM 平台描述硬件拓扑的标准方式，QEMU virt 机器虽然会自动生成设备树，但内核内部也有一些编译时嵌入的设备树 blob。

模块相关的标签出现在编译的末尾阶段。**MODPOST** 是模块后处理，它会生成 `Module.symvers` 文件（记录所有导出符号的版本信息）并检查模块的符号依赖。**SIGN** 给模块签名（如果开启了 `CONFIG_MODULE_SIG`），**DEPMOD** 生成模块依赖关系文件 `modules.dep`。

如果你想看每个标签背后的完整命令行，只需要在 make 命令后面加 `V=1`：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 V=1 -j$(nproc)
```

这样每一步操作都会打印完整的 gcc/ld 命令，包括所有编译选项、头文件搜索路径、宏定义等。调试编译问题的时候 `V=1` 是必备的。

### 验证编译结果

编译成功后，最后一行输出应该类似：

```
LD      arch/arm64/boot/Image
```

ARM64 的内核启动镜像叫 `Image`（注意没有压缩），位于编译输出目录的 `arch/arm64/boot/` 下。我们用 `file` 命令确认它的格式：

```bash
file out/build_latest_arm64/arch/arm64/boot/Image
# Linux kernel ARM64 boot executable Image, little-endian, 4K pages
```

看到 `Linux kernel ARM64 boot executable Image` 就对了。ARM32 平台的镜像名字和格式不一样，那里叫 `zImage`（自解压压缩镜像），但原理一样——QEMU 加载这个文件然后跳进去执行。

除了 `Image` 之外，编译输出目录里还有一个重要的文件 `vmlinux`。它是未压缩的 ELF 格式内核，包含完整的符号表和调试信息，后面 GDB 调试的时候需要用到它。`Image` 是从 `vmlinux` 经过 `objcopy` 剥离了 ELF 头和调试信息之后生成的纯二进制镜像，体积更小，适合 QEMU 加载。

### 输出目录结构

我们使用 `O=` 参数把所有编译产物放到 `out/build_latest_arm64/` 目录，而不是在源码树里到处散落文件。这个目录的结构基本是源码树结构的镜像——源码树里 `kernel/sched/` 下的源文件编译后的 `.o` 产物在 `out/build_latest_arm64/kernel/sched/` 下，源码树里 `arch/arm64/boot/` 下的启动镜像在 `out/build_latest_arm64/arch/arm64/boot/` 下。这种分离的好处是源码树保持干净，切换不同架构的编译输出也不会互相污染。就像咱们自己写C/C++工程的时候，也都会用类似CMake的构建工具指定合适的构建目录处理。对不对？

## 动手试试

1. 确认上一节的配置流程已完成，`out/build_latest_arm64/.config` 存在
2. 执行编译命令，观察终端输出中的各种标签
3. 编译完成后用 `file` 命令验证 `Image` 文件的格式
4. 用 `ls -lh out/build_latest_arm64/arch/arm64/boot/Image out/build_latest_arm64/vmlinux` 对比两者的大小，理解为什么 QEMU 用 `Image` 而 GDB 用 `vmlinux`
5. 试试 `V=1` 编译（可以只编一个文件：`make O=... arch/arm64/kernel/setup.o V=1`），看看完整命令行长什么样

## 延伸阅读

- [Linux 内核构建说明](https://docs.kernel.org/admin-guide/README.html) — kernel.org 官方的编译指南
- [Kbuild 文档](https://www.kernel.org/doc/html/latest/kbuild/kbuild.html) — 构建系统的详细文档
