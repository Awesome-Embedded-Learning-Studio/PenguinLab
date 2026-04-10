# Makefile for kernel module examples
#
# Usage:
#   make                      # Build all modules
#   make KDIR=/path/to/linux  # Build with custom kernel source
#   make clean                # Clean build artifacts

# Kernel source tree — defaults to project's third_party/linux
KDIR ?= $(shell realpath $(dir $(lastword $(MAKEFILE_LIST)))/../../third_party/linux)
ARCH ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-

obj-m += hello.o
obj-m += sym_export_a.o
obj-m += sym_export_b.o

all:
	make -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

clean:
	make -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
