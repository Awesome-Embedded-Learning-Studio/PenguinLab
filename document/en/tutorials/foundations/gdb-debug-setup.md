## What We're Doing

In this post, we set up the foundational infrastructure for kernel debugging — GDB remote debugging of an ARM64 kernel. We'll rely on this toolchain later when writing kernel modules, debugging drivers, and tracking down panics, so it's worth taking the time to get it right. Honestly, this process is more convoluted than it seems. We ran into three layers of issues: QEMU not exposing a debug port, VSCode's debug configuration using the wrong GDB, and KASLR causing breakpoint address mismatches. None of these are complex in isolation, but stacked together they produce the blood-pressure-spiking phenomenon of "the breakpoint is red but the kernel just runs right past it." We'll break this down from start to finish so you can quickly pinpoint similar issues using this troubleshooting hierarchy in the future.

## What You Need to Know

### Layer 1: QEMU Must Expose the GDB Port

By default, when QEMU launches a kernel, it runs straight through without pausing anywhere to wait for a debugger connection. To give GDB a chance to intervene, we need two startup parameters: `-s` is shorthand for `-gdb tcp::1234`, which tells QEMU to listen on port 1234 for the GDB remote debugging protocol; `-S` freezes the CPU immediately after launch, preventing it from executing the first instruction until GDB sends the `continue` command to continue.

Our [qemu-run.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/qemu-run.sh) script adds a `debug` command for this, automatically appending `-s -S` when building the QEMU command:

```bash
./scripts/qemu-run.sh debug
```

This way, QEMU pauses in its initial state after launch, waiting for GDB to connect. If we start it directly with the `run` command, the kernel runs to completion without waiting, leaving no window for GDB to connect.

### Layer 2: We Must Use a Cross-Debugger

This is the pitfall we actually fell into. Initially, our VSCode `launch.json` configuration used the local `/usr/bin/gdb` — an x86_64 GDB that doesn't understand the ARM64 instruction set at all. While connecting to QEMU's GDB stub doesn't inherently require understanding the target architecture (the GDB remote protocol is architecture-agnostic), operations like parsing symbols, setting breakpoints, and single-stepping all require understanding the target binary's instruction encoding and register layout — things an x86 GDB simply can't do.

The correct approach is to use the `aarch64-linux-gnu-gdb` included with our cross-toolchain. The corrected VSCode `launch.json` configuration looks like this:

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Kernel Debug (ARM64 QEMU)",
            "type": "cppdbg",
            "request": "launch",
            "program": "${workspaceFolder}/out/build_latest_arm64/vmlinux",
            "MIMode": "gdb",
            "miDebuggerPath": "/usr/sbin/aarch64-linux-gnu-gdb",
            "miDebuggerServerAddress": "localhost:1234",
            "cwd": "${workspaceFolder}",
            "setupCommands": [
                {
                    "text": "set architecture aarch64",
                    "ignoreFailures": false
                }
            ]
        }
    ]
}
```

There are a few key points here. `program` points to `vmlinux` rather than `Image`, because GDB needs an ELF file to read the symbol table and debug information (`Image` is a raw binary stripped of that information). `miDebuggerPath` points to the cross-debugger. `miDebuggerServerAddress` tells VSCode the address and port of the GDB stub. Note that we should not redundantly add `target remote localhost:1234` inside `setupCommands` — the `miDebuggerServerAddress` field itself causes the cppdbg adapter to automatically execute a `target remote` connection, and doing it manually again will trigger a duplicate connection error.

### Layer 3: KASLR Shifts Breakpoint Addresses

After fixing the first two layers, we used command-line GDB to verify that breakpoints could indeed be set successfully:

```
$ aarch64-linux-gnu-gdb -batch \
  -ex "set architecture aarch64" \
  -ex "target remote localhost:1234" \
  -ex "break start_kernel" \
  -ex "info breakpoints" \
  out/build_latest_arm64/vmlinux

