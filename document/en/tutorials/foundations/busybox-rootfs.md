## What We're Doing

The kernel is compiled, but a kernel alone isn't enough to be useful—after booting, the kernel needs a rootfs to provide a basic user-space environment. At the very least, we need a shell to type commands into. In this article, we use BusyBox to build a minimal rootfs, package it into a cpio.gz initramfs image, and use it as the initial RAM disk when the kernel boots. Once done, we'll have all the materials needed for booting: a compiled kernel + a packaged rootfs.

## What to Know

### Why BusyBox

BusyBox is the Swiss Army knife of the embedded Linux world—it packages dozens of standard Linux tools like `ls`, `cat`, `sh`, `mount`, `cp`, and `mv` into a single binary file. Through symbolic links, each "command" points to the same busybox executable. The benefit is a massive saving in storage space: the entire user-space toolset takes up only a few hundred KB, making it perfect for capacity-sensitive scenarios like initramfs.

Our rootfs doesn't need to be a fully functional Linux distribution. It only needs to do one thing: give us an interactive shell after booting so we can run basic commands like `uname -a`, `cat /proc/cpuinfo`, and `ls /sys/` to verify kernel functionality. BusyBox perfectly meets this need.

(A quick plug: the author vibe-coded a minimal core-binutils similar to BusyBox called CFBox. Check it out on GitHub: https://github.com/Awesome-Embedded-Learning-Studio/CFBox)


### Building the rootfs

The project provides an automation script, [rootfs-minimal-maker.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/rootfs-minimal-maker.sh), to handle the entire rootfs build process. Its core tasks include: compiling BusyBox (statically linked), creating the rootfs directory structure (`bin/`, `sbin/`, `usr/`, `proc/`, `sys/`, `dev/`, etc.), installing BusyBox's symbolic links, and generating the `/init` boot script. Run it like this:

```bash
ARCH=aarch64 ./scripts/rootfs-minimal-maker.sh defconfig
```

Here, `ARCH=aarch64` is critical—it determines whether the compiled BusyBox is for ARM64. If we forget to set `ARCH`, the script won't throw an error, but it will output the rootfs to a directory with a weird path (`out/build_latest_/rootfs/`—note the empty underscore, which happens because `ARCH` is empty), and the compiled BusyBox might be for the x86 architecture. We've actually fallen into this trap, and it's surprisingly tricky to debug.

After the build completes, let's check the rootfs directory:

```bash
ls out/build_latest_arm64/rootfs/
# bin/  dev/  etc/  init*  proc/  sbin/  sys/  usr/
```

A minimal bootable rootfs needs these directories and files. Under `bin/` and `sbin/` are BusyBox's symbolic links, and `init` is the first user-space program executed after the kernel boots.

### /init: The First User-Space Program After Kernel Boot

After completing hardware initialization, the kernel executes the `/init` program in the rootfs (assuming the kernel command line specifies `rdinit=/init`). Our `/init` is a simple shell script that does something very straightforward: it mounts `/proc`, `/sys`, and `/dev` (devtmpfs), then starts an interactive shell.

```bash
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec /bin/sh
```

Every line here is necessary. `/proc` provides the process information and kernel parameter interface, `/sys` provides the device model and driver information, and `/dev` provides device nodes (such as `/dev/console`, `/dev/null`, etc.). If we forget to mount `/dev`, BusyBox's shell will complain about `can't access tty` when starting. The shell will still come up, but it will lack some features (like job control).

### Packaging as cpio.gz

The initrd image QEMU needs is a cpio-format archive, and it must be in `newc` format—this is the standard format for kernel initramfs. Our build script already includes the packaging step, but if we need to package it manually (for example, after modifying the rootfs contents), the command is as follows:

```bash
cd out/build_latest_arm64/rootfs
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > ../rootfs.cpio.gz
```

Let's break down this pipeline command: `find . -print0` recursively lists all files under rootfs, separated by null bytes (to handle spaces and special characters in filenames); `cpio --null -ov --format=newc` reads these paths and packages them into a newc-format cpio archive; `gzip -9` compresses it with the maximum compression ratio, ultimately producing a `rootfs.cpio.gz` file of about 1MB.

Why static linking? When compiling BusyBox, we chose static linking (`CONFIG_STATIC=y`), which means the BusyBox executable contains all the required C library functions and doesn't depend on any external shared libraries (`.so` files). This is necessary in the initramfs scenario because our rootfs doesn't have a `/lib/` directory—if BusyBox were dynamically linked, executing `/init` after the kernel boots would fail to find the dynamic linker (`ld-linux-aarch64.so.1`) and exit with an error.

## Try It Yourself

1. Run `ARCH=aarch64 ./scripts/rootfs-minimal-maker.sh defconfig` to build the rootfs
2. Check that the `out/build_latest_arm64/rootfs/init` file exists and has execute permissions (`ls -l`)
3. Use `file out/build_latest_arm64/rootfs/bin/busybox` to confirm BusyBox is a statically linked ARM64 binary
4. Check that `out/build_latest_arm64/rootfs.cpio.gz` has been generated, and use `ls -lh` to view its size

## Further Reading

- [rootfs-minimal-maker.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/rootfs-minimal-maker.sh) — The rootfs build script; the `setup_rootfs()` function in particular shows which directories and files a minimal rootfs needs
- [BusyBox Official Website](https://busybox.net/) — The BusyBox project homepage and documentation
