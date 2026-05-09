// params.c — 内核模块参数演示
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Kernel module parameters demo");
MODULE_VERSION("0.1");

static int count = 1;
static char *name = "PenguinLab";
static int values[4] = {1, 2, 3, 4};
static int nvalues = 4;

module_param(count, int, 0644);
MODULE_PARM_DESC(count, "Number of greetings (default: 1)");

module_param(name, charp, 0644);
MODULE_PARM_DESC(name, "Name to greet (default: PenguinLab)");

module_param_array(values, int, &nvalues, 0644);
MODULE_PARM_DESC(values, "Array of integers (max 4)");

static int __init params_init(void)
{
    int i;
    pr_info("params: module loaded\n");
    for (i = 0; i < count; i++)
        pr_info("params: Hello, %s! (%d/%d)\n", name, i + 1, count);
    for (i = 0; i < nvalues; i++)
        pr_info("params: values[%d] = %d\n", i, values[i]);
    return 0;
}

static void __exit params_exit(void)
{
    pr_info("params: module unloaded\n");
}

module_init(params_init);
module_exit(params_exit);
