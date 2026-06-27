# 07-debug-oops — 故意触发一次 NULL 解引用 Oops

> 配套教程：[Oops：内核犯错时的现场](../../../document/tutorials/debugging/05-debug-oops.md)
> 对应进度节点：`debug-oops`（layer-4）
> 架构依赖：无（任何内核都会对 NULL 解引用报 Oops）

## ⚠️ 这个示例会触发内核 Oops

`trigger=1` 时，`insmod` 会让内核打印一段完整的 Oops 现场。后果取决于 `panic_on_oops`：

- `panic_on_oops=0`（默认，mini config 未开 `CONFIG_PANIC_ON_OOPS`）→ Oops 打印现场后**杀掉 insmod 进程，系统继续跑**
- `panic_on_oops=1`（`echo 1 > /proc/sys/kernel/panic_on_oops`）→ 系统**直接 panic 死透**

所以**先确认 `panic_on_oops` 是 0** 再触发，免得 QEMU 死了得重启。

## 这个示例演示什么

- **NULL 指针 + 结构体成员偏移**：`p=NULL`，`&p->data = NULL + 0x30`，Oops 报的故障地址就是 `0x30`（看到几十几百的小地址 = 八成是 NULL 解引用结构体成员，那数字是偏移）
- **`*(volatile)` 防优化**：GCC 会把"已知 NULL 解引用"当 UB 优化掉，`volatile` 强制保留这次访存
- **读 Oops 现场**：`pc` 偏移、`Code:` 字节（ARM64 用**圆括号**包崩点指令，不是 x86 的尖括号）、`Call trace`、`Tainted`（`G` 是干净基线不是污染位）

## 文件

| 文件 | 说明 |
|------|------|
| `oops.c` | `trigger` 门控 + `struct oopsie`(data 偏移 0x30) + `*(volatile)` NULL 写 |
| `Makefile` | `obj-m += oops.o`（无用户态，靠 `dmesg` 看 Oops） |

## 编译

```bash
cd example/mini/07-debug-oops
make             # oops.ko（默认 arm64）
```

## 亲测（QEMU ARM64，2026-06-27 实测）

```bash
# 先确认 panic_on_oops=0, 否则一崩就死
cat /proc/sys/kernel/panic_on_oops        # 应为 0

# 安全加载看一下
insmod oops.ko                            # trigger 默认 0, 安全
dmesg | tail -3

# 触发 oops
rmmod oops
insmod oops.ko trigger=1                  # insmod 立刻 Oops
dmesg | tail -60

# 进阶对比: 让它一崩就死
echo 1 > /proc/sys/kernel/panic_on_oops
insmod oops.ko trigger=1                  # 系统直接 panic
```

实测输出（2026-06-27，`trigger=1` 触发的 Oops 现场精简）：

```
[  694.410104] Unable to handle kernel NULL pointer dereference at virtual address 0000000000000030
[  694.452934] pc : oopsdemo_init+0x3c/0xfdc [oops]
[  694.488859] Call trace:
[  694.489529]  oopsdemo_init+0x3c/0xfdc [oops] (P)
 ...（do_one_initcall / load_module / sys_init_module 等）
[  694.509711] Code: 91012000 97ffffeb d2800600 52800f01 (39000001)
[  694.512143] ---[ end trace 0000000000000000 ]---
Tainted: G  O
```

> 关注点：故障地址 `0x30` 正是 `&p->data` 的结构体成员偏移（`p=NULL + 0x30`）；`pc : oopsdemo_init+0x3c/0xfdc [oops]` 指回模块初始化函数；`Code:` 行 ARM64 用**圆括号**包崩点指令（`(39000001)` 那条 str）；`Tainted: G O` 里 `G` 是干净基线、`O`（OOT_MODULE）表示载了树外模块。`panic_on_oops=0` 时 insmod 进程报 `Segmentation fault`，但系统继续跑。

解栈三件斧（宿主上跑）：拿到 `Code:` 里圆括号那串 / `pc` 地址，用 `aarch64-linux-gnu-objdump -d oops.o` 或 `addr2line` 对回源码行。
