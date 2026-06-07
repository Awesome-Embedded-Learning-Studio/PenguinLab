## What We're Doing

In this section, we're going to do something many people won't tell you about — designing a streamlined kernel configuration from scratch, instead of blindly using `defconfig`. We'll end up with a kernel config containing only the minimal feature set required to boot the QEMU virt machine. It has just 442 `=y` config options, whereas `defconfig` has 952.

Wait, we're getting our hands dirty this soon? Yep, why not? Haha! Building a kernel config ourselves from the ground up — isn't that awesome?

## What to Know

### The Problem with defconfig

`defconfig` is a predefined default configuration in the kernel source tree. For ARM64, it's located at `arch/arm64/configs/defconfig`. Running `make defconfig` gives you a "working" kernel config, which sounds great. The problem is that this config includes drivers for a massive number of real SoCs — GPUs, audio, and various board peripheral drivers. For kernel learning with the QEMU virt machine, we don't need any of this hardware support. It does nothing but slow down compilation and distract us.

To put it bluntly, more than half of the 952 `=y` options are things we'll never use. The hundreds of extra drivers compiled in are all dead code inside QEMU. Rather than learning inside a bloated kernel, we're better off trimming it down ourselves.

### The Three-Step Configuration Process

Our strategy is "start from zero, enable on demand," broken down into three steps.

First, we use `allnoconfig` to generate a baseline config with almost everything disabled. This target sets all non-essential options to `n`, keeping only the hard dependencies of the architecture itself. For ARM64, the generated `.config` has only a few dozen options enabled, with everything else turned off.

```bash
cd third_party/linux
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 allnoconfig
```

Second, we use `merge_config.sh` to merge in our prepared config fragment. This script lives in the `scripts/kconfig/` directory of the kernel source. It works by merging options from the fragment file into the baseline config one by one — encountering `=y` enables them, and encountering `=m` sets them as modules. The `-m` parameter is followed by the path to the target `.config` file:

```bash
scripts/kconfig/merge_config.sh -m \
    ../../out/build_latest_arm64/.config \
    ../../configs/arm64-qemu-virt-learn.config
```

Third, we use `olddefconfig` to have the kernel build system automatically fill in all dependencies. Our hand-written fragment only lists the options "we know we need," but kernel configs have tons of implicit dependencies — for example, enabling `CONFIG_PRINTK=y` might require several other config options. `olddefconfig` traverses the entire config tree, automatically filling in all missing dependencies and applying default values to any newly introduced options:

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 olddefconfig
```

After these three steps, the final `.config` inflates from a few dozen options to 442 — the extras are all dependencies automatically filled in by `olddefconfig`. This number is still less than half of `defconfig`, and every enabled option can be traced back to a specific requirement in our fragment.

### Design Philosophy of the Config Fragment

Our prepared fragment file is [configs/arm64-qemu-virt-learn.config](configs/arm64-qemu-virt-learn.config). It's organized by functional category, with each group annotated with comments explaining "why we need these options." Of course, you might wonder what all these things are. If you're not entirely sure — a great approach is to use a recursive descent method to look up the related concepts. Let's quickly run through what these are:

First, the platform basics. The ARM64 architecture itself is mandatory, and SMP (Symmetric Multiprocessing) must be enabled since our QEMU launch will configure two CPU cores:

```
CONFIG_ARM64=y
CONFIG_64BIT=y
CONFIG_SMP=y
CONFIG_NR_CPUS=2
```

Next is the serial console. The QEMU virt machine uses the ARM PL011 UART for serial output, which is exactly what the `console=ttyAMA0` kernel boot parameter points to. Without these options, you'll see nothing after the kernel boots — no boot logs, no shell prompt, just dead silence:

```
CONFIG_TTY=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

Then comes initramfs support. Our rootfs will be packaged as a cpio.gz file loaded as an initrd, so the kernel must support gzip decompression to unpack it:

```
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
```

