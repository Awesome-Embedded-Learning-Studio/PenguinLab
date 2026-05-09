---
title: QEMU ARM Quick Reference
sidebar_position: 11
---

# QEMU ARM Quick Reference

A quick reference for QEMU ARM system emulation, designed to be used alongside the `scripts/qemu-run.sh` script.

---

## Common Commands

### List Supported Platforms

```bash
# ARM64
qemu-system-aarch64 -M help

# ARM32
qemu-system-arm -M help
```

### List Supported CPU Types

```bash
qemu-system-aarch64 -cpu help
qemu-system-arm -cpu help
```

### List Supported Devices

```bash
qemu-system-aarch64 -device help
```

### Launch QEMU Directly (Without the Script)

```bash
# ARM64 virt
qemu-system-aarch64 \
  -M virt \
  -cpu cortex-a72 \
  -m 1G \
  -smp 2 \
  -kernel Image \
  -nographic \
  -serial mon:stdio

# ARM32 vexpress
qemu-system-arm \
  -M vexpress-a9 \
  -cpu cortex-a9 \
  -m 512M \
  -kernel zImage \
  -dtb vexpress-v2p-ca9.dtb \
  -nographic \
  -serial mon:stdio
```

---

## QEMU virt Machine Hardware Specs

### ARM64 virt

| Device | Type | Kernel Driver | Device Node / Notes |
|--------|------|---------------|---------------------|
| UART | PL011 | amba-pl011 | ttyAMA0 |
| RTC | PL031 | arm-pl031 | |
| NIC | VirtIO-net | virtio_net | |
| Storage | VirtIO-blk | virtio_blk | |
| GPIO | VirtIO-gpio | virtio_gpio | |
| PCI | PCIe host | pcie-port | |
| Interrupt | GIC v3/v4 | irq-gic-* | |
| Timer | ARMv8 Arch Timer | arch_timer | |

### ARM32 vexpress

| Device | Type | Kernel Driver | Device Node |
|--------|------|---------------|-------------|
| UART | PL011 | amba-pl011 | ttyAMA0 |
| Ethernet | LAN9118 | smsc911x | eth0 |
| Display | PL111 CLCD | pl111 | fb0 |
| RTC | PL031 | pl031 | |
| Interrupt | GIC | irq-gic | |

---

## Kernel Configuration

### ARM64 defconfig

```bash
# Base config (includes VirtIO support)
make ARCH=aarch64 defconfig

# Ensure CONFIG_VIRTIO=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

### ARM32 vexpress_defconfig

```bash
make ARCH=arm vexpress_defconfig
```

---

## Serial Console

### QEMU Serial Shortcuts

| Key | Function |
|-----|----------|
| `Ctrl+A, X` | Quit QEMU |
| `Ctrl+A, C` | Switch to QEMU monitor |
| `Ctrl+A, Z` | Show help |

### QEMU Monitor Commands

```
(qemu) info version      # QEMU version
(qemu) info status       # Run state
(qemu) info cpus         # CPU info
(qemu) info mem          # Memory info
(qemu) info qtree        # Device tree
(qemu) quit              # Quit
```

---

## Network Configuration

### User-mode Networking (Default)

Simplest option, no extra configuration needed. Guest can access host, but not the other way around.

```bash
# Enable user-mode networking
QEMU_NET=on ./scripts/qemu-run.sh run

# Default port forwarding: 2222 → 22
# Inside guest: ssh -p 2222 user@10.0.2.2
```

### TAP Networking (Advanced)

Requires TAP device and bridge setup for full bidirectional networking.

```bash
# Create TAP device (requires root)
sudo ip tuntap add dev tap0 mode tap
sudo ip link set tap0 up

# Add to bridge
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip link set tap0 master br0

# Use TAP networking
QEMU_NET=on QEMU_NET_TAP=on QEMU_TAP_IF=tap0 ./scripts/qemu-run.sh run
```

---

## GDB Debugging

### Launch QEMU Waiting for GDB Connection

```bash
qemu-system-aarch64 -M virt -cpu cortex-a72 -kernel Image -s -S
# -s: shorthand for -gdb tcp::1234
# -S: freeze CPU at startup
```

### Connect GDB

```bash
aarch64-linux-gnu-gdb vmlinux
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
```

### Common GDB Commands

```
(gdb) info registers        # Show registers
(gdb) bt                    # Backtrace
(gdb) thread apply all bt   # Backtrace for all threads
(gdb) x/10i $pc             # Disassemble current instructions
(gdb) disassemble           # Disassemble current function
```

---

## Kernel Boot Parameters

### Common Parameters

| Parameter | Purpose |
|-----------|---------|
| `console=ttyAMA0,115200` | Serial console |
| `earlyprintk=serial,ttyAMA0` | Early serial output |
| `root=/dev/vda` | Root device |
| `rootfstype=ext4` | Root filesystem type |
| `ro` | Mount root read-only |
| `rw` | Mount root read-write |
| `debug` | Enable kernel debug output |
| `quiet` | Reduce boot messages |
| `ignore_loglevel` | Ignore log level limits |

### How to Set

```bash
# Via environment variable
QEMU_KERNEL_CMDLINE="console=ttyAMA0 debug" ./scripts/qemu-run.sh run

# Or modify the default in the script
```

---

## Troubleshooting

### QEMU Fails to Start

1. **Check QEMU installation**
   ```bash
   qemu-system-aarch64 --version
   qemu-system-arm --version
   ```

2. **Check kernel image exists**
   ```bash
   ls -lh out/build_latest/arch/arm64/boot/Image
   ```

3. **Increase debug output**
   ```bash
   qemu-system-aarch64 -d int,cpu_reset  # Show execution log
   ```

### Kernel Hangs at Boot

1. **Check last log message** — determine where it's stuck
2. **Check CONFIG_SERIAL_AMBA_PL011_CONSOLE** — is it enabled?
3. **Try a simpler cmdline** — remove potentially problematic parameters

### Device Not Working

1. **Check device tree**
   ```bash
   # In QEMU monitor
   (qemu) info qtree
   ```

2. **Check kernel config**
   ```bash
   # Ensure relevant drivers are compiled
   grep VIRTIO .config
   ```

---

## QEMU virt vs. Rockchip Hardware

| Feature | QEMU virt | Rockchip RK3399 | Migration Notes |
|---------|-----------|-----------------|-----------------|
| CPU | cortex-a72 | 2×A72 + 4×A53 | Use SMP config to simulate multi-core |
| Serial | ttyAMA0 | ttyS0~4 | Modify cmdline |
| NIC | virtio-net | r8169/fec | Different driver interface |
| Storage | virtio-blk | dw-mmc/SD | Needs real hardware testing |
| GPIO | virtio-gpio | pinctrl-gpio | Similar code structure |
| I2C | virtio-i2c | rk-i2c | Same driver framework |
| Power | (none) | rk-pm | Needs real hardware |

**Learning recommendation**:
- Use QEMU to learn **kernel frameworks** and **subsystems**
- Use real hardware to test **hardware-specific** drivers and BSP code

---

## References

- [QEMU Official Docs - System Emulation](https://www.qemu.org/docs/master/system/index.html)
- [QEMU ARM Platform Docs](https://qemu-project.gitlab.io/qemu/system/arm/index.html)
- [Linux Kernel QEMU Documentation](https://www.kernel.org/doc/html/latest/virt/kvm/kvm-usage.html)
- [QEMU virt Machine Device Tree](https://qemu-project.gitlab.io/qemu/system/arm/virt.html)
