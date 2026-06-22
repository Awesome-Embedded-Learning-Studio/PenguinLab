---
title: 制作 BusyBox rootfs
description: 用 rootfs-minimal-maker.sh 编静态 BusyBox、生成 init 脚本、打成 initramfs——以及内核模块怎么塞进去
maturity: verified
---

# 制作 BusyBox rootfs

## 这个脚本干啥

`scripts/rootfs-minimal-maker.sh` 把「编一个静态 BusyBox → 装进最小根目录 → 写好 init 脚本 → 打成 cpio.gz initramfs」一气呵成，产物 `out/build_latest_<arch>/rootfs.cpio.gz` 直接喂给 QEMU 的 `-initrd`。

## 一条命令全流程

```bash
ARCH=aarch64 scripts/rootfs-minimal-maker.sh
```

默认走完整流程：配置（defconfig + 静态）→ 编译 → 安装 → 生成 init 脚本 → 打包。

## 各阶段在干啥

1. **配置**：用 BusyBox `defconfig`，强制开 `CONFIG_STATIC`（编成静态二进制，initramfs 里不依赖动态库），并关掉几个 ARM 上会出问题的 x86 专属项（SHA 硬加速、tc 等）。
2. **编译**：`make -j<nproc>`。
3. **安装**：`make install CONFIG_PREFIX=.../rootfs`，生成 `bin/ sbin/ usr/` 和一堆指向 busybox 的符号链接（ls、cat、sh…）。
4. **建根目录结构**：建 `proc sys dev tmp etc mnt`，写 `/init`、`/etc/inittab`、`/etc/init.d/rcS`、`/etc/fstab`。
5. **打包**：`find . | cpio -o -H newc | gzip > rootfs.cpio.gz`。

## /init 脚本做了啥

这是 initramfs 的入口（内核命令行 `rdinit=/init` 指向它）。核心几步：

```sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t tmpfs none /dev
mknod ... /dev/console /dev/ttyAMA0 ...   # 建必要设备节点
exec /bin/sh -i </dev/console >/dev/console 2>&1   # 丢你一个交互 shell
```

起来就是一个挂在 console 上的 BusyBox shell，proc/sys/dev 都挂好了，够你 `insmod`/`lsmod`/`dmesg` 折腾。

## 几种运行模式

| 用法 | 作用 |
|------|------|
| （默认） | 配置 + 编译 + 安装 + 打包，全流程 |
| `--build-only` | 只编译（用已有 .config） |
| `--install-only` | 只安装已有 busybox + 打包 |
| `--pack-only` | **只重新打包 cpio，不编译不安装** |
| `--clean` | 清干净重建 |
| `menuconfig` | 进图形化配置（改完退出，再 `--build-only`） |

## 内核模块怎么塞进去（现状）

initramfs 是个静态镜像，ko 没在打包时放进去，Guest 里就看不到。现在的迭代流程：

```bash
# 1. 把编好的 ko 拷进 rootfs 目录
cp example/mini/00-kernel_module_hello/hello.ko \
   out/build_latest_arm64/rootfs/

# 2. 只重打包，不重新编 BusyBox
ARCH=aarch64 scripts/rootfs-minimal-maker.sh --pack-only

# 3. 重启 QEMU，Guest 里 insmod hello.ko
```

`--pack-only` 就是为此设计的——不重编 BusyBox，只把 rootfs 目录重新打成 cpio.gz，几秒钟的事。但每次改 ko 都得 cp + pack + 重启 QEMU，**这正是 9p 共享目录要解决的痛点**：配通 9p 后，宿主机改 ko，Guest 挂载点立刻可见，cp + pack 这套退役。

## 产物

```
out/build_latest_arm64/
├── busybox/             BusyBox 构建目录（含编出的二进制和 .config）
├── rootfs/              展开的根目录（改它，然后 --pack-only）
└── rootfs.cpio.gz       ← initramfs 镜像（qemu-run 自动探测它）
```

## 常见坑

- **`--pack-only` 前忘了 cp ko**：包还是旧的，Guest 里 `insmod` 加载的还是老版本。养成「改了 rootfs 目录内容，就 pack-only」的肌肉记忆。
- **ARCH 映射**：和内核一样，`aarch64` 的输出目录用 `arm64`。
- **想加 BusyBox applet**：`scripts/rootfs-minimal-maker.sh menuconfig` 勾上（比如 telnetd、httpd），再 `--build-only` 重编。
