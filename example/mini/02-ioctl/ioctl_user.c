// SPDX-License-Identifier: GPL-2.0
/*
 * ioctl_user.c - 用户态测试程序: 通过 ioctl 读设备状态、重置
 *
 * 交叉编译静态链接, 拷进最小 BusyBox rootfs 跑:
 *   aarch64-linux-gnu-gcc -static -o ioctl_user ioctl_user.c
 * 或在 example 目录: make user
 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "ioctl_cmd.h"

#define DEV "/dev/llkd_miscdrv"

static void show_status(int fd, const char *tag)
{
	struct drv_status st;

	if (ioctl(fd, IOC_GETSTATUS, &st) < 0) {
		perror("ioctl IOC_GETSTATUS");
		return;
	}
	printf("[%s] open_count=%u ioctl_count=%u secret_len=%u secret='%s'\n",
	       tag, st.open_count, st.ioctl_count, st.secret_len, st.secret);
}

int main(void)
{
	int fd = open(DEV, O_RDWR);

	if (fd < 0) {
		perror("open " DEV);
		return 1;
	}

	show_status(fd, "first ");
	if (ioctl(fd, IOC_RESET) < 0)
		perror("ioctl IOC_RESET");
	show_status(fd, "reset ");

	close(fd);
	return 0;
}
