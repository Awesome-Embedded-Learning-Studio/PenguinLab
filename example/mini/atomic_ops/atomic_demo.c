// atomic_demo.c — 原子操作演示
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/atomic.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Atomic operations demo");
MODULE_VERSION("0.1");

static atomic_t penguin_atomic = ATOMIC_INIT(0);

static int __init atomic_demo_init(void)
{
    int old;

    atomic_set(&penguin_atomic, 42);
    pr_info("atomic_demo: set to %d\n", atomic_read(&penguin_atomic));

    atomic_add(8, &penguin_atomic);
    pr_info("atomic_demo: add 8 → %d\n", atomic_read(&penguin_atomic));

    atomic_inc(&penguin_atomic);
    pr_info("atomic_demo: inc → %d\n", atomic_read(&penguin_atomic));

    old = atomic_cmpxchg(&penguin_atomic, 51, 100);
    pr_info("atomic_demo: cmpxchg(51→100) old=%d, now=%d\n",
            old, atomic_read(&penguin_atomic));

    old = atomic_cmpxchg(&penguin_atomic, 99, 200);
    pr_info("atomic_demo: cmpxchg(99→200) old=%d, now=%d (no change expected)\n",
            old, atomic_read(&penguin_atomic));

    return 0;
}

static void __exit atomic_demo_exit(void)
{
    pr_info("atomic_demo: final value=%d\n", atomic_read(&penguin_atomic));
}

module_init(atomic_demo_init);
module_exit(atomic_demo_exit);
