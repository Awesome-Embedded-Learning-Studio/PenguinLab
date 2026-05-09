# kernel_module_params — 内核模块参数

演示 `module_param`、`module_param_array` 的用法，包括 int、charp 和数组类型参数。

## 构建

```bash
cd example/mini/kernel_module_params
make
```

## 测试

```bash
insmod params.ko count=3 name="World"
dmesg | tail -10
rmmod params

# 数组参数
insmod params.ko values=10,20,30
dmesg | tail -10
rmmod params
```
