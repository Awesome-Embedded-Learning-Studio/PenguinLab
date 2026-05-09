# workqueue_demo — 工作队列

演示 `create_singlethread_workqueue`、`INIT_WORK`、`queue_work` 异步执行延迟工作。

## 构建

```bash
cd example/mini/workqueue_demo
make
```

## 测试

```bash
insmod workqueue_demo.ko
dmesg | tail -10
# 应该看到 3 个 work item 依次执行
rmmod workqueue_demo
```

## 学习要点

- `create_singlethread_workqueue` 创建单线程工作队列
- `INIT_WORK` 初始化 work_struct 并绑定处理函数
- `queue_work` 将工作项提交到队列
- `container_of` 从 `work_struct` 获取自定义数据结构
- `flush_workqueue` 等待所有工作完成后再销毁
- 工作队列在进程上下文执行，可以睡眠
