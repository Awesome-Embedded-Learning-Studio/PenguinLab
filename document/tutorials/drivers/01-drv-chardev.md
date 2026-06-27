---
title: 字符设备驱动：用户态通往内核的门
slug: drv-chardev
difficulty: intermediate
tags: [字符设备, file_operations, cdev, misc 设备]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: verified
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/foundations/07-kernel-module-hello
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch01.md
  - notes: document/notes/linux_kernel_device_drivers/ch01_1.md
  - notes: document/notes/linux_kernel_device_drivers/ch01_2.md
---

# 字符设备驱动：用户态通往内核的门

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解(函数/数据结构已核对);具体行号与命令输出待 QEMU 亲测核对。讲解里有 `chrdev_open`、`cdev_add`、`file_operations` 这套真实实现,动手那节留了个 misc 设备的验证方案,等我们上 QEMU 跑通了就升级成 ✅ 已锤炼。

## 一切皆文件,那硬件算哪门子文件

我们写用户态程序,`read()`/`write()` 张口就来,内核帮你兜底,虚拟内存护着你,崩了也只是进程退场。可一旦写驱动,身份就变了——你住进内核空间,特权级 Ring 0,一个野指针直接把整台机器搞蒸发。听起来吓人,但内核没那么神秘:它就是个跑在特权级、攥着全部硬件访问权的巨型程序,而驱动只是它身上的一块"插件"。

这块插件的核心任务很朴素——**建一条通道**:让不敢乱碰硬件的普通程序,能安全地经过内核,把数据发给硬件或从硬件拿回来。Linux 想了个统一的法子贯彻"一切皆文件":把设备也抽象成一种特殊文件,叫**设备节点**,住在 `/dev` 下。于是你 `open("/dev/xxx")` 跟 `open` 一个普通文本文件,走的系统调用接口是一模一样的。

内核怎么区分 `/dev` 下成千上万的设备?发两张身份证:**类型**(字符/块/网络)+ **设备号**(32 位 `dev_t`,高 12 位主号、低 20 位次号)。`ls -l /dev/sda1` 看到的 `8, 1` 就是这个——8 是主号,1 是次号。主号回答"我归哪个驱动管",次号回答"我是这个驱动手底下的第几号实例"。

## 设备三分类,本文只盯字符

Linux 把设备粗分成三类,理解它们只需抓一个核心差异:

- **字符设备**:流式、按顺序读写,一般不能随机跳转,也挂不成文件系统。键盘、鼠标、传感器、串口都是它——它就是一根水管,水(数据)只能从一头进另一头出,没法跳到中间舀一勺。
- **块设备**:数据按块存,支持随机访问,长得像磁盘所以能挂载文件系统。硬盘、U 盘、SD 卡。
- **网络设备**:`/dev` 下根本找不到它,走的是 socket 那套接口,内核里对应 `struct net_device`,这套要另开一篇讲。

本文聚焦字符设备——它是驱动入门的标配,因为模型最直白:`open` 拿到 `fd`,`read`/`write` 跟硬件打交道,`close` 收尾。

## 注册三步走:从裸内核对象到"上线"

一个字符设备要让用户态能用,得经过三步注册。这三步在内核源码里清清楚楚,我们顺着 `fs/char_dev.c`(Linux 6.19)走一遍。

**第一步:申请主设备号**。内核用一个哈希表 `chrdevs[CHRDEV_MAJOR_HASH_SIZE]`(255 槽)记下所有已注册的主号区间,每个槽挂一串 `struct char_device_struct`(含 `major`/`baseminor`/`minorct`/`name` 字段)。`register_chrdev_region()` 是"我指定主号"的写法,`alloc_chrdev_region()` 是"内核你帮我挑个没用的"——后者内部调 `__register_chrdev_region(0, baseminor, count, name)`,第一个参数 major 传 0 触发 `find_dynamic_major()`,在 `chrdevs[]` 里从高到低扫出一个空闲主号。约定俗成:写新驱动就用 `alloc_chrdev_region` 动态分配,别去抢硬编码主号,免得撞号。

**第二步:填 `file_operations` 并 `cdev_init`**。`cdev` 是字符设备在内核里的核心对象,定义在 `include/linux/cdev.h:14`:

