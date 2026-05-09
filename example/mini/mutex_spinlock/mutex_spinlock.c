// mutex_spinlock.c — 互斥锁与自旋锁对比
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/delay.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Mutex vs spinlock comparison");
MODULE_VERSION("0.1");

static DEFINE_MUTEX(penguin_mutex);
static DEFINE_SPINLOCK(penguin_spinlock);
static int mutex_counter = 0;
static int spinlock_counter = 0;

/*
 * mutex: can sleep, suitable for long-held locks
 * spinlock: busy-wait, must be used in atomic context
 */
static int __init lock_demo_init(void)
{
    /* Mutex demo */
    mutex_lock(&penguin_mutex);
    mutex_counter++;
    pr_info("mutex_spinlock: mutex_counter=%d (mutex protected)\n", mutex_counter);
    msleep(100);  /* OK: mutex allows sleeping */
    mutex_unlock(&penguin_mutex);

    /* Spinlock demo */
    spin_lock(&penguin_spinlock);
    spinlock_counter++;
    pr_info("mutex_spinlock: spinlock_counter=%d (spinlock protected)\n", spinlock_counter);
    /* DO NOT sleep here! spinlock forbids sleeping */
    spin_unlock(&penguin_spinlock);

    pr_info("mutex_spinlock: demo complete\n");
    return 0;
}

static void __exit lock_demo_exit(void)
{
    pr_info("mutex_spinlock: mutex_counter=%d, spinlock_counter=%d\n",
            mutex_counter, spinlock_counter);
}

module_init(lock_demo_init);
module_exit(lock_demo_exit);
