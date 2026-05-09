// workqueue_demo.c — 工作队列演示
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/workqueue.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Workqueue demo");
MODULE_VERSION("0.1");

static struct workqueue_struct *penguin_wq;

struct penguin_work {
    struct work_struct work;
    int id;
};

static void work_handler(struct work_struct *work)
{
    struct penguin_work *pw = container_of(work, struct penguin_work, work);
    pr_info("workqueue_demo: work %d executing on cpu %d\n", pw->id, smp_processor_id());
    kfree(pw);
}

static int __init wq_demo_init(void)
{
    struct penguin_work *pw;
    int i;

    penguin_wq = create_singlethread_workqueue("penguin_wq");
    if (!penguin_wq)
        return -ENOMEM;

    for (i = 0; i < 3; i++) {
        pw = kmalloc(sizeof(*pw), GFP_KERNEL);
        if (!pw)
            continue;
        pw->id = i;
        INIT_WORK(&pw->work, work_handler);
        queue_work(penguin_wq, &pw->work);
    }

    pr_info("workqueue_demo: 3 work items queued\n");
    return 0;
}

static void __exit wq_demo_exit(void)
{
    flush_workqueue(penguin_wq);
    destroy_workqueue(penguin_wq);
    pr_info("workqueue_demo: removed\n");
}

module_init(wq_demo_init);
module_exit(wq_demo_exit);
