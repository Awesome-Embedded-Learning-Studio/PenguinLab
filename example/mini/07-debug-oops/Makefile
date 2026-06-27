obj-m += oops.o
# Import the common stub
include ../../common/Makefile.arch

# Make the kernel modules (默认)
all modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# Clean it up
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
