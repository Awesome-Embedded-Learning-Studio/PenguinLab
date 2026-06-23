---
title: poll/select：驱动怎么告诉用户"数据来了"
slug: drv-poll
difficulty: intermediate
tags: [字符设备, 等待队列, poll机制, select, epoll]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/drivers/01-drv-chardev
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch02.md
---

# poll/select：驱动怎么告诉用户"数据来了"

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解(函数/数据结构已核对);具体行号与命令输出待 QEMU 亲测核对。
>
> 诚实交代一句:本站读书笔记里**没有**专讲 poll/等待队列的章节(现有的 ch02 笔记讲的是 procfs/sysfs/debugfs/netlink/ioctl 这类通信手段,跟本篇主题对不上),所以这篇的素材是直接从 Linux 6.19 源码扒出来的,不走笔记路线。

## 阻塞 read 的死穴

上一篇我们写了字符设备驱动的 `read`。默认情况下它有个让人抓狂的特性:**数据没来,`read` 就卡死**。用户进程调一次 `read(fd, buf, N)`,驱动一看缓冲区空,就把它丢进等待队列睡大觉——直到数据来被唤醒。这种"阻塞 I/O"是 Unix 的默认脾气。

单看一个设备这没毛病。可现实是,一个程序经常要同时伺候好几个数据源:键盘敲一下要响应、串口来一帧要收、网络来包要处理。如果每个 fd 都阻塞 read,那第一个没数据的设备就把整个进程焊死了——后面的设备再忙也没人理。

这就是 poll/select/epoll 三兄弟要解决的问题:**让一个进程同时盯一堆 fd,谁先有数据就先告诉它,它再去 read 那个有货的**。从"轮流死等"变成"有货叫你"。

## 用户态三兄弟:同时盯多个 fd

用户态有三个长得像但进化程度不同的系统调用:

- **`select(fd_set, timeout)`**:最古老。用三个位图(读/写/异常)标关心哪些 fd,返回时改写位图标谁就绪。坑是 fd 用位图编号,默认上限 `FD_SETSIZE`=1024;而且每次都要把整个位图在用户态和内核态之间拷来拷去。
- **`poll(struct pollfd[], timeout)`**:进化版。传一个 `pollfd` 数组,每个元素写"关心哪个 fd、关心哪些事件",返回时往 `revents` 里填实际发生的事件。没有 1024 上限,但还是要每次全量拷数组。
- **`epoll`**:终极形态。`epoll_create` 建一个内核里的红黑树,`epoll_ctl` 注册关心的 fd(只注册一次),`epoll_wait` 只返回就绪的那些——O(就绪数)而非 O(总 fd 数)。高并发服务器几乎只用它。

这篇我们重点讲前两个的内核实现,因为它们的驱动侧接口完全一样:都是那个 `.poll` 回调。epoll 的用户态接口不同,但内核侧一样走 `vfs_poll()` → 驱动 `.poll`,所以把 `.poll` 写对,三个全照顾到了。

## 驱动 `.poll` 回调:两件事缺一不可

用户调 `poll()`,内核最终会回调驱动 `file_operations` 里那个 `.poll` 方法。签名长这样(Linux 6.19):

```c
__poll_t my_poll(struct file *filp, struct poll_table_struct *wait);
```

这个回调要干**两件缺一不可**的事:

**第一件:`poll_wait()` 把当前进程登记到等待队列上。**

```c
poll_wait(filp, &my_wq, wait);
```

`poll_wait` 是个 inline 函数,定义在 `include/linux/poll.h`(Linux 6.19)。它干的事其实就一句:如果 `wait->_qproc` 不为空,就调 `wait->_qproc(filp, wait_address, wait)`,把进程"预先挂"到你驱动的等待队列 `my_wq` 上。注意——是"登记",不是"立刻睡"。登记完内核还能继续跑,先把所有 fd 都问一遍再说。

**第二件:返回当前这个 fd 能不能读/写。**

驱动看一眼自己的状态:缓冲区有数据就返回 `EPOLLIN | EPOLLRDNORM`(可读),能写就返回 `EPOLLOUT | EPOLLWRNORM`(可写),没货就返回 0。这个掩码就是内核拿去判断"这个 fd 现在就绪没"的依据。

