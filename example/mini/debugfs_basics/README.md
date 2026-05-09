# debugfs_basics — debugfs 调试文件系统

演示 `debugfs` 创建调试目录、u32 计数器和自定义读写文件。

## 构建

```bash
cd example/mini/debugfs_basics
make
```

## 测试

```bash
insmod debugfs_demo.ko

# 查看计数器
cat /sys/kernel/debug/penguin_debug/counter
# 输出: 0

# 递增计数器
echo 5 > /sys/kernel/debug/penguin_debug/counter
cat /sys/kernel/debug/penguin_debug/counter
# 输出: 5

# 读写消息
cat /sys/kernel/debug/penguin_debug/message
echo "New message" > /sys/kernel/debug/penguin_debug/message
cat /sys/kernel/debug/penguin_debug/message

rmmod debugfs_demo
```

## 学习要点

- `debugfs_create_dir` 创建调试目录
- `debugfs_create_u32` 创建整数文件
- `debugfs_create_file` 创建自定义 file_operations 文件
- `simple_read_from_buffer` / `simple_write_to_buffer`
- `debugfs_remove_recursive` 清理
