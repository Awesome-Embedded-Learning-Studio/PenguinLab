// sym_export_b.c — 符号导出消费者
#include <linux/module.h>
#include <linux/kernel.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Symbol export consumer module");

extern int my_add(int a, int b);  /* 声明外部符号 */

static int __init module_b_init(void)
{
    int result = my_add(3, 4);
    pr_info("my_add(3, 4) = %d\n", result);
    return 0;
}
static void __exit module_b_exit(void) {}
module_init(module_b_init);
module_exit(module_b_exit);
