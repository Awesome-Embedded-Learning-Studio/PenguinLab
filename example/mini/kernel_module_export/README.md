# kernel_module_export — 符号导出与依赖

演示 `EXPORT_SYMBOL_GPL` 的使用：模块 A 导出符号，模块 B 引用。

## 构建

```bash
cd example/mini/kernel_module_export
make
```

## 测试

```bash
# 必须先加载 A（提供符号），再加载 B（使用符号）
insmod sym_export_a.ko
insmod sym_export_b.ko
dmesg | grep my_add
# 应该看到：my_add(3, 4) = 7

rmmod sym_export_b
rmmod sym_export_a
```

## 练习

- 尝试先 `insmod sym_export_b.ko`（不加载 A），观察 "Unknown symbol" 错误
- 将 `sym_export_b.c` 的 LICENSE 改为 `"Proprietary"`，观察 tainted 警告
