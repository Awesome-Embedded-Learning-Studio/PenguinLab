---
title: 用 9p 共享目录加速内核模块迭代
slug: kernel-module-9p-iteration
prerequisites:
  - kernel-module-hello
  - qemu-first-boot
next:
  - kernel-module-params
difficulty: intermediate
tags: [9p, qemu, kernel-module, 工作流, 调试]
architectures: [arm64, arm]
kernel_version: "6.19"
sources:
  - guide: helpers/study-guides/layer-0/kernel-module-basics-1/9p-share.md
  - log: helpers/study-guides/layer-0/kernel-module-basics-1/log.txt
maturity: verified
---

# 用 9p 共享目录加速内核模块迭代

## 做什么

学完这篇，我们能：

- 搞懂 9p 是什么、为什么它能让「改 ko 免重打包」
- 用 `qemu-run.sh` 的 `QEMU_9P` 开关一键挂起共享目录
- 在 Guest 里通过 9p 直接 `insmod` 宿主机刚 `make` 出来的 ko，告别 `cp + --pack-only + 重启` 的慢循环

## 要了解什么

### 先承认一个痛点

在没 9p 之前，内核模块的迭代循环是这样的：改 `hello.c` → `make` → `cp hello.ko` 进 rootfs 目录 → `rootfs-minimal-maker.sh --pack-only` 重打包 cpio → 重启 QEMU → `insmod`。每改一行代码，都得把整个 rootfs 重新打包一遍、Guest 重启一遍，几秒钟的改动要等半分钟。改得勤的时候，人是要疯的。

9p 要解决的就是这件事。

### 9p 是什么（够用就行）

- **9p** 是贝尔实验室 Plan 9 那套「一切皆文件」哲学里的远程文件协议；Linux 实现的是 `9P2000` 变体，比 NFS 轻、消息更简单。
- **QEMU 的 `-virtfs`**：把宿主机一个真实目录，通过 virtio 通道用 9p 协议暴露给 Guest；Guest 这边就像挂载一个普通文件系统，读写实际落宿主机磁盘。
- **为什么能免重打包**：因为 Guest 的挂载点直接映射到宿主机目录——你宿主机 `make` 出新 `.ko`，Guest 里 `ls` 立刻看见，根本不用进 rootfs 镜像。重打包那套流程，在这条路下可以退役了。

再往下钻（T-message/R-message 报文格式、trans=fd vs virtio transport、`9P2000.L` 和 `.u` 的区别）属于「用到再查」的范畴，这篇不展开。

### `qemu-run.sh` 的 `QEMU_9P` 开关

`scripts/qemu-run.sh` 已经把 9p 固化进去了，不用每次手敲一长串 `-virtfs`。四个环境变量控制：

| 变量 | 默认 | 说明 |
|------|------|------|
| `QEMU_9P` | `off` | 开关，`on` 时挂载 |
| `QEMU_9P_PATH` | （空） | 宿主机要共享的目录，**绝对路径**，`on` 时必填 |
| `QEMU_9P_TAG` | `hostshare` | mount tag，Guest 挂载时用这个名字 |
| `QEMU_9P_SEC` | `none` | `security_model`：`none`/`mapped-xattr`/`passthrough` |

`none` 最省心（非 root 也能用，传文件够）；`passthrough` 要 root，别碰。

## 动手试试

### 1. 确认内核 9p 已内建

我们这个项目的 ARM64 内核默认就把 9p 编进去了（`=y`，不是模块），确认一下：

```bash
grep -E 'CONFIG_NET_9P=|CONFIG_NET_9P_VIRTIO=|CONFIG_9P_FS=' out/build_latest_arm64/.config
```

三条都 `=y` 就行——意味着 Guest 启动就有 9p，不用再 `insmod` 任何 9p 模块，也不用重编内核。

### 2. 起一个带 9p 的 QEMU

把模块源码目录共享给 Guest（这样 `make` 出的 ko 直接可见）：

```bash
QEMU_9P=on QEMU_9P_PATH="$(pwd)/example/mini/00-kernel_module_hello" \
  scripts/qemu-run.sh run
```