Breakpoint 1 at 0xffff800081f207c4: file init/main.c, line 1007.
```

The breakpoint at `start_kernel` is set at `0xffff800081f207c4`, the address resolves correctly, and the source line number matches. But the kernel still didn't stop — this is the third layer of the problem.

The root cause is KASLR (Kernel Address Space Layout Randomization). Our mini config has `CONFIG_RANDOMIZE_BASE=y` enabled, which means the kernel adds a random offset to its own load base address on every boot. The symbol addresses in the `vmlinux` file are statically linked at compile time — for example, `start_kernel` is at `0xffff800081f207c4`, and the kernel base `_text` starts at `0xffff800080000000`. But if KASLR takes effect, the actual runtime base is shifted to a different address. GDB uses the static compile-time addresses to set breakpoints, so naturally it can't intercept code executing at different addresses.

The solution is to add `nokaslr` to the kernel boot parameters, telling the kernel not to randomize addresses for this boot. We integrated this into the `debug` command so that KASLR is only disabled during debugging and remains enabled for normal runs:

```bash
build_qemu_debug_command() {
    local cmd
    cmd="$(build_qemu_command)"
    # nokaslr: 让 GDB 断点地址匹配 vmlinux 的静态符号
    cmd="${cmd/rdinit=\/init/rdinit=\/init nokaslr}"
    # -s -S: 开放 GDB 端口 + 启动时暂停
    cmd+=" -s -S"
    echo "${cmd}"
}
```

Here we use a bash string replacement trick to insert `nokaslr` into the existing `-append` parameter, rather than overwriting the entire parameter.

### The Complete Debugging Workflow

With all three layers fixed, the debugging workflow is fully connected. It takes three steps.

First, launch QEMU in debug mode in one terminal:

```bash
./scripts/qemu-run.sh debug
```

QEMU starts up and pauses, waiting for GDB to connect.

Second, connect with command-line GDB and set a breakpoint (or press F5 in VSCode):

```bash
aarch64-linux-gnu-gdb out/build_latest_arm64/vmlinux
(gdb) set architecture aarch64
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
```

Third, the breakpoint hits. You'll see GDB stop at the `start_kernel` function in `init/main.c`. From here, we can single-step, inspect variables, and examine the call stack.

### Troubleshooting Hierarchy Summary

Looking back, these three issues form an outside-in troubleshooting hierarchy. The outermost layer is QEMU startup parameters — without `-s -S`, GDB has no window to intervene at all. The middle layer is the debugging toolchain — using the wrong GDB or redundantly executing `target remote` causes connection errors. The deepest layer is the kernel's own security feature, KASLR — which causes runtime addresses to diverge from compile-time symbols. In the future, when encountering "breakpoint not hit" issues, we recommend troubleshooting layer by layer in this order: **QEMU parameters → GDB connection → address mapping**.

## Try It Yourself

1. Run `./scripts/qemu-run.sh debug` in a terminal and check whether the output contains "Waiting for GDB connection"
2. Open another terminal, connect with command-line GDB, and verify by setting a breakpoint: `aarch64-linux-gnu-gdb -batch -ex "target remote :1234" -ex "break start_kernel" -ex "c" out/build_latest_arm64/vmlinux`
3. If using VSCode, configure `launch.json` and press F5 to confirm the breakpoint hits
4. In GDB, try `bt` (view the call stack), `list` (view source code), and `info registers` (view registers)
5. Try setting breakpoints on other functions like `rest_init` or `kernel_init` to observe different stages of kernel startup

## Further Reading

- [GDB kernel debugging documentation](https://docs.kernel.org/process/debugging/gdb-kernel-debugging.html) — The official kernel.org guide to QEMU+GDB debugging
- [Speeding up kernel development with QEMU](https://lwn.net/Articles/660404/) — A classic LWN article
- qemu-run.sh — The `build_qemu_debug_command()` function in the project script
