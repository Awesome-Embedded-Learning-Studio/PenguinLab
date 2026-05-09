# sysfs_attributes — sysfs 属性

演示通过 `kobject` 在 `/sys/kernel/` 下创建可读写属性文件。

## 构建

```bash
cd example/mini/sysfs_attributes
make
```

## 测试

```bash
insmod sysfs_demo.ko

# 读取属性
cat /sys/kernel/penguin/value
# 输出: 42

# 写入属性
echo 100 > /sys/kernel/penguin/value
cat /sys/kernel/penguin/value
# 输出: 100

dmesg | tail -5
rmmod sysfs_demo
```

## 学习要点

- `kobject_create_and_add` 创建内核对象
- `__ATTR` 定义 show/store 回调
- `sysfs_create_file` 注册属性
- `kstrtoint` 安全转换用户输入
