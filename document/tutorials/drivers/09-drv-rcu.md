---
title: RCU：读多写少的无锁魔法
slug: drv-rcu
difficulty: intermediate
tags: [RCU, 并发同步, 无锁编程, 内存屏障]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/drivers/08-drv-atomic
related:
  - /tutorials/drivers/08-drv-atomic
  - /tutorials/drivers/07-drv-sync
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch07.md
  - notes: document/notes/linux_kernel_device_drivers/ch07_3.md
---

# RCU：读多写少的无锁魔法

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## 锁的尽头是另一种思路

写到这一篇，我们已经攒了一抽屉的锁：自旋锁原地打转、互斥锁睡过去等。可内核里有一类场景特别折磨这些锁——**读极多、写极少**。典型的就是路由表、VFS 的 `dentry` 缓存、网络协议族的 `struct net_proto_family` 链表。热点路径上几百个 CPU 同时在读，可要更新它？几秒钟都不见得有一次。

如果给这种结构套一把自旋锁，那画面太美不敢看：每个读者进临界区都要 `spin_lock`，在多核 SMP 上这等于所有 CPU 排队抢同一把锁——锁总线、刷缓存行、CAS 自旋，读得越多锁竞争越惨，典型的"用锁保护读"是把性能往火坑里推。

RCU（Read-Copy-Update）就是为这种"读多写少"量身打造的。它的核心承诺听起来像作弊：**读者完全不加锁、不做原子操作、不写共享变量**，所以读者之间零竞争，速度跟单线程裸读几乎一样。代价全部转移给了写者。这不是黑魔法，是靠精巧的设计把"快"和"正确"分开买单。

## RCU 的核心三步

RCU 名字里 Read-Copy-Update 就把套路交代了，我们一行行拆：

1. **读者无锁读旧副本**：读者进临界区只标记一下"我在读"（具体怎么标记待会儿用源码说），然后直接顺着指针读当前数据，全程不碰任何锁、不做原子操作。
2. **写者复制一份再改**：写者不原地修改共享数据，而是 `kmalloc` 一份新副本，在新副本上改。这期间老读者还在读旧数据，互不干扰。
3. **等合适时机回收旧版**：旧数据不能马上 `kfree`，因为可能有读者正引用着它。写者登记一个回收动作，等所有"老读者"都退出临界区后，才真正释放旧数据。

关键在第 3 步——"等所有老读者退出"这件事，RCU 有个专门的名词：**宽限期（grace period）**。理解了宽限期，就理解了 RCU 一半。

## 宽限期：等老读者安全下车

写者改完、把指针切到新副本之后，旧副本里还可能有"在改之前就已经进入临界区"的读者在引用它。这种读者叫**老读者**。RCU 不去精确追踪每一个读者（那等于又加锁了），而是用一个粗粒度但高效的判定：**宽限期**。

宽限期的定义很朴素：从写者发起回收那一刻起，等**所有 CPU 都经历一次"静止状态"（quiescent state）**。什么叫静止状态？对一个非抢占内核来说，就是 CPU 发生了一次上下文切换、或经历了一次时钟中断、或跑进了用户态——任何能让 RCU 确认"这个 CPU 上当前没有卡在 `rcu_read_lock` 临界区里"的时刻。一个宽限期意味着：所有在回收发起前进入临界区的老读者，到宽限期结束时一定已经退出了。为什么？因为非抢占内核里，一个 CPU 要退出 `rcu_read_lock` 临界区，必然伴随着被抢占/调度出去，而那就是静止状态。宽限期扫过所有 CPU 的静止状态，就等于"老读者全清"。

一旦宽限期结束，旧副本就彻底没人引用了，写者登记的释放回调安全执行。这就是 RCU "延迟回收"的本质——**不是不释放，是等安全了再释放**。

## 读者 API：`rcu_read_lock` / `rcu_read_unlock`

读者的全套家当就两个宏：

```c
rcu_read_lock();       /* 进临界区 */
/* 这里读 RCU 保护的数据，随便读，不加锁 */
rcu_read_unlock();     /* 出临界区 */
```

这两个宏到底干了什么？我们直接看 6.19 源码。`rcu_read_lock()`（`include/linux/rcupdate.h:863`）本体是个 inline 函数：

```c
static __always_inline void rcu_read_lock(void)
{
    __rcu_read_lock();
    __acquire(RCU);
    rcu_lock_acquire(&rcu_lock_map);
    ...
}
```

真正干活的是 `__rcu_read_lock()`。在非抢占内核（`TREE_RCU`）配置下，它长这样（`include/linux/rcupdate.h:91`）：

