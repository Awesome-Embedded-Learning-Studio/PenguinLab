# Example — 示例练习代码

每个子目录对应一个独立的可构建示例，包含源码、Makefile 和说明文档。

## 目录结构

```
example/
├── mini/          # 小型单概念演示
├── project/       # 综合项目（待填充）
└── common/        # 共享构建基础设施
```

## mini/ — 单概念示例

| 目录 | 说明 |
|------|------|
| [linked_list_kernel/](mini/linked_list_kernel/) | 内核侵入式链表的用户态实现 + 12 个测试用例 |
| [kernel_module_hello/](mini/kernel_module_hello/) | 最简内核模块：module_init/module_exit |
| [kernel_module_params/](mini/kernel_module_params/) | 内核模块参数：module_param、module_param_array |
| [kernel_module_export/](mini/kernel_module_export/) | 符号导出：EXPORT_SYMBOL_GPL、模块间依赖 |
| [chardev_basic/](mini/chardev_basic/) | 字符设备驱动：cdev、file_operations、mutex |
| [sysfs_attributes/](mini/sysfs_attributes/) | sysfs 属性：kobject、show/store 回调 |
| [debugfs_basics/](mini/debugfs_basics/) | debugfs 调试文件系统：u32、自定义读写 |
| [kthread_demo/](mini/kthread_demo/) | 内核线程：kthread_create/wake_up_process |
| [wait_queue_demo/](mini/wait_queue_demo/) | 等待队列：wait_event/wake_up |
| [mutex_spinlock/](mini/mutex_spinlock/) | 互斥锁与自旋锁对比 |
| [atomic_ops/](mini/atomic_ops/) | 原子操作：atomic_set/add/inc/cmpxchg |
| [workqueue_demo/](mini/workqueue_demo/) | 工作队列：create_workqueue/queue_work |

## 通用构建说明

**内核模块**需要交叉编译工具链和内核源码：

```bash
# 安装 ARM 交叉编译工具链
sudo apt install gcc-arm-linux-gnueabihf

# 确保 third_party/linux 子模块已初始化
git submodule update --init third_party/linux

# 进入示例目录构建
cd example/mini/<示例名>
make
# 或指定架构
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```

**用户态示例**（linked_list_kernel）使用 CMake：

```bash
cd example/mini/linked_list_kernel
mkdir -p build && cd build
cmake ..
make
./penguin_example
```

## common/ — 共享构建文件

| 文件 | 说明 |
|------|------|
| `Makefile.arch` | 架构检测、KDIR 路径、CROSS_COMPILE 设置 |
| `cross-compile.mk` | 各架构工具链定义（ARM32/ARM64/RISC-V/x86_64） |
