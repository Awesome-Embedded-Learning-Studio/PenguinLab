// wait_queue_demo.c — 等待队列演示
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/wait.h>
#include <linux/sched.h>
#include <linux/kthread.h>
#include <linux/delay.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Wait queue demo");
MODULE_VERSION("0.1");

static DECLARE_WAIT_QUEUE_HEAD(penguin_wq);
static int condition = 0;
static struct task_struct *waiter_thread;

static int waiter_fn(void *data)
{
    pr_info("wait_queue_demo: waiter going to sleep\n");
    wait_event_interruptible(penguin_wq, condition != 0);
    if (signal_pending(current))
        return -ERESTARTSYS;
    pr_info("wait_queue_demo: waiter woke up! condition=%d\n", condition);
    return 0;
}

static int __init wq_demo_init(void)
{
    waiter_thread = kthread_create(waiter_fn, NULL, "penguin_waiter");
    if (IS_ERR(waiter_thread))
        return PTR_ERR(waiter_thread);
    wake_up_process(waiter_thread);

    /* Wait a bit then wake the waiter */
    ssleep(3);
    pr_info("wait_queue_demo: waking up waiter\n");
    condition = 42;
    wake_up_interruptible(&penguin_wq);
    return 0;
}

static void __exit wq_demo_exit(void)
{
    condition = -1;
    wake_up_interruptible(&penguin_wq);
    kthread_stop(waiter_thread);
    pr_info("wait_queue_demo: removed\n");
}

module_init(wq_demo_init);
module_exit(wq_demo_exit);
