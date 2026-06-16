---
title: "从零写第一个内核模块:Hello World 与开发工具链打通"
prerequisites:
  - gdb-debug-setup
next:
  - kernel-module-params
difficulty: beginner
tags: [kernel-module, kbuild, printk, qemu, arm64]
architectures: [arm64]
kernel_version: "6.19"
sources:
  - guide: helpers/study-guides/layer-0/kernel-module-basics-0
---

## 做什么

这篇我们要彻底打通内核模块的完整开发闭环。后续无论是写驱动、调子系统、还是排查 panic，靠的都是同一条链路：写一个 `.c` → 编译成 `.ko` → 把它塞进 QEMU 跑的虚拟机 → `insmod` 加载、`rmmod` 卸载、`dmesg` 看输出。听起来不过是几条命令的事对吧？说实话，我们实际走下来踩了两个相当典型的坑，每一个都值得单独拎出来拆——第一个是 `make` 的架构变量没传进内核构建系统，导致不知不觉用了本机 x86 的 gcc 去编 ARM64 模块；第二个更阴险，是 `printk` 的输出在串口屏幕上"差一次"显示，差点让我们误判 exit 函数压根没执行，白白怀疑了一通自己的代码。这篇我们从头到尾走一遍，把这两个坑连同它们背后的内核机制一起拆透，并且——重点——所有现象都贴真实的串口日志，因为内核这玩意儿，眼见为实。

## 要了解什么

### 一、内核模块的最小骨架:四件套

先想清楚一件事：内核为什么需要模块机制，而不是把所有功能都一股脑编译进内核镜像？道理很直接，内核源码体量惊人，如果每加一个功能、每改一处代码都要重新编译整个内核、刷写镜像、重启系统，开发节奏会慢到令人绝望。模块机制（loadable kernel module）让我们把功能编译成独立的 `.ko` 文件，在内核已经跑起来之后动态地加载和卸载——改一行代码，只需要重新编这一个模块、重新 `insmod` 一次，几秒钟的事。

那么一个最小可加载模块到底长什么样？我们看自己写的 `hello.c`：

```c
#include <linux/init.h>
#include <linux/module.h>
#include <linux/printk.h>

static int my_first_module_init(void) {
	pr_info("My First Module!\n");
	return 0;
}

static void my_first_module_exit(void) {
	pr_info("My First Module exit, say goodbye!\n");
}

module_init(my_first_module_init);
module_exit(my_first_module_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("CharlieChen114514");
MODULE_DESCRIPTION("A Module setup for qemu");
```

核心就四样东西，我们把每一行的"为什么"都拆开。两个函数是真正干活的：`my_first_module_init` 在模块加载（`insmod`）时被内核调用，它的返回值有讲究——返回 0 表示加载成功，返回负数（比如 `-ENOMEM`）内核就会判定加载失败并把模块踢出去；`my_first_module_exit` 在卸载（`rmmod`）时调用，没有返回值。`module_init` 和 `module_exit` 这两个宏的作用是"注册"，告诉内核"加载的时候调哪个函数、卸载的时候调哪个函数"，括号里填的就是上面两个函数的名字，两者必须对得上，写错一个字母编译期不会报错，但运行时内核就找不到入口了。

`MODULE_LICENSE("GPL")` 这行看着像个注释，但它绝不是装饰，背后牵扯到内核能不能正常工作——这个我们放在最后专门讲，因为它和 `taints kernel` 那条警告直接相关。至于输出，内核里没有我们用户态熟悉的 `printf`，底层的打印函数叫 `printk`，而 `pr_info` 是套在 `printk` 外面的便捷宏，用法和 `printf` 几乎一样，只是它把消息按 `KERN_INFO` 这个日志级别投递到内核日志缓冲区。关于这个"投递"的细节，正是后面那个 console 延迟坑的根源，我们到那再展开。

### 二、编译:请内核构建系统代劳

