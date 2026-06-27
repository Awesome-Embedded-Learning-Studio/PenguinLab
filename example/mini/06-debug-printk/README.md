# 06-debug-printk — printk 八级日志 + pr_xxx 演示

> 配套教程：[printk：内核调试的生命线](../../../document/tutorials/debugging/01-debug-printk.md)
> 对应进度节点：`debug-printk`（layer-4）
> 架构依赖：无（printk 是内核基础，任何 config 都能跑）

## 这个示例做什么

内核里没有 `printf`，调试靠 `printk` 插桩。本例演示：

- **`pr_fmt` 前缀**：`#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt`，让每条 `pr_xxx` 自动带模块名前缀，`dmesg` 里一眼定位调用者
- **八级 loglevel**：`pr_emerg`/`pr_alert`/`pr_crit`/`pr_err`/`pr_warn`/`pr_notice`/`pr_info`/`pr_debug`（对应 `KERN_EMERG`..`KERN_DEBUG`）
- **`pr_debug` 默认不显示**：需动态调试（`CONFIG_DYNAMIC_DEBUG`，当前 mini config 未开）或编译期 `-DDEBUG`——最常见的"我打了为啥没输出"坑

## 文件

| 文件 | 说明 |
|------|------|
| `dbgprintk.c` | `pr_fmt` + 八级 `pr_xxx` + 原始 `KERN_INFO` 写法对照 |
| `Makefile` | `obj-m += printk.o`；注释里给出 `-DDEBUG` 让 `pr_debug` 也打印的办法 |

## 编译

```bash
cd example/mini/06-debug-printk
make             # dbgprintk.ko（默认 arm64）
```

## 亲测（QEMU ARM64，2026-06-27 实测）

```bash
insmod dbgprintk.ko
dmesg | tail -10
dmesg | tail -10 | cat -v   # 或 dmesg -r 看不可见的 loglevel 前缀字符
rmmod dbgprintk
dmesg | tail -2
```

实测输出（2026-06-27）：

```
dbgprintk: EMERG (0): system is unusable
dbgprintk: ALERT (1): action must be taken immediately
dbgprintk: CRIT  (2): critical conditions
dbgprintk: ERR   (3): error conditions
dbgprintk: WARN  (4): warning conditions
dbgprintk: NOTICE(5): normal but significant
dbgprintk: INFO  (6): informational
printk demo: loaded, pr_fmt prefix = 'dbgprintk: '
```

> 注：`pr_debug` 那条默认不出现——当前 mini config 没开 `CONFIG_DYNAMIC_DEBUG`，这是最常见的"我打了为啥没输出"坑。
> 进阶：`make EXTRA_CFLAGS=-DDEBUG` 重编，`pr_debug` 那条就会出现（编译期打开 debug，等价于动态调试对单文件生效）。
