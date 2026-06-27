// SPDX-License-Identifier: GPL-2.0
/*
 * chardev.c - 最小 misc 字符设备示例
 *
 * 配套教程: tutorials/drivers/01-drv-chardev.md
 * 对应节点: drv-chardev (layer-2)
 *
 * 注册一个 misc 设备 /dev/llkd_miscdrv: 内核里存一句"秘密",
 * 用户态 cat 读、echo 写。麻雀虽小, 字符设备全套骨架都在:
 *   - misc_register() 一把注册(内部走完 申请主号+cdev+建节点 三步)
 *   - file_operations 四件套 (.open/.read/.write/.release)
 *   - copy_to_user/copy_from_user 搬数据, 写时先判 count 上界返回 -EFBIG
 *   - mutex 保护内核缓冲区的并发读写
 */

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/string.h>
#include <linux/minmax.h>

#define DRVNAME "llkd_miscdrv"

/* 写入上界: 超过即拒, 严守 copy_from_user 不查缓冲区大小的安全红线 */
#define MAXBYTES	128

static char secret[MAXBYTES + 1];	/* 内核里存的那句"秘密" */
static size_t secret_len;		/* 当前秘密的有效长度 */
static DEFINE_MUTEX(dev_lock);		/* 保护 secret 的并发读写 */

static int chardev_open(struct inode *inode, struct file *filp)
{
	pr_info("%s: open() by pid %d\n", DRVNAME, task_pid_nr(current));
	return nonseekable_open(inode, filp);
}

static ssize_t chardev_read(struct file *filp, char __user *ubuf,
			    size_t count, loff_t *off)
{
	size_t to_read;
	ssize_t ret;

	mutex_lock(&dev_lock);
	/* 用 *off 驱动: 读到末尾返回 0, 让 cat 正常退出, 不死循环 */
	if (*off >= secret_len) {
		ret = 0;
		goto unlock;
	}
	to_read = min_t(size_t, count, secret_len - *off);
	if (copy_to_user(ubuf, secret + *off, to_read)) {
		ret = -EFAULT;
		goto unlock;
	}
	*off += to_read;
	pr_info("%s: read() %zu bytes\n", DRVNAME, to_read);
	ret = to_read;

unlock:
	mutex_unlock(&dev_lock);
	return ret;
}

static ssize_t chardev_write(struct file *filp, const char __user *ubuf,
			     size_t count, loff_t *off)
{
	ssize_t ret;

	/* 边界检查是驱动作者的命: 先拒超长, 再谈搬运 */
	if (count > MAXBYTES)
		return -EFBIG;

	mutex_lock(&dev_lock);
	if (copy_from_user(secret, ubuf, count)) {
		ret = -EFAULT;
		goto unlock;
	}
	secret_len = count;
	secret[secret_len] = '\0';	/* 补 NUL, 方便调试 %s 打印 */
	pr_info("%s: write() %zu bytes: %s\n", DRVNAME, secret_len, secret);
	ret = count;

unlock:
	mutex_unlock(&dev_lock);
	return ret;
}

static int chardev_release(struct inode *inode, struct file *filp)
{
	pr_info("%s: release() by pid %d\n", DRVNAME, task_pid_nr(current));
	return 0;
}

static const struct file_operations chardev_fops = {
	.owner		= THIS_MODULE,
	.open		= chardev_open,
	.read		= chardev_read,
	.write		= chardev_write,
	.release	= chardev_release,
	.llseek		= noop_llseek,	/* nonseekable_open() 才是真正禁 seek 的 */
};

static struct miscdevice chardev_misc = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= DRVNAME,
	.mode	= 0666,			/* 调试期图方便, 生产环境是大忌 */
	.fops	= &chardev_fops,
};

static int __init chardev_init(void)
{
	int ret;

	/* 给个初始秘密, 免得首次 cat 出来是空的 */
	strscpy(secret, "<empty>", MAXBYTES);
	secret_len = strlen(secret);

	ret = misc_register(&chardev_misc);
	if (ret) {
		pr_err("%s: misc_register failed: %d\n", DRVNAME, ret);
		return ret;
	}

	pr_info("%s: registered, initial secret = '%s'\n", DRVNAME, secret);
	return 0;
}

static void __exit chardev_exit(void)
{
	misc_deregister(&chardev_misc);
	pr_info("%s: deregistered\n", DRVNAME);
}

module_init(chardev_init);
module_exit(chardev_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("misc char device demo: cat/echo read/write with bounds check");
