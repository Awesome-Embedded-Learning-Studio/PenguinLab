## What We're Doing

This is the climax of our entire environment setup—we're finally going to boot the compiled kernel and the built rootfs. We'll use QEMU's `virt` machine type to boot the ARM64 kernel, then break down the boot log line by line to understand exactly what each output means. Understanding boot logs is a core skill in kernel learning, because when debugging drivers or troubleshooting issues later on, these logs are the primary information you'll work with.

## What to Know

### QEMU virt Machine Type

QEMU supports multiple machine types on the ARM/ARM64 platform, ranging from emulating real development boards (like Raspberry Pi or Versatile Express) to purely virtual machines. We use the `virt` type, which is QEMU's recommended virtual platform for ARM64 kernel development. `virt` doesn't emulate any real physical SoC; instead, it provides a clean set of VirtIO devices—generic virtualized device interfaces that offer good performance, clean code, and no legacy baggage.

You can use `qemu-system-aarch64 -M help` to see all ARM64 machine types supported by QEMU. The list is long, covering everything from various BMC boards to Xilinx Zynq, but we only care about `virt`.

### Boot Command

The project provides a [qemu-run.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/qemu-run.sh) script to simplify QEMU's boot parameters. It automatically detects the kernel image and rootfs file in the build output directory. Running it is straightforward:

```bash
./scripts/qemu-run.sh run
```

The script prints the detected configuration at startup so we can confirm it found the correct files:

```
[INFO] === QEMU ARM System Emulation ===
[INFO] Architecture:     aarch64
[INFO] Machine:          virt
[INFO] CPU:              cortex-a72
[INFO] Memory:           1G
[INFO] SMP:              2
[INFO] Detected QEMU binary: qemu-system-aarch64
[INFO] Auto-detected kernel: .../out/build_latest_arm64/arch/arm64/boot/Image
[INFO] Auto-detected initrd: .../out/build_latest_arm64/rootfs.cpio.gz
```

The kernel is `Image` (the ARM64 boot image we compiled in the previous article), the initrd is `rootfs.cpio.gz` (the BusyBox rootfs we packaged in the article before that), and we don't need to specify a DTB—the QEMU virt machine automatically generates a Device Tree and passes it to the kernel.

After booting, press `Ctrl+A, X` in the QEMU serial terminal to exit.

### Boot Log Breakdown

The kernel boot log is a timeline. The timestamp at the beginning of each line, `[0.000000]`, represents the seconds elapsed since the kernel started. Let's break down our actual boot output section by section to understand the different phases of kernel startup.

