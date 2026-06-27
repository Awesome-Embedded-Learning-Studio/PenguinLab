// SPDX-License-Identifier: GPL-2.0
/*
 * irq.c - 硬件中断演示: 上半部 + 线程化中断 + workqueue 下半部
 *
 * 配套教程: tutorials/drivers/05-drv-irq.md
 * 对应节点: drv-irq (layer-2)
 *
 * ⚠️ 这是个 platform driver, 与 01-04 的 misc 软设备不同:
 *    完整触发中断需要设备树里一个 compatible="penguinlab,irq-demo" 的设备
 *    并提供 interrupts 属性(见 README)。insmod 只注册驱动, 不调 probe。
 *
 * 演示要点:
 *   - devm_request_threaded_irq: 一次注册上半部 + 线程化下半部
 *   - 上半部 hardirq: 中断上下文, 绝不能睡, 只计数 + schedule_work + 返回 IRQ_WAKE_THREAD
 *   - 线程化 thread_fn: 进程上下文, 可 msleep 睡眠(IRQF_ONESHOT 保底)
 *   - workqueue 下半部: 另一种"可睡的下半部"姿势, 与线程化中断对比
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/interrupt.h>
#include <linux/workqueue.h>
#include <linux/preempt.h>		/* in_task(): 6.19 用它判上下文(in_irq 已移除) */
#include <linux/delay.h>
#include <linux/of.h>

struct irq_priv {
	int irq;
	unsigned long irq_count;
	struct work_struct bh_work;
};

/* workqueue 下半部: 进程上下文, 可睡眠/持锁 */
static void bh_work_fn(struct work_struct *w)
{
	pr_info("irq-demo: bottom half (workqueue) in task context (in_task=%d)\n",
		in_task());
}

/* 线程化中断处理: 进程上下文, 可睡眠 */
static irqreturn_t irq_thread_fn(int irq, void *dev_id)
{
	struct irq_priv *p = dev_id;

	msleep(10);		/* 线程化中断的铁证: 能睡不 panic */
	pr_info("irq-demo: thread_fn ran (in_task=%d), irq_count=%lu\n",
		in_task(), p->irq_count);
	return IRQ_HANDLED;
}

/* 上半部: 硬中断上下文, 绝不能睡, 要快 */
static irqreturn_t irq_hardirq(int irq, void *dev_id)
{
	struct irq_priv *p = dev_id;

	p->irq_count++;
	schedule_work(&p->bh_work);	/* 重活推给 workqueue 下半部 */
	pr_info("irq-demo: hardirq (in_task=%d, i.e. interrupt ctx), count=%lu -> wake thread\n",
		in_task(), p->irq_count);
	return IRQ_WAKE_THREAD;		/* 让 thread_fn 接管 */
}

static int irq_probe(struct platform_device *pdev)
{
	struct irq_priv *p;
	int ret;

	p = devm_kzalloc(&pdev->dev, sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;

	INIT_WORK(&p->bh_work, bh_work_fn);

	p->irq = platform_get_irq(pdev, 0);
	if (p->irq < 0)
		return p->irq;

	/*
	 * devm_request_threaded_irq: 注册上半部 irq_hardirq + 线程化 irq_thread_fn。
	 * IRQF_ONESHOT: hardirq 跑完保侍屏蔽, 直到 thread_fn 跑完——电平触发防风暴必备。
	 */
	ret = devm_request_threaded_irq(&pdev->dev, p->irq, irq_hardirq,
					irq_thread_fn, IRQF_ONESHOT,
					"irq-demo", p);
	if (ret) {
		dev_err(&pdev->dev, "request_threaded_irq failed: %d\n", ret);
		return ret;
	}

	platform_set_drvdata(pdev, p);
	dev_info(&pdev->dev, "registered irq %d\n", p->irq);
	return 0;
}

static const struct of_device_id irq_dt_ids[] = {
	{ .compatible = "penguinlab,irq-demo", },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, irq_dt_ids);

static struct platform_driver irq_drv = {
	.probe = irq_probe,
	.driver = {
		.name = "irq-demo",
		.of_match_table = irq_dt_ids,
	},
};
module_platform_driver(irq_drv);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("irq demo: hardirq + threaded irq + workqueue bottom half");