```c
static inline void __rcu_read_lock(void)
{
    preempt_disable();    /* 就这一句！禁掉本 CPU 抢占 */
}

static inline void __rcu_read_unlock(void)
{
    preempt_enable();
}
```

看到没？读者进临界区，RCU 做的全部事情就是 `preempt_disable()`——**禁掉本 CPU 的抢占**。没有自旋、没有 CAS、没有原子读改写、没有写共享变量。所以读者快到飞起：它付出的代价仅仅是"告诉调度器：这一小段别把我换走"。而这点代价正是宽限期判定的依据——只要本 CPU 还没发生上下文切换，RCU 就知道这个读者可能还在临界区里。

（抢占内核 `PREEMPT_RCU` 下 `__rcu_read_lock` 会真正计数 `current->rcu_read_lock_nesting`，允许读者被抢占，判定逻辑更复杂，但对外 API 一模一样。）

> 注释里还有一句很硬的话（rcupdate.h:872）：`So where is rcu_write_lock()? It does not exist`——**RCU 根本没有写者锁**，因为没有任何机制能"挡住"读者，这正是 RCU 快的根源。

## 写者 API：`synchronize_rcu` 与 `call_rcu`

写者改完数据后，要把旧副本的安全回收托付给 RCU。有两条路：

**同步等宽限期——`synchronize_rcu()`**。调用者会**阻塞**，直到当前宽限期结束、旧数据确认安全才返回。看源码（`kernel/rcu/tree.c:3337`）：

```c
void synchronize_rcu(void)
{
    ...
    if (!rcu_blocking_is_gp()) {
        if (rcu_gp_is_expedited())
            synchronize_rcu_expedited();   /* 强制快速宽限期，代价是 IPI 打扰所有 CPU */
        else
            synchronize_rcu_normal();      /* 正常等宽限期，友好 */
        return;
    }
    ...
}
```

`synchronize_rcu` 内部调用 `synchronize_rcu_normal()`（tree.c:3265），它注册一个回调然后睡死等宽限期完成。注意它要求**进程上下文**——中断里绝对不能调，因为它会睡眠。典型写法是写者持一把普通自旋锁（**只用来隔绝写者之间**，不是隔绝读者），改完指针、`spin_unlock`，然后 `synchronize_rcu()` + `kfree(old)`。

**异步回收——`call_rcu()`**。不想阻塞？把释放动作包成回调挂上去，宽限期结束后 RCU 自己调它：

```c
void call_rcu(struct rcu_head *head, rcu_callback_t func)
{
    __call_rcu_common(head, func, enable_rcu_lazy);
}
```

（tree.c:3237）`call_rcu` 不阻塞，立即返回。代价是回调延迟执行、且写者要保证传入的 `old` 指针在这期间不会被二次释放。更新极频繁的场景（比如路由表）几乎只用 `call_rcu`，把 `kfree` 推迟到宽限期之后批量做。

## 为什么读者快、写者贵

把账算清楚：

**读者快，是因为它什么都不做**。`preempt_disable` 一条指令级别的事，没有跨 CPU 的总线同步、没有缓存行乒乓。N 个 CPU 同时读一个 RCU 链表，彼此完全无感，扩展性近乎线性。这正是 RCU 在网络/调度热路径上铺天盖地的原因。

**写者贵，贵在三处**：(1) 要 `kmalloc` 复制一份新数据并改它；(2) 要等一个完整宽限期才能释放旧数据，宽限期可能长达几毫秒到几十毫秒；(3) 在宽限期结束前，**新旧的内存同时存在**，内存占用短暂翻倍。所以 RCU 是"读者爽、写者扛"的交换——只有当读频率远远高于写频率时，这笔买卖才划算。若读写都频繁，RCU 反而比锁更糟。

## 链表 RCU：`list_for_each_entry_rcu` / `list_add_rcu`

实战中 RCU 最常见的载体是双向链表。读者用 RCU 版本遍历，写者用 RCU 版本增删，二者可安全并发：

```c
/* 读者：在 rcu_read_lock() 保护下 */
struct foo *entry;
list_for_each_entry_rcu(entry, head, list) {
    /* 读 entry，绝不能 free，也绝不能改它 */
}

/* 写者：加一把普通锁隔绝其它写者 */
spin_lock(&writers_lock);
list_add_rcu(&new->list, head);     /* 原子地插入，读者要么看到要么看不到，不会看到半个节点 */
spin_unlock(&writers_lock);
```

