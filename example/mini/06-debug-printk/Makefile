obj-m += dbgprintk.o
# Import the common stub
include ../../common/Makefile.arch

# Make the kernel modules (默认)
all modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# 想让 pr_debug 也打印? 用 CFLAGS 定义 DEBUG(等价动态调试, 编译期开):
# make EXTRA_CFLAGS=-DDEBUG
# 或在 Makefile 里加: CFLAGS_printk.o = -DDEBUG

# Clean it up
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
