## What We'll Do

In this section, we do exactly one thing—compile our carefully crafted mini config into a bootable ARM64 kernel. The compilation itself is just a single `make` command, but the kernel build system produces very rich output that is worth taking the time to understand. When we finish, we'll get a `Image` file—this is the ARM64 kernel boot image that QEMU will load later to boot the system.

## What to Know

### Kicking Off the Build

Make sure you've completed the three-step configuration process from the previous section and that `out/build_latest_arm64/.config` exists with the correct contents. Then, run the following in the `third_party/linux/` directory:

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 -j$(nproc)
```

`-j$(nproc)` automatically uses all available CPU cores for parallel compilation. On our 14-thread machine, a mini config build takes about 3–5 minutes; if we use the 952 options in `defconfig`, that time doubles or more.

During the build, you'll see a massive amount of output scrolling rapidly across the terminal, with a short tag at the beginning of each line. If these tags look like gibberish, don't worry—that's exactly what we're about to break down.

### Build Output Tags Cheat Sheet

The kernel build system defines an abbreviated tag for each type of operation, controlled by the `quiet_cmd_*` variable in `scripts/Makefile.*`. In the default mode (without the `V=` parameter), `make` only shows these abbreviations instead of the full command lines, keeping the output compact and readable.

First are the core compilation tags. **CC** is the one you'll see most often; it represents the C compiler translating a `.c` source file into a `.o` object file. If it's followed by `[M]`, it means the file is being compiled as a loadable module (`.ko`) rather than built into the core kernel. **AS** is the assembler, handling `.S` assembly source files—many critical paths on ARM64, such as boot code, interrupt handling, and context switching, are written in assembly. **LD** is the linker, combining multiple `.o` files into a larger object; similarly, `[M]` indicates that a module is being linked. **AR** is the archiver, packing a batch of `.o` files into a `.a` static library—every subdirectory in the kernel source tree ultimately produces a `built-in.a` containing all the object files from that directory that need to be built into the kernel.

Next are the host tool tags. **HOSTCC** and **HOSTLD** compile and link helper tools that run on the host machine (our x86_64 WSL2). These tools aren't for the target board; they're small utilities needed by the kernel build process itself, such as generating the kernel symbol table or processing the device tree. You might also see **HOSTCXX**, which compiles C++ host tools (like the Qt-based graphical configuration tool for KConfig).

Generation and checking tags also appear frequently. **GEN** indicates the generation of various intermediate files, such as `asm-offsets` (a constant bridge between assembly and C) and `autoconf.h` (converting `.config` into a C header file). **CHK** and **UPD** are a duo—`CHK` checks whether a file's contents need to be regenerated, and if the check finds changes, a `UPD` line follows to indicate the file was actually updated.

Device tree related tags are common on ARM platforms. **DTC** is the Device Tree Compiler, which compiles `.dts` source files into `.dtb` binary blobs. The device tree is the standard way to describe hardware topology on ARM platforms. While the QEMU virt machine automatically generates a device tree, the kernel also has some device tree blobs embedded at compile time.

Module related tags appear toward the final stages of compilation. **MODPOST** stands for module post-processing; it generates the `Module.symvers` file (recording version information for all exported symbols) and checks module symbol dependencies. **SIGN** signs the modules (if `CONFIG_MODULE_SIG` is enabled), and **DEPMOD** generates the module dependency file `modules.dep`.

If you want to see the full command line behind each tag, simply add `V=1` to the `make` command:

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 V=1 -j$(nproc)
```

This prints the complete `gcc`/`ld` command for every step, including all compiler options, header search paths, and macro definitions. `V=1` is essential when debugging build issues.

### Verifying the Build Results

After a successful build, the last line of output should look something like this:

```
LD      arch/arm64/boot/Image
```

The ARM64 kernel boot image is called `Image` (note that it is uncompressed) and is located under `arch/arm64/boot/` in the build output directory. We use the `file` command to verify its format:

```bash
file out/build_latest_arm64/arch/arm64/boot/Image
# Linux kernel ARM64 boot executable Image, little-endian, 4K pages
```

Seeing `Linux kernel ARM64 boot executable Image` means we're on the right track. The ARM32 platform uses a different image name and format—there it's called `zImage` (self-extracting compressed image)—but the principle is the same: QEMU loads this file and jumps into it for execution.

In addition to `Image`, there's another important file in the build output directory: `vmlinux`. This is the uncompressed ELF format kernel, containing the full symbol table and debug information, which we'll need later for GDB debugging. `Image` is a pure binary image generated from `vmlinux` by stripping the ELF headers and debug information using `objcopy`. It is smaller in size and suitable for QEMU to load.

### Output Directory Structure

We use the `O=` parameter to place all build artifacts in the `out/build_latest_arm64/` directory, rather than scattering files throughout the source tree. The structure of this directory is essentially a mirror of the source tree—compiled `.o` artifacts from source files under `kernel/sched/` in the source tree end up under `out/build_latest_arm64/kernel/sched/`, and the boot image from `arch/arm64/boot/` in the source tree lands in `out/build_latest_arm64/arch/arm64/boot/`. The benefit of this separation is that the source tree stays clean, and switching between build outputs for different architectures won't cause any cross-contamination. It's just like when we write our own C/C++ projects and use build tools like CMake to specify a dedicated build directory, right?

## Try It Yourself

1. Confirm that the configuration process from the previous section is complete and that `out/build_latest_arm64/.config` exists
2. Run the build command and observe the various tags in the terminal output
3. After the build finishes, use the `file` command to verify the format of the `Image` file
4. Use `ls -lh out/build_latest_arm64/arch/arm64/boot/Image out/build_latest_arm64/vmlinux` to compare the sizes of the two, and understand why QEMU uses `Image` while GDB uses `vmlinux`
5. Try a `V=1` build (you can compile just a single file: `make O=... arch/arm64/kernel/setup.o V=1`) to see what the full command line looks like

## Further Reading

- [Linux Kernel Build Instructions](https://docs.kernel.org/admin-guide/README.html) — The official compilation guide on kernel.org
- [Kbuild Documentation](https://www.kernel.org/doc/html/latest/kbuild/kbuild.html) — Detailed documentation for the build system
