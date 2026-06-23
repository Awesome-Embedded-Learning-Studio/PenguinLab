---
title: 硬件中断：设备怎么打断 CPU
slug: drv-irq
difficulty: intermediate
tags: [中断, 硬件中断, 线程化中断, 驱动框架]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/drivers/01-drv-chardev
sources:
  - notes: document/notes/linux_kernel_device_drivers/ch04.md
  - notes: document/notes/linux_kernel_device_drivers/ch04_1.md
  - notes: document/notes/linux_kernel_device_drivers/ch04_2.md
  - notes: document/notes/linux_kernel_device_drivers/ch04_3.md
---

# 硬件中断：设备怎么打断 CPU

> 🔨 **整理中** · 这篇把硬件中断从「电信号 → CPU → 内核 → 驱动 ISR」这条链路，对着 Linux 6.19 源码讲透了（函数 / 数据结构已核对）；具体行号与 `/proc/interrupts` 命令输出待 QEMU 亲测核对。

## 中断到底是怎么打断 CPU 的

写用户态程序时，CPU 仿佛永远在老老实实跑我们的代码。其实它每执行完一条指令，硬件都会偷偷瞄一眼中断引脚——一旦有信号，立刻保存现场、跳到内核预设的入口。这股「最高优先级」的力量，就是硬件中断。

先记下这条物理路径，它是后面一切机制的根：

1. **外设拉线**：网卡收到一个包，在它连接到中断控制器的物理线上拉高（或拉低）电压。
2. **中断控制器汇总**：x86 上是 IO-APIC，ARM 上是 GIC——叫它 PIC（可编程中断控制器）。它把信号暂存进寄存器，再拉高通往 CPU 的中断引脚。
3. **CPU 捕获**：CPU 检测到引脚信号，硬件自动保存现场、跳进内核的低级入口（ARM 上常是 `asm_do_IRQ` 之类）。CPU 不知道「网卡」「键盘」是什么，它只知道「第 24 号中断线触发了」——这个号叫 **IRQ**（Interrupt ReQuest），是硬件中断的身份证号。
4. **通用 IRQ 层分发**：内核拿到 IRQ 号，查中断描述符数组里这个号挂的处理函数链，逐个调用。
5. **驱动 ISR 执行**：我们注册的处理函数被叫醒。

为了屏蔽「PIC 各家操作方式天差地别」这件事，内核专门有 **Generic IRQ 处理层**。它就像一个适配器：上层驱动只管调标准 API「给我分配 24 号中断」，这层负责翻译成给具体 PIC 的指令，还顺手处理共享中断、屏蔽重入这些麻烦事。这样我们写的驱动代码能在 x86、ARM、RISC-V 上编译运行，一行不用改。

## 注册中断：把自己的函数挂到 IRQ 上

要收中断，得先向内核「预订」这个号。这条路最终都收敛到一个函数上——`request_threaded_irq()`（Linux 6.19，`kernel/irq/manage.c:2100`）：

```c
int request_threaded_irq(unsigned int irq, irq_handler_t handler,
                         irq_handler_t thread_fn, unsigned long irqflags,
                         const char *devname, void *dev_id);
```

我们平时更熟的 `request_irq()` 其实只是它的一层薄包装，定义在 `include/linux/interrupt.h:173`：把 `thread_fn` 填 `NULL`，自动补一个 `IRQF_COND_ONESHOT` 标志，然后原样转发：

```c
static inline int __must_check
request_irq(unsigned int irq, irq_handler_t handler, unsigned long flags,
            const char *name, void *dev)
{
    return request_threaded_irq(irq, handler, NULL, flags | IRQF_COND_ONESHOT, name, dev);
}
```

参数逐个看（`manage.c:2073` 的注释讲得很直白）：

