## Welcome to the Kernel!

This is going to be an extremely long journey. As an operating system that has evolved over decades, Linux's complexity stands as the pinnacle of software engineering in human history! A journey of a thousand miles begins with a single step. Let's start our journey with this article!

## What We'll Do

The author developed this tutorial based on their own learning path using WSL2. If you're using a different distribution on a real physical machine, some modifications might be necessary. The distribution running on the author's WSL2 is Arch Linux—simply out of habit! So please forgive us; if you're an Ubuntu/Debian user, you may need to adjust the commands accordingly.

We need to set up a complete Linux kernel development environment inside WSL2. Specifically, we need to confirm whether WSL2 is up to the task, then install a cross-compilation toolchain to prepare for building ARM64 kernels later. After finishing this article, we'll have a "verified working" development environment with the toolchain in place, ready to configure the kernel, compile it, and run it in QEMU at any time.

## What to Understand

### Why WSL2

We need to answer a question first: why not just do kernel development directly on a physical machine? The answer is simple—the ARM64 kernel we build can't run on an x86 host at all; it must execute inside an emulator (QEMU). WSL2 provides a complete Linux environment while acting as a lightweight virtual machine for Windows. This lets us enjoy the convenience of the Linux toolchain without worrying about breaking the host system—because what actually runs our compiled kernel is QEMU, which is completely isolated within WSL2. Even if the kernel crashes, a driver panics, or the rootfs gets corrupted, the worst-case scenario is just the QEMU process dying; the host machine remains completely unaffected.

### Assessing WSL2 Capabilities

Before installing anything, let's spend a few minutes figuring out exactly what we're working with. First, let's check the kernel version and basic system info:

```bash
uname -a
# Linux Charliechen 6.6.87.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC ... x86_64 GNU/Linux
```

Notice the `-microsoft-standard-WSL2` suffix—that's the Linux kernel bundled with WSL2, which is completely different from the ARM64 kernel we'll compile later. This kernel is just our "host system"; the actual target kernel we'll study and tinker with will run inside QEMU.

Next, let's look at the CPU and virtualization capabilities:

```bash
cat /proc/cpuinfo | head -20
# processor    : 0
# model name   : AMD Ryzen 7 5800H with Radeon Graphics
# cpu cores    : 7
# ...
```

There's a key check here—whether `/dev/kvm` exists. KVM (Kernel-based Virtual Machine) is a virtualization accelerator built into the Linux kernel. If WSL2 supports KVM, QEMU can use hardware virtualization to significantly boost execution speed; if it doesn't exist, QEMU can still run using pure software emulation, but it will be noticeably slower. Starting from Windows 11 22H2, WSL2 began supporting nested virtualization, so there's a high probability that `/dev/kvm` exists:

```bash
ls /dev/kvm
# /dev/kvm  ← 存在，QEMU 可以用硬件加速
```

Our machine has a solid foundation—an AMD Ryzen 7 5800H, 7 cores and 14 threads, KVM available, and the parallelism for kernel compilation (`-j14`) can be fully utilized.

Let's also check the distribution info, since this directly affects package management commands:

```bash
cat /etc/os-release
# NAME="Arch Linux"
# PRETTY_NAME="Arch Linux"
# ID=arch
# ...
```

We're using Arch Linux (rolling release), so the package manager is `pacman` rather than `apt`. If you're using an Ubuntu/Debian-based WSL2, the software installation commands will differ later on. I'll note both syntaxes at the relevant places.

### Cross-Compilation Toolchain: Building ARM Wheels on x86

Next, we'll install the cross-compilation toolchain. Why is it called "cross" compilation? Because our host machine is x86_64, but the target platform is ARM64—the compiler runs on x86, but the machine code it generates is for ARM execution. It's like manufacturing products to another country's standards in your own factory; the tools themselves need to be adapted.

Installing the toolchain is straightforward—just one command:

```bash
# Arch Linux
pacman -S aarch64-linux-gnu-gcc   # ARM64 交叉编译器

# Ubuntu / Debian
sudo apt install gcc-aarch64-linux-gnu   # ARM64 交叉编译器
```

After installation, let's verify it:

```bash
aarch64-linux-gnu-gcc --version
# aarch64-linux-gnu-gcc (GCC) 15.2.0
# Copyright (C) 2025 Free Software Foundation, Inc.
# ...
```

Seeing the version number means the toolchain is in place. Now let's understand what this long name actually means—the naming convention for `aarch64-linux-gnu-gcc` is `<架构>-<厂商>-<操作系统>-<ABI>-<工具>`, where `aarch64` is the official architecture name for ARM64 (defined by ARM Ltd.), `linux` indicates the target system is Linux, `gnu` means it uses the GNU C Library (glibc), and the final `gcc` is our familiar C compiler. This naming convention is consistent across the entire cross-compilation toolchain. For example, `aarch64-linux-gnu-ld` is the linker, `aarch64-linux-gnu-objdump` is the disassembler, and `aarch64-linux-gnu-gdb` is the debugger—they all share the same prefix.

