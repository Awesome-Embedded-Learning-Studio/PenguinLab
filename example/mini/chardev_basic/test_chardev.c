// test_chardev.c — 用户态字符设备测试程序
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

int main(void)
{
    int fd;
    char wbuf[] = "Hello from userspace! Testing chardev.\n";
    char rbuf[256] = {0};
    ssize_t n;

    fd = open("/dev/mychardev", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    /* 写入 */
    n = write(fd, wbuf, strlen(wbuf));
    printf("Wrote %zd bytes\n", n);

    /* 重置文件偏移 */
    lseek(fd, 0, SEEK_SET);

    /* 读回 */
    n = read(fd, rbuf, sizeof(rbuf) - 1);
    printf("Read %zd bytes: %s", n, rbuf);

    /* 验证数据一致 */
    if (strcmp(wbuf, rbuf) == 0)
        printf("Data integrity: OK\n");
    else
        printf("Data integrity: MISMATCH!\n");

    close(fd);
    return 0;
}