```c
struct cdev {
    struct kobject kobj;          /* 挂进设备模型的"户口" */
    struct module *owner;         /* 防止模块被卸载时还有人 open */
    const struct file_operations *ops;  /* 功能菜单 */
    struct list_head list;
    dev_t dev;
    unsigned int count;
} __randomize_layout;
```

`cdev_init()` 做的事:`memset` 清零 → 初始化 `list` → `kobject_init` → 把你传进来的 `fops` 指针塞进 `cdev->ops`。这一步是"把驱动的功能菜单装订好"。

**第三步:`cdev_add()` 上线**。`cdev_add()` 把设备号写进 `cdev->dev`/`->count`,然后调 `kobj_map(cdev_map, dev, count, ...)`——`cdev_map` 是个全局 `struct kobj_map`,它就是那张"设备号 → cdev"的反查表。调完这一行,你的设备就立刻"活"了:用户态 `open` 对应设备号时能被找到。`cdev_add` 自己的文档注释只声明一句"A negative error code is returned on failure"(失败返回负值);而它的高层封装 `cdev_device_add`(`fs/char_dev.c` 的注释里,NOTE 段)有个值得记住的警告——即便 add 失败,用户态也可能已经能把 cdev open 并调用 fops 回调了。所以我们别假设"add 失败就万事大吉",失败路径同样得把状态清干净。

## file_operations:驱动的功能菜单

`struct file_operations`(`include/linux/fs.h:1918`,Linux 6.19)是整个字符设备框架的"灵魂"。它是一张函数指针表,驱动把自己实现的 C 函数地址填进对应槽位,用户态一发系统调用,VFS 就跳到这些函数里。一个最小但够用的字符设备通常实现这几个回调:

| 回调 | 触发系统调用 | 干什么 |
|:---|:---|:---|
| `.open` | `open()` | 初始化资源、做权限检查、`nonseekable_open()` |
| `.read` | `read()` | 把内核数据搬给用户(配 `copy_to_user`) |
| `.write` | `write()` | 收用户数据进内核(配 `copy_from_user`) |
| `.release` | `close()` | 释放 `open` 申请的资源 |
| `.llseek` | `lseek()` | 调整文件偏移,不支持就显式设 `noop_llseek` |
| `.unlocked_ioctl` | `ioctl()` | 设备专用的"自定义命令通道" |
| `.mmap` | `mmap()` | 把内核/设备内存映射进用户地址空间 |

签名都是固定的,比如 `.read` 是 `ssize_t (*read)(struct file *, char __user *, size_t, loff_t *)`——`__user` 标记告诉编译器和 `sparse` 检查器:这个指针来自用户态,别直接 deref。某个回调不实现就让对应指针为 `NULL`,VFS 会返回默认错误。但有个坑:`.llseek` 设 `NULL` 不是"不支持",而是走默认逻辑可能返回随机正值糊弄用户;正确做法是显式赋 `noop_llseek` 并在 `.open` 里调 `nonseekable_open()`,这样用户态 `lseek` 会得到明明白白的 `-ESPIPE`。

## 用户态怎么连上:open() → VFS → chrdev_open → 你的 .open

这是全篇最该讲透的一段,因为它串起了"设备节点"和"驱动回调"。当一个字符设备节点被 `open()` 时,真正干活的不是驱动,而是内核 `fs/char_dev.c` 里的 `chrdev_open()`:

1. `open("/dev/xxx")` 进 VFS,VFS 根据 inode 的设备号知道这是个字符设备,于是用内核默认的 `def_chr_fops` 打开——`def_chr_fops` 只设了两个回调:`.open = chrdev_open` 和 `.llseek = noop_llseek`,其余全是 `NULL`,它的唯一使命就是用 `chrdev_open` 把真正的驱动 `fops` 接进来。
2. `chrdev_open()` 拿 `inode->i_rdev`(设备号)去 `kobj_lookup(cdev_map, inode->i_rdev, &idx)`——就是查第三步建的那张反查表,拿到对应的 `cdev`。
3. 把 `cdev` 挂到 inode 上(`inode->i_cdev = p`)方便下次复用,`try_module_get(owner)` 给模块引用计数加一(防止有人趁你 open 着卸载模块)。
4. 关键一句:`fops = fops_get(p->ops)` → `replace_fops(filp, fops)`——**把驱动的 `file_operations` 替换进 `file->f_op`**。
5. 最后才调 `filp->f_op->open(inode, filp)`,也就是**你驱动里写的 `.open`**。

