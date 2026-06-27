obj-m += irq.o
# Import the common stub
include ../../common/Makefile.arch

# Make the kernel modules (默认)
all modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# 无用户态测试程序: 中断由设备触发, 靠 /proc/interrupts + dmesg 验证

# Clean it up
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
