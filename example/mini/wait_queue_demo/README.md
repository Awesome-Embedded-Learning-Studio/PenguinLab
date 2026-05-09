# wait_queue_demo — 等待队列

演示 `wait_event_interruptible`/`wake_up_interruptible` 实现线程间同步。

## 构建

```bash
cd example/mini/wait_queue_demo
make
```

## 测试

```bash
insmod wait_queue_demo.ko
# 等待约 3 秒后观察 dmesg
dmesg | tail -10
# 应该看到 waiter 线程先睡眠，然后被唤醒
rmmod wait_queue_demo
```

## 学习要点

- `DECLARE_WAIT_QUEUE_HEAD` 静态声明等待队列
- `wait_event_interruptible` 可中断等待
- `wake_up_interruptible` 唤醒等待线程
- 条件变量检查模式（condition != 0）
- `signal_pending` 处理信号中断
