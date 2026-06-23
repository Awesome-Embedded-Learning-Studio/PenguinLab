---
title: KCSAN：抓并发里的数据竞争
slug: debug-kcsan
difficulty: intermediate
tags: [并发调试, 数据竞争, KCSAN, 编译器插桩]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/debugging/03-debug-kasan
sources:
  - notes: document/notes/linux_kernel_debugging/ch08.md
  - notes: document/notes/linux_kernel_debugging/ch08_3.md
---

# KCSAN：抓并发里的数据竞争

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数名 / 数据结构 / Kconfig 默认值均已核对）；具体行号、menuconfig 截图与 `dmesg` 输出待 QEMU 亲测核对。

## 并发 bug 的痛：会隐身的"海森堡 bug"

先说最折磨人的一类 bug：**数据竞争**。两个执行流（两个线程、或者线程和中断）不加任何同步，就往同一块共享可写内存上招呼——一个在写前 32 位，另一个冲进来读，读到的是"既不是旧值也不是新值"的撕裂脏数据（torn read）。按 LKMM（Linux Kernel Memory Model）的严格定义，只要满足"同地址 + 并发 + 至少一个写 + 至少一个是普通 C 访问"，这就是数据竞争。

这类 bug 的恶心之处在于它**会隐身**：你盯着代码看一切正常，加一行 `printk` 想抓它，结果因为输出带来的时序变化，bug 消失了；上 GDB 单步，时序一变又复现不了。这就是所谓的海森堡 bug（Heisenbug）——观察行为本身改变了行为。进了生产环境，复现一次得烧香，定位一次得掉头发。

人类大脑天生不擅长模拟多核并发时序，所以我们需要一个工具，在内核**运行时**替我们盯着这些稍纵即逝的竞争。这就是 KCSAN（Kernel Concurrency Sanitizer），2020 年 8 月随 5.8 进主线，专治数据竞争。

## KCSAN 的思路：编译器插桩 + 软观察点

KCSAN 的总策略一句话能讲清：**靠编译器插桩，给每次普通内存访问套上一个"软观察点"，再用一点人为延时把竞争窗口撑大，撞上了就报告。**

插桩是怎么进来的？打开 `CONFIG_KCSAN` 后，编译器对被插桩的编译单元开启 `-fsanitize=thread`，于是它把每条普通的 load/store 都改写成对 `__tsan_*` 运行时函数的调用。KCSAN 的 `kernel/kcsan/core.c`（Linux 6.19）里就用一个宏 `DEFINE_TSAN_READ_WRITE(size)` 批量定义了这些桩函数，比如 1/2/4/8/16 字节的版本，它们全都最终落到同一个核心入口 `check_access()`：

```c
// kernel/kcsan/core.c（Linux 6.19）
void __tsan_write##size(void *ptr) {
    check_access(ptr, size, KCSAN_ACCESS_WRITE, _RET_IP_);
}
```

`__tsan_*` 这套名字不是 KCSAN 凭空造的——它复用了编译器为 ThreadSanitizer（TSAN）已经会生成的桩，所以不用自己写 pass，编译器帮你把活干了。

**软观察点**才是 KCSAN 的灵魂。硬件断点资源稀缺，不可能给每个地址都上硬观察点，KCSAN 的做法是开一个全局数组当"软观察点池"：

```c
// kernel/kcsan/core.c（Linux 6.19）
static atomic_long_t watchpoints[CONFIG_KCSAN_NUM_WATCHPOINTS + NUM_SLOTS-1];
```

每个槽位是一个 `atomic_long_t`，里面把"被监视的地址 + 访问大小 + 是不是写"用 `encode_watchpoint()` 打包编码进一个长整数（编码细节在 `kernel/kcsan/encoding.h`）。用 `atomic_long` 而不是带锁的结构体，是为了让快速路径（每次内存访问都要走）零锁开销。`CONFIG_KCSAN_NUM_WATCHPOINTS` 默认 64（见 `lib/Kconfig.kcsan`）。

