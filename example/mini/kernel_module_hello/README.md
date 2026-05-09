# kernel_module_hello — 最简内核模块

最简单的可加载内核模块，演示 `module_init`/`module_exit`、`MODULE_LICENSE`、`pr_info`。

## 构建

```bash
cd example/mini/kernel_module_hello
make
# 或指定架构
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```

## 测试

```bash
insmod hello.ko
dmesg | tail -5
rmmod hello
```