- **`irq`**：IRQ 号。嵌入式上来自设备树或 `platform_get_irq()`，PCI 设备来自 `pci_dev->irq`，别硬编码。
- **`handler`**：主处理函数，跑在硬中断上下文。传 `NULL` 的话，内核给你装个默认的（`manage.c:988` 的 `irq_default_primary_handler`），它就干一件事——返回 `IRQ_WAKE_THREAD`。
- **`thread_fn`**：线程化处理函数，跑在内核线程上下文（见后文）。传 `NULL` 表示不线程化。
- **`irqflags`**：行为标志位，待会儿细讲。
- **`devname`**：字符串名字，会出现在 `/proc/interrupts` 里，调试时你会感谢起个好名字的自己。
- **`dev_id`**：私有数据指针，中断发生时原样传回 handler。**共享中断（`IRQF_SHARED`）时必须非空**——否则释放时内核分不清该摘掉链表上哪个节点。注释里 `manage.c:2087` 原话："@dev_id must be globally unique"。

返回值加 `__must_check`：0 成功，负数失败（`-EBUSY` 表示线被人占了且不让共享，`-EINVAL` 多半是标志组合不合法）。

内核注册时做了一道硬性校验（`manage.c:2124`）：`IRQF_SHARED` 配了却没给 `dev_id`、或者共享中断还设了 `IRQF_NO_AUTOEN`，直接 `-EINVAL` 打回。然后 `kzalloc` 一个 `struct irqaction`，把我们的 handler/flags/name/dev_id 填进去，交给 `__setup_irq()` 挂到 `irq_desc` 的 action 链表上。

## irqaction 与共享中断的链表

为什么是「链表」？因为一根 IRQ 线可能被多个设备共享（PCI 的老传统）。每个设备的注册信息是一个 `struct irqaction`（`include/linux/interrupt.h:123`），关键字段：

```c
struct irqaction {
    irq_handler_t handler;        // 主处理函数
    void *dev_id;                 // 私有数据 cookie
    struct irqaction *next;       // 链到下一个 action（共享时）
    irq_handler_t thread_fn;      // 线程化处理函数
    struct task_struct *thread;   // 线程化时对应的内核线程
    unsigned int irq;
    unsigned int flags;           // IRQF_* 标志
    const char *name;
    ...
};
```

那个 `next` 指针就是共享中断的关键：共享同一根 IRQ 线的多个 action 串成链。当中断真的发生，内核不知道是哪个设备拉的线，就把链上每个 handler 都调一遍——**轮到每个驱动自己读硬件寄存器，判断「是不是我的设备」**，不是就返回 `IRQ_NONE`。

## ISR 的铁律：不能睡，要快

handler 跑在**中断上下文**——一个比进程上下文严苛得多的环境。核心铁律只有一条，但要刻进骨头里：

> **在中断处理程序里，绝不能睡眠。**

不能调 `mutex_lock()`，不能 `kmalloc(GFP_KERNEL)`（必须 `GFP_ATOMIC`），不能 `copy_to_user()`（可能触发缺页睡眠）。理由很简单：中断上下文**不属于任何进程**，调度器根本没法把你「挂起再唤醒」——你一旦睡，系统就死在那儿。内核配了 `CONFIG_DEBUG_ATOMIC_SLEEP` 的话，`might_sleep()` 会吐一条 `WARNING` 并 `dump_stack()`（底层走 `__might_sleep()`，`kernel/sched/core.c:8751`）——只是警告加打印调用栈，不会 oops、也不会 panic，但看到这栈你该知道自己踩雷了。

handler 的标准长相：

```c
static irqreturn_t my_isr(int irq, void *dev_id)
{
    /* 1. 读寄存器，确认是不是本设备触发 */
    /* 2. 清掉硬件的 interrupt pending 位（否则电平触发会风暴） */
    /* 3. 只做最紧急的活，重活推给下半部 */
    return IRQ_HANDLED;   /* 或 IRQ_NONE / IRQ_WAKE_THREAD */
}
```

返回值 `irqreturn_t`：`IRQ_HANDLED`（处理了）、`IRQ_NONE`（不是我的，共享中断里常见）、`IRQ_WAKE_THREAD`（唤醒线程化 handler，见下）。注意 `IRQ_NONE` 不能滥用——持续返回它会被内核的虚假中断逻辑（`note_interrupt()`，在 `kernel/irq/spurious.c`）记成 spurious，超过阈值就可能自动把这条 IRQ 线禁掉，得排查清楚再返回。