整套设点—拖延—收网逻辑集中在 `kcsan_setup_watchpoint()`，挨着读一遍就能看明白它干的三件事：

1. **设点**：`insert_watchpoint()` 用 `atomic_long_try_cmpxchg_relaxed` 抢一个空槽，把编码后的观察点塞进去（抢失败就放弃，记一个 `KCSAN_COUNTER_NO_CAPACITY`）。
2. **拖延**：`delay_access()` 里 `udelay(delay)`，任务上下文默认 `kcsan_udelay_task = 80` 微秒，中断上下文 `kcsan_udelay_interrupt = 20` 微秒（见 `core.c` 顶上的全局变量和 Kconfig 默认值）。这一下故意停顿，就是为了把竞争窗口撑大，让另一个执行流有机会在这 80µs 里撞进来。
3. **收网**：拖延期间如果有人来碰这个地址，那次的访问会在快速路径的 `find_watchpoint()` 里命中并走 `kcsan_found_watchpoint()`，把自己的调用栈塞进 `other_info`；设点线程拖完之后 `read_instrumented_memory()` 重读一次，靠 `old ^ new` 判断值有没有被改（值变化检测，只对 ≤8 字节的访问做）。撞上、值又变了，就调 `kcsan_report_known_origin()` 出报告。

快速路径的入口是 `check_access()`——它先 `find_watchpoint()` 看当前访问有没有命中别人设的点；没命中再 `should_watch()` 决定自己要不要设点。`should_watch()` 里有两道关卡，正是 KCSAN 抽样 + 免检的设计核心，下一节细说。

## 抽样与免检：`should_watch()` 的两道关卡

KCSAN 不能每次访问都设点，那系统直接卡死。它的节流靠两个机制，都在 `should_watch()`（`core.c`，Linux 6.19）里：

**第一关：原子访问直接免检。** `should_watch()` 第一行就是 `if (is_atomic(ctx, ptr, size, type)) return false;`。`is_atomic()` 判断这个访问是不是原子的——是，就绝不给它设点。这覆盖三种情况：访问带了 `KCSAN_ACCESS_ATOMIC` 标记（也就是 `READ_ONCE`/`WRITE_ONCE`/`atomic_*` 这些"标记访问"）；满足"对齐且不超过字长的普通写被假设为原子"（这条是 `CONFIG_KCSAN_ASSUME_PLAIN_WRITES_ATOMIC` 的魔法，后面踩坑专门讲）；或者当前处于原子区（`atomic_nest_count`/`in_flat_atomic`/`atomic_next`，靠 `kcsan_nestable_atomic_begin()` 等设置，存在 `struct kcsan_ctx` 里，见 `include/linux/kcsan.h`）。

**第二关：抽样计数。** 免检过了，再看每 CPU 的跳过计数器 `kcsan_skip`：`if (this_cpu_dec_return(kcsan_skip) >= 0) return false;`。每访问一次就减一，减到负数才肯设点，然后 `reset_kcsan_skip()` 重新装填成 `kcsan_skip_watch`（默认 4000，还带 `KCSAN_SKIP_WATCH_RANDOMIZE` 随机化抖动）。也就是说每 4000 次内存访问才抽检一次——这就是 KCSAN 抓 bug 带点运气、要靠密集循环喂它的根因。

## 与 KASAN 的分工

很多人会把 KASAN 和 KCSAN 搞混，它俩名字像、都是 sanitizer、都用编译器插桩，但查的东西完全不一样：

- **KASAN**（Kernel Address Sanitizer）查的是**内存正确性**——越界访问（out-of-bounds）、释放后使用（UAF）、双重释放。它靠给每块内存配"影子内存"（shadow memory）记状态，访问时查影子。
- **KCSAN** 查的是**并发正确性**——同一块内存在多个执行流之间有没有没加保护的竞争访问。