引导时内核日志会打印：

```
9p: Installing v9fs 9p2000 file system support
9pnet: Installing 9P2000 support
```

### 3. Guest 里挂载

进到 BusyBox shell（`~ #`）后：

```sh
mkdir -p /mnt/share
mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/share
echo $?                 # 0 = 挂载成功
ls /mnt/share           # 应看到 hello.c、Makefile、hello.ko ...
```

### 4. 真正的迭代：改 ko 不重打包

这才是 9p 的价值所在。宿主机改 `hello.c`（比如把 `pr_info` 的文案改一下）→ `make` 出新 `hello.ko`，然后 Guest 里**直接重新 `insmod` 同一个路径**：

```sh
# Guest 里（ko 已经 insmod 过的话先 rmmod）
rmmod hello
insmod /mnt/share/hello.ko      # 加载的就是宿主机刚 make 的新版本
dmesg | tail -5                 # 看新的 printk
```

宿主机每次 `make` 覆盖 `hello.ko`，Guest 不用动 rootfs、不用重启，`rmmod` + `insmod` 就能加载到最新版。

### 实测输出（对照参考）

我们用两个不同 build 的 ko（`hello-A.ko` / `hello-B.ko`，只是 `pr_info` 文案不同）演示「Guest 通过 9p 加载宿主机的不同 build，全程不碰 rootfs」。共享目录里放这俩 ko，Guest 操作：

```
~ # mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/iter
~ # echo MOUNT_RC=$?
MOUNT_RC=0
~ # ls /mnt/iter
hello-A.ko  hello-B.ko
~ # insmod /mnt/iter/hello-A.ko
[   17.575143] hello: loading out-of-tree module taints kernel.
[   17.580515] 9p iter: build A
~ # rmmod hello
[   19.256294] My First Module exit, say goodbye!
~ # insmod /mnt/iter/hello-B.ko
[   20.278137] 9p iter: build B
```

`build A` → `build B`，两次 `insmod` 加载的是宿主机不同的 ko，rootfs 自始至终没重打包。这就是 9p 给模块开发带来的提速。

### 验证清单

- [ ] 内核 `.config` 里 `CONFIG_NET_9P`/`CONFIG_NET_9P_VIRTIO`/`CONFIG_9P_FS` 都是 `=y`
- [ ] `QEMU_9P=on QEMU_9P_PATH=... scripts/qemu-run.sh run` 能正常启动
- [ ] Guest 里 `mount -t 9p ...` 返回 0
- [ ] Guest `ls` 能看到宿主机共享目录的内容
- [ ] 宿主机改文件后，Guest 立刻可见（不用任何重打包）

## 踩过的坑

- **`-virtfs` 的 `id=` 必须字母开头**：QEMU 的标识符要求以字母起头，写成 `id=9p0`（数字开头）会被拒：`Parameter 'id' expects an identifier ... starting with a letter`。我们固化进 `qemu-run.sh` 时踩过，现在用的是 `id=fs9p`。
- **非 root 别用 `passthrough`**：`security_model=passthrough` 要 QEMU 以 root 跑；普通用户用 `none`（或 `mapped-xattr`）。
- **`mount_tag` 两边要逐字一致**：`QEMU_9P_TAG`（默认 `hostshare`）和 Guest `mount ... hostshare` 必须相同。
- **`version` 用 `9p2000.L`**：Linux 增强版，推荐；老式 `9p2000.u` 特性少。
- **`path=` 用绝对路径**：相对路径会指错。

## 延伸阅读

- 项目指南「[QEMU 启动与调试](/guides/03-qemu)」「[制作 BusyBox rootfs](/guides/02-rootfs)」——理解 9p 替代的重打包流程
- 前置教程「[第一个内核模块](./07-kernel-module-hello)」——先会编 hello.ko
- QEMU 9p 设置：<https://wiki.qemu.org/Documentation/9psetup>
- Linux 9p 文件系统文档：<https://docs.kernel.org/filesystems/9p.html>

