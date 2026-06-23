---
title: ioctl：结构化的内核-用户命令通道
slug: drv-ioctl
difficulty: intermediate
tags: [字符设备, ioctl, 用户内核通信, 安全]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/drivers/01-drv-chardev
related:
  - /tutorials/drivers/01-drv-chardev
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch02_2.md
  - notes: document/notes/linux_kernel_device_drivers/ch02_3.md
---

# ioctl：结构化的内核-用户命令通道

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（`fs/ioctl.c`、`include/uapi/asm-generic/ioctl.h` 的函数/数据结构已逐行核对）。需要诚实说明：读书笔记里 ioctl 的正文章节是缺失的（ch02 只在通信全景里一笔带过，真正的机制正文没写），所以这篇以**源码为权威来源**，练习 2.5/2.6 的素材来自笔记 ch02_3。具体行号与命令输出待 QEMU 亲测核对。

上一篇我们用字符设备的 `read`/`write` 把数据在用户态和内核态之间搬来搬去。但很快就撞墙了：`read`/`write` 是一条**无类型的数据流水线**——它只认字节流，不认"命令"。你想对设备说"复位"、"换波特率"、"查一下当前状态结构体"，全靠约定俗成的字节序去解析，这就把驱动逼成了一个臃肿的协议解析器。

`ioctl`（I/O Control）就是给这条无类型流水线加上**结构化命令语义**的口子：一次调用 = 一个命令码 + 一个参数。它是最老牌的设备控制通道，也是最容易写成一团魔数黑盒的那个——所以我们不光讲怎么写，要把内核里这套命令通道的实现掰开看。

## ioctl 的接口形态

用户态的入口是 `ioctl(2)` 系统调用，原型 `int ioctl(int fd, unsigned long request, ...)`，第三个参数在内核侧统一收成一个 `unsigned long arg`。落到驱动这边，挂的是 `struct file_operations` 里的 `unlocked_ioctl`（Linux 6.19，`include/linux/fs.h:1930`）：

```c
long (*unlocked_ioctl) (struct file *, unsigned int, unsigned long);
long (*compat_ioctl)   (struct file *, unsigned int, unsigned long);
```

那个 `arg` 是个**双面人**：它可能是一个标量值（比如要把某个寄存器设成几），也可能是一个**用户空间指针**（指向一个结构体，驱动再 `copy_from_user` 拷进来）。到底是哪种，完全由 `cmd` 的语义决定——这就是为什么 `cmd` 必须自带"参数怎么传"的信息。

## cmd 的编码魔法：四个宏

`ioctl` 最容易被滥用成黑盒的根源，是早年大家随便挑个数字当命令码。Linux 后来钉死了一套编码方案，在 `include/uapi/asm-generic/ioctl.h`（Linux 6.19）里，把一个 32 位的 `cmd` 拆成四段：

| 字段 | 位宽 | 含义 |
|:---|:---:|:---|
| `_IOC_DIR`（方向） | 2 | NONE/READ/WRITE |
| `_IOC_SIZE`（参数大小） | 14 | 参数结构体字节数 |
| `_IOC_TYPE`（魔数） | 8 | 区分驱动家族的"姓氏" |
| `_IOC_NR`（序号） | 8 | 该家族下的命令编号 |

关键是位宽注释里那句大实话：参数大小塞进命令码，上限约 **16KB - 1**，"有用——能抓住用旧版头文件编译的程序，也能防止写越界用户缓冲"（`include/uapi/asm-generic/ioctl.h:12`）。也就是说，内核**从命令码本身**就能知道要拷多少字节、方向是哪边，这对后面做边界检查是免费的保险。

四个构造宏（同文件 `:85-88`）把上面四段打包：

