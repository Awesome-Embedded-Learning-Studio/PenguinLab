# Example — 示例练习代码

每个子目录对应一个独立的可构建示例，包含源码、Makefile 和说明文档。

## 示例列表

| 目录 | 对应教程 | 说明 |
|------|----------|------|
| [kernel_base_ds/](kernel_base_ds/) | Week 1 Day 5-6 | 内核侵入式链表的用户态实现 + 12 个测试用例 |
| [kernel_module/](kernel_module/) | Week 2 Day 8-9 | 最小内核模块、module_param、符号导出 |
| [chardev/](chardev/) | Week 2 Day 10-11 | 完整字符设备驱动 + 用户态测试程序 |

## 通用构建说明

**内核模块**（kernel_module、chardev）需要交叉编译工具链和内核源码：

```bash
# 安装 ARM 交叉编译工具链
sudo apt install gcc-arm-linux-gnueabihf

# 确保 third_party/linux 子模块已初始化
git submodule update --init third_party/linux

# 进入示例目录构建
cd example/<示例名>
make
```

**用户态示例**（kernel_base_ds）使用 CMake：

```bash
cd example/kernel_base_ds
mkdir -p build && cd build
cmake ..
make
./penguin_example
```