On the filesystem front, `devtmpfs` tells the kernel to automatically create device nodes under `/dev`, while `procfs` and `sysfs` provide kernel information interfaces for `/proc` and `/sys` respectively, and `tmpfs` is for memory-based filesystems. These four are the basic prerequisites for BusyBox shell to work properly. The kernel module related configs let us load and unload `.ko` modules later on, and the debugging support group (`DEBUG_INFO`, `GDB_SCRIPTS`, `KALLSYMS`) is prepared for GDB remote debugging.

The entire fragment is about 40 lines, with each config option accompanied by a comment explaining its purpose and dependencies. This "minimal + annotated" approach turns the config file itself into a study note.

### Pitfalls We Hit

This three-step process sounds simple, but we ran into quite a few pitfalls along the way. Here are the most noteworthy ones.

**"The source tree is not clean"**

This is the most common issue. The kernel Makefile has a check (in the `outputmakefile` target of `Makefile`) that, when using `O=` for out-of-tree builds, detects whether a `.config` file, a `include/config/` directory, or a `arch/arm64/include/generated/` directory exists in the source tree root. If it detects any of them, it deems the "source tree not clean" and refuses to continue.

Here's what happened to us: we had previously run a defconfig test directly in the source tree. Although we later cleaned up most artifacts with `make mrproper`, running `merge_config.sh` creates a `.config` file in the source tree root as a side effect, which caused subsequent `olddefconfig` runs to fail. The fix is straightforward — manually delete the leftover `.config`:

```bash
rm -f third_party/linux/.config
```

The core principle to prevent this issue: when building with `O=`, never run make directly inside the source tree. If you absolutely must operate inside the source tree (e.g., `merge_config.sh`), immediately check and clean up `.config` afterward.

**merge_config.sh Parameters**

The `-m` parameter must be followed by the full path to the target `.config` file, not a directory path. It modifies this file in place, merging the fragment options into it. So the correct invocation is `merge_config.sh -m <output_dir>/.config <fragment>`, not `merge_config.sh -m <output_dir> <fragment>`.

**Forgetting to Set ARCH and Building for x86**

This is a classic pitfall. The kernel build system determines the target architecture based on the `ARCH` variable; if unset, it defaults to the host architecture (x86_64 in WSL2). If `CROSS_COMPILE` is unset, it uses the native gcc. The result is that `make -j14` completes and outputs `arch/x86/boot/bzImage is ready` — a whole lot of compiling for nothing.

There are two solutions: either append `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-` to every make command, or export these two variables in the shell. The latter is less tedious, but keep in mind that export only affects the current shell session — close the terminal and you'll need to set them again.

**Working Directory and make -C**

Running `make O=... Image` directly from the project root `PenguinLab/` will throw a `No targets specified and no makefile found` error because the project root doesn't contain the kernel's Makefile. You either need to `cd third_party/linux` first before running make, or use `make -C third_party/linux` to explicitly specify the source directory.

## Try It Yourself

1. Confirm that `third_party/linux/Makefile` exists; if not, run `./scripts/linux-submodule.sh init` to fetch the kernel source
2. Execute the three-step configuration process in order: `allnoconfig` → `merge_config.sh` → `olddefconfig`, making sure to include `ARCH` and `CROSS_COMPILE` with each step
3. Use `grep -c "=y" out/build_latest_arm64/.config` to count the final number of config options — you should see a number between 400 and 500
4. Use `diff <(grep "=y" out/build_latest_arm64/.config | sort) <(grep "=y" <(make ARCH=arm64 O=../../out/build_latest_arm64 defconfig && cat ../../out/build_latest_arm64/.config) | sort)` to compare it against defconfig and see what we cut out

## Further Reading

- [Kbuild Kernel Build System Documentation](https://www.kernel.org/doc/html/latest/kbuild/kbuild.html) — Official definitions for variables like `ARCH`, `CROSS_COMPILE`, and `O=`
- [Linux Kernel Build Instructions](https://docs.kernel.org/admin-guide/README.html) — The official kernel.org getting-started guide for building the kernel
- [configs/arm64-qemu-virt-learn.config](configs/arm64-qemu-virt-learn.config) — Our mini config fragment file, with comments on every config option
