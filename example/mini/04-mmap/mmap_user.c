// SPDX-License-Identifier: GPL-2.0
/*
 * mmap_user.c - 用户态: mmap 设备页, 读内核魔数 + 写回新值
 *
 * 交叉编译静态链接: make user
 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define DEV "/dev/llkd_mmapdev"
#define MAGIC_BASE 0xDEADBEEFu
#define PAGE 4096

int main(void)
{
	int fd = open(DEV, O_RDWR);
	unsigned int *map;

	if (fd < 0) {
		perror("open " DEV);
		return 1;
	}

	map = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	/* 1. 读内核填的魔数 → 映射建立成功 */
	printf("kernel magic: page[0]=0x%08x page[1]=0x%08x\n", map[0], map[1]);
	if (map[0] == MAGIC_BASE)
		printf("OK: mapping established, kernel magic visible\n");
	else
		printf("WARN: expected 0x%08x\n", MAGIC_BASE);

	/* 2. 用户写新值, 内核 release 时会读到(共享映射, 写直达物理页) */
	map[0] = 0xCAFEBABE;
	map[1] = 0x12345678;
	printf("user wrote:   page[0]=0x%08x page[1]=0x%08x\n", map[0], map[1]);

	munmap(map, PAGE);
	close(fd);		/* 触发 .release, dmesg 看 kernel 读到的值 */
	printf("check dmesg for kernel-side read\n");
	return 0;
}