它俩水火不容，`lib/Kconfig.kcsan` 里写死了互斥（都做大量插桩，叠一起会炸），menuconfig 里只能二选一。用 Clang 编译时 KCSAN 还和 KCOV（覆盖率工具）冲突。所以选哪个看你抓什么 bug：怀疑内存越界/UAF 开 KASAN，怀疑时序竞争开 KCSAN。

## KCSAN 的独门绝技：Advisory Lock 检测

这是 KCSAN 比 Lockdep 强的地方，也是它真正"读并发语义"的部分。

Lockdep（锁依赖检测器）盯的是**加锁顺序**——它看你拿锁、放锁的序列，抓死锁、抓锁依赖成环。但它有个盲区：**你拿了一把锁，却忘了用它去保护某个共享变量**。这种"持了锁、却没锁该锁的变量"的访问，Lockdep 一无所知，因为它根本不关心你拿锁之后访问了哪些内存。

KCSAN 通过一组 `ASSERT_EXCLUSIVE*()` 宏（定义在 `include/linux/kcsan-checks.h`，Linux 6.19）来补这个洞。比如 `ASSERT_EXCLUSIVE_WRITER(var)`：

```c
// include/linux/kcsan-checks.h（Linux 6.19）
#define ASSERT_EXCLUSIVE_WRITER(var) \
    __kcsan_check_access(&(var), sizeof(var), KCSAN_ACCESS_ASSERT)
```

它发起一次带 `KCSAN_ACCESS_ASSERT` 标记的访问。在 `core.c` 里，`is_atomic()` 对 assert 访问特意返回 false（注释写得很直白："never consider an assertion access as atomic"），于是 KCSAN 会在它身上设点；而报告侧 `report.c` 的 `get_bug_type()` 看到 assert 标记就把 bug 类型从 `data-race` 换成 `assert: race`。意思就是：**我断言这个变量在这段范围内只能被当前线程写，谁敢并发写就是 bug**——哪怕那个并发写本身是"标记访问"（按严格 LKMM 不算 data-race），KCSAN 照样抓。这正是 Lockdep 够不着的角落。

还有 `ASSERT_EXCLUSIVE_BITS(var, mask)` 这种位粒度断言，用 `kcsan_set_access_mask(mask)` 设掩码，只检查指定那几位有没有被并发改——适合"某些位只读、某些位可并发改"的 flags 变量。

## CONFIG_KCSAN：编译开销与 runtime 控制

启用 KCSAN 有不少硬性前置（`lib/Kconfig.kcsan`）：架构要支持（x86_64 自 5.8、arm64 自 5.17），编译器要 GCC/Clang ≥11（由 `CONFIG_HAVE_KCSAN_COMPILER` 检查），要开 `CONFIG_DEBUG_KERNEL`，且和 KASAN/KCOV 互斥。menuconfig 路径是 `Kernel hacking → Generic Kernel Debugging Instruments → KCSAN: dynamic data race detector`。勾上 `CONFIG_KCSAN` 会自动 `select CONFIG_STACKTRACE`（报告要打调用栈）。

编译开销很重——全内核插桩 + 每访问都过一遍快速路径，所以 KCSAN 内核只适合调试环境跑，不能上生产。几个关键 Kconfig 旋钮（默认值已在 `lib/Kconfig.kcsan` 核对）：

| 配置项 | 默认 | 作用 |
|:---|:---:|:---|
| `KCSAN_ASSUME_PLAIN_WRITES_ATOMIC` | y | 假设对齐、≤字长的普通写是原子的（初学者最大困惑源） |
| `KCSAN_REPORT_VALUE_CHANGE_ONLY` | y | 只有竞争真的改了值才报，过滤无害竞争 |
| `KCSAN_SKIP_WATCH` | 4000 | 每 4000 次访问抽检一次（越小越准越卡） |
| `KCSAN_NUM_WATCHPOINTS` | 64 | 软观察点池大小 |
| `KCSAN_UDELAY_TASK` / `UDELAY_INTERRUPT` | 80 / 20 | 设点后拖延的微秒数 |
| `KCSAN_REPORT_ONCE_IN_MS` | 3000 | 3 秒内同一场竞争只报一次 |