**Phase 1: Kernel Decompression and Platform Initialization (0.000000 - 0.010000)**

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd083]
[    0.000000] Linux version 6.19.9 (charliechen@Charliechen) (aarch64-linux-gnu-gcc (GCC) 15.2.0, GNU ld (GNU Binutils) 2.46.0) #1 SMP PREEMPT Sat May  9 13:22:23 CST 2026
```

The first line tells us the kernel is booting on CPU 0. `0x410fd083` is the CPU's MIDR (Main ID Register) value, and the QEMU-emulated cortex-a72 corresponds to this ID. The second line is the classic kernel version string, containing the compiler username, compiler version, linker version, SMP/PREEMPT flags, and build time. This information might look like showing off, but it's crucial for troubleshooting—we need to confirm we're actually running the kernel we compiled, not some version that came with the system.

```
[    0.000000] Machine model: linux,dummy-virt
[    0.000000] efi: UEFI not found.
```

`linux,dummy-virt` is the `model` property value of the QEMU virt machine in the Device Tree. "UEFI not found" is normal—we didn't configure a UEFI firmware, so the kernel jumps directly into startup from the bootloader, following the traditional Device Tree boot path.

```
[    0.000000] Kernel command line: console=ttyAMA0,115200 root=/dev/ram0 rdinit=/init
```

These are the boot parameters passed to the kernel. `console=ttyAMA0,115200` specifies the serial console device as the PL011 UART with a baud rate of 115200; `root=/dev/ram0` tells the kernel that the root filesystem is on a RAM disk; `rdinit=/init` specifies the first userspace program the kernel executes inside the initramfs.

**Phase 2: Memory and CPU Initialization (0.000000 - 0.070000)**

```
[    0.000000] Zone ranges:
[    0.000000]   DMA      [mem 0x0000000040000000-0x000000007fffffff]
[    0.000000]   DMA32    empty
[    0.000000]   Normal   empty
```

The kernel divides physical memory into different zones. The entire 1GB kernel on ARM64 falls into the DMA zone (0x40000000-0x7FFFFFFF), because our QEMU is configured with 1GB of memory starting at address 0x40000000 (the DRAM base address of the virt machine). The DMA32 and Normal zones are empty because a 1GB address range doesn't require higher zones.

```
[    0.065793] Detected PIPT I-cache on CPU1
[    0.066669] CPU1: Booted secondary processor 0x0000000001 [0x410fd083]
[    0.070450] smp: Brought up 1 node, 2 CPUs
```

The SMP (Symmetric Multiprocessing) subsystem brings up the second CPU core. CPU0 is the primary core (boot CPU), which starts working at the very beginning of kernel boot; CPU1 is a secondary core, woken up shortly after by the SMP framework. Both cores are identified as cortex-a72.

**Phase 3: Kernel Subsystem Initialization (0.070000 - 0.500000)**

This is the longest section of the log. The kernel's various subsystems initialize in a fixed order—memory management, scheduler, timers, interrupt controller, clocksource, device model, network stack, and so on. Each "Registered" or "initialized" represents a subsystem that has completed its initialization.

A few lines worth noting:

```
[    0.221730] Serial: AMBA PL011 UART driver
[    0.270233] 9000000.pl011: ttyAMA0 at MMIO 0x9000000 (irq = 13, base_baud = 0) is a PL011 rev1
[    0.273819] printk: console [ttyAMA0] enabled
```

The PL011 serial driver initializes and registers the `ttyAMA0` device. The MMIO address `0x9000000` is the physical address allocated by the QEMU virt machine for the PL011 UART. From this moment on, the output from `printk` actually appears on our terminal—everything we saw before this was actually stored in the kernel's log buffer first, and only flushed out together once the serial driver was ready.

**Phase 4: initramfs Decompression and Userspace Startup (0.420000 - 0.990000)**

```
[    0.428951] Unpacking initramfs...
```

The kernel begins decompressing our cpio.gz initramfs. It uses the gzip algorithm to decompress, then parses the file list in cpio newc format, creating each file into the rootfs.

```
[    0.987816] Freeing unused kernel memory: 3264K
[    0.989078] Run /init as init process
```

`Freeing unused kernel memory` is the kernel freeing the memory of the `__init` section—this code only runs once during the boot phase (such as various `__init` functions) and is no longer needed after startup, so the kernel reclaims this memory for system use. Then the kernel executes `/init`, transferring control from kernel space to userspace.

```
=== PenguinLab Initramfs ===
Kernel: 6.19.9
Console: /dev/console

Starting shell...

/bin/sh: can't access tty; job control turned off
~ #
```

This is the output from our `/init` script. That final `can't access tty; job control turned off` is not a fatal error—BusyBox's shell disables job control (Ctrl+Z, `fg`/`bg`, etc.) when there's no real TTY device, but basic command execution is unaffected.

At this point, from QEMU loading the kernel image to entering the BusyBox shell, the total time was less than 1 second. This speed is thanks to our streamlined mini config—no unnecessary driver initialization, no waiting for hardware probe timeouts, the entire boot chain is clean and efficient.

## Try It Yourself

1. Run `./scripts/qemu-run.sh run` and wait to enter the BusyBox shell
2. Run `uname -a` in the shell to confirm the kernel version is 6.19.9 and the architecture is aarch64
3. Run `cat /proc/cpuinfo` to see the CPU information reported by QEMU
4. Run `cat /proc/meminfo` to see the memory usage reported by the kernel
5. Run `ls /sys/` and `ls /dev/` to confirm that sysfs and devtmpfs are mounted correctly
6. Press `Ctrl+A, X` to exit QEMU

## Further Reading

- scripts/qemu-run.sh — The project's QEMU boot script; the `cmd_run()` function shows the complete boot parameter configuration
- [QEMU ARM System Emulator Documentation](https://www.qemu.org/docs/master/system/target-arm.html) — QEMU's official ARM/ARM64 emulation reference
- [Speeding up kernel development with QEMU](https://lwn.net/Articles/660404/) — A classic LWN article on why QEMU is the best companion for kernel development