读者那个 `list_for_each_entry_rcu`（`include/linux/rculist.h:446`）展开后核心是：用 `list_entry_rcu` 取节点，而它底层是 `READ_ONCE` 取 `next` 指针——一个普通加载，不带锁。它能和 `list_add_rcu` 安全并发，靠的是 RCU 写者**先建好新节点的全部内容，最后再用一次原子指针更新把它挂进链表**，以及宽限期保证被摘除的旧节点在读者退出前不会被释放。读者可能"绕过"刚加的新节点（看到旧的 `next`），也可能看到，但绝不会看到半个写了一半的脏节点。

## 与内存屏障衔接：`rcu_assign_pointer` / `rcu_dereference`

链表 API 帮你把指针更新封装好了，但如果你自己手搓 RCU 保护的结构体（比如一个全局指针 `gp` 指向某结构），就必须用这一对宏来发布/订阅，**不能裸赋值**：

```c
struct foo __rcu *gp;     /* __rcu 是给 sparse 看的标注 */

/* 写者：发布 */
p = kmalloc(...);
p->a = 1; p->b = 2;       /* 先填好字段 */
rcu_assign_pointer(gp, p); /* 再发布指针 */

/* 读者：订阅 */
rcu_read_lock();
local = rcu_dereference(gp);   /* 取到指针 */
do_something(local->a);        /* 安全读 */
rcu_read_unlock();
```

为什么要这俩宏？因为现代 CPU 和编译器都会**乱序**。写者写完 `p->a`、`p->b` 后，如果裸 `gp = p`，CPU 可能把指针更新排到字段写入之前——读者拿到指针时，字段可能还没落内存。`rcu_assign_pointer`（`rcupdate.h:588`）用 `smp_store_release` 解决：它是一条**release 语义的存储**，保证屏障之前的所有写（字段赋值）全部对其它 CPU 可见之后，才让指针更新可见：

```c
#define rcu_assign_pointer(p, v)                          \
do {                                                      \
    ...                                                   \
    smp_store_release(&p, RCU_INITIALIZER(...));          \
} while (0)
```

对称地，读者端 `rcu_dereference`（rcupdate.h:770，包到 `rcu_dereference_check`）用 `READ_ONCE` + 依赖屏障保证：先读到正确的指针，再去读它指向的字段。**发布用 release、订阅用 deref**，这一对配合就是 RCU 版的"内存屏障契约"——上一篇讲的手写 `wmb()`/`rmb()`，RCU 替你压进了这两个宏里。

## 动手验证（待亲测）

本篇不贴完整示例，给两个验证方案，留到 QEMU 上跑：

**方案 A：体会宽限期。** 写一个模块，`rcu_read_lock` 里 `udelay` 卡住一会儿模拟长读者，另一个 CPU/线程 `synchronize_rcu()` 并在前后打 `ktime_get` 截时间——你会看到 `synchronize_rcu` 的返回被读者卡住的时长拖长，直观感受"宽限期等老读者"。

**方案 B：RCU 链表并发。** 一个内核线程 `list_add_rcu` 猛加节点 + 旧节点 `call_rcu` 回收，几个线程 `list_for_each_entry_rcu` 遍历只读。开 `CONFIG_PROVE_RCU` 和 lockdep，故意写错（比如读者不加 `rcu_read_lock`）观察 splat，体会 RCU 的纪律。

> ⚠️ **待亲测**：上面两个方案的代码、`dmesg` 输出、宽限期耗时实测，都要在 QEMU ARM64 上跑一遍落实，再把数字填回这里。

## 小结

RCU 把"读多写少"的并发做到了极致：读者只 `preempt_disable`、不加锁、不做原子操作，所以读侧近零开销、扩展性近乎线性；代价全部转给写者——复制副本、等宽限期、延迟回收。三步走（读者读旧副本 → 写者复制改 → 等宽限期回收）加上一对发布/订阅宏（`rcu_assign_pointer`/`rcu_dereference`）和链表 RCU 家族，就构成了内核里路由、VFS、网络协议等热路径的并发骨架。

记住一句话：**RCU 不是"不释放"，是"等安全了再释放"**；它适合读远多于写的场景，读写都频繁时它比锁更糟。

## 延伸阅读

- 源码：`include/linux/rcupdate.h`（RCU 核心 API 与宏）、`kernel/rcu/tree.c`（Tree RCU 宽限期引擎，`synchronize_rcu`/`call_rcu`）、`include/linux/rculist.h`（RCU 链表）。
- kernel.org 文档：[RCU documentation index](https://docs.kernel.org/RCU/index.html)（RCU 设计、内存序、 stall 诊断全套）、[What is RCU?](https://docs.kernel.org/RCU/rcu.html)。
- 关联篇：原子与内存屏障（`/tutorials/drivers/08-drv-atomic`）、同步原语总览（`/tutorials/drivers/07-drv-sync`）。