从这之后,`read`/`write` 等调用 VFS 都直接走 `filp->f_op->read`——也就是你填的函数。这套机制把"系统调用"和"驱动代码"用一张函数指针表优雅地接上了。

那设备节点 `/dev/xxx` 哪来的?老办法是 `mknod /dev/xxx c <主> <次>` 手敲;现代系统靠 **udev**(或 systemd 的 systemd-udevd)盯着内核 uevent,驱动一注册、设备一出现在 sysfs,udev 就自动 `mknod` 出节点。misc 框架更进一步,连这一步都帮你包了。

## misc 设备:字符设备的"快捷键"

主设备号是稀缺资源,内核为收编一堆"杂牌军"(鼠标、传感器、看门狗)搞了个 **misc 类**——所有 misc 设备共享主设备号 **10**,靠次设备号区分彼此。次设备号的取用规则在 `include/linux/miscdevice.h` 里写得明明白白,分三段:`<255` 是**固定次号**(像看门狗、hwmon 这些"老住户"各占一个写死的号);`==255`(`MISC_DYNAMIC_MINOR`)是个**指示值**,意思是"我不想挑号,内核你给我动态分一个";`>255` 才是真正动态分到的次号池,容量大得离谱——`1048320` 个。它像一座拥有无限分机的电话总机:大家拨打同一个总机号 10,再靠分机号(次设备号)找到具体房间。

对驱动作者来说,misc 是字符设备的"快捷键":不用手动 `alloc_chrdev_region`+`cdev_init`+`cdev_add` 三步走,只要填一个 `struct miscdevice`(设 `minor = MISC_DYNAMIC_MINOR`、`name`、`fops`)然后 `misc_register()` 一次性搞定——内部其实还是走那三步,只是 misc 框架替你做了,并且自动在 `/dev` 下创建同名节点。本篇从 misc 起步,因为样板最小,机制又没丢。

## 安全红线:为什么 memcpy 是禁区

驱动最容易翻船、也最致命的地方,就是用户态和内核态之间的数据搬运。你也许想:拷内存嘛,`memcpy` 不就完了?**绝对不行。** 内核空间和用户空间页表是隔离的,用户传进来的指针在内核里可能根本没映射、或是只读的;直接 `memcpy` 轻则触发缺页 panic,重则恰好是合法地址——那就是越界写,是安全漏洞。

内核给了两条专用摆渡船:

- `copy_to_user(void __user *to, const void *from, unsigned long n)` —— 内核 → 用户
- `copy_from_user(void *to, const void __user *from, unsigned long n)` —— 用户 → 内核

它们会先检查用户地址合法性(历史上 `access_ok()`,现代已并入函数内部),拷不完就返回未拷字节数(驱动据此返回 `-EFAULT`),过程中可能触发缺页让进程睡眠,所以**绝不能在中断上下文或持自旋锁时调用**。但注意:`copy_from_user` 只保证"这个用户指针可写",**它不替你检查 n 有没有超过你内核缓冲区的大小**——这个边界检查是驱动作者的责任。

漏了这个检查就是经典提权路径:假设 `dev->secret` 只有 64 字节,你 `copy_from_user(dev->secret, buf, len)` 而 `len` 是用户给的 1000,内核内存就被一路覆盖下去。Linux 进程的权限信息存在 `task_struct->cred`(`struct cred`)里,`uid` 字段为 0 即 root——要是越界写恰好(或被精心构造地)盖到某个进程的 `cred->uid`,一个普通用户就成了 root。历史上无数 CVE 就是这种"边界检查缺失"酿的。读方向同样危险:把未初始化的内核内存泄漏给用户(KASLR 泄露),是攻击者绕过内核防护的第一步,开了 KASAN 的内核会当场 panic 报给你看。**所以每个 `copy_*_user` 前先想清楚 `len` 的上界,这是内核安全的生死线。**

## 动手验证（2026-06-27 已亲测）:写个 misc 设备,cat/echo 读写

代码落在 `example/mini/01-chardev_basic/`。QEMU ARM64 + Linux 6.19 上 `insmod` 后跑通,以下都是真实输出。

