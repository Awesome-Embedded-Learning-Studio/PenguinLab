// debugfs_demo.c — debugfs 基本使用
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/debugfs.h>
#include <linux/uaccess.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("debugfs basics demo");
MODULE_VERSION("0.1");

static struct dentry *debugfs_dir;
static u32 debugfs_counter = 0;
static char debugfs_msg[64] = "Hello from debugfs!\n";

static ssize_t msg_read(struct file *filp, char __user *buf, size_t count, loff_t *pos)
{
    return simple_read_from_buffer(buf, count, pos, debugfs_msg, strlen(debugfs_msg));
}

static ssize_t msg_write(struct file *filp, const char __user *buf, size_t count, loff_t *pos)
{
    ssize_t ret;
    if (count >= sizeof(debugfs_msg))
        count = sizeof(debugfs_msg) - 1;
    ret = simple_write_to_buffer(debugfs_msg, sizeof(debugfs_msg), pos, buf, count);
    if (ret > 0)
        debugfs_msg[ret] = '\0';
    return ret;
}

static const struct file_operations msg_fops = {
    .owner = THIS_MODULE,
    .read  = msg_read,
    .write = msg_write,
};

static int __init debugfs_demo_init(void)
{
    debugfs_dir = debugfs_create_dir("penguin_debug", NULL);
    if (IS_ERR(debugfs_dir))
        return PTR_ERR(debugfs_dir);

    debugfs_create_u32("counter", 0644, debugfs_dir, &debugfs_counter);
    debugfs_create_file("message", 0644, debugfs_dir, NULL, &msg_fops);

    pr_info("debugfs_demo: created /sys/kernel/debug/penguin_debug/\n");
    return 0;
}

static void __exit debugfs_demo_exit(void)
{
    debugfs_remove_recursive(debugfs_dir);
    pr_info("debugfs_demo: removed\n");
}

module_init(debugfs_demo_init);
module_exit(debugfs_demo_exit);