写完源码，下一个问题是怎么把它变成 `.ko`。这里有个新手很容易栽的直觉——能不能直接 `gcc hello.c -o hello.ko`？答案是不行，而且差得很远。内核模块是一种非常特殊的 ELF 文件，它需要用内核自己的头文件、需要内核规定的特殊段（比如存元数据的 `.modinfo` 段、存 `struct module` 实例的 `.gnu.linkonce.this_module` 段），最后还要链接成可加载的 `.ko`。这些规矩只有内核的构建系统（Kbuild）知道怎么做，所以我们写 Makefile 的本质，是"我没能力编，我去请内核构建系统帮我编"。

外部模块的 Makefile 核心就一行声明加一段委托规则：

```makefile
obj-m += hello.o

include ../../common/Makefile.arch

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
```

`obj-m += hello.o` 是给 Kbuild 看的声明：`m` 表示 module（编译成模块），对应地 `obj-y` 里的 `y` 表示 yes（编译进内核、内建）。注意这里写的是 `hello.o` 而不是 `hello.c`，我们只声明目标名字，Kbuild 会自动去找 `hello.c` 编译，最后产出 `hello.ko`。`include ../../common/Makefile.arch` 引入的是项目共享的架构配置，它帮我们设好三个变量：`ARCH=arm64`（目标架构，别编成 x86）、`CROSS_COMPILE=aarch64-linux-gnu-`（交叉编译前缀）、`KDIR`（内核源码树路径，自动算到 `out/build_latest_arm64`）。真正驱动 Kbuild 动起来的是 `all` 规则里那条命令：`$(MAKE) -C $(KDIR)` 表示先切到内核源码树目录、用那里的 Makefile（因为编译能力在内核树里），`M=$(CURDIR)` 告诉它"外部模块的源码在当前目录"，最后的 `modules` 是要执行的目标。整句翻译过来就是——去内核源码树，借用它的构建能力，把当前目录里的模块编译出来。

⚠️ 这里有个 Makefile 最经典的坑必须提一句：`all:` 和 `clean:` 下面那两行命令前面必须是**一个 Tab**，不是空格。用空格 make 会报 `missing separator`，编辑器里要小心别被"Tab 转 4 空格"的设置坑到。

#### 第一个坑:架构变量没传进内核构建系统

按上面写完，满怀信心地 `make`，结果收获了一个相当唬人的报错：

```
$ make
make -C /home/charliechen/PenguinLab/out/build_latest_arm64 M=.../00-kernel_module_hello modules
warning: the compiler differs from the one used to build the kernel
  The kernel was built by: aarch64-linux-gnu-gcc (GCC) 15.2.0
  You are using:           gcc (GCC) 16.1.1 20260430
  CC [M]  hello.o
In file included from <command-line>:
.../include/linux/compiler_types.h:201:10: fatal error: asm/compiler.h: No such file or directory
  201 | #include <asm/compiler.h>
      |          ^~~~~~~~~~~~~~~~
compilation terminated.
make: *** Error 2
```

这条 warning 是破案的关键线索。内核是用 `aarch64-linux-gnu-gcc` 编译的，但编译我们的模块时用的却是本机 x86 的 `gcc`——这说明 `CROSS_COMPILE` 根本没生效，跟着就因为用 x86 gcc 去编 ARM64 代码、架构头文件路径对不上，炸出了 `asm/compiler.h` 找不到。

根因藏在 make 的变量传递机制里。`include ../../common/Makefile.arch` 确实在当前这一层 make 里设好了 `ARCH=arm64` 和 `CROSS_COMPILE=aarch64-linux-gnu-`，但 `all` 规则里的 `$(MAKE) -C $(KDIR) ... modules` 是**递归调用 make**——它会切到内核目录、启动一个全新的 make 进程。这里的关键是：当前 make 里的变量是"局部的"，新的子 make 进程默认看不到它们，就好比你在函数 A 里设了个局部变量，调用函数 B 时不传参，B 自然访问不到。子 make（也就是内核构建系统）拿不到 `CROSS_COMPILE`，就退回默认的本机 `gcc`，于是报错。

