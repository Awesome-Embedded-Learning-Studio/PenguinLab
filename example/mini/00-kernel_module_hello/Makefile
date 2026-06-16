obj-m += hello.o
# Import the common stub
include ../../common/Makefile.arch

# Make the kernel modules
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# Clean it up
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean