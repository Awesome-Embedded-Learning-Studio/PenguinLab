# PenguinLab — 30 天嵌入式 Linux 内核学习计划

面向有 C 语言和嵌入式基础（STM32 / FreeRTOS）的工程师，通过 QEMU + 真机（i.MX6ULL / 全志 H618）实践，掌握 Linux 内核驱动开发、内核移植定制和性能调优。

## 快速开始

### 1. 克隆仓库

```bash
git clone --recursive https://github.com/your-username/PenguinLab.git
cd PenguinLab

# 如果已克隆但未初始化子模块
git submodule update --init third_party/linux third_party/busybox
```

### 2. 安装工具链

```bash
# ARM32
sudo apt install gcc-arm-linux-gnueabihf

# ARM64（可选）
sudo apt install gcc-aarch64-linux-gnu

# QEMU
sudo apt install qemu-system-arm

# CMake（用于用户态示例）
sudo apt install cmake
```

### 3. 构建内核 + 根文件系统

```bash
# 构建 ARM64 内核
./scripts/linux-action-scripts.sh config_and_build \
    ARCH=arm64 LINUX_DEFCONFIG=defconfig

# 构建最小 rootfs
./scripts/rootfs-minimal-maker.sh --static all
```

### 4. 启动 QEMU

```bash
./scripts/qemu-run.sh run
```

内核启动后在 QEMU shell 里操作。退出 QEMU：`Ctrl+A X`。

## 目录结构

```
PenguinLab/
├── tutorial/              # Week 1 教程（环境搭建、Kconfig、数据结构、QEMU）
├── todo/                  # Week 2–4 学习计划（内核模块、驱动、DTS、BSP）
├── example/               # 可构建的示例代码
│   ├── kernel_base_ds/    # 侵入式链表实现 + 12 个测试用例
│   ├── kernel_module/     # 最小内核模块、符号导出
│   └── chardev/           # 字符设备驱动 + 用户态测试
├── scripts/               # 自动化脚本
│   ├── linux-action-scripts.sh   # 内核配置与交叉编译
│   ├── qemu-run.sh              # QEMU ARM 仿真
│   ├── rootfs-minimal-maker.sh   # BusyBox 最小根文件系统
│   └── linux-submodule.sh       # 子模块管理
├── document/              # 参考文档
│   ├── booklist.md        # 13 本书推荐（含章节定位和阅读时机）
│   └── qemu-reference.md  # QEMU 速查手册
├── third_party/           # 第三方子模块
│   ├── linux/             # Linux 内核 6.19.y
│   └── busybox/           # BusyBox
├── .clang-format          # 代码格式化配置
└── .clangd                # clangd LSP 配置（内核源码导航）
```

## 学习路线

| 周次 | 主题 | 里程碑 |
|------|------|--------|
| Week 1 | 内核解剖 & 构建体系 | QEMU 跑起来交叉编译的 ARM 内核 |
| Week 2 | 内核模块 & 字符驱动 | 完整字符设备驱动 + 用户态测试程序 |
| Week 3 | DTS 深度 & 中断子系统 | 驱动在 imx6ull 真机上跑通 |
| Week 4 | BSP 实战 & 性能调优 | H618 内核定制 + I²C 综合驱动 |

## 使用建议

- 每天**先读对应教程的「要了解什么」部分**（10–15 分钟），再动手
- 命令块中的内容可以直接复制到终端执行
- 每个文件末尾有**延伸阅读**，标注了书名 + 具体章节
- 打 ✅ 标记完成的练习项，方便复盘进度

## 许可证

MIT License — 详见 [LICENSE](LICENSE)