```c
#define _IO(type,nr)            _IOC(_IOC_NONE,(type),(nr),0)
#define _IOR(type,nr,argtype)   _IOC(_IOC_READ, (type),(nr),(_IOC_TYPECHECK(argtype)))
#define _IOW(type,nr,argtype)   _IOC(_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(argtype)))
#define _IOWR(type,nr,argtype)  _IOC(_IOC_READ|_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(argtype)))
```

方向命名是个**坑**，源码注释专门强调（`include/uapi/asm-generic/ioctl.h:53-54` 与 `:82-83`）：`_IOW` 是"用户在写、内核在读"，`_IOR` 反过来。第一次接触必踩，记住"站在用户视角命名"就对了。

`_IOC_TYPECHECK(argtype)` 在用户态（`include/uapi/asm-generic/ioctl.h:75-77`，`#ifndef __KERNEL__` 块里）展开成 `sizeof(argtype)`，所以一旦你改了参数结构体大小，命令码自动变——用旧头文件的程序拿老码来调，驱动一眼就能识别不匹配（这正是练习 2.6 `ioctl_undoc` 那种"未文档化命令"要小心防护的场景）。

内核侧这道保险更硬：`include/asm-generic/ioctl.h`（内核专用副本，`:12-15`）把 `_IOC_TYPECHECK` 套进一个编译期检查——`sizeof(t) < (1 << _IOC_SIZEBITS)`，否则让符号解析成未定义的 `extern __invalid_size_argument_for_IOC`，直接**编译失败**。所以参数结构体超过 14 位 size 上限（>16383 字节）时，内核这侧连编都编不过——这是"塞 size 字段"在编码方案之外的又一道硬保险，和上面的 16KB-1 上限呼应。

**铁律：用户态和内核态共用同一份命令定义头**。把 `_IO*` 宏放进一个既能被用户程序 `#include`、又能被内核 `#include` 的头里（用 `#ifdef __KERNEL__` 分隔内核专用部分），保证两边算出来的 `cmd` 位级一致。否则你靠"手抄数字"，早晚抄错。

## VFS 层流程：do_vfs_ioctl → vfs_ioctl

用户态 `ioctl(2)` 一进来，先走 `SYSCALL_DEFINE3(ioctl, ...)`（`fs/ioctl.c:583`，Linux 6.19）。这条路径分两步，顺序很讲究：

```c
error = do_vfs_ioctl(fd_file(f), fd, cmd, arg);   // 内核"公共命令"先拦截
if (error == -ENOIOCTLCMD)
    error = vfs_ioctl(fd_file(f), cmd, arg);      // 没人认领，才转交驱动
```

`do_vfs_ioctl`（`fs/ioctl.c:492`）是个**公共命令总机**，它先用 `switch(cmd)` 截胡一批面向所有文件描述符的通用命令——`FIOCLEX`/`FIONCLEX`（设 close-on-exec）、`FIONBIO`（非阻塞）、`FIOASYNC`、`FIFREEZE`/`FITHAW`（冻结/解冻文件系统）、`FS_IOC_GETFLAGS`/`FS_IOC_SETFLAGS` 等等，这些命令**驱动不需要自己实现**。注意进总机前还有一道 `security_file_ioctl()`（`fs/ioctl.c:591`）——LSM（比如 SELinux）有权在这里把整次 ioctl 直接毙掉。

措辞要精确一点：`switch` 里那批是**面向所有 fd 的通用命令**，但行为并不对每种 fd 完全一致。`do_vfs_ioctl` 的 default 分支（`fs/ioctl.c:574-577`）在普通文件（`S_ISREG` 且非匿名文件）上还会把命令转交给 `file_ioctl()`（`:322`），后者处理 `FIBMAP`、`FIONREAD` 这类**受文件类型门控**的命令——换句话说，不是所有"公共命令"对任意 fd 行为都一样。

只有 `do_vfs_ioctl` 返回 `-ENOIOCTLCMD`（意思是"我不认识这个命令"），才轮到 `vfs_ioctl`（`:44`）把命令真正交给你驱动的 `.unlocked_ioctl`：