为什么两件都要?因为有个经典的竞态:如果只返回掩码不登记等待队列,那么驱动在 `.poll` 返回后、内核真正决定睡之前,如果数据恰好来了,没人会唤醒这个进程——它就睡死或等超时。登记等待队列是为了"数据来时能叫醒我",返回掩码是为了"现在就有货就别睡了"。两个一起,才堵住竞态。

## 等待队列:数据就绪谁来叫醒

`poll_wait` 登记的等待队列,本质是 `wait_queue_head_t`,对应的结构体定义在 `include/linux/wait.h`(Linux 6.19):

```c
struct wait_queue_head {
    spinlock_t      lock;
    struct list_head head;
};
```

就是个带自旋锁的链表头。`init_waitqueue_head(&my_wq)` 初始化它。当数据真的来了(比如中断里收完一帧),驱动要主动喊一嗓子:

```c
wake_up_interruptible(&my_wq);
```

`wake_up_interruptible` 是 `include/linux/wait.h` 里的宏,展开成 `__wake_up(x, TASK_INTERRUPTIBLE, 1, NULL)`——只唤醒一个可被信号打断的睡眠者。`wake_up` 则是 `__wake_up(x, TASK_NORMAL, 1, NULL)`,唤醒 `TASK_NORMAL` 的。区别很重要:`TASK_INTERRUPTIBLE` 状态的进程收到信号会被叫醒,适合可中断的等待。

那么 `.poll` 登记的等待项,内核是怎么塞进队列的?看 `fs/select.c`(Linux 6.19)的 `__pollwait()`:

```c
static void __pollwait(struct file *filp, wait_queue_head_t *wait_address,
                       poll_table *p)
{
    struct poll_wqueues *pwq = container_of(p, struct poll_wqueues, pt);
    struct poll_table_entry *entry = poll_get_entry(pwq);
    ...
    entry->filp = get_file(filp);
    entry->wait_address = wait_address;
    entry->key = p->_key;
    init_waitqueue_func_entry(&entry->wait, pollwake);
    entry->wait.private = pwq;
    add_wait_queue(wait_address, &entry->wait);
}
```

关键点:它创建一个 `poll_table_entry`,里面塞个 `wait_queue_entry`,唤醒回调函数设成 `pollwake`(不是默认的 `default_wake_function`),然后 `add_wait_queue` 挂到你驱动的等待队列上。所以你 `wake_up_interruptible` 一喊,最终走 `pollwake` → `__pollwake`,它把 `pwq->triggered` 置 1,再 `default_wake_function` 把进程真叫醒。

## 内核流程:`do_sys_poll` → 驱动 `.poll` → 没货就睡 → 被唤醒重查

把整条链路串起来,以 `poll()` 系统调用为例(`fs/select.c`,Linux 6.19):

1. **`SYSCALL_DEFINE3(poll, ...)`** 进内核,算好超时,调 `do_sys_poll()`。
2. **`do_sys_poll()`** 在栈上开个 `struct poll_wqueues table`,调 **`poll_initwait(&table)`**——它把 `table.pt._qproc` 设成 `__pollwait`(就是上面那个塞等待项的函数),`polling_task = current`(记下是哪个进程在 poll),`triggered = 0`。
3. **`do_poll()`** 是核心循环。它遍历每个关心的 fd,对每个调 **`do_pollfd()`**:
   ```c
   filter = demangle_poll(pollfd->events) | EPOLLERR | EPOLLHUP;
   pwait->_key = filter | busy_flag;
   mask = vfs_poll(fd_file(f), pwait);   // 这一句回调你的 .poll
   return mask & filter;
   ```
   `vfs_poll()`(在 `include/linux/poll.h`)就是 `file->f_op->poll(file, pt)`——直接打到你驱动的 `.poll` 回调。你的 `.poll` 里 `poll_wait()` 登记队列、返回掩码,全在这一步发生。
