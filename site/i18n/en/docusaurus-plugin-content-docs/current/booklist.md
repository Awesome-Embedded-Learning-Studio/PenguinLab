---
title: Recommended Books
sidebar_position: 10
---

# Book List: Recommended Reading for Embedded Linux Kernel Learning

> Organized by learning stage, with recommended timing, focus areas, and availability for each book.
> Principle: theory books build the foundation, hands-on books go to real hardware, source code is the ultimate documentation.

---

## Quick Book Guide

| Your Current Question | Check This First |
|-----------------------|------------------|
| How a kernel mechanism works | *Linux Kernel Development* by Robert Love |
| How to use a specific API | LDD3 (free) or *Linux Device Driver Development* by Song Baohua |
| Specific devm_/regmap/IIO APIs | *Linux Device Driver Development* by Madieu |
| i.MX6ULL pin/clock config | i.MX6ULL Reference Manual (NXP official) |
| H618 related | sunxi community wiki + Allwinner SDK docs |
| Performance troubleshooting | *Linux Performance Optimization in Practice* by Ni Pengfei |
| Kernel synchronization/locking | Paul McKenney's free book |

---

## Table of Contents

- [Layer 1: Kernel Principles (Theoretical Foundation)](#layer-1-kernel-principles-theoretical-foundation)
- [Layer 2: Device Drivers (Core Practice)](#layer-2-device-drivers-core-practice)
- [Layer 3: Embedded Systems (Engineering Practice)](#layer-3-embedded-systems-engineering-practice)
- [Layer 4: Performance & Debugging](#layer-4-performance--debugging)
- [Layer 5: Free Online Resources](#layer-5-free-online-resources-high-quality)

---

## Layer 1: Kernel Principles (Theoretical Foundation)

> Read through before starting. Refer back as needed.

### 1. *Linux Kernel Development*, 3rd Edition — Robert Love
- **Chinese edition**: Translated by Chen Lijun et al., China Machine Press
- **Recommended timing**: Read through before starting; refer back by chapter during corresponding tasks
- **Content**: Process management, memory management, VFS, interrupts, kernel synchronization, timers. Comprehensive but not deep. Great for building the big picture.
- **Pages**: ~440, fast-paced, quick to read through
- **Availability**: Print; English PDF legally available on archive.org
- **Key chapters**:
  - Ch.1–2: Kernel intro, getting started
  - Ch.6: Kernel data structures (list_head, rbtree)
  - Ch.7–8: Interrupts and bottom halves
  - Ch.12: Memory management
  - Ch.17: Device model and sysfs

---

### 2. *Understanding the Linux Kernel*, 3rd Edition — Daniel P. Bovet, Marco Cesati
- **Chinese edition**: Translated by Chen Lijun, Zhang Qiongsheng, China Electric Power Press
- **Recommended timing**: When you want to dig deeper into a specific mechanism
- **Content**: 3x deeper than LKD. Interrupts, memory management, process scheduling, filesystems — every mechanism traced down to assembly level
- **Pages**: ~900, not meant for cover-to-cover reading, best as a **reference book**
- **Note**: Based on kernel 2.6, some implementation details have changed, but the principles still apply
- **Key chapters**:
  - Ch.4: Interrupts and exceptions
  - Ch.8: Memory management (buddy system, slab)
  - Ch.3: Processes, understanding task_struct

---

### 3. *Professional Linux Kernel Architecture* — Wolfgang Mauerer
- **Chinese edition**: Translated by Guo Xu, Posts & Telecom Press
- **Recommended timing**: Long-term reference after completing the curriculum
- **Content**: Most comprehensive coverage — memory management, VFS, networking, modules, device drivers. Each chapter has extensive diagrams and source code analysis
- **Pages**: ~1400, the thickest kernel book
- **Availability**: Print hard to find; older English PDF available online
- **Recommended usage**: Memorize the table of contents, know "this mechanism is in chapter X", flip there when needed

---

## Layer 2: Device Drivers (Core Practice)

> Start from the driver development essential reading layer.

### 4. *Linux Device Drivers*, 3rd Edition (LDD3)
- **Authors**: Jonathan Corbet, Alessandro Rubini, Greg Kroah-Hartman
- **Chinese edition**: Translated by Wei Yongming et al.
- **Recommended timing**: **Must-read classic** for driver development
- **Content**: Character devices, block devices, network devices, USB, PCI, memory mapping, DMA, interrupts
- **Pages**: ~600
- **Free download**: https://lwn.net/Kernel/LDD3/ (complete English PDF, author-authorized free)
- **Note**: Based on kernel 2.6.10, many APIs have been updated (e.g., `register_chrdev` should use cdev, `ioremap_nocache` is deprecated), but concepts are entirely correct
- **Key chapters**:
  - Ch.2: Building and running modules
  - Ch.3: Character devices
  - Ch.14: Linux device model
  - Ch.10: Interrupt handling
  - Ch.15: Memory mapping and DMA

---

### 5. *Linux Device Driver Development* (based on latest kernel and ARM64 architecture) — Song Baohua
- **Publisher**: Posts & Telecom Press, 3rd edition (2022)
- **Recommended timing**: The most commonly used Chinese reference for Chinese engineers
- **Content**: Covers 5.x kernel — character/block/network device drivers, platform drivers, DTS, I2C/SPI/USB subsystems, memory management
- **Strengths**: Many examples, ARM-embedded focused, code runs on real hardware; author is a kernel community contributor
- **Recommended usage**: Read alongside LDD3 — LDD3 for concepts, this book for latest APIs and real hardware practice
- **Key chapters**:
  - Chapters 4–5: Character devices
  - Chapter 11: Platform drivers
  - Chapter 14: I2C, SPI bus drivers
  - Chapter 17: Memory and I/O mapping

---

### 6. *Linux Device Driver Development*, 2nd Edition — John Madieu
- **Publisher**: Packt Publishing (2022)
- **Recommended timing**: The most up-to-date hands-on driver development book
- **Content**: Based on 5.10+ kernel, covers modern kernel APIs (devm_, managed resources, threaded IRQ, regmap, DMA engine, IIO), with Raspberry Pi examples
- **Strengths**: Most systematic coverage of devm_, regmap, and IIO frameworks; complete example code on GitHub
- **Code repository**: https://github.com/PacktPublishing/Linux-Device-Driver-Development
- **Key chapters**:
  - Ch.2: Module basics
  - Ch.3: Character devices
  - Ch.6: Platform Driver (with devm_ system explanation)
  - Ch.9: I2C drivers
  - Ch.12: Pinctrl
  - Ch.14: Debugging

---

## Layer 3: Embedded Systems (Engineering Practice)

> Full reference for building the embedded engineering big picture.

### 7. *Embedded Linux Primer*, 2nd Edition — Christopher Hallinan
- **Chinese edition**: Translated by Li Yun, Posts & Telecom Press
- **Recommended timing**: Build the overall embedded Linux engineering perspective
- **Content**: U-Boot, kernel boot, cross-compilation, filesystems, debugging. Very engineering-oriented
- **Key chapters**:
  - Ch.5: Kernel initialization
  - Ch.7: U-Boot
  - Ch.12: Embedded development environment (NFS, JTAG)

---

### 8. *Mastering Embedded Linux Programming*, 3rd Edition — Chris Simmonds
- **Publisher**: Packt Publishing (2021)
- **Recommended timing**: Full reference throughout
- **Content**: Toolchains, U-Boot, kernel configuration, Buildroot/Yocto, root filesystems, driver debugging — systematic and up-to-date
- **Code repository**: https://github.com/PacktPublishing/Mastering-Embedded-Linux-Programming-Third-Edition
- **Key chapters**:
  - Ch.4: Kernel configuration and compilation
  - Ch.6: Choosing a build system (Buildroot/Yocto)
  - Ch.11: Interacting with device drivers

---

### 9. *Building Embedded Linux Systems*, 2nd Edition — Karim Yaghmur et al.
- **Recommended timing**: When you need to understand BSP construction as a whole
- **Content**: Deep coverage of toolchains, kernel configuration, root filesystem building, booting, power management. A BSP engineer's reference manual
- **Availability**: O'Reilly platform; older English PDF on archive.org

---

### 10. *Linux Driver Development for Embedded Processors*, 2nd Edition — Alberto Liberal de los Rios
- **Publisher**: Self-published (Amazon)
- **Recommended timing**: DTS and peripheral driver phase
- **Content**: ARM embedded focused — DTS, GPIO, I2C, SPI, UART, USB, with complete runnable examples verified on Raspberry Pi and i.MX
- **Code repository**: https://github.com/ALIBEK/linux-kernel-module-cheat

---

## Layer 4: Performance & Debugging

> Advanced direction after completing the core curriculum.

### 11. *Linux Performance Optimization in Practice* — Ni Pengfei
- **Publisher**: Publishing House of Electronics Industry
- **Recommended timing**: ftrace/perf phase
- **Content**: CPU, memory, I/O, network performance analysis — all based on perf, ftrace, eBPF with real-world case studies
- **Notable**: The most systematic Chinese-language Linux performance analysis resource

---

### 12. *BPF Performance Tools* — Brendan Gregg
- **Publisher**: Addison-Wesley (2019)
- **Recommended timing**: Advanced direction (eBPF is the modern replacement for kprobes)
- **Content**: BCC, bpftrace toolchain — CPU/memory/network/storage performance analysis with eBPF
- **Notable**: Brendan Gregg is the authority on Linux performance analysis; this is the most authoritative eBPF practical reference
- **Website**: https://www.brendangregg.com/bpf-performance-tools-book.html

---

### 13. *Is Parallel Programming Hard, And, If So, What Can You Do About It?* — Paul E. McKenney
- **Free download**: https://mirrors.edge.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html
- **Recommended timing**: Long-term reference for understanding kernel synchronization mechanisms
- **Content**: The authoritative guide to memory models, atomic operations, RCU, memory barriers. Essential for writing kernel synchronization code

---

## Layer 5: Free Online Resources (High Quality)

### Selected LWN.net Kernel Articles

LWN.net is the primary source for kernel developers, with articles written by kernel community members.

| Article | URL |
|---------|-----|
| The platform device API | https://lwn.net/Articles/448499/ |
| Threaded interrupts | https://lwn.net/Articles/302043/ |
| The common clock framework | https://lwn.net/Articles/472998/ |
| Kernel debugging with kprobes | https://lwn.net/Articles/290277/ |
| Device tree overlays | https://lwn.net/Articles/616859/ |
| Intrusive linked lists | https://lwn.net/Articles/336224/ |
| The sysfs filesystem | https://lwn.net/Articles/31185/ |

### Official Kernel Documentation (Available Locally)

```bash
# High-quality documentation in the kernel source tree
Documentation/driver-api/          # Driver API reference
Documentation/devicetree/          # DTS related
Documentation/trace/               # ftrace, kprobe
Documentation/core-api/            # Core API (memory, locks, etc.)
Documentation/kbuild/              # Build system

# Generate HTML documentation (viewable in browser)
sudo apt install python3-sphinx
make ARCH=arm htmldocs
# Output in Documentation/output/
```
