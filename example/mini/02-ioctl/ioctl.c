// SPDX-License-Identifier: GPL-2.0
/*
 * ioctl.c - 在 chardev 基础上扩展结构化 ioctl 命令通道
 *
 * 配套教程: tutorials/drivers/02-drv-ioctl.md
 * 对应节点: drv-ioctl (layer-2)
 *
 * 在 misc 字符设备上挂 .unlocked_ioctl, 演示:
 *   - IOC_GETSTATUS (_IOWR): copy_from_user 收参数, 填充状态, copy_to_user 回填
 *   - IOC_RESET     (_IO)  : 无参数重置
 *   - default            : -ENOTTY (不认识的命令必须拒, 绝不放行)
 *   - .compat_ioctl = compat_ptr_ioctl (struct 布局 32/64 兼容, 复用通用实现)
 */

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/string.h>
#include <linux/minmax.h>
#include <linux/compat.h>

#define DRVNAME "llkd_miscdrv"

#include "ioctl_cmd.h"		/* 内核/用户共享的命令定义 */

struct drv_state {
	unsigned int open_count;
	unsigned int ioctl_count;
	char secret[64];
	size_t secret_len;
};

static struct drv_state state;
static DEFINE_MUTEX(state_lock);	/* 保护 state 的并发访问 */

static int drv_open(struct inode *inode, struct file *filp)
{
	mutex_lock(&state_lock);
	state.open_count++;
	pr_info("%s: open() (#%u)\n", DRVNAME, state.open_count);
	mutex_unlock(&state_lock);
	return nonseekable_open(inode, filp);
}

/* 把当前状态填进用户给的结构体。注意: copy_to_user 可能睡眠, 必须在锁外。 */
static int fill_status(struct drv_status __user *ust)
{
	struct drv_status st;

	mutex_lock(&state_lock);
	state.ioctl_count++;
	st.open_count = state.open_count;
	st.ioctl_count = state.ioctl_count;
	st.secret_len = min_t(size_t, state.secret_len, sizeof(st.secret));
	memcpy(st.secret, state.secret, sizeof(st.secret));
	mutex_unlock(&state_lock);

	if (copy_to_user(ust, &st, sizeof(st)))
		return -EFAULT;

	pr_info("%s: IOC_GETSTATUS open=%u ioctl=%u\n",
		DRVNAME, st.open_count, st.ioctl_count);
	return 0;
}

static long drv_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	switch (cmd) {
	case IOC_GETSTATUS:
		return fill_status((struct drv_status __user *)arg);
	case IOC_RESET:
		mutex_lock(&state_lock);
		strscpy(state.secret, "<empty>", sizeof(state.secret));
		state.secret_len = strlen(state.secret);
		state.ioctl_count = 0;
		mutex_unlock(&state_lock);
		pr_info("%s: IOC_RESET done\n", DRVNAME);
		return 0;
	default:
		/*
		 * 不认识的命令必须返 -ENOTTY, 绝不能让 default 悄悄放行——
		 * 否则一个不校验的 ioctl 就是个后门(见教程"未文档化命令"一节)。
		 */
		return -ENOTTY;
	}
}

static int drv_release(struct inode *inode, struct file *filp)
{
	return 0;
}

static const struct file_operations drv_fops = {
	.owner		= THIS_MODULE,
	.open		= drv_open,
	.release	= drv_release,
	.unlocked_ioctl	= drv_ioctl,
	.compat_ioctl	= compat_ptr_ioctl,	/* 布局兼容, 复用通用实现规整指针 */
	.llseek		= noop_llseek,
};

static struct miscdevice drv_misc = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= DRVNAME,
	.mode	= 0666,
	.fops	= &drv_fops,
};

static int __init drv_init(void)
{
	int ret;

	strscpy(state.secret, "<empty>", sizeof(state.secret));
	state.secret_len = strlen(state.secret);

	ret = misc_register(&drv_misc);
	if (ret) {
		pr_err("%s: misc_register failed: %d\n", DRVNAME, ret);
		return ret;
	}
	pr_info("%s: registered (with ioctl)\n", DRVNAME);
	return 0;
}

static void __exit drv_exit(void)
{
	misc_deregister(&drv_misc);
	pr_info("%s: deregistered\n", DRVNAME);
}

module_init(drv_init);
module_exit(drv_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("misc char device with structured ioctl commands");