## 标志位：IRQF_ 家族

`irqflags` 控制中断行为，定义在 `include/linux/interrupt.h`：

- **`IRQF_SHARED`**（`0x00000080`）：允许多个设备共用一根 IRQ 线。配它就必须给非空 `dev_id`。PCI 设备的标配。
- **`IRQF_TRIGGER_RISING/FALLING/HIGH/LOW`**（`0x1/0x2/0x4/0x8`）：电气触发方式。上升沿/下降沿是边沿触发，高/低电平是电平触发。
- **`IRQF_ONESHOT`**（`0x00002000`）：线程化中断专用。hardirq 跑完**不立即重开这条 IRQ 线**，保持屏蔽直到 thread_fn 跑完。电平触发中断不加它就完蛋——电平一直高着，thread 还没跑完就被新中断淹死。
- **`IRQF_NO_THREAD`**、`IRQF_NO_AUTOEN`、`IRQF_TIMER` 等：按需翻头文件。

边沿 vs 电平触发的坑：电平触发必须 handler 里把电平拉下去（ack 硬件），否则 handler 一返回立刻又被触发，形成中断风暴；边沿触发只在跳变瞬间响一次，相对省心但高负载下可能漏脉冲。设备树或 BSP 通常已经配好触发方式，驱动里很少手动设。

## 上半部 / 下半部：拆开「急活」和「重活」

ISR 有两个天敌：**太慢会丢后续中断，太原子干不了重活**。Linux 的解法是分治——**上半部（Top Half）** 抢时间、关中断里干最紧急的确认和 ack；**下半部（Bottom Half）** 把不急的重活延后到开中断的环境里慢慢做。

下半部的实现有好几代，按「能干多重的活」排：

- **softirq**：编译期静态注册的向量（`HI_SOFTIRQ`、`NET_RX_SOFTIRQ` 等，见 `interrupt.h:562` 的枚举）。驱动不能动态注册新类型。最底层、最快，但没并发保护，容易踩 SMP 竞态。
- **tasklet**：建在 softirq 之上的动态机制，保证「同一个 tasklet 不会同时在两个 CPU 上跑」，简化了锁。**注意它已被标记 deprecated**（`interrupt.h:680` 头注），官方建议改用线程化中断。
- **workqueue**：把活儿丢给内核线程跑，**可以睡眠**，适合要分配大内存、要持 mutex 的重活。
- **线程化中断**：见下节，本质是把下半部这件事做到极致。

softirq 疯起来会饿死用户进程——于是内核搞了 `ksoftirqd` 内核线程，软中断过载时把活儿甩给它当普通进程调度。`/proc/softirqs` 能看到各类软中断的计数。

## 线程化中断：让 ISR 也能睡觉

「不能睡眠」这条规矩对某些硬件太憋屈——比如要走 I2C 慢总线读数据的传感器，或者要持 mutex 访问临界区的设备。`request_threaded_irq()` 把处理拆成两段：

1. **Primary handler（hardirq）**：跑在硬中断上下文，只做最紧急的确认/屏蔽，然后返回 `IRQ_WAKE_THREAD`。
2. **Threaded handler（`thread_fn`）**：跑在专门的内核线程里，**可以睡眠、持 mutex、做所有进程上下文能做的事**。

线程怎么来的？`__setup_irq()` 里调 `setup_irq_thread()`（`manage.c:1391`），用 `kthread_create(irq_thread, new, "irq/%d-%s", irq, name)` 造一个内核线程，名字就是 `irq/24-eth0` 这种（见 `manage.c:1396`）。这线程平时睡在 `irq_wait_for_interrupt()`（`manage.c:1043`）里等被叫醒。顺带一提，如果驱动还配了 secondary 线程，第二个线程名字会带个 `-s-`（`irq/%d-s-%s`，`manage.c:1399`），用来跑 force-threaded 场景下的「被强制线程化的原 hardirq」。