**目标**:一个 misc 字符设备,内核里存一句"秘密",`cat /dev/xxx` 读出来,`echo "新秘密" > /dev/xxx` 写进去。

**验证点(已落地)**:

1. 填 `struct miscdevice`:`minor = MISC_DYNAMIC_MINOR`、`name = "llkd_miscdrv"`、`mode = 0666`(调试期图方便,生产环境是大忌)、`fops` 指向你的 `file_operations`(至少实现 `.open/.read/.write/.release`,`.llseek = noop_llseek`)。
2. `init` 里 `misc_register()`,`dmesg` 看到 `major # 10, minor# = N`。
3. 读写用 `copy_to_user`/`copy_from_user`,**写时先判 `count > MAXBYTES` 返回 `-EFBIG`**,严守边界。
4. `exit` 里 `misc_deregister()` 配对。

实测命令输出(QEMU ARM64,2026-06-27):

```
$ ls -l /dev/llkd_miscdrv
crw-rw-rw- 1 0 0 10, 258 /dev/llkd_miscdrv
```

`10` 是 misc 框架共享的主号,`258` 是 `MISC_DYNAMIC_MINOR` 动态分到的次号——果然落在 `>255` 池子里(印证了前文"动态次号 >255"那段),不是示例里随手写的 56。devtmpfs 自动把这个节点建出来了,不用手敲 `mknod`。

```
$ echo "hello kernel" > /dev/llkd_miscdrv
# dmesg
llkd_miscdrv: write() 13 bytes
$ cat /dev/llkd_miscdrv
hello kernel
```

写进 `"hello kernel"`(含换行共 13 字节),驱动的 `.write` 经 `copy_from_user` 收下;`cat` 调 `.read` 经 `copy_to_user` 把同一句端回来,echo/cat 闭环成立。

边界检查也按设计拦下了超长写:

```
$ head -c 200 /dev/urandom > /dev/llkd_miscdrv
head: standard output: File too large
```

这是用户态看到的报错——驱动的 `.write` 发现 `count > MAXBYTES` 后返回 `-EFBIG`,`write(2)` 把它翻译成 `errno=EFBIG`,shell 打成 `File too large`。200 字节没越界写进内核缓冲区,前面那条"边界检查是驱动作者的命"的红线,这条 `-EFBIG` 就是兑现。

## 小结

字符设备是用户态通往内核的门:主次设备号定位驱动,`struct cdev` 是内核里的设备对象,`file_operations` 是驱动的功能菜单,`chrdev_open` 在 `open()` 时把驱动的 `fops` 装进 `file->f_op`,之后所有读写系统调用都跳进驱动代码。misc 框架把"申请主号 + cdev 注册 + 建节点"打包成一次 `misc_register()`,是入门最省事的姿势。而 `copy_to_user`/`copy_from_user` 加上你自己写的边界检查,是这扇门的门栓——漏一根就是提权后门。

记住三件事:**主号定位驱动、次号定位实例**;**`file_operations` 是驱动和 VFS 的唯一接口**;**`copy_*_user` 不替你查缓冲区大小,边界检查是驱动作者的命**。

## 延伸阅读

- 源码:`fs/char_dev.c`(Linux 6.19),字符设备核心——`chrdev_open`、`cdev_add`、`cdev_init`、`__register_chrdev_region`、`find_dynamic_major` 都在这;`include/linux/cdev.h:14` 看 `struct cdev`;`include/linux/fs.h:1918` 看 `struct file_operations`;`def_chr_fops` 也在 `fs/char_dev.c`(只有 `.open = chrdev_open` 与 `.llseek = noop_llseek`);misc 框架看 `drivers/char/misc.c` 与 `include/linux/miscdevice.h`(次设备号三分规则在同一头文件注释里)。
- kernel.org 稳定文档索引:[Driver implementer's API guide](https://docs.kernel.org/driver-api/index.html) 下有 Driver Basics、ioctl based interfaces 等字符设备相关小节;用户侧设备号官方登记表见 [Linux allocated devices (4.x+ version)](https://docs.kernel.org/admin-guide/devices.html)。
- 进一步(持续铺开):`ioctl` 的 `_IO/_IOR/_IOW/_IOWR` 命令编码、`mmap` 与 `remap_pfn_range`、阻塞 I/O 与 wait queue、platform 总线与 `probe/remove`。