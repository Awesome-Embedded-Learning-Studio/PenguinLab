# chardev_basic — 字符设备驱动

完整字符设备驱动：动态设备号、cdev、file_operations、mutex、自动创建 `/dev` 节点。

## 构建

```bash
cd example/mini/chardev_basic
make
```

## 测试

```bash
insmod chardev.ko
dmesg | tail -5
ls -la /dev/mychardev
./test_chardev
rmmod chardev
```

## 学习要点

- `alloc_chrdev_region` vs `register_chrdev_region`
- `cdev_init` + `cdev_add`（现代做法，替代 `register_chrdev`）
- `copy_to_user` / `copy_from_user`
- `container_of` 获取设备私有数据
- 错误处理路径的 `goto` 链式清理