运行时还能通过 debugfs 现场开关（需 root）：`/sys/kernel/debug/kcsan`。`echo on/off > /sys/kernel/debug/kcsan` 切开关，`cat` 看统计（查了多少、抓了多少 race）。

## 报告解读：两个调用栈 + 读写类型

报告生成逻辑在 `kernel/kcsan/report.c`（Linux 6.19）。设点线程抓到竞争后调 `kcsan_report_known_origin()`，另一个线程的栈通过 `other_info` 结构体跨线程传过来，最后在 `print_report()` 里拼成一份完整报告。`struct other_info`（`report.c`）里装着对方的 `struct access_info`（含 ptr/size/access_type/task_pid/cpu_id）和一组 `stack_entries[]`，靠 `raw_spin_lock` 保护的 `report_lock` 串行化，避免两线程同时往 `printk` 写乱。

报告长这样（结合 `print_report()` 的 `pr_err` 拼出来的格式，输出待亲测核对）：

```
==================================================================
BUG: KCSAN: data-race in do_the_work1 / do_the_work2

write to 0xffff...3238 of 8 bytes by task ... on cpu 0:
 do_the_work1+0x...
 process_one_work+0x...
 ...

write to 0xffff...3238 of 8 bytes by task ... on cpu 1:
 do_the_work2+0x...
 process_one_work+0x...
 ...

value changed: 0x0000000000007d00 -> 0x00000000000017d0

Reported by Kernel Concurrency Sanitizer on:
...
==================================================================
```

读报告分三块：第一行 `BUG: KCSAN: data-race in A / B` 直接点名两个打架的函数（`report.c` 的 `sym_strcmp` 把两函数按字典序排，保证 bug 标题稳定）；接着是每个访问一行的"访问信息"（读/写、是否 marked、内核虚地址、谁在哪个 CPU 干的，由 `get_access_type()` 拼字符串，比如 `write`、`read (marked)`、`assert no writes`），紧跟各自的调用栈；最后若有值变化会打印 `value changed: 旧值 -> 新值`（`old ^ new` 的 diff）。顺着调用栈往上爬就能定位到具体代码行。

## 一个必踩的坑：两个普通写却不报警

笔记里记的真实现象：写个模块，两个工作队列线程疯狂地不加锁写同一个全局变量，满心欢喜等 KCSAN 报错，结果**一声不吭**。

根因就是 `CONFIG_KCSAN_ASSUME_PLAIN_WRITES_ATOMIC` 默认 y。在 `is_atomic()` 里这段：

```c
// kernel/kcsan/core.c（Linux 6.19）
if (IS_ENABLED(CONFIG_KCSAN_ASSUME_PLAIN_WRITES_ATOMIC) &&
    (type & KCSAN_ACCESS_WRITE) && size <= sizeof(long) &&
    !(type & KCSAN_ACCESS_COMPOUND) && IS_ALIGNED((unsigned long)ptr, size))
    return true; /* Assume aligned writes up to word size are atomic. */
```

对齐、不超过字长、非复合的普通写，被当成原子的——既然原子，`should_watch()` 第一关就 return false，连点都不设。再加 `KCSAN_REPORT_VALUE_CHANGE_ONLY` 默认 y，竞争若没明显改值也不报。所以两个普通写互撞，默认配置下 KCSAN 睁一只眼闭一只眼。

想让它报，得开 `CONFIG_KCSAN_STRICT=y`（`kcsan_init()` 里会打印 `strict mode configured`），或手动关掉 `KCSAN_ASSUME_PLAIN_WRITES_ATOMIC`——告诉 KCSAN 别做任何假设，凡是未标记的并发写撞上就是 bug。重新编译内核，再插模块，报告立刻炸出来。

