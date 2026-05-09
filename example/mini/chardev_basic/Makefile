include ../../common/Makefile.arch

obj-m += chardev.o

all: module usertest

module:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

usertest:
	$(CROSS_COMPILE)gcc -o test_chardev test_chardev.c

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
	rm -f test_chardev
