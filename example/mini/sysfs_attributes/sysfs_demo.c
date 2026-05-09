// sysfs_demo.c — sysfs 属性演示
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/slab.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab learner");
MODULE_DESCRIPTION("sysfs attributes demo");
MODULE_VERSION("0.1");

static struct kobject *penguin_kobj;
static int penguin_value = 42;

static ssize_t value_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    return sprintf(buf, "%d\n", penguin_value);
}

static ssize_t value_store(struct kobject *kobj, struct kobj_attribute *attr,
                           const char *buf, size_t count)
{
    int ret;
    ret = kstrtoint(buf, 10, &penguin_value);
    if (ret < 0)
        return ret;
    pr_info("sysfs_demo: value changed to %d\n", penguin_value);
    return count;
}

static struct kobj_attribute value_attr = __ATTR(value, 0644, value_show, value_store);

static int __init sysfs_demo_init(void)
{
    int ret;
    penguin_kobj = kobject_create_and_add("penguin", kernel_kobj);
    if (!penguin_kobj)
        return -ENOMEM;
    ret = sysfs_create_file(penguin_kobj, &value_attr.attr);
    if (ret)
        kobject_put(penguin_kobj);
    pr_info("sysfs_demo: created /sys/kernel/penguin/value\n");
    return ret;
}

static void __exit sysfs_demo_exit(void)
{
    kobject_put(penguin_kobj);
    pr_info("sysfs_demo: removed\n");
}

module_init(sysfs_demo_init);
module_exit(sysfs_demo_exit);