> 还有一条正告：**看到报告别急着甩个 `READ_ONCE`/`WRITE_ONCE` 消警告**。那只是让 KCSAN 闭嘴，数据不一致的风险还在。正确姿势是加锁、用原子操作、或上无锁技术。只有确定是良性竞争（统计计数器那种读 100 还是 101 无所谓），才用 `data_race()` 宏明确告诉工具"我知道，别管"。

## 动手待亲测

> ⚠️ **待亲测**：以下方案还没在 QEMU 上跑过，只列步骤，实测后补真实输出。

验证目标：在 QEMU（x86_64 或 arm64）里复现一次 KCSAN 报告。方案：

1. 编译内核：menuconfig 开 `CONFIG_KCSAN=y`（注意关掉 KASAN），建议再开 `CONFIG_KCSAN_STRICT=y`，重编内核、做 rootfs、启动 QEMU。
2. 写一个内核模块（放 `example/mini/` 下，遵循 `Makefile.arch`）：起两个 `kthread`，循环里不加锁、直接 `ptr->data = ...` 写同一个全局 `u64`，跑几万次。
3. `insmod` 后 `dmesg | grep KCSAN`，对照上面的报告格式读两个调用栈。
4. 对照实验：把写改成 `WRITE_ONCE`，重跑，看报告是否消失（体会 `KCSAN_ACCESS_ATOMIC` 的免检）；再试一次关掉 `KCSAN_ASSUME_PLAIN_WRITES_ATOMIC`、用普通写，看报告是否复现（体会那个坑）。
5. 进阶：在写之前加一行 `ASSERT_EXCLUSIVE_WRITER(ptr->data)`，再让另一处并发写，观察 bug 类型从 `data-race` 变成 `assert: race`，亲手验证 Advisory Lock 检测。

## 小结

KCSAN 用编译器插桩（`__tsan_*` 桩）+ 软观察点（`watchpoints[]` 数组）+ 抽样（`should_watch` 的 `kcsan_skip`）+ 人为延时（`udelay`），在运行时动态抓并发数据竞争。记住它的设计取舍：默认配置（`ASSUME_PLAIN_WRITES_ATOMIC` + `REPORT_VALUE_CHANGE_ONLY`）为降误报做了妥协，想看全部竞争要开 strict 模式。它和 KASAN 分工明确（内存正确性 vs 并发正确性、二选一），又靠 `ASSERT_EXCLUSIVE*()` 弥补 Lockdep 在"持锁却没保护对应变量"上的盲区。最后一句忠告：报告是症状不是处方，别用 `READ_ONCE` 当创可贴。

## 延伸阅读

- 源码（Linux 6.19）：
  - `kernel/kcsan/core.c` —— KCSAN 运行时核心，`check_access` / `should_watch` / `kcsan_setup_watchpoint` / `__tsan_*` 桩都在这。
  - `kernel/kcsan/report.c` —— 报告生成，`print_report` / `struct other_info` / 限流 `rate_limit_report`。
  - `kernel/kcsan/encoding.h` —— 观察点的编码/解码、`matching_access`、slot 映射。
  - `include/linux/kcsan-checks.h` —— `ASSERT_EXCLUSIVE*` 宏、`KCSAN_ACCESS_*` 标记位、`__kcsan_check_access`。
  - `include/linux/kcsan.h` —— `struct kcsan_ctx`（`atomic_nest_count` / `in_flat_atomic` / `access_mask` 等上下文字段）。
  - `lib/Kconfig.kcsan` —— 所有 KCSAN 配置项与默认值。
- 文档：[docs.kernel.org 内核调试工具索引](https://docs.kernel.org/dev-tools/index.html)、[KCSAN 官方说明](https://docs.kernel.org/dev-tools/kcsan.html)、[LKMM 与 access marking](https://docs.kernel.org/overview.html)（`tools/memory-model/Documentation/access-marking.txt`）。
- 战果追踪：[Syzbot KCSAN 上游实例](https://syzkaller.appspot.com/upstream?manager=ci2-upstream-kcsan-gce)。