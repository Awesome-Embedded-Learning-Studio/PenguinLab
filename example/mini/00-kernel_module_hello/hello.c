#include <linux/init.h>
#include <linux/module.h>
#include <linux/printk.h>

static int my_first_module_init(void) {
  pr_info("My First Module!\n");
  return 0;
}

static void my_first_module_exit(void) {
  pr_info("My First Module exit, say goodbye!\n");
}

/* ===== ③ 注册:告诉内核"加载调谁、卸载调谁" ===== */
module_init(my_first_module_init); /* ← 括号里填你上面 init 函数的名字 */
module_exit(my_first_module_exit);

/* ===== ④ 元数据(最低限度要 license) ===== */
MODULE_LICENSE("GPL"); /* ← 不是任意字符串,必须是内核认识的值:"GPL"/"GPL
                          v2"/"Dual BSD/GPL" 等 */

MODULE_AUTHOR("CharlieChen114514");
MODULE_DESCRIPTION("A Module setup for qumu");