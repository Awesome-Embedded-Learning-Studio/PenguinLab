// chardev.c — 完整字符设备驱动
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/mutex.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("Character device driver practice");

#define DEVICE_NAME "mychardev"
#define BUF_SIZE    4096

struct chardev_data {
    char *buffer;
    size_t buf_len;
    struct mutex lock;
    struct cdev cdev;
};

static dev_t devno;
static struct class *chardev_class;
static struct chardev_data *chardev;

/* ——— file_operations 实现 ——— */

static int chardev_open(struct inode *inode, struct file *filp)
{
    struct chardev_data *dev;
    dev = container_of(inode->i_cdev, struct chardev_data, cdev);
    filp->private_data = dev;
    pr_info(DEVICE_NAME ": opened (pid=%d)\n", current->pid);
    return 0;
}

static int chardev_release(struct inode *inode, struct file *filp)
{
    pr_info(DEVICE_NAME ": released\n");
    return 0;
}

static ssize_t chardev_read(struct file *filp, char __user *buf,
                             size_t count, loff_t *pos)
{
    struct chardev_data *dev = filp->private_data;
    ssize_t ret;

    if (mutex_lock_interruptible(&dev->lock))
        return -ERESTARTSYS;

    if (*pos >= dev->buf_len) {
        ret = 0;  /* EOF */
        goto out;
    }

    count = min(count, dev->buf_len - (size_t)*pos);
    if (copy_to_user(buf, dev->buffer + *pos, count)) {
        ret = -EFAULT;
        goto out;
    }

    *pos += count;
    ret = count;
    pr_debug(DEVICE_NAME ": read %zu bytes at offset %lld\n", count, *pos - count);

out:
    mutex_unlock(&dev->lock);
    return ret;
}

static ssize_t chardev_write(struct file *filp, const char __user *buf,
                              size_t count, loff_t *pos)
{
    struct chardev_data *dev = filp->private_data;
    ssize_t ret;

    if (count > BUF_SIZE)
        count = BUF_SIZE;

    if (mutex_lock_interruptible(&dev->lock))
        return -ERESTARTSYS;

    if (copy_from_user(dev->buffer, buf, count)) {
        ret = -EFAULT;
        goto out;
    }

    dev->buf_len = count;
    *pos = count;
    ret = count;
    pr_info(DEVICE_NAME ": wrote %zu bytes\n", count);

out:
    mutex_unlock(&dev->lock);
    return ret;
}

static const struct file_operations chardev_fops = {
    .owner   = THIS_MODULE,
    .open    = chardev_open,
    .release = chardev_release,
    .read    = chardev_read,
    .write   = chardev_write,
    .llseek  = default_llseek,
};

/* ——— 模块初始化 / 退出 ——— */

static int __init chardev_init(void)
{
    int ret;

    /* 1. 动态分配设备号 */
    ret = alloc_chrdev_region(&devno, 0, 1, DEVICE_NAME);
    if (ret < 0) {
        pr_err(DEVICE_NAME ": alloc_chrdev_region failed: %d\n", ret);
        return ret;
    }
    pr_info(DEVICE_NAME ": major=%d, minor=%d\n", MAJOR(devno), MINOR(devno));

    /* 2. 分配设备数据结构 */
    chardev = kzalloc(sizeof(*chardev), GFP_KERNEL);
    if (!chardev) {
        ret = -ENOMEM;
        goto err_region;
    }

    chardev->buffer = kzalloc(BUF_SIZE, GFP_KERNEL);
    if (!chardev->buffer) {
        ret = -ENOMEM;
        goto err_chardev;
    }

    mutex_init(&chardev->lock);

    /* 3. 初始化并注册 cdev */
    cdev_init(&chardev->cdev, &chardev_fops);
    chardev->cdev.owner = THIS_MODULE;
    ret = cdev_add(&chardev->cdev, devno, 1);
    if (ret < 0) {
        pr_err(DEVICE_NAME ": cdev_add failed: %d\n", ret);
        goto err_buffer;
    }

    /* 4. 创建设备类和设备节点（生成 /dev/mychardev） */
    chardev_class = class_create(DEVICE_NAME "_class");
    if (IS_ERR(chardev_class)) {
        ret = PTR_ERR(chardev_class);
        goto err_cdev;
    }

    if (IS_ERR(device_create(chardev_class, NULL, devno, NULL, DEVICE_NAME))) {
        ret = PTR_ERR(device_create(chardev_class, NULL, devno, NULL, DEVICE_NAME));
        goto err_class;
    }

    pr_info(DEVICE_NAME ": initialized, /dev/%s created\n", DEVICE_NAME);
    return 0;

err_class:
    class_destroy(chardev_class);
err_cdev:
    cdev_del(&chardev->cdev);
err_buffer:
    kfree(chardev->buffer);
err_chardev:
    kfree(chardev);
err_region:
    unregister_chrdev_region(devno, 1);
    return ret;
}

static void __exit chardev_exit(void)
{
    device_destroy(chardev_class, devno);
    class_destroy(chardev_class);
    cdev_del(&chardev->cdev);
    kfree(chardev->buffer);
    kfree(chardev);
    unregister_chrdev_region(devno, 1);
    pr_info(DEVICE_NAME ": removed\n");
}

module_init(chardev_init);
module_exit(chardev_exit);
