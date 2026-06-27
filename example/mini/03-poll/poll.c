// SPDX-License-Identifier: GPL-2.0
/*
 * poll.c - 字符设备的 poll/select + 等待队列 + 阻塞 read 配合
 *
 * 配套教程: tutorials/drivers/03-drv-poll.md
 * 对应节点: drv-poll (layer-2)
 *
 * 演示 poll 机制的核心纪律:
 *   - .poll 回调两件事缺一不可: poll_wait 登记等待队列 + 返回当前就绪掩码
 *   - .poll 和阻塞 .read 共用同一个 wait_queue_head(否则两边叫不齐)
 *   - .read 尊重 O_NONBLOCK: 没数据立刻返 -EAGAIN
 *   - write 模拟"数据来了": 写完 wake_up_interruptible 叫醒 poll/阻塞read 的等待者
 *
 * 无真实硬件: 用 write 触发数据到达, 不需要中断。
 */

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/poll.h>
#include <linux/wait.h>
#include <linux/minmax.h>

#define DRVNAME "llkd_polldev"
#define BUFSZ 256

static char data[BUFSZ];
static size_t data_len;
static bool data_ready;			/* 是否有待读数据 */
static DEFINE_MUTEX(dev_lock);
static DECLARE_WAIT_QUEUE_HEAD(read_wq);	/* poll 和阻塞 read 共用 */

static int drv_open(struct inode *inode, struct file *filp)
{
	return 0;
}

/* poll/select/epoll 共用入口: 两件事缺一不可 */
static __poll_t drv_poll(struct file *filp, struct poll_table_struct *wait)
{
	__poll_t mask = 0;

	poll_wait(filp, &read_wq, wait);	/* 1. 把当前进程登记到等待队列 */

	mutex_lock(&dev_lock);
	if (data_ready)				/* 2. 返回当前就绪状态 */
		mask |= EPOLLIN | EPOLLRDNORM;
	mutex_unlock(&dev_lock);
	return mask;
}

static ssize_t drv_read(struct file *filp, char __user *ubuf,
			size_t count, loff_t *off)
{
	size_t to_read;
	ssize_t ret;

	/* 非阻塞模式: 没数据立刻返 -EAGAIN, 不傻睡 */
	if (filp->f_flags & O_NONBLOCK && !READ_ONCE(data_ready))
		return -EAGAIN;

	/*
	 * 阻塞等数据。与 .poll 共用 read_wq, 所以 wake_up 能同时唤醒
	 * 阻塞 read 的等待者和 poll 的等待者——机制统一。
	 */
	if (wait_event_interruptible(read_wq, READ_ONCE(data_ready)))
		return -ERESTARTSYS;		/* 被信号打断 */

	mutex_lock(&dev_lock);
	if (!data_ready) {			/* 唤醒后二次确认, 防竞态 */
		ret = 0;
		goto unlock;
	}
	to_read = min_t(size_t, count, data_len);
	if (copy_to_user(ubuf, data, to_read)) {
		ret = -EFAULT;
		goto unlock;
	}
	data_ready = false;			/* 消费掉, 等下一批 */
	ret = to_read;
unlock:
	mutex_unlock(&dev_lock);
	return ret;
}

/* write 模拟"数据来了": 写完唤醒所有等待者 */
static ssize_t drv_write(struct file *filp, const char __user *ubuf,
			 size_t count, loff_t *off)
{
	size_t to_write = min_t(size_t, count, (size_t)BUFSZ);

	mutex_lock(&dev_lock);
	if (copy_from_user(data, ubuf, to_write)) {
		mutex_unlock(&dev_lock);
		return -EFAULT;
	}
	data_len = to_write;
	WRITE_ONCE(data_ready, true);
	mutex_unlock(&dev_lock);

	wake_up_interruptible(&read_wq);	/* 数据来了, 叫醒 poll/阻塞read */
	pr_info("%s: write() %zu bytes, woke up waiters\n", DRVNAME, to_write);
	return to_write;
}

static int drv_release(struct inode *inode, struct file *filp)
{
	return 0;
}

static const struct file_operations drv_fops = {
	.owner		= THIS_MODULE,
	.open		= drv_open,
	.read		= drv_read,
	.write		= drv_write,
	.poll		= drv_poll,
	.release	= drv_release,
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
	int ret = misc_register(&drv_misc);

	if (ret) {
		pr_err("%s: misc_register failed: %d\n", DRVNAME, ret);
		return ret;
	}
	pr_info("%s: registered (poll/wait_queue demo)\n", DRVNAME);
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
MODULE_DESCRIPTION("char device with poll() + wait_queue + blocking read");