解法是把这两个变量 `export` 成环境变量，子进程就能继承了。最干净的修法是改共享的 [example/common/Makefile.arch](example/common/Makefile.arch)，在文件末尾加一行：

```makefile
# 导出给内核构建系统的递归子 make（外部模块编译必需）
export ARCH CROSS_COMPILE
```

这样改一处，以后所有 `include Makefile.arch` 的模块都自动受益。`KDIR` 不用 export，因为它在规则里是当前 make 展开的（`$(MAKE) -C $(KDIR)`），不需要传给子进程；只有 `ARCH` 和 `CROSS_COMPILE` 是子 make 要用的，才必须 export。加完再 `make`，这次终于顺利产出 `hello.ko`：

```
$ make
  CC [M]  hello.o
  MODPOST Module.symvers
  CC [M]  hello.mod.o
  CC [M]  .module-common.o
  LD [M]  hello.ko
```

看着 `LD [M]  hello.ko` 这行，第一个模块就算编出来了。

### 三、把 .ko 塞进 QEMU:initramfs 是只读快照

`hello.ko` 编出来了，但它在宿主机上，怎么把它弄进 QEMU 跑的虚拟机里？这里要先理解我们的 rootfs 是怎么组织的。我们用的是 initramfs 方式启动——`out/build_latest_arm64/rootfs.cpio.gz` 是一个 cpio 打包的根文件系统镜像，内核启动时把它解包到内存里作为根目录。关键性质是：这个镜像在**启动的那一刻就固定了**，它是一个只读快照，启动之后我们在虚拟机 shell 里没法往根目录写新文件。所以宿主机上后来编译出来的 `hello.ko`，自然不在虚拟机的文件系统里——这也是笔者一开始对着 `ls` 找不到 ko 一脸懵的原因。

最直接的解法是把 `.ko` 放进 rootfs 目录、重新打包 cpio。项目提供了 [scripts/rootfs-minimal-maker.sh](scripts/rootfs-minimal-maker.sh)，而且它有个 `--pack-only` 选项，专门用来"只重新打包 cpio、不重新编译 BusyBox"，非常轻量：

```bash
$ cp example/mini/00-kernel_module_hello/hello.ko out/build_latest_arm64/rootfs/
$ ARCH=aarch64 ./scripts/rootfs-minimal-maker.sh --pack-only
[INFO] Packing rootfs into cpio archive...
[CMD] find . | cpio -o -H newc 2>/dev/null | gzip > .../rootfs.cpio.gz
[SUCCESS] Cpio archive created: .../rootfs.cpio.gz (1.10 MB)
```

⚠️ 这里必须带 `ARCH=aarch64`——这个脚本默认 `ARCH=arm`，不带的话它会去找 `out/build_latest_arm` 这个路径，结果打包了个空目录或者压根找不到，是第二个容易手滑的地方。打包完看到 `rootfs.cpio.gz (1.10 MB)` 更新成功，重启 QEMU 就行：

```bash
$ ./scripts/qemu-run.sh run
```

这种重打包方式的缺点是每改一次模块都要重新打包、重启 QEMU，迭代起来比较折腾。内核其实已经编译进了 9p 文件系统支持，后续可以配一个共享目录，改了 `.ko` 直接 `insmod` 新的、不用重打包——那是另一篇的内容了，先按下不表。

### 四、加载验证 + 第二个坑

进入 QEMU 的 BusyBox shell 之后，终于到了验证环节。模块相关的操作就四条命令：`insmod` 加载、`rmmod` 卸载、`lsmod` 列出已加载模块、`dmesg` 看内核日志。我们依次来：

