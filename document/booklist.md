---
title: 推荐书单
sidebar_position: 10
---

# 书单：嵌入式 Linux 内核学习推荐书目

> 按学习阶段排列，每本书标注推荐阅读时机、侧重和获取方式。
> 原则：理论书打地基，实战书上真机，源码才是最终文档。

---

## 快速选书指南

| 你现在的问题 | 先查这本 |
|-------------|---------|
| 某个内核机制的原理 | 《Linux 内核设计与实现》Robert Love |
| 某个 API 怎么用 | LDD3（免费）或《Linux 设备驱动开发详解》宋宝华 |
| 某个 devm_/regmap/IIO API | *Linux Device Driver Development* Madieu |
| imx6ull 引脚/时钟配置 | i.MX6ULL 参考手册（NXP 官网） |
| H618 相关 | sunxi 社区 wiki + 全志 SDK 文档 |
| 性能问题排查 | 《Linux 性能优化实战》倪朋飞 |
| 内核同步/锁 | Paul McKenney 免费书 |

---

## 目录

- [第一层：内核原理（理论基础）](#第一层内核原理理论基础)
- [第二层：设备驱动（核心实战）](#第二层设备驱动核心实战)
- [第三层：嵌入式系统（工程实践）](#第三层嵌入式系统工程实践)
- [第四层：性能与调试](#第四层性能与调试)
- [第五层：免费在线资源](#第五层免费在线资源高质量)

---

## 第一层：内核原理（理论基础）

> Week 1 开始前通读，后续按需查阅。

### 1. 《Linux 内核设计与实现》第 3 版
- **英文原版**：*Linux Kernel Development*, 3rd Edition — Robert Love
- **中文版**：《Linux 内核设计与实现》陈莉君等译，机械工业出版社
- **推荐时机**：Week 1 开始前通读；后续按章节配合对应任务查阅
- **内容**：进程管理、内存管理、VFS、中断、内核同步、定时器。覆盖全面但不深。适合建立全局观。
- **页数**：约 440 页，节奏快，可快速通读
- **获取**：实体书；英文版 PDF 在 archive.org 可合法获取
- **最该读的章节**：
  - Ch.1–2：内核简介，起步
  - Ch.6：内核数据结构（list_head、rbtree）← Week 1 Day 5-6 配合
  - Ch.7–8：中断与下半部 ← Week 3 配合
  - Ch.12：内存管理 ← Week 4 配合
  - Ch.17：设备模型和 sysfs

---

### 2. 《深入理解 Linux 内核》第 3 版
- **英文原版**：*Understanding the Linux Kernel*, 3rd Edition — Daniel P. Bovet, Marco Cesati
- **中文版**：《深入理解 Linux 内核》陈莉君、张琼声译，中国电力出版社
- **推荐时机**：Week 2–3 期间，遇到某个机制想深挖时查阅
- **内容**：比 LKD 深 3 倍。中断、内存管理、进程调度、文件系统，每个机制都追到汇编级别
- **页数**：约 900 页，不适合通读，适合作**参考书**按需查阅
- **注意**：基于 2.6 内核，部分实现细节已变化，但原理完全适用
- **最该读的章节**：
  - Ch.4：中断和异常 ← Week 3 中断子系统配合
  - Ch.8：内存管理（伙伴系统、slab）← Week 4 配合
  - Ch.3：进程，理解 task_struct

---

### 3. 《深入 Linux 内核架构》
- **英文原版**：*Professional Linux Kernel Architecture* — Wolfgang Mauerer
- **中文版**：《深入 Linux 内核架构》郭旭译，人民邮电出版社
- **推荐时机**：本月学完后，长期参考书
- **内容**：覆盖最全，包含内存管理、虚拟文件系统、网络、模块、设备驱动。每章都有大量图表和源码分析
- **页数**：约 1400 页，是内核书里最厚的一本
- **获取**：实体书较难找，英文版 PDF 可在网上找到旧版
- **推荐用法**：把目录背熟，知道"这个机制在第 X 章"，查阅时直接翻到那里

---

## 第二层：设备驱动（核心实战）

> Week 2 开始，驱动开发的必读层。

### 4. *Linux Device Drivers*, 3rd Edition（LDD3）
- **作者**：Jonathan Corbet, Alessandro Rubini, Greg Kroah-Hartman
- **中文版**：《Linux 设备驱动》魏永明等译（第 3 版中文版）
- **推荐时机**：Week 2 开始，驱动开发的**必读经典**
- **内容**：字符设备、块设备、网络设备、USB、PCI、内存映射、DMA、中断
- **页数**：约 600 页
- **免费获取**：https://lwn.net/Kernel/LDD3/ （完整英文 PDF，作者授权免费）
- **注意**：基于 2.6.10 内核，很多 API 已更新（如 `register_chrdev` 应改用 cdev，`ioremap_nocache` 已废弃），但概念完全正确
- **最该读的章节**：
  - Ch.2：构建和运行模块 ← Week 2 Day 8-9
  - Ch.3：字符设备 ← Week 2 Day 10-11
  - Ch.14：Linux 设备模型 ← Week 2 Day 12-13
  - Ch.10：中断处理 ← Week 3 Day 17-18
  - Ch.15：内存映射和 DMA ← Week 4

---

### 5. 《Linux 设备驱动开发详解》（基于最新内核和 ARM64 体系结构）
- **作者**：宋宝华
- **出版**：人民邮电出版社，第 3 版（2022 年）
- **推荐时机**：Week 2 开始，国内工程师最常用的中文参考书
- **内容**：涵盖 5.x 内核，覆盖字符/块/网络设备驱动、平台驱动、DTS、I²C/SPI/USB 子系统、内存管理
- **优点**：例子多，针对 ARM 嵌入式，代码可直接在真机上跑；作者是内核社区贡献者，内容准确
- **推荐用法**：与 LDD3 配合读，LDD3 讲概念，这本讲最新 API 和真机实践
- **最该读的章节**：
  - 第 4–5 章：字符设备
  - 第 11 章：平台驱动
  - 第 14 章：I²C、SPI 总线驱动
  - 第 17 章：内存与 I/O 映射

---

### 6. *Linux Device Driver Development*, 2nd Edition
- **作者**：John Madieu
- **出版**：Packt Publishing（2022 年）
- **推荐时机**：Week 2–4，目前最新的驱动开发实战书
- **内容**：基于 5.10+ 内核，覆盖现代内核 API（devm_、managed resources、threaded IRQ、regmap、DMA engine、IIO），含 Raspberry Pi 实机示例
- **优点**：是目前讲 devm_、regmap、IIO 框架最系统的书；示例代码在 GitHub 上有完整仓库
- **代码仓库**：https://github.com/PacktPublishing/Linux-Device-Driver-Development
- **最该读的章节**：
  - Ch.2：模块基础
  - Ch.3：字符设备
  - Ch.6：Platform Driver（含 devm_ 系统讲解）
  - Ch.9：I²C 驱动
  - Ch.12：Pinctrl
  - Ch.14：调试

---

## 第三层：嵌入式系统（工程实践）

> Week 1–4 全程参考，建立嵌入式工程全局观。

### 7. *Embedded Linux Primer*, 2nd Edition
- **作者**：Christopher Hallinan
- **中文版**：《嵌入式 Linux 基础教程》李云译，人民邮电出版社（第 2 版）
- **推荐时机**：Week 1，建立嵌入式 Linux 整体工程观
- **内容**：U-Boot、内核启动、交叉编译、文件系统、调试。非常工程导向
- **最该读的章节**：
  - Ch.5：内核初始化 ← Week 1 QEMU 任务配合
  - Ch.7：U-Boot
  - Ch.12：嵌入式开发环境（NFS、JTAG）← Week 3 真机配合

---

### 8. *Mastering Embedded Linux Programming*, 3rd Edition
- **作者**：Chris Simmonds
- **出版**：Packt Publishing（2021 年）
- **推荐时机**：Week 1–4 全程参考
- **内容**：工具链、U-Boot、内核配置、Buildroot/Yocto、根文件系统、驱动调试，很系统且最新
- **代码仓库**：https://github.com/PacktPublishing/Mastering-Embedded-Linux-Programming-Third-Edition
- **最该读的章节**：
  - Ch.4：内核配置与编译 ← Week 1
  - Ch.6：选择构建系统（Buildroot/Yocto）
  - Ch.11：与设备驱动交互 ← Week 2–3

---

### 9. *Building Embedded Linux Systems*, 2nd Edition
- **作者**：Karim Yaghmour, Jon Masters, Gilad Ben-Yossef, Philippe Gerum
- **中文版**：《构建嵌入式 Linux 系统》（中文版翻译质量一般，推荐读英文）
- **推荐时机**：Week 4，需要理解 BSP 整体构建时
- **内容**：深度讲解 toolchain、内核配置、根文件系统构建、启动、电源管理。是 BSP 工程师的参考手册
- **获取**：O'Reilly 平台；英文版 PDF 可在 archive.org 找到旧版

---

### 10. 《嵌入式 Linux 设备驱动程序开发》
- **英文原版**：*Linux Driver Development for Embedded Processors*, 2nd Edition — Alberto Liberal de los Ríos
- **出版**：自出版（Amazon）
- **推荐时机**：Week 3 DTS 和外设驱动阶段
- **内容**：专注 ARM 嵌入式平台，覆盖 DTS、GPIO、I²C、SPI、UART、USB，每章都有完整可运行示例，示例在 Raspberry Pi 和 i.MX 上验证
- **代码仓库**：https://github.com/ALIBEK/linux-kernel-module-cheat

---

## 第四层：性能与调试

> Week 4 及学完后的进阶方向。

### 11. 《Linux 性能优化实战》
- **作者**：倪朋飞（极客时间专栏，后出书）
- **出版**：电子工业出版社
- **推荐时机**：Week 4 ftrace/perf 阶段
- **内容**：CPU、内存、I/O、网络性能分析，全部基于 perf、ftrace、eBPF 实战，有大量真实案例
- **特点**：国内最系统的 Linux 性能分析中文资料，例子来自真实生产环境

---

### 12. *BPF Performance Tools*
- **作者**：Brendan Gregg（《Systems Performance》同一作者）
- **出版**：Addison-Wesley（2019 年）
- **推荐时机**：本月学完后的进阶方向（eBPF 是 kprobe 的现代替代）
- **内容**：BCC、bpftrace 工具集，用 eBPF 做 CPU/内存/网络/存储性能分析
- **特点**：Brendan Gregg 是 Linux 性能分析领域权威，本书是 eBPF 实战最权威参考
- **网站**：https://www.brendangregg.com/bpf-performance-tools-book.html

---

### 13. *Is Parallel Programming Hard, And, If So, What Can You Do About It?*
- **作者**：Paul E. McKenney（Linux 内核 RCU 维护者）
- **免费获取**：https://mirrors.edge.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html
- **推荐时机**：长期参考，需要理解内核同步机制时
- **内容**：内存模型、原子操作、RCU、内存屏障的权威讲解。写内核同步代码必备

---

## 第五层：免费在线资源（高质量）

### LWN.net 内核文章精选

LWN.net 是内核开发者的第一手资料，每篇文章都由内核社区人员撰写。

| 文章 | URL | 配合的任务 |
|------|-----|-----------|
| The platform device API | https://lwn.net/Articles/448499/ | Week 2 platform driver |
| Threaded interrupts | https://lwn.net/Articles/302043/ | Week 3 中断 |
| The common clock framework | https://lwn.net/Articles/472998/ | Week 3 clock |
| Kernel debugging with kprobes | https://lwn.net/Articles/290277/ | Week 4 kprobe |
| Device tree overlays | https://lwn.net/Articles/616859/ | Week 3 DTS overlay |
| Intrusive linked lists | https://lwn.net/Articles/336224/ | Week 1 数据结构 |
| The sysfs filesystem | https://lwn.net/Articles/31185/ | Week 2 sysfs |

### 内核官方文档（本地可查）

```bash
# 在内核源码树中，以下目录有高质量文档
Documentation/driver-api/          # 驱动 API 参考
Documentation/devicetree/          # DTS 相关
Documentation/trace/               # ftrace、kprobe
Documentation/core-api/            # 核心 API（内存、锁等）
Documentation/kbuild/              # 构建系统

# 生成 HTML 格式文档（可在浏览器浏览）
sudo apt install python3-sphinx
make ARCH=arm htmldocs
# 结果在 Documentation/output/
```