```c
static int vfs_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    int error = -ENOTTY;
    if (!filp->f_op->unlocked_ioctl)
        goto out;
    error = filp->f_op->unlocked_ioctl(filp, cmd, arg);
    if (error == -ENOIOCTLCMD)
        error = -ENOTTY;          // 驱动说不认识，统一翻译成 ENOTTY
    ...
}
```

这套两级分发的好处：公共功能内核替你兜了，驱动只管自己的私货；不认识的命令也别返回乱七八糟的码，`-ENOTTY`（"非终端设备"）是 ioctl"不认识此命令"的统一暗号。

## 参数传递：指针就得 copy_from_user

当 `arg` 实际是个用户指针时，驱动必须用 `copy_from_user`/`copy_to_user` 跨边界拷贝——这点和 `read`/`write` 一模一样，绝对不能直接解引用用户传来的指针（会 Oops，甚至被打穿成安全漏洞）。`ioctl_fiemap`（`fs/ioctl.c:199`）就是个教科书范例：先 `copy_from_user(&fiemap, ufiemap, sizeof(fiemap))` 把用户结构体搬进来，处理完再 `copy_to_user` 搬回去，两步都检查返回值，失败返回 `-EFAULT`。

对于单个标量，内核给了轻量包装：`get_user(x, ptr)` / `put_user(x, ptr)`，`ioctl_fibmap`（`fs/ioctl.c:58`，函数体内 `:68` 行 `get_user(ur_block, p)`）就是这么用的。

### 32 位进程跑 64 位内核：compat_ioctl

真正折磨人的是 32 位用户程序跑在 64 位内核上。指针大小、结构体对齐都对不上，原始 `unlocked_ioctl` 直接收到的 `arg` 是个被零扩展的 32 位指针，`copy_from_user` 会读到鬼地方去。内核为此准备了 `compat_ioctl`（`include/linux/fs.h:1931`）和一整套 `COMPAT_SYSCALL_DEFINE3(ioctl, ...)`（`fs/ioctl.c:638`）路径：它的 default 分支（`:688-690`）先把 `arg` 用 `compat_ptr()` 规整成正确的内核指针（在 s390 等架构上还会清最高位），再决定是直接转交 `do_vfs_ioctl`，还是调驱动的 `.compat_ioctl`（`:694`）。

内核还贴心提供了 `compat_ptr_ioctl`（`fs/ioctl.c:629`）这个通用实现——如果你的 ioctl 参数要么是无指针标量、要么是 32/64 位布局兼容的结构体，直接 `.compat_ioctl = compat_ptr_ioctl` 就够了，它会规整指针后转给你的 `unlocked_ioctl`。但凡有 `long`/指针/64 位字段混在结构体里，就必须手写 `compat_ioctl` 单独处理对齐。

## 安全：cmd 校验与边界检查

`ioctl` 的危险在于它太自由——一个不校验的 ioctl 就是个后门。踩坑笔记里反复强调的"未文档化命令"（练习 2.6 `ioctl_undoc`，见 `document/notes/linux_kernel_device_drivers/ch02_3.md`）正是攻击面：用户可以塞任意 `cmd` 进来，驱动必须对**每一个不认识的 cmd 返回 `-ENOTTY`**，绝不能让 default 分支悄悄放行。

其次，`arg` 指向的用户缓冲区得做**边界检查**。`ioctl_file_dedupe_range`（`fs/ioctl.c:415`）的做法值得抄：先 `get_user` 读出 `count`，用 `struct_size` 算总大小，超 `PAGE_SIZE` 直接 `-ENOMEM` 拒绝，再用 `memdup_user` 一次性拷进来。涉及特权操作的（如 `ioctl_fsfreeze`）必须查 `capable(CAP_SYS_ADMIN)` / `ns_capable`，否则普通用户一句 ioctl 就把文件系统冻住了。

