# common/cross-compile.mk — Cross-compile toolchain definitions
#
# Usage: include ../../common/cross-compile.mk

# ARM32 toolchain
CC_ARM32   = arm-linux-gnueabihf-gcc
LD_ARM32   = arm-linux-gnueabihf-ld

# ARM64 toolchain
CC_ARM64   = aarch64-linux-gnu-gcc
LD_ARM64   = aarch64-linux-gnu-ld

# RISC-V toolchain
CC_RISCV   = riscv64-linux-gnu-gcc
LD_RISCV   = riscv64-linux-gnu-ld

# x86_64 (native)
CC_X86_64  = gcc
LD_X86_64  = ld
