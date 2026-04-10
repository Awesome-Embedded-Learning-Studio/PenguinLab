// hello.c — 最小内核模块
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Hello World kernel module");
MODULE_VERSION("0.1");

/* module_param 示例：允许 insmod 时传参 */
static int count = 1;
module_param(count, int, 0644);
MODULE_PARM_DESC(count, "Number of greetings (default: 1)");

static int __init hello_init(void)
{
    int i;
    pr_info("hello: module loaded, count=%d\n", count);
    for (i = 0; i < count; i++)
        pr_info("hello: greeting %d/%d\n", i + 1, count);
    return 0;  /* 非零返回值会导致 insmod 失败 */
}

static void __exit hello_exit(void)
{
    pr_info("hello: module unloaded\n");
}

module_init(hello_init);
module_exit(hello_exit);
