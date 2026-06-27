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

> 命名约定：目录用 `NN-名称` 数字前缀按学习顺序排列（对齐站点教程排序）。
> 下表区分「已落地」与「规划中」——教程里若写"代码进 example/mini/"，以本表为准，落地后从规划区移入已落地。

### ✅ 已落地

| 目录 | 说明 | 对应教程 |
|------|------|----------|
| [00-kernel_module_hello/](mini/00-kernel_module_hello/) | 最简内核模块：module_init/module_exit | foundations/07、08 |
| [01-chardev_basic/](mini/01-chardev_basic/) | misc 字符设备：fops 四件套 + copy_*_user 边界检查 + mutex | drv-chardev |
| [02-ioctl/](mini/02-ioctl/) | 结构化命令通道：_IOWR/_IO 编码 + switch + compat_ptr_ioctl + 用户态测试程序 | drv-ioctl |
| [03-poll/](mini/03-poll/) | poll/select + 等待队列 + 阻塞 read：poll_wait + 掩码 + wake_up + O_NONBLOCK | drv-poll |
| [04-mmap/](mini/04-mmap/) | 设备内存映射：vm_insert_page 把一页内核 RAM 映射给用户态，双向读写验证 | drv-mmap |
| [05-irq/](mini/05-irq/) | 硬件中断：platform driver + 上半部 + 线程化 irq + workqueue 下半部（⚠️ 需设备树设备） | drv-irq |
| [06-debug-printk/](mini/06-debug-printk/) | printk 八级日志 + pr_xxx + pr_fmt 前缀 + pr_debug 默认隐藏 | debug-printk |
| [07-debug-oops/](mini/07-debug-oops/) | 故意 NULL 解引用触发 oops（trigger 门控），看栈/Code/Tainted | debug-oops |

### 📚 规划中（教程已写或在写，代码待落地）

| 计划目录 | 说明 | 对应节点 |
|----------|------|----------|
| `02-kernel_module_params` | 内核模块参数：module_param、module_param_array | kernel-module-params |
| `03-kernel_module_export` | 符号导出：EXPORT_SYMBOL_GPL、模块间依赖 | kernel-module-basics |
| `04-sysfs_attributes` | sysfs 属性：kobject、show/store 回调 | （待补节点） |
| `05-debugfs_basics` | debugfs 调试文件系统：u32、自定义读写 | （待补节点） |
| `06-kthread_demo` | 内核线程：kthread_create/wake_up_process | （待补节点） |
| `07-wait_queue_demo` | 等待队列：wait_event/wake_up | （待补节点） |
| `08-mutex_spinlock` | 互斥锁与自旋锁对比 | drv-sync |
| `09-atomic_ops` | 原子操作：atomic_set/add/inc/cmpxchg | drv-atomic |
| `10-workqueue_demo` | 工作队列：create_workqueue/queue_work | （待补节点） |
| `linked_list_kernel` | 内核侵入式链表的用户态实现 + 12 个测试用例 | （独立，CMake 用户态） |

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