4. **第一轮全扫一遍**:如果某个 fd 返回了非零掩码(`mask`),`count++`,并把 `pt->_qproc = NULL`(找到就绪的了,后面的 fd 就不必再登记等待项,省事)。
5. **没找到任何就绪 fd**:如果 `count` 为 0 且没信号、没超时,就调 **`poll_schedule_timeout(wait, TASK_INTERRUPTIBLE, ...)`**——把进程设成 `TASK_INTERRUPTIBLE` 睡下去,等定时器或唤醒。
6. **被唤醒**:驱动的 `wake_up_interruptible(&my_wq)` 触发 `pollwake` → `triggered=1` → 进程被唤醒。
7. **醒来重查**:`for(;;)` 循环回去再扫一遍所有 fd,这次某个 fd 就会返回 `POLLIN`,`count>0`,`break` 出循环,返回到用户态。

`select` 走的是 `do_select()`(同文件),逻辑几乎一样,只是用位图而非 `pollfd` 数组、用 `select_poll_one()` 而非 `do_pollfd()`。两套入口,一套精神。

## 和阻塞 read 的配合:同一个等待队列

这里有个新手最容易踩的坑:`.poll` 用的等待队列,和 `.read` 阻塞用的等待队列,**必须是同一个**。

为什么?因为 `.poll` 只是"登记+查状态",真正读数据还是 `read` 干。如果数据来时 `wake_up_interruptible` 喊的是 A 队列,而阻塞 `read` 把进程挂在 B 队列上,那 poll 能被叫醒,read 却睡死——两个机制各干各的,数据对不齐。

所以驱动的标准写法是:**一个设备一个等待队列**,`poll` 和阻塞 `read` 共用它:

- `.poll`:`poll_wait(filp, &dev->wq, wait);` 然后返回掩码。
- `.read`:缓冲区空时用 `wait_event_interruptible(&dev->wq, 有数据了)`(或手写 `prepare_to_wait` + `schedule`)把自己挂上去;数据来时中断里 `wake_up_interruptible(&dev->wq)`。

这样数据一来,喊一嗓子,poll 的等待者和阻塞 read 的等待者都被叫醒,各自重查状态——机制统一,不重复造轮子。

还有个搭配:`read` 要尊重 `O_NONBLOCK`。用户以非阻塞模式打开设备时,`read` 在没数据时应立刻返回 `-EAGAIN`,而不是傻睡。`filp->f_flags & O_NONBLOCK` 一测便知。poll 和非阻塞 read 是天生一对:poll 负责"等",read 负责"拿",互不阻塞。

## 小结

poll/select 的内核实现,核心就一条主线:**用户态一次盯多个 fd → 内核回调每个驱动的 `.poll` → `.poll` 里 `poll_wait` 把进程登记到驱动等待队列,并返回当前就绪掩码 → 全都没就绪就睡 → 驱动数据来时 `wake_up_interruptible` 叫醒 → 醒来重扫一遍 → 返回就绪列表**。

记住三个源码锚点:`poll_wait`(`include/linux/poll.h`,登记)、`__pollwait`/`pollwake`(`fs/select.c`,塞等待项与唤醒)、`do_poll` 的 `for(;;)` 循环(扫-睡-重扫)。再加一条纪律:`.poll` 和阻塞 `.read` 共用同一个 `wait_queue_head`,否则两边叫不齐。epoll 用户态接口虽不同,内核侧同样走 `vfs_poll` → 驱动 `.poll`,所以把 `.poll` 写对,三兄弟全受益。

## 延伸阅读

- 源码:`fs/select.c`(Linux 6.19),`do_sys_poll`/`do_poll`/`do_pollfd`/`__pollwait`/`pollwake` 全在这;`include/linux/poll.h` 看 `poll_wait`/`vfs_poll`/`poll_wqueues`;`include/linux/wait.h` 看等待队列与 `wait_event_*` 宏。
- 内核文档:等待队列 API(`include/linux/wait.h` 与 `kernel/sched/wait.c` 的 kernel-doc)见 [Linux Driver Implementer's API Guide — Wait queues and events](https://docs.kernel.org/driver-api/basics.html);poll 相关数据结构对照源码 `include/linux/poll.h`。
- 进一步(待亲测铺开):epoll 的红黑树+就绪链表实现(`fs/eventpoll.c`)、`fasync` 异步信号通知、驱动的中断顶半部与 `wake_up` 配合。