# mutex_spinlock — 互斥锁与自旋锁对比

对比 `mutex` 和 `spinlock` 的使用场景：mutex 可以睡眠适合长持有，spinlock 忙等待必须用于原子上下文。

## 构建

```bash
cd example/mini/mutex_spinlock
make
```

## 测试

```bash
insmod mutex_spinlock.ko
dmesg | tail -10
rmmod mutex_spinlock
```

## 学习要点

- `DEFINE_MUTEX` / `DEFINE_SPINLOCK` 静态定义锁
- `mutex_lock` / `mutex_unlock` — 可睡眠的互斥锁
- `spin_lock` / `spin_unlock` — 忙等待的自旋锁
- **关键区别**：mutex 持有期间可以调用 `msleep`/`copy_from_user` 等可能睡眠的函数；spinlock 持有期间**禁止**睡眠
