// kthread_demo.c — 内核线程演示
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/atomic.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Kernel thread demo");
MODULE_VERSION("0.1");

static struct task_struct *penguin_thread;
static atomic_t stop_thread = ATOMIC_INIT(0);

static int thread_fn(void *data)
{
    int count = 0;
    pr_info("kthread_demo: thread started\n");
    while (!kthread_should_stop()) {
        if (atomic_read(&stop_thread))
            break;
        pr_info("kthread_demo: tick %d\n", count++);
        ssleep(2);
    }
    pr_info("kthread_demo: thread exiting after %d ticks\n", count);
    return 0;
}

static int __init kthread_demo_init(void)
{
    penguin_thread = kthread_create(thread_fn, NULL, "penguin_thread");
    if (IS_ERR(penguin_thread))
        return PTR_ERR(penguin_thread);
    wake_up_process(penguin_thread);
    pr_info("kthread_demo: thread created\n");
    return 0;
}

static void __exit kthread_demo_exit(void)
{
    kthread_stop(penguin_thread);
    pr_info("kthread_demo: thread stopped\n");
}

module_init(kthread_demo_init);
module_exit(kthread_demo_exit);