```bash
~ # insmod hello.ko
[    8.531937] hello: loading out-of-tree module taints kernel.
~ # rmmod hello.ko
~ # lsmod
~ # dmesg | grep -i -e first -e goodbye
[    8.539528] My First Module!
[   18.855000] My First Module exit, say goodbye!
```

`insmod` 之后那行 `loading out-of-tree module taints kernel` 是内核自动加的提示，不是我们写的 `pr_info`——它告诉我们这个模块不在内核源码树里（out-of-tree），具体含义放最后一节讲。`lsmod` 在 `rmmod` 之后是空的，说明模块已经干净卸载。而 `dmesg | grep` 的结果才是真正的验证证据：init 的 `My First Module!` 和 exit 的 `say goodbye` 都在内核日志缓冲区里，说明 init 和 exit 两个函数都正确执行了。

但事情到这里还没完。如果我们不是事后用 `grep` 复盘，而是照着 `insmod` 然后立刻 `dmesg | tail` 看，最初看到的现象其实相当邪门：

```bash
~ # insmod hello.ko
[   18.855000] My First Module exit, say goodbye!   ← insmod 之后，涌出来的居然是 exit 的输出？
~ # rmmod hello.ko
[  512.165240] My First Module!                      ← rmmod 之后，反而涌出 init 的输出？
```

`insmod` 之后屏幕上迟迟不出现 init 的输出，倒是 `rmmod` 之后莫名其妙"涌"出来一行 `My First Module!`，而 exit 那句 `say goodbye` 像人间蒸发了一样。说实话，那一刻笔者是真开始怀疑自己了——exit 函数是不是压根没注册上？`module_exit` 那行是不是手滑拼错了？回头把 hello.c 扒了三遍，init、exit、注册、license 一个不差，代码明明白白一点毛病没有。

这种"代码对、现象却对不上"的情况最搞心态。别急，怀疑人生的情绪先收一收，我们把目光落在那两个时间戳上——破案全靠它。init 输出的时间戳是 `[8.539]`，紧跟 `insmod` 的 `[8.531]`，中间只差 8 毫秒。这一个小数字直接说明：这条消息确实是 `insmod` 那一刻打印的，只不过它一直赖在内核的日志缓冲区里没上屏幕，积压到我们敲 `rmmod` 时才不情不愿地涌出来。于是从我们的视角看，就像是"`rmmod` 之后才打印 init 输出"——纯属屏幕刷新慢半拍的错觉。

那屏幕为什么会慢半拍？得拆开 `printk` 的两个输出去向。它把消息写进内核的 log buffer（环形缓冲区）是同步、即时的，持有锁的瞬间就完成；可把 buffer 内容真正刷到 console（我们这里是 PL011 串口）却是异步的。串口是个慢速设备，波特率摆在那，而 BusyBox 这种简陋 initramfs 里，我们敲的 shell 命令输出还得跟 `printk` 抢同一个串口带宽，一积压就滞后。exit 的输出同理堵在 console 队列里没及时涌出，制造出"exit 没执行"的假象。等改用 `dmesg`（它直接读 log buffer、绕开 console）一查，两条输出齐齐整整都在——代码从头到尾完全正确。

这现象有个形象的说法：屏幕永远慢 buffer 一拍，"刚好差一次"。背后机制在内核文档和 LWN 里讲得透：传统 `console_unlock()` 在调用者上下文里同步刷 console，串口波特率低时慢得抠脚；后来的内核为此引入了异步刷新（唤醒专门线程打印）和 NBCON（No-BLocking Console）等优化，但 initramfs + BusyBox + PL011 这套组合下，延迟依然肉眼可见。

所以这一关最该记住的一条，也是笔者最想让大家刻进脑子的：验证内核模块输出，永远信 `dmesg`（buffer 真相），别信串口屏幕的时序。屏幕会骗你，buffer 不会。

### 五、为什么 MODULE_LICENSE 不是装饰:taint 与 GPL 符号

