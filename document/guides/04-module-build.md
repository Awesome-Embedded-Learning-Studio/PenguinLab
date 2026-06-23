---
title: 交叉编译内核模块
description: 用 example/common/Makefile.arch 把内核模块交叉编译到 ARM32/ARM64/RISC-V/x86_64——四架构 + export 那个坑
maturity: verified
---

# 交叉编译内核模块

## 一个模块目录的最小结构

看现成的范例 `example/mini/00-kernel_module_hello/`，就两个文件：

```
example/mini/00-kernel_module_hello/
├── hello.c       模块源码（init/exit + module_init/exit + MODULE_LICENSE）
├── Makefile      obj-m += hello.o + include 公共 Makefile.arch
└── （make 后生成 hello.ko 等）
```

`Makefile` 长这样：

```makefile
obj-m += hello.o
# Import the common stub
include ../../common/Makefile.arch

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
```

核心就三件事：

- `obj-m += hello.o`：告诉内核构建系统「把 hello.o 编成模块 hello.ko」。多文件模块写成 `obj-m += mymod.o` + `mymod-y := a.o b.o`。
- `include ../../common/Makefile.arch`：引入公共的架构/工具链/KDIR 设定（下面详述）。
- `all`/`clean`：委托给内核构建系统——`-C $(KDIR)` 进入内核树、`M=$(CURDIR)` 构建外部模块。

## Makefile.arch 干啥

`example/common/Makefile.arch` 是所有示例模块共享的桩，集中定义三件事：

```makefile
ARCH ?= arm64
KDIR ?= $(shell realpath .../out/build_latest_$(ARCH))

ifeq ($(ARCH),arm)
  CROSS_COMPILE ?= arm-none-linux-gnueabihf-
else ifeq ($(ARCH),arm64)
  CROSS_COMPILE ?= aarch64-linux-gnu-
else ifeq ($(ARCH),riscv)
  CROSS_COMPILE ?= riscv64-linux-gnu-
else ifeq ($(ARCH),x86_64)
  CROSS_COMPILE ?=
  KDIR ?= /lib/modules/$(shell uname -r)/build
endif

export ARCH CROSS_COMPILE
```

- `ARCH`：目标架构（默认 `arm64`）。
- `KDIR`：内核树路径，默认指向 `out/build_latest_$(ARCH)`——**所以编模块前，对应架构的内核得先编过**（见 [编译内核](./01-kernel-build)）。
- `CROSS_COMPILE`：按架构自动选工具链前缀。
- **末尾的 `export ARCH CROSS_COMPILE`：关键，见下。**

## 那个 export 坑（重点）

模块的 `all` 目标会递归调用内核构建：

```makefile
$(MAKE) -C $(KDIR) M=$(CURDIR) modules
```

这一步要进入内核树 `$(KDIR)` 跑构建，内核的 Makefile 会读 `ARCH` 和 `CROSS_COMPILE` 决定**目标架构和工具链**。

问题在于：GNU make 里，普通变量赋值（`ARCH ?= arm64`）**默认不导出**给子进程。于是 `$(MAKE) -C $(KDIR)` 起的子 make 看不到 `ARCH`，内核 Makefile 就用它自己的默认值（通常是宿主机 x86），结果要么编错架构、要么在错的目录里找东西，报一堆莫名其妙的错。

`export ARCH CROSS_COMPILE` 这行把它们塞进环境变量，子 make 才能继承。PenguinLab 早期就被这个坑过（递归 make 变量不传递），现在这行已经固化在 `Makefile.arch` 里，照着 `include` 就不会再踩。

> 一句话记牢：**外部模块构建是「借内核的构建系统」，借的时候得把 ARCH/CROSS_COMPILE 一起递过去，靠 `export`。**

## 怎么编

```bash
cd example/mini/00-kernel_module_hello
make ARCH=arm64           # 编出 hello.ko
make ARCH=arm64 clean     # 清理
```

不传 `ARCH` 就用默认 `arm64`。换架构：

```bash
make ARCH=arm             # ARM32
make ARCH=riscv           # RISC-V（需先编过 riscv 内核）
make ARCH=x86_64          # x86_64（KDIR 指向宿主内核）
```

产物 `hello.ko` 就在当前目录。

## 模块怎么上机

编出 `hello.ko` 后，两条路上机验证：

- **现状（塞 rootfs）**：cp 进 `out/build_latest_arm64/rootfs/` + `rootfs-minimal-maker.sh --pack-only` + 重启 QEMU，Guest 里 `insmod hello.ko`。见 [制作 rootfs](./02-rootfs)。
- **未来（9p 共享）**：配通 9p 后，把模块目录挂进 Guest，宿主机 `make` 出新 ko，Guest 立刻能 `insmod`，免重打包。

## 常见坑

- **没编内核就编模块**：`KDIR` 指向 `out/build_latest_<arch>`，里面没有内核构建产物（尤其 `Module.symvers`、`scripts/`），模块编译报错。先编内核。
- **ARCH 和 KDIR 对不上**：`make ARCH=arm64` 但 `out/build_latest_arm64` 是空的——检查内核是不是按 `ARCH=aarch64` 编过（`aarch64`→`arm64` 输出目录）。
- **改了 Makefile.arch 不生效**：多半是 `ARCH` 没传对，或 `export` 那行被误删。
- **多文件模块**：`obj-m += mymod.o` 后加 `mymod-y := a.o b.o`，别漏。
