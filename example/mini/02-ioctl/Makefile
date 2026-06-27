obj-m += ioctl.o
# Import the common stub
include ../../common/Makefile.arch

# Make the kernel modules (默认)
all modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# 用户态测试程序: 交叉编译 + 静态链接, 方便丢进最小 BusyBox rootfs
user: ioctl_user.c ioctl_cmd.h
	$(CROSS_COMPILE)gcc -static -o ioctl_user ioctl_user.c

# Clean it up
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f ioctl_user