最后把那行 `loading out-of-tree module taints kernel` 和 `MODULE_LICENSE` 的关系彻底讲清楚，因为这里有个极容易混淆的点。内核有一套"污染标志"（taint flag）机制，用一组字母标记内核当前所处的"不干净"状态，方便开发者排查 bug 时知道这个内核跑了什么非主线的东西。我们这个模块触发的 taint 是 `'O'`，含义是 **out-of-tree**——模块不在内核源码树内编译，内核开发者不为其质量背书，所以加载它时内核会主动打这条警告。注意，这跟 `MODULE_LICENSE` **没有直接关系**：我们声明了 `MODULE_LICENSE("GPL")`，所以并没有触发专有模块的 `'P'`（proprietary）taint，这俩字母是两码事，千万别混。

那 `MODULE_LICENSE` 到底管什么？它管的是**符号访问权限**。内核里有两种导出符号的方式：`EXPORT_SYMBOL` 导出的符号任何模块都能用；而 `EXPORT_SYMBOL_GPL` 导出的符号，只允许声明了 GPL 兼容 license 的模块使用。这些 GPL-only 符号通常是和内核内部实现深度耦合的接口，内核维护者认为使用它们的模块已经是内核的派生作品，理应遵循 GPL。如果一个模块声明的是非 GPL 的 license（比如 `"Proprietary"`），它不仅用不了 `EXPORT_SYMBOL_GPL` 的符号，还会额外触发 `'P'` taint。所以我们老老实实写 `MODULE_LICENSE("GPL")`，既是为了能用上那些 GPL-only 的内核接口，也是为了避免给内核加上不必要的 taint——这是技术约束，也是许可证策略，不是走形式。

## 动手试试

1. 在 `example/mini/00-kernel_module_hello/` 下从零写 `hello.c` 和 `Makefile`（别忘了 `export ARCH CROSS_COMPILE`），`make` 出 `hello.ko`
2. `cp hello.ko` 进 rootfs 目录，`ARCH=aarch64 ./scripts/rootfs-minimal-maker.sh --pack-only` 重打包，重启 QEMU
3. `insmod hello.ko`，用 `dmesg | grep` 确认 init 的输出在 buffer 里（别只看屏幕，会被 console 延迟骗到）
4. `lsmod` 确认模块已加载，`rmmod hello`，再用 `dmesg | grep` 确认 exit 的输出
5. 试一下 `modinfo hello.ko`，对照源码里的 `MODULE_*` 宏，看 license、author、description、vermagic 这些元数据
6. 把 `MODULE_LICENSE("GPL")` 改成 `"Proprietary"` 重新编译加载，观察 taint 信息有什么变化（思考：为什么 license 字段会影响内核行为）

## 延伸阅读

- [Message logging with printk](https://docs.kernel.org/core-api/printk-basics.html) — kernel.org 官方，printk 的日志级别、console_loglevel 与输出时机
- [The Perils of printk()](https://lwn.net/Articles/705938/) — LWN 经典，讲 `console_unlock()` 同步/异步刷新的来龙去脉
- [We made Linux v6.19 boot quicker for everyone](https://www.thegoodpenguin.co.uk/blog/we-made-linux-v6-19-boot-quicker-for-everyone/) — 串口 console 延迟如何拖慢启动，以及 NBCON 的优化
- [Linux Kernel Licensing Rules](https://docs.kernel.org/process/license-rules.html) — kernel.org 官方，`MODULE_LICENSE` 的合法取值与 taint 判定
- [Symbol Namespaces](https://docs.kernel.org/core-api/symbol-namespaces.html) — kernel.org，`EXPORT_SYMBOL` 家族与符号导出机制
- [MODULE_LICENSE and EXPORT_SYMBOL_GPL](https://lwn.net/2001/1025/a/module-license.php3) — LWN 2001，这套许可证机制最初的设计动机
- LDD3 第 2 章《构建和运行模块》（注意部分 API 已更新，结合 6.19 源码看）