线程的调度策略在线程一启动就定了：`irq_thread()` 里对主线程调 `sched_set_fifo(current)`、对 secondary 线程调 `sched_set_fifo_secondary(current)`（都在 `manage.c:1244` 附近）。这两个函数都在 `kernel/sched/syscalls.c:812`，把线程设成 `SCHED_FIFO` 实时策略，主线程优先级 `MAX_RT_PRIO / 2`（即 50，`MAX_RT_PRIO` 在 `include/linux/sched/prio.h:16` 定义为 100），secondary 线程低一档 `MAX_RT_PRIO / 2 - 1`（49）。

唤醒的链路在 `kernel/irq/handle.c:185` 的 `__handle_irq_event_percpu()`——遍历 action 链调每个 handler，拿到返回值后 `switch`：

```c
res = action->handler(irq, action->dev_id);
...
switch (res) {
case IRQ_WAKE_THREAD:
    if (unlikely(!action->thread_fn)) { warn_no_thread(irq, action); break; }
    __irq_wake_thread(desc, action);   /* 唤醒对应内核线程跑 thread_fn */
    break;
default:
    break;
}
```

这就是「handler 返回 `IRQ_WAKE_THREAD` → 内核唤醒 irq 线程 → thread_fn 跑」的源码真相。`handle.c:216` 还有个贴心检查：handler 跑完发现中断居然被开了（`!irqs_disabled()`），直接 `WARN_ONCE` 并帮你关回去——别让你的 ISR 偷偷开中断。

线程化中断另一个深层好处是**优先级可控**：普通硬中断优先级压倒一切用户进程，但线程化后中断变成了一个 `SCHED_FIFO` 实时调度实体（默认 prio ≈ 50）。于是一个优先级更高的实时任务（比如 `SCHED_FIFO` prio 60）能抢占它，系统设计者得以把「中断处理」和「关键实时任务」排出明确的高低。这正是 PREEMPT_RT 的核心逻辑之一——在 RT 内核里，绝大多数硬中断被强制线程化，可控的优先级就是它「可预测延迟」的根基。

## 释放、启用与禁用 IRQ

用完要还：`free_irq(irq, dev_id)`（`manage.c:1989`，签名是 `const void *free_irq(...)`）。它调 `__free_irq()` 从 action 链上摘掉匹配 `dev_id` 的节点、`kfree(action)`，并**等待当前正在跑的 handler 跑完**才返回（内部正是调 `__synchronize_irq()`，`manage.c:108`）。返回值是被摘下那个 action 的 name（即当初注册时的 `devname`），无可释放则返回 `NULL`——释放后判个空，能确认自己确实摘对了节点。共享中断务必先在硬件层禁用这条线再 `free_irq`，否则释放途中又来中断、handler 却已解绑，系统会懵。

光释放不够时，还得会「临时掐断再恢复」。常用的几个 API 都在 `kernel/irq/manage.c`，作用域差很多，别混用：

- **`disable_irq(irq)`**（`manage.c:710`）：同步禁用——标记这条线不响应，**并等待当前正在跑的 handler 结束**才返回。所以它本身可能睡眠，**绝不能在持有自旋锁或中断上下文里调**，否则死锁。
- **`disable_irq_nosync(irq)`**（`manage.c:690`）：异步禁用——只标记，不等 handler。中断上下文里要禁用就用它，但代价是你返回后 handler 可能还在别的 CPU 上跑完。
- **`enable_irq(irq)`**（`manage.c:800`）：和上面配对，重新开线。开之前必须保证 `disable` 调了几次、`enable` 就配几次，内核对这对操作有计数。
- **`synchronize_irq(irq)`**（`manage.c:133`）：不改变使能状态，纯粹「等到这条 IRQ 上所有 pending 的 handler 跑完」。换 buffer、卸 handler 前调它最稳。
- **`local_irq_disable()` / `local_irq_enable()`**（`include/linux/irqflags.h`）：这是宏，关/开**当前 CPU 的全部中断**，粒度最粗。只能极短临界区用，关太久直接拖垮实时性。

