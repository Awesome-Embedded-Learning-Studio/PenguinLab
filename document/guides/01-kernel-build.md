---
title: 编译 Linux 内核
description: 用 linux-action-scripts.sh 交叉编译 ARM32/ARM64 内核——config/build/clean 三板斧、O= 外部构建、配置怎么查怎么改
maturity: verified
---

# 编译 Linux 内核

## 这个脚本干啥

`scripts/linux-action-scripts.sh` 把「配置内核 → 编译 → 清理」这套交叉编译流程包成几个子命令，统一用 `O=` 外部构建，产物落在 `out/build_latest_<arch>/`。

## 前置

- 内核源码子模块已初始化：`git submodule update --init third_party/linux`
- 交叉工具链在 PATH：ARM64 用 `aarch64-linux-gnu-`，ARM32 用 `arm-none-linux-gnueabihf-`

## 四个子命令

脚本接受任意顺序的子命令串：

```bash
scripts/linux-action-scripts.sh config           # 配置（需 LINUX_DEFCONFIG）
scripts/linux-action-scripts.sh build            # 编译（需先有 .config）
scripts/linux-action-scripts.sh config_and_build # 配置 + 编译一步到位
scripts/linux-action-scripts.sh clean            # 删 out/build_latest_<arch>/
```

## 关键环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `ARCH` | `arm` | `aarch64` 会被脚本映射成内核命名 `arm64` |
| `CROSS_COMPILE` | `arm-none-linux-gnueabihf-`（ARM32） | 工具链前缀；**ARM64 必须显式设 `CROSS_COMPILE=aarch64-linux-gnu-`**——脚本不会按 `ARCH` 自动切（实测踩坑，见下） |
| `LINUX_DEFCONFIG` | （无） | `config` 命令必填；ARM64 用 `defconfig`，ARM32 用 `vexpress_defconfig` |
| `BUILD_OUTPUT_BASE` | `out/build_latest_<arch>` | 产物目录；显式指定时不触发自动备份 |
| `BUILD_JOBS` | `nproc` | 并行度 |

## O= 外部构建与自动备份

脚本始终用 `make O="${BUILD_OUTPUT_BASE}"`，产物和源码树分离。一个贴心的设计：**若输出目录里已有 `.config`，就直接复用**（你只是想重新 `build`）；若没有，就把旧目录改名备份成 `build_<时间戳>`，再开新的。

所以「改了配置想重新 config」时，要么先 `clean`，要么手动指定一个新的 `BUILD_OUTPUT_BASE`。

## 产物在哪

```
out/build_latest_arm64/
├── .config
├── arch/arm64/boot/Image          ← 内核镜像（qemu-run 自动探测它）
├── arch/arm64/boot/dts/*.dtb      ← 设备树（virt 机器其实用 QEMU 现场生成的）
├── vmlinux                        ← 带调试符号的未压缩内核（GDB 用）
└── ...                            ← 内核模块、Module.symvers 等
```

ARM32 对应 `arch/arm/boot/zImage`。

## 实操：编一个 ARM64 内核

```bash
ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- LINUX_DEFCONFIG=defconfig \
  scripts/linux-action-scripts.sh config_and_build
```

编完，`out/build_latest_arm64/arch/arm64/boot/Image` 就是 QEMU 要的内核。

## 怎么查 / 改内核配置

`config_and_build` 用的是 defconfig，很多特性默认就开了。想确认或修改，两条路。

**查**：直接 grep 输出目录的 `.config`。比如想确认 9p（virtio-9p 共享目录用的）开没开：

```bash
grep -iE '9P|VIRTIO' out/build_latest_arm64/.config
```

当前 ARM64 defconfig 下，`CONFIG_NET_9P=y`、`CONFIG_NET_9P_VIRTIO=y`、`CONFIG_9P_FS=y` 都已经编进内核——意味着 Guest 这边挂 9p 文件系统**不用再重编内核**，只剩 QEMU 侧加 `-virtfs` 这一步。

**改**：进输出目录用内核自带工具改完，再 `build`（不用重 `config`）：

```bash
cd out/build_latest_arm64
make menuconfig                       # 图形化勾选
# 或精确开关单项：
./scripts/config --enable 9P_FS_POSIX_ACL   # 比如想开 POSIX ACL
make O=$(pwd) olddefconfig
cd ../..
ARCH=aarch64 scripts/linux-action-scripts.sh build
```

> 小坑：`9P_FS_POSIX_ACL` 默认没开。只有在 9p 挂载点上要 `chown`/`chmod` 并保留 ACL 时才需要它；单纯传 `.ko` 文件用不到。

## 换架构：ARM32

```bash
ARCH=arm LINUX_DEFCONFIG=vexpress_defconfig \
  scripts/linux-action-scripts.sh config_and_build
```

产物落到 `out/build_latest_arm/`，内核镜像是 `zImage`，配合 `vexpress-a9` 机器的 dtb。

## 常见坑

- **`LINUX_DEFCONFIG` 没设就跑 `config`**：脚本直接报错退出。ARM64 填 `defconfig`，ARM32 填 `vexpress_defconfig`。
- **改了源码不生效**：确认改的是 `third_party/linux/` 下的文件，且 `build` 用的 `O=` 目录和之前一致——别一不小心换了输出目录，等于从头编译。
- **`ARCH=aarch64` vs `arm64`**：你输入 `aarch64`（工具链习惯），脚本内部转成 `arm64`（内核习惯），输出目录也用 `arm64`。记住这点就不会找错目录。
- **漏 `CROSS_COMPILE` 会用 ARM32 默认工具链（大坑）**：脚本 `CROSS_COMPILE` 默认 `arm-none-linux-gnueabihf-`（ARM32），**不会按 `ARCH` 自动切**。ARM64 编译必须显式 `CROSS_COMPILE=aarch64-linux-gnu-`，否则 ARM32 gcc 不认 ARM64 选项（`-msign-return-address=non-leaf` 等）编译失败——而且脚本不检测编译错误会**误报 SUCCESS**，结果 Image 根本没更新、`struct module` 布局对不上，外部模块 insmod 报 `invalid module format`。看到 build 秒结束就要怀疑这个。
