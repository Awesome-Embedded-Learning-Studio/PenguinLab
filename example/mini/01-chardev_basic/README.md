# 01-chardev_basic — 最小 misc 字符设备

> 配套教程：[字符设备驱动：用户态通往内核的门](../../../document/tutorials/drivers/01-drv-chardev.md)
> 对应进度节点：`drv-chardev`（layer-2）

## 这个示例做什么

注册一个 **misc 字符设备** `/dev/llkd_miscdrv`：内核里存一句"秘密"，
用户态 `cat` 读出来、`echo` 写进去。麻雀虽小，字符设备的全套骨架都在：

- `struct miscdevice` + `misc_register()` 一把注册（内部替你走完
  申请主号 + cdev 注册 + 建节点 三步）
- `file_operations` 四件套：`.open/.read/.write/.release`，加
  `.llseek = no_llseek` + `nonseekable_open()`（不可 seek）
- `copy_to_user` / `copy_from_user` 搬数据，**写时先判 `count > MAXBYTES`
  返回 `-EFBIG`** —— 严守"边界检查是驱动作者的命"那条安全红线
- `mutex` 保护内核缓冲区的并发读写；`read` 用 `*off` 驱动，让 `cat` 能正常退出

## 编译

```bash
# 默认 arm64，KDIR 指向 out/build_latest_arm64（需先编译过内核树）
cd example/mini/01-chardev_basic
make
# 换架构：
make ARCH=riscv
make ARCH=x86_64   # KDIR 会指向宿主内核 /lib/modules/$(uname -r)/build
```

产出 `chardev.ko`。

## 亲测（QEMU ARM64，2026-06-27 实测）

用 9p 共享目录热加载（见 foundations/08），进 QEMU 后：

```bash
insmod chardev.ko                          # dmesg: registered, initial secret = '<empty>'
ls -l /dev/llkd_miscdrv                    # devtmpfs 自动建节点(主 10, 次号动态)
echo "hello kernel" > /dev/llkd_miscdrv    # dmesg: write() 13 bytes
cat /dev/llkd_miscdrv                      # 读出 hello kernel
head -c 200 /dev/urandom > /dev/llkd_miscdrv   # write 返回 -EFBIG
rmmod chardev                              # dmesg: deregistered
```

实测输出（2026-06-27）：

```
crw-rw-rw- 1 0 0 10, 258 Jun 27 06:13 /dev/llkd_miscdrv   # 次号 258 > 255(MISC_DYNAMIC_MINOR 池)
[  15.254708] llkd_miscdrv: registered, initial secret = '<empty>'
[  15.317594] llkd_miscdrv: write() 13 bytes: hello kernel
[  15.361878] llkd_miscdrv: read() 13 bytes
head: standard output: File too large                      # -EFBIG 边界检查生效
[  15.477817] llkd_miscdrv: deregistered
```

## 文件

| 文件 | 说明 |
|------|------|
| `chardev.c` | misc 字符设备实现：fops 四件套 + copy_*_user 边界检查 + mutex + *off 读驱动 |
| `Makefile` | `obj-m += chardev.o`，include `../../common/Makefile.arch` |
