# 02-ioctl — 在 chardev 上扩展结构化命令通道

> 配套教程：[ioctl：结构化的内核-用户命令通道](../../../document/tutorials/drivers/02-drv-ioctl.md)
> 对应进度节点：`drv-ioctl`（layer-2）
> 前置示例：[01-chardev_basic](../01-chardev_basic/)

## 这个示例做什么

上一篇 chardev 用 `read`/`write` 搬字节流；本篇给设备接上 **ioctl**——一次调用 = 一个命令码 + 一个参数，命令码自带"参数怎么传"的元数据。演示要点：

- **内核/用户共用一份命令定义头** `ioctl_cmd.h`（`_IOWR('k', 1, struct drv_status)` 编码命令）
- `.unlocked_ioctl` 里 `switch(cmd)`：
  - `IOC_GETSTATUS`（`_IOWR`）—— `copy_from_user` 收参 + 填状态 + `copy_to_user` 回填
  - `IOC_RESET`（`_IO`）—— 无参数重置
  - `default` —— 返 `-ENOTTY`（**不认识的命令必须拒，绝不放行**）
- `.compat_ioctl = compat_ptr_ioctl`（struct 布局 32/64 兼容，复用通用实现）
- `copy_to_user` 在锁外调用（它可能睡眠，不能持 mutex 时用）

## 文件

| 文件 | 说明 |
|------|------|
| `ioctl_cmd.h` | **内核/用户共享**的命令定义：`struct drv_status` + `IOC_GETSTATUS`/`IOC_RESET` 宏 |
| `ioctl.c` | 内核模块：misc 设备 + `.unlocked_ioctl`（switch + copy_*_user）+ compat_ptr_ioctl |
| `ioctl_user.c` | 用户态测试程序：`ioctl(fd, IOC_GETSTATUS, &st)` 读状态、`IOC_RESET` 重置 |
| `Makefile` | `obj-m += ioctl.o`；`make` 出模块，`make user` 出用户态程序 |

## 编译

```bash
cd example/mini/02-ioctl
make             # 编内核模块 ioctl.ko（默认 arm64）
make user        # 交叉编译用户态测试程序（静态链接）
```

## 亲测（QEMU ARM64，2026-06-27 实测）

把 `ioctl.ko` 和 `ioctl_user` 丢进 rootfs（或用 9p 共享目录），进 QEMU 后：

```bash
insmod ioctl.ko
./ioctl_user
dmesg | tail
rmmod ioctl
```

实测输出（2026-06-27）：

```
[first ] open_count=1 ioctl_count=1 secret_len=7 secret='<empty>'
[reset ] open_count=1 ioctl_count=1 secret_len=7 secret='<empty>'
[  XX.XXXXXX] llkd_miscdrv: IOC_GETSTATUS open=1 ioctl=1
[  XX.XXXXXX] llkd_miscdrv: IOC_RESET done
```

> 注：`secret_len=7` 是 "<empty>" 那 7 个字符。`IOC_RESET` 把 `ioctl_count` 清零，但紧接着的 `GETSTATUS` 又把它 +1，所以仍显示 1。
> 进阶验证：用 `gcc -m32` 编译 32 位用户程序跑在 64 位内核上，验证 `compat_ptr_ioctl` 的指针规整（需 rootfs 有 32 位 libc）。