### ARCH and CROSS_COMPILE: Two Key Variables in the Kernel Build System

The kernel's build system (Kbuild) controls cross-compilation through two environment variables: `ARCH` specifies the target architecture, and `CROSS_COMPILE` specifies the toolchain prefix.

On this topic, the author recommends that anyone learning the kernel should start getting familiar with the Linux Documentation. The author is happy to excerpt content from the Documentation—after all, the authority of the official documentation always far outweighs making things up by asking an LLM to ramble, right?

> URL: https://www.kernel.org/doc/html/latest/kbuild/kbuild.html

Find the introduction to ARCH and CROSS_COMPILE.

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

Can't read the English? No problem. Keep a translation tool handy—the author will do the honors this time:

```text
ARCH
将 ARCH 设置为要构建的架构。在大多数情况下，架构名称与 arch/ 目录中的目录名称相同。但某些架构如 x86 和 sparc 有别名。

- x86：32 位使用 i386，64 位使用 x86_64
- parisc：64 位使用 parisc64
- sparc：32 位使用 sparc32，64 位使用 sparc64

CROSS_COMPILE
- 指定 binutils 文件名的可选固定部分。CROSS_COMPILE 可以是文件名的一部分或完整路径。在某些设置中，CROSS_COMPILE 也用于 ccache。
```

There's an easy pitfall to fall into here—the value of `ARCH` doesn't always have a one-to-one correspondence with the toolchain prefix naming. For ARM64, the architecture name used by the kernel build system is `arm64`, but the toolchain prefix is `aarch64-linux-gnu-`; they are different. This is due to historical reasons. The ARM64 architecture has always been called `arm64` in the kernel community, while the toolchain side uses the `aarch64` name officially defined by ARM. The project's [linux-action-scripts.sh](scripts/linux-action-scripts.sh) lines 69–72 specifically handle this mapping, converting user-provided `aarch64` or `arm64` into the `arm64` that Kbuild recognizes.

`CROSS_COMPILE` is even more interesting—it's not a complete command name, but a prefix. The kernel build system automatically appends suffixes like `gcc`, `ld`, and `objcopy` after this prefix to find the corresponding tools. In other words, when you set `CROSS_COMPILE=aarch64-linux-gnu-`, make will look for `aarch64-linux-gnu-gcc`, `aarch64-linux-gnu-ld`, `aarch64-linux-gnu-objcopy`, and a whole series of other tools. If `CROSS_COMPILE` is an empty string, make will directly use the local machine's `gcc`, `ld`, etc.—this is exactly why, when you forget to set this variable, the kernel gets compiled for the x86 architecture. The empty string prefix causes the build system to use the host's compiler.

A recommended practice is to export these two variables in your current shell, so you don't have to repeat them for every subsequent make command:

```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
```

Besides the toolchain, compiling the kernel requires some auxiliary tools (bison, flex, etc.). On Ubuntu/Debian, one line does the trick:

```bash
# Ubuntu / Debian, UnAuthorized Commands，这部分我没验证
sudo apt install build-essential libncurses-dev bison flex libssl-dev libelf-dev
```

Arch Linux users generally already have these tools installed through the base-devel group. If not, use `pacman -S base-devel` to fill in the gaps.

## Try It Yourself

Here's how the author does it! Come give it a try!

1. Run `uname -r`, `cat /proc/version`, and `ls /dev/kvm` in sequence in your WSL2 terminal, and record your environment info
2. Install the ARM64 cross-compiler and verify that `aarch64-linux-gnu-gcc --version` outputs a version number
3. Export `ARCH=arm64` and `CROSS_COMPILE=aarch64-linux-gnu-` in your terminal, then run `echo __PRESERVED_10__CROSS_COMPILE` to confirm the variables have taken effect
4. If you're also interested in RISC-V, you can install `gcc-riscv64-linux-gnu` along the way (Arch: `pacman -S riscv64-linux-gnu-gcc`); subsequent exercises will support multiple architectures

## Further Reading

- [Kbuild Kernel Build System Documentation](https://www.kernel.org/doc/html/latest/kbuild/kbuild.html) — The official kernel.org definitions for variables like `ARCH` and `CROSS_COMPILE`
- [Linux Kernel Build Instructions](https://docs.kernel.org/admin-guide/README.html) — The web version of the README in the kernel source root directory
- [Cross-Compiling for Debian/Ubuntu in Practice](https://jensd.be/1126/linux/cross-compiling-for-arm-or-aarch64-on-debian-or-ubuntu) — A cross-compilation tutorial for Ubuntu-based environments
