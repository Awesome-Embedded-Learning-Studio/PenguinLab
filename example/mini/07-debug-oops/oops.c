// SPDX-License-Identifier: GPL-2.0
/*
 * oops.c - 故意触发一次 NULL 解引用 Oops(门控, 默认安全)
 *
 * 配套教程: tutorials/debugging/05-debug-oops.md
 * 对应节点: debug-oops (layer-4)
 *
 * ⚠️ trigger=1 时 insmod 会触发内核 Oops。
 *    - panic_on_oops=0(默认): Oops 打印现场后杀掉 insmod 进程, 系统继续。
 *    - panic_on_oops=1:        系统直接 panic 死透。
 *
 * 演示要点:
 *   - NULL 指针 + 结构体成员偏移: p=NULL, &p->data = NULL+0x30, oops 报址 0x30
 *   - *(volatile) 防 GCC 把"已知 NULL 解引用"当 UB 优化掉
 *   - 配合 dmesg 读 Oops 现场: pc/Code(ARM64 圆括号)/Call trace/Tainted
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/printk.h>

static int trigger;
module_param(trigger, int, 0644);
MODULE_PARM_DESC(trigger, "1 = force a NULL-deref oops in init (default 0 = safe)");

/* data 偏移设计成 0x30(48): NULL + 0x30 = 0x30, oops 报的地址就是这个数 */
struct oopsie {
	char pad[0x30];
	char data;
};

static int __init oopsdemo_init(void)
{
	struct oopsie *p = NULL;

	if (!trigger) {
		pr_info("loaded (safe). rmmod && insmod oops.ko trigger=1 to force oops\n");
		return 0;
	}

	pr_info("about to write NULL->data (addr = NULL + 0x30 = 0x30)...\n");
	/*
	 * *(volatile) 防 GCC 把"已知 NULL 解引用"当 UB 优化掉; 真正触发 oops 的是这一行。
	 */
	*(volatile char *)&p->data = 'x';
	pr_info("never reached (if you see this, the oops got optimized away)\n");
	return 0;
}

static void __exit oopsdemo_exit(void)
{
	pr_info("unloaded\n");
}

module_init(oopsdemo_init);
module_exit(oopsdemo_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("intentional NULL-deref oops demo (trigger-gated)");
