# chardev — 字符设备驱动示例

对应教程：`todo/week2/day10-11_字符设备驱动.md`

## 包含的文件

| 文件 | 说明 |
|------|------|
| `chardev.c` | 完整字符设备驱动：动态设备号、cdev、file_operations、mutex、class/device 自动创建 `/dev` 节点 |
| `test_chardev.c` | 用户态测试程序：open → write → lseek → read → 验证数据一致性 |
| `Makefile` | 驱动 + 测试程序的交叉编译 |

## 构建方法

```bash
cd example/chardev
make

# 如需指定架构和工具链
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```

## 在 QEMU 中测试

```bash
# 把 chardev.ko 和 test_chardev 打包进 initramfs，启动 QEMU
insmod chardev.ko
dmesg | tail -5                  # 确认主设备号
ls -la /dev/mychardev            # 确认设备节点存在
./test_chardev                   # 验证写入读出

# 手动测试
echo "test" > /dev/mychardev
cat /dev/mychardev

rmmod chardev
```

## 学习要点

- `alloc_chrdev_region` vs `register_chrdev_region`（动态 vs 静态设备号）
- `cdev_init` + `cdev_add` 体系（现代做法，替代老式 `register_chrdev`）
- `copy_to_user` / `copy_from_user`（不能直接 dereference 用户指针）
- `container_of` 在 `open` 中获取设备私有数据
- `mutex_lock_interruptible` 处理信号中断
- 错误处理路径的 `goto` 链式清理模式

## 练习

- [ ] 用 `cat /proc/devices` 查看动态分配的主设备号
- [ ] 修改 BUF_SIZE，测试写入超过缓冲区大小的情况
- [ ] 在 `chardev_read` 中故意去掉 `mutex_lock`，用两个进程并发读写，观察竞争
