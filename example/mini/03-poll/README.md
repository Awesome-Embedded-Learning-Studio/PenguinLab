# 03-poll — poll/select + 等待队列 + 阻塞 read 的配合

> 配套教程：[poll/select：驱动怎么告诉用户"数据来了"](../../../document/tutorials/drivers/03-drv-poll.md)
> 对应进度节点：`drv-poll`（layer-2）
> 前置示例：[01-chardev_basic](../01-chardev_basic/)

## 这个示例做什么

chardev 的 `read` 在没数据时会**卡死**（阻塞）。本篇演示怎么用 `poll` 让用户"先问有没有货，再决定读"——而且 `.poll` 和阻塞 `.read` 共用同一套机制。要点：

- **`.poll` 回调两件事缺一不可**：`poll_wait` 把进程登记到等待队列 + 返回当前就绪掩码（`EPOLLIN|EPOLLRDNORM`）
- **`.poll` 和阻塞 `.read` 共用同一个 `wait_queue_head`**（`read_wq`）——否则两边叫不齐
- **`.read` 尊重 `O_NONBLOCK`**：非阻塞模式没数据立刻返 `-EAGAIN`
- **`write` 模拟"数据来了"**：写完 `wake_up_interruptible` 叫醒所有等待者（无真实硬件/中断）

## 文件

| 文件 | 说明 |
|------|------|
| `poll.c` | 内核模块：misc 设备 + `.poll`（poll_wait + 掩码）+ 阻塞 `.read`（wait_event）+ 非阻塞 + `wake_up` |
| `poll_user.c` | 用户态：`poll()` 阻塞等待数据，被唤醒后读出 |
| `Makefile` | `make` 出模块，`make user` 出用户态程序 |

## 编译

```bash
cd example/mini/03-poll
make             # poll.ko（默认 arm64）
make user        # poll_user（静态链接）
```

## 亲测（QEMU ARM64，2026-06-27 实测）

```bash
# 终端 1: insmod 后跑 poll_user, 它会阻塞在 poll() 等数据
insmod poll.ko
./poll_user

# 终端 2: 写数据触发唤醒
echo "hello poll" > /dev/llkd_polldev

# 回到终端 1: poll_user 被唤醒, 读出数据
dmesg | tail
rmmod poll
```

实测输出（2026-06-27）：

```
# 终端 1（先阻塞，被写唤醒后）
poll() waiting for data (10s timeout)...
poll woken up, read 11 bytes: 'hello poll'

# dmesg
[  XX.XXXXXX] llkd_polldev: write() 11 bytes, woke up waiters
```

非阻塞验证：`cat /dev/llkd_polldev`（无数据时阻塞）vs 用 `O_NONBLOCK` 打开读（立刻 `-EAGAIN`）。
