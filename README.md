<div align="center">

# PenguinLab

<!-- COVERAGE_START -->
![English Coverage](https://img.shields.io/badge/en_coverage-100%25-green.svg) 262/262 docs translated
<!-- COVERAGE_END -->

**Linux 内核学习站 — 从 QEMU 实践到内核原理、驱动开发与嵌入式全栈**

[![Kernel](https://img.shields.io/badge/Linux%20Kernel-6.19.y-blue)](https://kernel.org)
[![Arch](https://img.shields.io/badge/Arch-ARM32%20%7C%20ARM64%20%7C%20RISC--V%20%7C%20x86__64-green)](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab)
[![Docusaurus](https://img.shields.io/badge/Docusaurus-3.10-orange)](https://docusaurus.io)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

[English](#) · [在线阅读](https://awesome-embedded-learning-studio.github.io/PenguinLab/) · [开始学习](#快速开始)

</div>

---

## 为什么要有 PenguinLab？

学 Linux 内核的资料不少，但大多要么偏理论（ULK、LKD 看完还是不会写驱动），要么偏实操（LDD3 的 API 已经过时）。PenguinLab 想做的是：

- **知识图谱驱动**，不是线性教程——你可以按推荐路径走，也可以根据兴趣自由选择下一步
- **全栈覆盖**——从内核模块基础到调度器、内存管理、设备驱动、嵌入式 BSP、调试调优、虚拟化，一个站点搞定
- **纯 QEMU 实践**——不需要开发板，ARM32/ARM64/RISC-V/x86_64 四种架构都能跑
- **基于最新稳定内核 6.19.y**——不教过时 API，不拿 2.6 时代的代码糊弄人

## 内容覆盖

PenguinLab 采用 **6 层知识图谱** 组织教程，89 个知识节点之间有明确的前置/后继关系：

<table>
<tr><td><strong>Layer 0</strong></td><td>🎯 通识基础</td><td>环境搭建 · Kconfig · 内核模块 · 数据结构 · 进程与地址空间</td><td><strong>10 节点</strong></td></tr>
<tr><td><strong>Layer 1</strong></td><td>🧠 内核子系统</td><td>调度器 · 内存管理 · 文件系统 · 网络栈</td><td><strong>26 节点</strong></td></tr>
<tr><td><strong>Layer 2</strong></td><td>🔧 驱动开发</td><td>字符设备 · 平台驱动 · 设备树 · 中断 · GPIO · 同步原语</td><td><strong>22 节点</strong></td></tr>
<tr><td><strong>Layer 3</strong></td><td>📦 嵌入式全栈</td><td>交叉编译 · U-Boot · 内核裁剪 · Buildroot · BSP 项目</td><td><strong>8 节点</strong></td></tr>
<tr><td><strong>Layer 4</strong></td><td>🔍 调试与性能</td><td>printk · ftrace · perf · eBPF · KASAN · KGDB · Lockdep</td><td><strong>17 节点</strong></td></tr>
<tr><td><strong>Layer 5</strong></td><td>☁️ 虚拟化与容器</td><td>KVM · Namespaces · cgroups · 容器运行时</td><td><strong>7 节点</strong></td></tr>
</table>

### 知识图谱预览

```
                         ┌─→ sched-overview ──→ sched-cfs ──→ sched-rt
                         │                         │
process-thread-kernel ───┤                         └─→ sched-context-switch
                         │
                         ├─→ mm-overview ──→ mm-buddy ──→ mm-slab ──→ mm-vmalloc
                         │
                         ├─→ fs-vfs ──→ fs-ext4 · fs-procfs · fs-page-cache
                         │
                         └─→ net-overview ──→ net-sk-buff ──→ net-ipv4 ──→ net-tcp

kernel-module-basics ──→ drv-model ──→ drv-chardev ──→ drv-ioctl · drv-poll · drv-mmap
                            │
                            ├─→ drv-dts ──→ drv-platform ──→ drv-irq ──→ drv-threaded-irq
                            │
                            └─→ drv-sync ──→ drv-atomic ──→ drv-rcu
```

## 基于真实的笔记和代码

PenguinLab 不是凭空写出来的，背后有 **253 篇学习笔记** 和 **12 个可构建的代码示例** 作为内容基础：

| 笔记来源 | 篇数 | 覆盖范围 |
|----------|------|----------|
| *Linux Kernel Programming* | 13 章 | 内核基础、模块、进程、调度器、内存、同步 |
| *Linux Kernel Device Drivers* | 22 章 | 设备模型、字符设备、procfs/sysfs、中断、DMA |
| *Linux Kernel Debugging* | 93 章 | printk、ftrace、KASAN、Lockdep、KGDB、crash |
| *Linux Kernel Networking* | 124 章 | 网络栈全貌、sk_buff、IPv4、TCP、Netfilter、XDP |

每个代码示例放在 `example/mini/` 下，自带 Makefile，支持多架构交叉编译：

```
example/mini/
├── kernel_module_hello/     # 最小内核模块
├── kernel_module_params/    # 模块参数
├── kernel_module_export/    # 符号导出
├── chardev_basic/           # 字符设备驱动
├── sysfs_attributes/        # sysfs 属性
├── debugfs_basics/          # debugfs 基础
├── linked_list_kernel/      # 侵入式链表（用户态实现）
├── kthread_demo/            # 内核线程
├── wait_queue_demo/         # 等待队列
├── mutex_spinlock/          # 互斥锁 vs 自旋锁
├── atomic_ops/              # 原子操作
└── workqueue_demo/          # 工作队列
```

## 快速开始

### 1. 克隆仓库

```bash
git clone --recursive https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab.git
cd PenguinLab

# 如果已克隆但未初始化子模块
git submodule update --init third_party/linux third_party/busybox
```

### 2. 安装工具链

```bash
# ARM64 交叉编译
sudo apt install gcc-aarch64-linux-gnu

# ARM32（可选）
sudo apt install gcc-arm-linux-gnueabihf

# QEMU
sudo apt install qemu-system-arm

# 内核编译依赖
sudo apt install build-essential libncurses-dev bison flex libssl-dev
```

### 3. 构建内核 + 启动 QEMU

```bash
# 构建 ARM64 内核
./scripts/linux-action-scripts.sh config_and_build \
    ARCH=arm64 LINUX_DEFCONFIG=defconfig

# 构建最小 rootfs
./scripts/rootfs-minimal-maker.sh --static all

# 启动！
./scripts/qemu-run.sh run
```

内核启动后在 QEMU shell 里操作。退出：`Ctrl+A X`。

## 推荐学习路径

PenguinLab 的知识图谱支持多条路径，这里列出四条典型路线：

**嵌入式驱动工程师**（最热门）：
```
通识基础 → 内核模块 → 驱动模型 → 设备树 → 平台驱动
→ 字符设备 → 中断 → GPIO → DMA → 综合驱动项目
```

**内核爱好者**：
```
通识基础 → 进程/线程 → 调度器 CFS → 内存管理 Buddy/Slab
→ 文件系统 VFS → 网络栈 sk_buff → Netfilter → XDP
```

**调试专家**：
```
通识基础 → printk → ftrace → perf → eBPF → KASAN → KGDB
→ 综合性能调优实战
```

**BSP 工程师**：
```
通识基础 → 交叉编译 → QEMU → U-Boot → 内核裁剪
→ 根文件系统 → Buildroot → 完整 BSP 项目
```

## 其他兄弟仓库？

如果你手头有一块真实的硬件开发板，比如说imx-forge，那就更棒了。

🚀👉[IMX-Forge](https://github.com/Awesome-Embedded-Learning-Studio/imx-forge)

## 参考书单

教程内容参考了 13 本内核领域经典书籍，[完整书单见这里](https://awesome-embedded-learning-studio.github.io/PenguinLab/booklist)。核心参考包括：

- *Linux Kernel Development* — Robert Love
- *Understanding the Linux Kernel* — Bovet & Cesati
- *Linux Device Driver Development* — John Madieu
- *BPF Performance Tools* — Brendan Gregg
- *Mastering Embedded Linux Programming* — Frank Vasquez

## 许可证

MIT License — 详见 [LICENSE](LICENSE)
