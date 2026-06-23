---
title: 项目指南
description: PenguinLab 的工具链全景——怎么交叉编译内核、做最小 rootfs、跑 QEMU、编内核模块、构建网站
maturity: verified
---

# 项目指南

> 这一卷讲的是「怎么用 PenguinLab 这套环境真正干活」——交叉编译内核、做一个最小 rootfs、在 QEMU 里跑起来、编译内核模块、以及这个网站本身怎么构建。面向两类人：刚 clone 仓库不知道从哪下手的新人，和想把某条链路彻底吃透的老手。

之所以单独抽一卷写这些，是因为 PenguinLab 的工具链横跨**宿主工具链、内核构建、initramfs、QEMU、模块编译、网站构建**好几层，每层都有自己的脚本和约定。它们散落在各处，容易「每次上手都要重新摸索一遍」——这卷文档把它们一次性钉死，既是给学习者的地图，也是项目的长期资产。

## 全景：一条主线串起来

PenguinLab 的内核学习闭环，本质是这条流水线：

```
third_party/linux (源码 v6.19.9)
        │  linux-action-scripts.sh build
        ▼
out/build_latest_<arch>/   ← 一切产物的家
   ├─ arch/<arch>/boot/Image        内核镜像
   ├─ .config                       内核配置
   └─ ...
        │
third_party/busybox ──rootfs-minimal-maker.sh──► rootfs.cpio.gz   (initramfs)
        │
        ▼
qemu-run.sh run   →   Image + rootfs.cpio.gz   →   QEMU virt   →   串口 shell
        ▲
        │  example/common/Makefile.arch
example/mini/<demo>/hello.ko   (cp 进 rootfs 重打包，或走 9p 免重打包)
```

记牢一个目录：**`out/build_latest_<arch>/`**。内核镜像、内核配置、BusyBox、rootfs、initramfs 全部落在这儿，按架构分目录（`arm64` / `arm`）。找东西先往这儿看。

## 三方依赖与版本

| 组件 | 位置 | 版本 |
|------|------|------|
| Linux 内核 | `third_party/linux`（git 子模块） | v6.19.9 |
| BusyBox | `third_party/busybox`（git 子模块） | 构建脚本自动解析打印 |
| 交叉工具链 (ARM64) | 系统 PATH | `aarch64-linux-gnu-gcc` |
| 交叉工具链 (ARM32) | 系统 PATH | `arm-none-linux-gnueabihf-gcc` |
| QEMU | 系统 | `qemu-system-aarch64` / `qemu-system-arm` |

初始化子模块：

```bash
git submodule update --init third_party/linux third_party/busybox
```

安装工具链（Ubuntu/Debian）：

```bash
sudo apt install gcc-aarch64-linux-gnu gcc-arm-none-linux-gnueabihf \
                 qemu-system-arm qemu-user-static
```

## 五条主线脚本

| 脚本 | 作用 | 关键产物 |
|------|------|----------|
| `scripts/linux-action-scripts.sh` | 交叉编译内核（config/build/clean） | `Image` / `zImage`、dtbs、modules |
| `scripts/rootfs-minimal-maker.sh` | 编 BusyBox + 打 initramfs | `rootfs.cpio.gz` |
| `scripts/qemu-run.sh` | 启动 QEMU 跑内核 | 串口 shell / GDB stub |
| `example/common/Makefile.arch` | 交叉编译内核模块 | `*.ko` |
| `scripts/build.ts` | 构建本网站（VitePress 分卷） | `site/.vitepress/dist` |

## 最小可跑闭环（速记）

```bash
# 1. 编内核（ARM64）
ARCH=aarch64 LINUX_DEFCONFIG=defconfig \
  scripts/linux-action-scripts.sh config_and_build

# 2. 打 rootfs（ARM64）
ARCH=aarch64 scripts/rootfs-minimal-maker.sh

# 3. 跑起来
scripts/qemu-run.sh run
# 退出：Ctrl+A 然后 X
```

跑通这三步，你就有一个能交互的 ARM64 Linux 最小系统。

## 设计约定（为什么是这样）

- **外部构建 `O=`**：内核和 rootfs 都用 `make O=out/build_latest_<arch>` 把产物外置，不污染 `third_party/` 源码树，也方便多架构并存（`out/build_latest_arm64` 与 `out/build_latest_arm` 互不干扰）。
- **`out/` 不进 git**：全是可重建的构建产物、体积大，所以 `.gitignore` 掉。
- **架构后缀**：`aarch64`（工具链命名）在内核世界映射成 `arm64`（内核命名），脚本内部做了这层映射，输出目录统一用 `arm64`。这是最容易让人找错目录的一个点。
- **initrd 优先**：QEMU 默认走 initramfs（`-initrd`）而非块设备 rootfs，最小系统够用且免分区。

## 阅读路线

按编号顺序读，每篇也独立可查：

- [编译 Linux 内核](./01-kernel-build) — 内核怎么编、配置怎么改、9p 这种特性怎么查开没开
- [制作 BusyBox rootfs](./02-rootfs) — initramfs 怎么来、ko 怎么塞进去
- [QEMU 启动与调试](./03-qemu) — 跑起来、串口、网络、GDB 一条龙
- [交叉编译内核模块](./04-module-build) — `Makefile.arch` 四架构、`export` 那个坑
- [构建本网站](./05-site-build) — VitePress 分卷构建，以及几个踩过的认知坑

---

> 写作约定：本卷面向人读，保留和教程一致的人味（讲清「为什么」，附真实命令），但更偏「使用手册」——能查、能照着做。发现哪处和实际脚本对不上，欢迎在 GitHub 上提 issue 或直接改。
