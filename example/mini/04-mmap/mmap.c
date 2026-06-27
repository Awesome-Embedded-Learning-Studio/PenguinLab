// SPDX-License-Identifier: GPL-2.0
/*
 * mmap.c - 把一页内核 RAM 映射进用户进程地址空间
 *
 * 配套教程: tutorials/drivers/04-drv-mmap.md
 * 对应节点: drv-mmap (layer-2)
 *
 * 演示要点:
 *   - init 里 alloc_page 一页内核 RAM, 填上特征魔数
 *   - .mmap 回调用 vm_insert_page 把这页映射出去(RAM 页的现代做法, 吃 struct page
 *     不用手算 pfn; 替代方案 remap_pfn_range(... page_to_pfn(page) ...) 见注释)
 *   - 用户态 mmap 后读魔数(映射建立) + 写回新值, release 时内核读回确认双向连通
 *
 * 无真实设备 I/O 内存: 映射的是普通内核 RAM 页, 不需要 pgprot_noncached。
 */

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/gfp.h>

#define DRVNAME "llkd_mmapdev"
#define MAGIC_BASE 0xDEADBEEFu

static struct page *shared_page;	/* 映射给用户的那一页内核 RAM */

static int drv_mmap(struct file *filp, struct vm_area_struct *vma)
{
	unsigned long size = vma->vm_end - vma->vm_start;

	/* 只允许映射这一页, 偏移必须为 0 */
	if (vma->vm_pgoff != 0 || size > PAGE_SIZE)
		return -EINVAL;

	/*
	 * 映射内核 RAM 单页: 优先 vm_insert_page(吃 struct page, 不用手算 pfn)。
	 * 等价的传统写法:
	 *   return remap_pfn_range(vma, vma->vm_start, page_to_pfn(shared_page),
	 *                          size, vma->vm_page_prot);
	 * 后者会给 VMA 打上 VM_IO|VM_PFNMAP; vm_insert_page 走的是 page 路径。
	 */
	return vm_insert_page(vma, vma->vm_start, shared_page);
}

static int drv_open(struct inode *inode, struct file *filp)
{
	return 0;
}

static int drv_release(struct inode *inode, struct file *filp)
{
	unsigned int *p = page_address(shared_page);

	/*
	 * 用户写的值直达这一页(共享映射), 这里读出来验证"内核侧读到用户写的"。
	 * 期望: 用户改了 page[0] 为 0xCAFEBABE, 这里 dmesg 应打印出来。
	 */
	pr_info("%s: release, page[0]=0x%08x page[1]=0x%08x (did user write?)\n",
		DRVNAME, p[0], p[1]);
	return 0;
}

static const struct file_operations drv_fops = {
	.owner		= THIS_MODULE,
	.open		= drv_open,
	.release	= drv_release,
	.mmap		= drv_mmap,
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
	unsigned int *p;
	int ret, i;

	shared_page = alloc_page(GFP_KERNEL | __GFP_ZERO);
	if (!shared_page)
		return -ENOMEM;

	/* 填特征值, 用户 mmap 后读应看到这一串 */
	p = page_address(shared_page);
	for (i = 0; i < PAGE_SIZE / sizeof(unsigned int); i++)
		p[i] = MAGIC_BASE + i;

	ret = misc_register(&drv_misc);
	if (ret) {
		__free_page(shared_page);
		pr_err("%s: misc_register failed: %d\n", DRVNAME, ret);
		return ret;
	}
	pr_info("%s: registered, shared page filled from 0x%08x\n",
		DRVNAME, MAGIC_BASE);
	return 0;
}

static void __exit drv_exit(void)
{
	misc_deregister(&drv_misc);
	__free_page(shared_page);
	pr_info("%s: deregistered\n", DRVNAME);
}

module_init(drv_init);
module_exit(drv_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("map one kernel RAM page to userspace via vm_insert_page");
