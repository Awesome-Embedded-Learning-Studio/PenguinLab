// sym_export_a.c — 符号导出提供者
#include <linux/module.h>
#include <linux/kernel.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Symbol export provider module");

int my_add(int a, int b)
{
    pr_info("my_add called: %d + %d\n", a, b);
    return a + b;
}
EXPORT_SYMBOL_GPL(my_add);  /* 只有 GPL 模块才能使用 */

static int __init module_a_init(void) { return 0; }
static void __exit module_a_exit(void) {}
module_init(module_a_init);
module_exit(module_a_exit);
