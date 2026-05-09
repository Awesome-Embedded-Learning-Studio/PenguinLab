# atomic_ops — 原子操作

演示 Linux 内核原子操作 API：`atomic_set`、`atomic_read`、`atomic_add`、`atomic_inc`、`atomic_cmpxchg`。

## 构建

```bash
cd example/mini/atomic_ops
make
```

## 测试

```bash
insmod atomic_demo.ko
dmesg | tail -10
rmmod atomic_demo
```

## 学习要点

- `ATOMIC_INIT` 初始化原子变量
- `atomic_set` / `atomic_read` 基础读写
- `atomic_add` / `atomic_sub` / `atomic_inc` / `atomic_dec` 算术操作
- `atomic_cmpxchg` 比较并交换（CAS，lock-free 编程基础）
- 原子操作不需要锁，适用于简单计数器场景
