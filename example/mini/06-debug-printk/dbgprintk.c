// SPDX-License-Identifier: GPL-2.0
/*
 * printk.c - printk 八级日志 + pr_xxx 宏 演示
 *
 * 配套教程: tutorials/debugging/01-debug-printk.md
 * 对应节点: debug-printk (layer-4)
 *
 * 最朴素也最可靠的内核调试手段: 用各级别 printk 插桩, dmesg 看输出。
 * 演示:
 *   - pr_fmt 前缀(让每条打印自动带模块名, 定位调用者)
 *   - 八级 loglevel: pr_emerg .. pr_debug(KERN_EMERG .. KERN_DEBUG)
 *   - pr_debug 默认不打印(需 dynamic-debug 或 -DDEBUG), 这是常见坑
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt	/* 每条打印自动带 "printk: " 前缀 */

#include <linux/module.h>
#include <linux/printk.h>

static int __init printk_demo_init(void)
{
	pr_emerg("EMERG (0): system is unusable");
	pr_alert("ALERT (1): action must be taken immediately");
	pr_crit("CRIT  (2): critical conditions");
	pr_err("ERR   (3): error conditions");
	pr_warn("WARN  (4): warning conditions");
	pr_notice("NOTICE(5): normal but significant");
	pr_info("INFO  (6): informational");
	pr_debug("DEBUG (7): debug-level — 默认不显示, 需动态调试或 -DDEBUG");

	/* 也演示一次原始 KERN_* 写法, 与 pr_xxx 等价 */
	printk(KERN_INFO "printk demo: loaded, pr_fmt prefix = '%s'\n", pr_fmt(""));

	return 0;
}

static void __exit printk_demo_exit(void)
{
	pr_info("printk demo: unloaded");
}

module_init(printk_demo_init);
module_exit(printk_demo_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("printk loglevel + pr_xxx demo");
