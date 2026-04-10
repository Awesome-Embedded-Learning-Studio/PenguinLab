# Makefile for character device driver example
#
# Usage:
#   make                      # Build driver + userspace test
#   make KDIR=/path/to/linux  # Build with custom kernel source
#   make clean                # Clean build artifacts

KDIR ?= $(shell realpath $(dir $(lastword $(MAKEFILE_LIST)))/../../third_party/linux)
ARCH ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-

obj-m += chardev.o

all: module usertest

module:
	make -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

usertest:
	$(CROSS_COMPILE)gcc -o test_chardev test_chardev.c

clean:
	make -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
	rm -f test_chardev