还有一道容易被忽略的保险：**命令编码里的 `_IOC_SIZE`**。驱动可以用 `_IOC_SIZE(cmd)` 取出"声明的大小"，和它实际要拷的结构体大小比对，不匹配就拒——这正是内核在编码方案里塞 size 字段的本意。

## 动手待亲测

我们会在 `example/mini/` 下落一个 ioctl demo，目标清单：

- 用 `_IOWR` 编码一个命令，比如 `#define IOC_GETSTATUS _IOWR('k', 1, struct drv_status)`，魔数 `'k'`，参数结构体含几个字段。
- 驱动 `unlocked_ioctl` 里 `switch(cmd)`，命中时 `copy_from_user` 收参数、处理、`copy_to_user` 回填；default 返 `-ENOTTY`。
- 用户态 C 程序 `ioctl(fd, IOC_GETSTATUS, &st)` 调用，打印结构体。
- 故意用 32 位编译的用户程序（`gcc -m32`）跑在 64 位内核上，验证不写 `compat_ioctl` 会怎样，再补上。

> ⚠️ **待亲测**：上面命令输出、`dmesg` 现象、32/64 位兼容的实测结果，都要拿到 QEMU ARM64/x86_64 上跑一遍记下来，回头把这一节从占位升级成真实记录。

## 小结

`ioctl` 给无类型的 `read`/`write` 流水线接上了结构化命令通道：一个 `cmd` 用四段编码（方向 + 大小 + 魔数 + 序号）自带"怎么传参数"的元数据，内核从 `SYSCALL_DEFINE3(ioctl)` 经 `do_vfs_ioctl`（公共命令总机）两级分发到驱动的 `unlocked_ioctl`。参数是指针时老老实实 `copy_from_user`/`copy_to_user`；32/64 位混跑要靠 `compat_ioctl`（或 `compat_ptr_ioctl`）规整指针；安全上每个 cmd 都得校验、不认识的返 `-ENOTTY`、特权操作查 capability、用户缓冲区做边界检查。

记住一句话：ioctl 的自由度是它的力量，也是它的债务——编码方案和校验纪律，就是还债的账本。

## 延伸阅读

- 源码：`fs/ioctl.c`（Linux 6.19），`SYSCALL_DEFINE3(ioctl`（`:583`）/ `do_vfs_ioctl`（`:492`）/ `vfs_ioctl`（`:44`）/ `compat_ptr_ioctl`（`:629`）全在这；`include/uapi/asm-generic/ioctl.h` 看 `_IO*` 宏与编码位布局；`include/asm-generic/ioctl.h`（内核副本，`:12-15`）看 `_IOC_TYPECHECK` 的编译期 size 上限断言；`include/linux/fs.h:1930` 看 `struct file_operations` 的 `unlocked_ioctl`/`compat_ioctl` 字段。
- kernel.org 文档（均经树内核 `Documentation/` 核实存在）：[ioctl based interfaces](https://docs.kernel.org/driver-api/ioctl.html)（`Documentation/driver-api/ioctl.rst`，讲命令编号约定、错误码、`_IOC_SIZE` 用法）、[(How to avoid) Botching up ioctls](https://docs.kernel.org/process/botching-up-ioctls.html)（`Documentation/process/botching-up-ioctls.rst`，Daniel Vetter 写的 ioctl 设计避坑经典）、[Decoding ioctl numbers](https://docs.kernel.org/userspace-api/ioctl/ioctl-decoding.html)（`Documentation/userspace-api/ioctl/ioctl-decoding.rst`）、[Linux Filesystems API summary](https://docs.kernel.org/filesystems/api-summary.html)（`Documentation/filesystems/api-summary.rst`）。
- man page：`ioctl(2)`、`ioctl_list(2)`——用户态接口语义与已知命令码清单。
- 进一步（持续铺开）：sysfs/debugfs/netlink 这几条兄弟通道的取舍，以及 64 位兼容的完整 `compat` 框架。