这套 API 跟 `free_irq` 的「等 handler 跑完」是同一条逻辑线：只要你想动一条正在服务的中断，都得先确保没人还在它的 handler 里。

现代驱动更推荐托管版 `devm_request_irq()` / `devm_request_threaded_irq()`：多传一个 `struct device *`，内核记录归属，设备移除时自动 `free_irq`，省去手动配对的麻烦。

怎么验证中断真的来了？看 `/proc/interrupts`——每行一个 IRQ，列依次是 IRQ 号、各 CPU 核上的触发计数、中断控制器类型、触发方式、设备名。怀疑中断没触发，先来这儿看计数是不是 0：是 0 就说明硬件压根没拉线，或者 IRQ 号/触发方式没配对。

## 动手验证方案（待 QEMU 亲测）

> ⚠️ 以下为验证方案，具体代码与命令输出待我们在 QEMU 上跑通后回填。

1. **环境**：用 `scripts/qemu-run.sh` 起一个带 virtio-gpio 或简易 platform 设备的 ARM64 虚拟机；内核开 `CONFIG_DEBUG_ATOMIC_SLEEP`、`CONFIG_GENERIC_IRQ_DEBUGFS`。
2. **注册一个虚拟中断**：写一个 platform 驱动，`probe` 里用 `devm_request_irq()` 注册一段 IRQ，handler 只做计数自增 + 返回 `IRQ_HANDLED`，再挂一个 tasklet 或 workqueue 打印一行日志当下半部对比。
3. **触发与观察**：通过 sysfs/gpio 或 `irq_inject_interrupt()`（`interrupt.h:262`）注入一次中断，`cat /proc/interrupts` 看对应 IRQ 计数是否 +1，`dmesg` 看 ISR 与下半部的执行先后与上下文（用 `in_irq()`/`in_task()` 打印）。
4. **线程化对比**：把同一套逻辑换成 `devm_request_threaded_irq()` + `IRQF_ONESHOT`，在 thread_fn 里 `msleep(10)`——观察它居然不 panic，且 thread_fn 跑在进程上下文（`in_task()` 为真）。这正是线程化中断能睡眠的铁证。

## 小结

硬件中断是 CPU 能被打断的根：电信号 → PIC → CPU 跳异常向量 → 通用 IRQ 层查 `irq_desc` → 调我们挂的 `irqaction`。注册走 `request_irq()`（实为 `request_threaded_irq` 的薄包装），handler 跑在中断上下文里**绝不能睡眠、要尽快返回**，重活交给下半部（softirq/tasklet/workqueue）。慢活、要睡眠的活就用 `request_threaded_irq()` 丢给专门的 irq 内核线程（默认 `SCHED_FIFO` prio 50），配 `IRQF_ONESHOT` 防电平风暴。要临时掐断用 `disable_irq(_nosync)`/`enable_irq`，要彻底收摊用 `free_irq`。`/proc/interrupts` 是验证中断到没到的第一现场。

## 延伸阅读

- 源码：`kernel/irq/manage.c`（Linux 6.19），`request_threaded_irq` / `free_irq` / `disable_irq` / `enable_irq` / `__setup_irq`；`kernel/irq/handle.c` 的 `__handle_irq_event_percpu` 看分发链路；`kernel/irq/spurious.c` 的 `note_interrupt` 看虚假中断判定。
- 头文件：`include/linux/interrupt.h`，`struct irqaction`、`IRQF_*` 标志、softirq/tasklet 定义全在这儿；`include/linux/sched/prio.h` 的 `MAX_RT_PRIO`；`kernel/sched/syscalls.c:812` 的 `sched_set_fifo` 看 IRQ 线程优先级。
- kernel.org：[核心 API 文档索引](https://docs.kernel.org/core-api/index.html)、[驱动 API 文档索引](https://docs.kernel.org/driver-api/index.html)。
- 进一步（持续铺开）：softirq/tasklet 工作流、workqueue、IRQ affinity 与 smp_affinity、PREEMPT_RT 的强制线程化。