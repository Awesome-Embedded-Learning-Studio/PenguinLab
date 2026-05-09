# kthread_demo — 内核线程

演示 `kthread_create`/`wake_up_process`/`kthread_stop` 创建和管理内核线程。

## 构建

```bash
cd example/mini/kthread_demo
make
```

## 测试

```bash
insmod kthread_demo.ko
# 等待几秒观察 dmesg 输出
dmesg | tail -20
rmmod kthread_demo
```

## 学习要点

- `kthread_create` 创建内核线程（初始为停止状态）
- `wake_up_process` 唤醒线程开始执行
- `kthread_should_stop` 检查停止信号
- `kthread_stop` 同步停止线程
- `ssleep` 内核中的秒级休眠
