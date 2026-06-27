/* SPDX-License-Identifier: GPL-2.0 */
/*
 * ioctl_cmd.h - 内核/用户共享的 ioctl 命令定义
 *
 * 铁律: 用户态和内核态必须共用同一份命令定义头, 保证两边算出来的
 *       cmd 位级一致; _IOC_TYPECHECK 让你改了参数结构体大小后,
 *       命令码自动失效旧码, 用旧头编译的程序一眼就能被识别。
 */
#ifndef _LLKD_IOCTL_CMD_H
#define _LLKD_IOCTL_CMD_H

#ifdef __KERNEL__
#include <linux/ioctl.h>
#else
#include <sys/ioctl.h>		/* 用户态: 提供 _IO/_IOWR 等宏 */
#endif

/*
 * 设备状态结构体。布局在 32/64 位下一致(没有 long/指针字段),
 * 所以驱动可以直接用 compat_ptr_ioctl 处理 32 位用户程序。
 */
struct drv_status {
	unsigned int open_count;	/* 累计 open 次数 */
	unsigned int ioctl_count;	/* 累计 ioctl(本设备) 次数 */
	unsigned int secret_len;	/* 当前秘密的有效长度 */
	char secret[64];		/* 当前秘密内容 */
};

/* 魔数 'k' 作为本驱动家族的"姓氏"; 序号从 1 起 */
#define IOC_GETSTATUS	_IOWR('k', 1, struct drv_status)	/* 双向: 读设备状态 */
#define IOC_RESET	_IO('k', 2)				/* 无参数: 重置 */

#endif /* _LLKD_IOCTL_CMD_H */
