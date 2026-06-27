// SPDX-License-Identifier: GPL-2.0
/*
 * poll_user.c - 用户态: poll() 阻塞等待设备数据, 被唤醒后读出
 *
 * 交叉编译静态链接: make user
 * 验证场景: 本进程 poll 等待, 另一个终端 echo > /dev/llkd_polldev 触发唤醒。
 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>

#define DEV "/dev/llkd_polldev"

int main(void)
{
	int fd = open(DEV, O_RDWR);
	struct pollfd pfd;
	char buf[256];
	ssize_t n;
	int rc;

	if (fd < 0) {
		perror("open " DEV);
		return 1;
	}

	pfd.fd = fd;
	pfd.events = POLLIN;
	pfd.revents = 0;

	printf("poll() waiting for data (10s timeout)...\n");
	printf("in another shell run: echo hello > %s\n", DEV);

	rc = poll(&pfd, 1, 10000);
	if (rc < 0) {
		perror("poll");
		close(fd);
		return 1;
	}
	if (rc == 0) {
		printf("timeout, no data\n");
		close(fd);
		return 0;
	}

	if (pfd.revents & POLLIN) {
		n = read(fd, buf, sizeof(buf) - 1);
		if (n > 0) {
			buf[n] = '\0';
			printf("poll woken up, read %zd bytes: '%s'\n", n, buf);
		}
	}
	close(fd);
	return 0;
}
