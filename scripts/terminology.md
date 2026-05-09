# PenguinLab Terminology Glossary

> Linux kernel / embedded systems Chinese-to-English terminology reference.
> Used by `scripts/translate.py` for consistent technical translations.

| English | Chinese | Notes |
|---------|---------|-------|
| Kernel Module | 内核模块 | |
| Character Device | 字符设备 | |
| Block Device | 块设备 | |
| Network Device | 网络设备 | |
| Device Tree | 设备树 | |
| Device Tree Source (DTS) | 设备树源文件 | |
| Platform Driver | 平台驱动 | |
| Interrupt | 中断 | |
| Interrupt Handler | 中断处理函数 | |
| Interrupt Context | 中断上下文 | |
| Top Half | 上半部 | Interrupt handling |
| Bottom Half | 下半部 | Interrupt handling |
| Softirq | 软中断 | |
| Tasklet | tasklet | |
| Workqueue | 工作队列 | |
| Threaded Interrupt | 线程化中断 | |
| Scheduler | 调度器 | |
| Completely Fair Scheduler (CFS) | 完全公平调度器 | |
| Scheduling Entity | 调度实体 | |
| Virtual Runtime (vruntime) | 虚拟运行时间 | |
| Run Queue | 运行队列 | |
| Context Switch | 上下文切换 | |
| Process | 进程 | |
| Thread | 线程 | |
| Task Structure (task_struct) | 任务结构体 | |
| Process Descriptor | 进程描述符 | |
| Memory Management | 内存管理 | |
| Page Frame | 页帧 | |
| Page Table | 页表 | |
| Buddy System | 伙伴系统 | |
| Slab Allocator | Slab 分配器 | |
| Slub Allocator | Slub 分配器 | |
| Slob Allocator | Slob 分配器 | |
| Page Cache | 页缓存 | |
| Page Reclaim | 页面回收 | |
| Swap | 交换空间 | |
| Memory Mapping | 内存映射 | |
| Virtual Memory Area (VMA) | 虚拟内存区域 | |
| kmalloc | kmalloc | Keep as-is |
| vmalloc | vmalloc | Keep as-is |
| Filesystem | 文件系统 | |
| Virtual File System (VFS) | 虚拟文件系统 | |
| Superblock | 超级块 | |
| Inode | 索引节点 | |
| Dentry | 目录项 | |
| File Operations (file_operations) | 文件操作 | |
| Mount | 挂载 | |
| Root Filesystem | 根文件系统 | |
| Network Stack | 网络协议栈 | |
| Socket | 套接字 | |
| Network Device Driver | 网络设备驱动 | |
| Netfilter | Netfilter | Keep as-is |
| sk_buff | sk_buff | Keep as-is |
| Spinlock | 自旋锁 | |
| Mutex | 互斥锁 | |
| Semaphore | 信号量 | |
| Read-Copy Update (RCU) | 读-拷贝更新 | |
| Atomic Operation | 原子操作 | |
| Memory Barrier | 内存屏障 | |
| Completion | 完成量 | |
| ftrace | ftrace | Keep as-is |
| perf | perf | Keep as-is |
| eBPF | eBPF | Keep as-is |
| kprobes | kprobes | Keep as-is |
| printk | printk | Keep as-is |
| dmesg | dmesg | Keep as-is |
| Cross-compilation | 交叉编译 | |
| Toolchain | 工具链 | |
| Bootloader | 引导加载程序 | |
| U-Boot | U-Boot | Keep as-is |
| Buildroot | Buildroot | Keep as-is |
| Yocto | Yocto | Keep as-is |
| Board Support Package (BSP) | 板级支持包 | |
| Rootfs | 根文件系统 | |
| BusyBox | BusyBox | Keep as-is |
| QEMU | QEMU | Keep as-is |
| Kernel Configuration | 内核配置 | |
| defconfig | defconfig | Keep as-is |
| Kconfig | Kconfig | Keep as-is |
| Makefile | Makefile | Keep as-is |
| Kbuild | Kbuild | Keep as-is |
| initcall | initcall | Keep as-is |
| Sysfs | sysfs | Keep as-is |
| Procfs | procfs | Keep as-is |
| Debugfs | debugfs | Keep as-is |
| IOCTL | ioctl | Keep as-is |
| Memory-Mapped I/O (MMIO) | 内存映射 I/O | |
| Port-Mapped I/O (PMIO) | 端口映射 I/O | |
| Direct Memory Access (DMA) | 直接内存访问 | |
| General-Purpose I/O (GPIO) | 通用输入输出 | |
| I2C | I2C | Keep as-is |
| SPI | SPI | Keep as-is |
| UART | UART | Keep as-is |
| USB | USB | Keep as-is |
| PCI/PCIe | PCI/PCIe | Keep as-is |
| Generic Interrupt Controller (GIC) | 通用中断控制器 | |
| ARM | ARM | Keep as-is |
| RISC-V | RISC-V | Keep as-is |
| x86_64 | x86_64 | Keep as-is |
| Virtualization | 虚拟化 | |
| Hypervisor | Hypervisor | Keep as-is |
| KVM | KVM | Keep as-is |
| Container | 容器 | |
| Namespace | 命名空间 | |
| cgroup | cgroup | Keep as-is |
| Merge Window | 合并窗口 | |
| Patch | 补丁 | |
| Commit | 提交 | |
| Mainline Kernel | 主线内核 | |
| Stable Kernel | 稳定版内核 | |
| Long-Term Support (LTS) | 长期支持 | |
| Linux Kernel Mailing List (LKML) | Linux 内核邮件列表 | |
