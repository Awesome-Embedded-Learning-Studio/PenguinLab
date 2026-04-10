# kernel_module — 内核模块基础示例

对应教程：`todo/week2/day08-09_内核模块基础设计.md`

## 包含的示例

| 文件 | 说明 |
|------|------|
| `hello.c` | 最小内核模块，演示 `module_init`/`module_exit`、`module_param`、`pr_info` |
| `sym_export_a.c` | 符号导出提供者，用 `EXPORT_SYMBOL_GPL` 导出 `my_add` |
| `sym_export_b.c` | 符号导出消费者，调用 `my_add` 并打印结果 |

## 构建方法

```bash
# 确保已初始化 third_party/linux 子模块
cd example/kernel_module
make

# 如需指定架构和工具链
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```

## 在 QEMU 中测试

```bash
# 将 .ko 文件打包进 initramfs，启动 QEMU
insmod hello.ko count=3
dmesg | tail -10
rmmod hello

# 符号导出测试：先加载 a 再加载 b
insmod sym_export_a.ko
insmod sym_export_b.ko
dmesg | grep my_add
rmmod sym_export_b
rmmod sym_export_a
```

## 练习

- [ ] 修改 `count` 参数，验证 dmesg 输出
- [ ] 尝试先 insmod `sym_export_b.ko`（不加载 a），观察错误信息
- [ ] 将 `sym_export_b.c` 的 LICENSE 改为 `"Proprietary"`，观察 tainted 警告
