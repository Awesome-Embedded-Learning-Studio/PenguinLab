# Day 22–23 · H618 内核定制

**预计时长**：2 小时 / 天，共 4 小时  
**类型**：真机实操

---

## 做什么

拿全志 H618 的 BSP 内核源码（厂商 fork），与 mainline 做对比分析。然后进行内核裁剪：去掉不需要的模块，添加自定义 Kconfig 选项，重编译烧录到 H618。

---

## 要了解什么

### 1. 厂商 BSP 内核 vs Mainline

全志、瑞芯微等国内 SOC 厂商通常维护自己 fork 的内核（基于某个老版本如 5.4、5.15），包含：

- SOC 特有驱动（GPU、VPU、NPU）
- 未进入 mainline 的 hack 和补丁
- 厂商自定义的 DTS
- 可能有大量 "dirty" 提交（直接改现有文件而非补丁形式）

**如何分析厂商 patch：**

```bash
# 克隆厂商内核
git clone --depth=1 https://github.com/orangepi-xunlong/linux-orangepi \
  -b orange-pi-6.1-sun50iw9 ~/kernel/h618-kernel

# 克隆对应的 mainline 版本
git clone --depth=1 -b v6.1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
  ~/kernel/linux-6.1-mainline

# 对比某个子系统的差异（以 GPU 驱动为例）
diff -rq ~/kernel/linux-6.1-mainline/drivers/gpu/drm \
         ~/kernel/h618-kernel/drivers/gpu/drm \
  --exclude="*.o" --exclude="*.ko" 2>/dev/null | head -30

# 查看厂商的提交历史
cd ~/kernel/h618-kernel
git log --oneline | head -30
git shortlog --summary | head -20
```

### 2. `make localmodconfig`：基于运行中系统生成最小配置

这是 BSP 裁剪最实用的技巧：在目标系统（H618）上运行 `lsmod`，把输出传给 `localmodconfig`，它自动生成只包含当前系统需要的模块的配置。

```bash
# 步骤 1：在 H618 上收集当前加载的模块列表
ssh root@h618-board "lsmod" > /tmp/h618_lsmod.txt

# 步骤 2：在主机（WSL2）上运行 localmodconfig
cd ~/kernel/h618-kernel
LSMOD=/tmp/h618_lsmod.txt make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- localmodconfig
# 它会询问对每个未知模块是否需要，通常全选 n（不需要）

# 步骤 3：比较配置文件大小
wc -l .config
grep "=y\|=m" .config | wc -l
```

典型效果：从 5000+ 配置项减少到 300-500 个，编译时间减半，镜像体积减小。

### 3. 内核配置的关键裁剪方向

针对嵌入式场景，可以关闭：

```bash
# 在 menuconfig 中搜索并关闭以下类别

# 不需要的文件系统（保留 ext4/f2fs/tmpfs 即可）
CONFIG_BTRFS_FS=n
CONFIG_XFS_FS=n
CONFIG_JFS_FS=n

# 不需要的网络协议
CONFIG_IPV6=n  # 如果不用 IPv6
CONFIG_BLUETOOTH=n

# 调试选项（发布版本关闭）
CONFIG_DEBUG_KERNEL=n
CONFIG_KASAN=n
CONFIG_UBSAN=n
CONFIG_LOCKDEP=n  # 这几个对性能影响很大

# 不需要的驱动类别
CONFIG_SOUND=n  # 如果不用音频
CONFIG_DRM=n   # 如果不用显示
```

### 4. 添加自定义 Kconfig 选项

```bash
# 在 drivers/misc/ 下创建你的驱动目录
mkdir -p ~/kernel/h618-kernel/drivers/misc/myh618
```

按 Day 3-4 学到的方法，添加 Kconfig + Makefile，在 menuconfig 中显示。

---

## 练习

- [ ] 克隆 H618 厂商内核，用 `diffstat` 或 `diff -rq` 统计厂商添加了多少新文件、修改了多少文件
- [ ] 在 H618 上运行 `lsmod`，记录加载了哪些模块，有没有让你感到意外的？
- [ ] 用 `make localmodconfig` 生成精简配置，编译，烧录到 H618，确认系统正常启动
- [ ] 找到 H618 的 VPU（视频处理单元）驱动，看它是否已进入 mainline，还是只在厂商 fork 里
- [ ] 在精简后的内核配置中，加入 `CONFIG_FTRACE=y` 和 `CONFIG_KPROBES=y`（为 Week 4 第二个任务准备）

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| *Building Embedded Linux Systems* Yaghmour 等 | Ch.4 "Building the Linux Kernel" | 内核配置与裁剪的系统讲解 |
| 《嵌入式 Linux 系统开发》Karim Yaghmour 著 | 第 4 章 | 同上中文版 |
| *Mastering Embedded Linux Programming* Simmonds | Ch.4 "Configuring and Building the Kernel" | localmodconfig 等实用技巧 |
| 全志 H618 开源文档 | https://linux-sunxi.org/H618 | sunxi 社区对 H618 的 mainline 支持状态 |

---

# Day 24–25 · ftrace 与 kprobe 调试

**预计时长**：2 小时 / 天，共 4 小时  
**类型**：实验（调试技能）

---

## 做什么

掌握 ftrace 和 kprobe，这是内核调试的两件核武器，不需要修改内核源码就能深度追踪任意内核函数。

---

## 要了解什么

### 1. ftrace：内核函数跟踪框架

ftrace 通过在函数入口插入 mcount/fentry 调用实现跟踪，运行时开销很低（未使能时接近零）。

**tracefs 接口**（挂载在 `/sys/kernel/debug/tracing/`）：

```bash
# 查看可用 tracer
cat /sys/kernel/debug/tracing/available_tracers
# 通常有：nop, function, function_graph, blk, hwlat, ...

# function_graph tracer：追踪函数调用树
echo function_graph > /sys/kernel/debug/tracing/current_tracer
echo 1 > /sys/kernel/debug/tracing/tracing_on
# 做一些操作...
echo 0 > /sys/kernel/debug/tracing/tracing_on
cat /sys/kernel/debug/tracing/trace | head -50
```

**追踪特定函数**（过滤减少噪音）：

```bash
# 追踪 GPIO 相关函数
echo "gpio*" > /sys/kernel/debug/tracing/set_ftrace_filter
echo function_graph > /sys/kernel/debug/tracing/current_tracer
echo 1 > /sys/kernel/debug/tracing/tracing_on
# 触发 GPIO 操作
cat /sys/kernel/debug/tracing/trace
```

**trace-cmd 工具**（命令行封装，推荐）：

```bash
# 安装
sudo apt install trace-cmd kernelshark

# 追踪中断处理（irq 相关事件）
trace-cmd record -e irq:irq_handler_entry -e irq:irq_handler_exit \
                 -e sched:sched_switch -- sleep 1
trace-cmd report | head -50

# 追踪特定进程的系统调用
trace-cmd record -p function_graph -g sys_read -F cat /dev/mychardev
trace-cmd report | head -100

# 使用 kernelshark GUI（WSL2 需要 X11 或 WSLg）
kernelshark trace.dat
```

**追踪你自己驱动的函数**：

```bash
# 查看你的模块有哪些函数可以追踪
cat /sys/kernel/debug/tracing/available_filter_functions | grep chardev

# 只追踪你的驱动函数
echo "chardev_*" > /sys/kernel/debug/tracing/set_ftrace_filter
```

### 2. perf：性能分析工具

```bash
# 编译 perf（在内核源码树里）
cd ~/kernel/linux-stable/tools/perf
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
# 或直接安装：sudo apt install linux-tools-common linux-tools-$(uname -r)

# CPU 性能计数器统计
perf stat -e cache-misses,cache-references,instructions,cycles \
          -- ./my_test_program

# 实时 profiling（类似 top，但按 CPU 使用率显示函数）
perf top -g --call-graph dwarf

# 记录并分析（生成火焰图）
perf record -g ./my_test_program
perf report --stdio | head -50
```

### 3. kprobe：任意内核函数动态插桩

kprobe 可以在**任意内核函数**的入口和返回处插入探针，无需修改内核源码，无需重启。

**方法 1：通过 tracefs 接口（最简单）**：

```bash
# 在 do_sys_open 函数入口插探针（监控所有文件 open）
echo 'p:myprobe do_sys_open filename=+0(%si):string' \
    > /sys/kernel/debug/tracing/kprobe_events

echo 1 > /sys/kernel/debug/tracing/events/kprobes/myprobe/enable
echo 1 > /sys/kernel/debug/tracing/tracing_on
# 操作文件...
cat /sys/kernel/debug/tracing/trace | grep myprobe | head -20

# 清理
echo 0 > /sys/kernel/debug/tracing/events/kprobes/myprobe/enable
echo '-:myprobe' > /sys/kernel/debug/tracing/kprobe_events
```

**方法 2：在内核模块中用 kprobe API**：

```c
#include <linux/kprobes.h>

static struct kprobe kp = {
    .symbol_name = "vfs_read",  /* 追踪的函数名 */
};

static int handler_pre(struct kprobe *p, struct pt_regs *regs)
{
    /* 在 vfs_read 入口运行 */
    pr_info("vfs_read called, file count: %lx\n", regs->ARM_r0);
    return 0;
}

static void handler_post(struct kprobe *p, struct pt_regs *regs,
                         unsigned long flags)
{
    /* 在 vfs_read 返回后运行 */
    pr_info("vfs_read returned: %ld\n", regs->ARM_r0);
}

kp.pre_handler  = handler_pre;
kp.post_handler = handler_post;
register_kprobe(&kp);
// 用完后
unregister_kprobe(&kp);
```

---

## 练习

- [ ] 用 `function_graph` tracer 追踪 `insmod chardev.ko` 时的函数调用树，找到 `chardev_init` 出现在哪里
- [ ] 用 trace-cmd 追踪一次 `write` 系统调用到你的 `chardev_write` 函数的完整路径
- [ ] 用 kprobe（tracefs 接口）监控所有对 `/dev/mychardev` 的 open 操作，打印进程名和 PID
- [ ] 用 `perf stat` 比较：对 `/dev/mychardev` 做 1000 次 read 和 1000 次 write，哪个 cache-miss 更多？分析原因
- [ ] 在 H618 上（如果已搭建），用 ftrace 追踪一次网络数据包的接收路径（`netif_receive_skb` 相关函数）

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| 内核文档 | `Documentation/trace/ftrace.rst` | ftrace 完整官方文档 |
| 内核文档 | `Documentation/trace/kprobes.rst` | kprobe 官方文档 |
| 《Linux 性能优化实战》倪朋飞 | 全书 | 国内最系统的 Linux 性能分析，配合 perf 使用 |
| *BPF Performance Tools* Brendan Gregg | Ch.1–3 | perf + ftrace 的现代替代，eBPF 入门 |
| Brendan Gregg's blog | https://www.brendangregg.com/flamegraphs.html | 火焰图使用指南 |
| LWN.net | https://lwn.net/Articles/290277/ | "Kernel debugging with kprobes" |

---

# Day 26–27 · 内存管理基础

**预计时长**：2 小时 / 天，共 4 小时  
**类型**：理论

---

## 要了解什么

### 1. 内核内存分配 API 对比

| API | 物理连续 | 可睡眠 | 大小限制 | 用途 |
|-----|:--------:|:------:|---------|------|
| `kmalloc(size, GFP_KERNEL)` | ✅ | ✅ | < 128KB | 通用小块，进程上下文 |
| `kmalloc(size, GFP_ATOMIC)` | ✅ | ❌ | < 128KB | 中断上下文 |
| `kzalloc` | ✅ | ✅ | < 128KB | 同 kmalloc + 清零 |
| `vmalloc(size)` | ❌ | ✅ | 受虚拟地址空间限制 | 大块内存，物理不连续 |
| `alloc_pages(GFP, order)` | ✅ | 视 GFP | 2^order 页 | 页级别分配 |
| `dma_alloc_coherent` | ✅ | ✅ | 受 DMA 区域限制 | DMA 缓冲区（不经过 cache） |

### 2. GFP flags 含义

```c
GFP_KERNEL   = __GFP_RECLAIM | __GFP_IO | __GFP_FS
               // 可睡眠等待内存释放，最常用
GFP_ATOMIC   = __GFP_HIGH
               // 不可睡眠，优先级高，中断/软中断上下文使用
GFP_DMA      = __GFP_DMA
               // 分配 DMA 区域内存（ISA DMA 需要，现代很少用）
GFP_DMA32    = __GFP_DMA32
               // 分配 32 位地址内可达的内存（32 位 DMA 设备）
GFP_NOWAIT   // 不等待，不可睡眠，但不使用紧急储备
GFP_NOIO     // 可等待，但不触发 I/O（避免死锁）
```

### 3. slab 分配器

`kmalloc` 底层是 slab（或 slub/slob）分配器，按大小分类管理内存池，避免频繁向页分配器申请。

对于频繁分配/释放的固定大小对象，用 `kmem_cache` 更高效：

```c
struct kmem_cache *my_cache;

// 模块初始化时创建 cache
my_cache = kmem_cache_create("my_obj_cache",
                              sizeof(struct my_obj),  // 对象大小
                              0,                       // 对齐（0=默认）
                              SLAB_HWCACHE_ALIGN,      // flags
                              NULL);                   // 构造函数

// 分配/释放
struct my_obj *obj = kmem_cache_alloc(my_cache, GFP_KERNEL);
kmem_cache_free(my_cache, obj);

// 模块退出时销毁（必须确保所有对象已归还）
kmem_cache_destroy(my_cache);
```

### 4. DMA 内存管理

```c
#include <linux/dma-mapping.h>

dma_addr_t dma_handle;
void *cpu_addr;

// 分配 coherent（一致性）DMA 缓冲区
// coherent：CPU 和 DMA 设备看到的数据一致，不需要手动 flush cache
cpu_addr = dma_alloc_coherent(&pdev->dev, size, &dma_handle, GFP_KERNEL);
// cpu_addr：CPU 访问的虚拟地址
// dma_handle：DMA 控制器使用的物理地址（写入 DMA 描述符）

// 释放
dma_free_coherent(&pdev->dev, size, cpu_addr, dma_handle);

// Streaming DMA（性能更好，但需要手动同步）
// 适合大量数据传输（网卡、存储等）
dma_map_single(&pdev->dev, kbuf, size, DMA_TO_DEVICE);  // 刷 cache
// DMA 传输...
dma_unmap_single(&pdev->dev, dma_handle, size, DMA_TO_DEVICE);  // 无效化 cache
```

### 5. 内存泄漏排查

```bash
# 查看 slab 分配情况
cat /proc/slabinfo | sort -k3 -rn | head -20

# 查看内存使用情况
cat /proc/meminfo
# 重点字段：MemFree（可用物理内存），Slab（slab 占用），
#           SReclaimable（可回收 slab），SUnreclaim（不可回收 slab）

# kmemleak：内核内存泄漏检测（需要 CONFIG_DEBUG_KMEMLEAK=y）
echo scan > /sys/kernel/debug/kmemleak
cat /sys/kernel/debug/kmemleak
```

---

## 练习

- [ ] 写一个内核模块，用 `kmalloc`、`vmalloc`、`dma_alloc_coherent` 各分配 4MB，观察 `/proc/meminfo` 中 `MemFree` 和 `Slab` 字段的变化
- [ ] 尝试在中断上下文（timer callback）中用 `kmalloc(GFP_KERNEL)` 看看会发生什么（在 QEMU 里测试，安全）
- [ ] 写一个"内存泄漏"模块（分配但不释放），观察 kmemleak 如何检测到它
- [ ] 查看 `cat /proc/slabinfo`，找出 `size-128`、`size-256` 等 cache 的对象数量，理解 slab 的分级策略

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| 《Linux 内核设计与实现》Robert Love | 第 12 章 | 内存管理，kmalloc/vmalloc/slab |
| *Linux Kernel Development* Love | Ch.12 "Memory Management" | 英文原版 |
| 《深入理解 Linux 内核》Bovet & Cesati | 第 8 章 | 内存管理最详细 |
| 内核文档 | `Documentation/core-api/memory-allocation.rst` | 内存分配官方指南 |
| 内核文档 | `Documentation/core-api/dma-api.rst` | DMA API 完整文档 |
| LWN.net | https://lwn.net/Articles/229984/ | "Memory compaction" 和内存管理系列文章 |

---

# Day 28–30 · 综合项目：I²C 传感器驱动

**预计时长**：2 小时 / 天，共 6 小时  
**类型**：综合项目（真机验证）

---

## 做什么

用一个月学到的全部知识，写一个完整的 I²C 温湿度传感器驱动（以 SHT30 为例，或你手边有的任何 I²C 设备）。要求覆盖：DTS 配置、i2c_driver 注册、threaded IRQ、sysfs 接口、完整的 devm_ 资源管理、真机验证。

---

## 要了解什么

### I²C 子系统核心 API

```c
#include <linux/i2c.h>

/* 驱动结构 */
static struct i2c_driver sht30_driver = {
    .driver = {
        .name           = "sht30",
        .of_match_table = sht30_of_match,
    },
    .probe    = sht30_probe,
    .remove   = sht30_remove,
    .id_table = sht30_id,
};
module_i2c_driver(sht30_driver);  /* 等价于手写 module_init/exit */

/* 在 probe 中：client 是 I²C 设备描述符 */
static int sht30_probe(struct i2c_client *client)
{
    /* 写寄存器 */
    u8 cmd[2] = {0x24, 0x00};  /* SHT30 测量命令 */
    i2c_master_send(client, cmd, 2);

    /* 读数据 */
    u8 data[6];
    i2c_master_recv(client, data, 6);

    /* 或使用 smbus 接口（更简单，适合标准 I²C 设备）*/
    s32 val = i2c_smbus_read_word_data(client, 0x00);  /* 读 16bit 寄存器 */
}
```

### DTS 配置

```dts
/* imx6ull 的 i2c1 节点下添加 SHT30 */
&i2c1 {
    clock-frequency = <100000>;  /* 100 kHz 标准模式 */
    pinctrl-names = "default";
    pinctrl-0 = <&pinctrl_i2c1>;
    status = "okay";

    sht30: humidity-sensor@44 {
        compatible = "sensirion,sht30";
        reg = <0x44>;          /* I²C 地址 */
        alert-gpios = <&gpio1 28 GPIO_ACTIVE_HIGH>;  /* ALERT 引脚（中断）*/
    };
};
```

---

## 完整驱动框架

```c
// sht30.c — 完整 I²C 驱动（框架，需补全硬件通信细节）
#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/sysfs.h>
#include <linux/hwmon.h>
#include <linux/hwmon-sysfs.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("learner");
MODULE_DESCRIPTION("SHT30 temperature/humidity sensor driver");

/* SHT30 命令 */
#define SHT30_CMD_MEAS_HIGHREP_STRETCH  0x2C06
#define SHT30_CMD_SOFTRESET             0x30A2

struct sht30_data {
    struct i2c_client *client;
    struct gpio_desc  *alert_gpio;
    struct mutex       lock;

    /* 最近一次测量结果 */
    int temperature_m_c;  /* 毫摄氏度 */
    int humidity_m_pct;   /* 千分之一百分比 */
};

static int sht30_read_measurement(struct sht30_data *data)
{
    struct i2c_client *client = data->client;
    u8 cmd[2];
    u8 buf[6];
    u16 raw_temp, raw_hum;
    int ret;

    /* 发送测量命令 */
    cmd[0] = (SHT30_CMD_MEAS_HIGHREP_STRETCH >> 8) & 0xFF;
    cmd[1] = SHT30_CMD_MEAS_HIGHREP_STRETCH & 0xFF;
    ret = i2c_master_send(client, cmd, 2);
    if (ret < 0) return ret;

    msleep(20);  /* 等待测量完成（可以用中断替代 polling）*/

    /* 读取 6 字节（温度 MSB, 温度 LSB, CRC, 湿度 MSB, 湿度 LSB, CRC）*/
    ret = i2c_master_recv(client, buf, 6);
    if (ret < 0) return ret;

    raw_temp = (buf[0] << 8) | buf[1];
    raw_hum  = (buf[3] << 8) | buf[4];

    /* 换算（SHT30 数据手册公式）*/
    /* T[°C] = -45 + 175 * raw / 65535 */
    data->temperature_m_c = -45000 + (175000 * (int)raw_temp) / 65535;
    /* RH[%] = 100 * raw / 65535 */
    data->humidity_m_pct = (100000 * (int)raw_hum) / 65535;

    return 0;
}

/* sysfs 属性：温度 */
static ssize_t temperature_show(struct device *dev,
                                 struct device_attribute *attr, char *buf)
{
    struct sht30_data *data = dev_get_drvdata(dev);
    int ret;

    mutex_lock(&data->lock);
    ret = sht30_read_measurement(data);
    mutex_unlock(&data->lock);

    if (ret) return ret;
    return sysfs_emit(buf, "%d\n", data->temperature_m_c);
    /* 单位：毫摄氏度，用户态除以 1000 得到摄氏度 */
}
static DEVICE_ATTR_RO(temperature);

/* sysfs 属性：湿度 */
static ssize_t humidity_show(struct device *dev,
                               struct device_attribute *attr, char *buf)
{
    struct sht30_data *data = dev_get_drvdata(dev);
    int ret;

    mutex_lock(&data->lock);
    ret = sht30_read_measurement(data);
    mutex_unlock(&data->lock);

    if (ret) return ret;
    return sysfs_emit(buf, "%d\n", data->humidity_m_pct);
}
static DEVICE_ATTR_RO(humidity);

static struct attribute *sht30_attrs[] = {
    &dev_attr_temperature.attr,
    &dev_attr_humidity.attr,
    NULL,
};
ATTRIBUTE_GROUPS(sht30);

/* 中断处理（ALERT 引脚，温度/湿度越限告警）*/
static irqreturn_t sht30_alert_handler(int irq, void *dev_id)
{
    struct sht30_data *data = dev_id;
    dev_warn(&data->client->dev, "Alert triggered!\n");
    /* TODO：读取告警寄存器，清除告警 */
    return IRQ_HANDLED;
}

static int sht30_probe(struct i2c_client *client)
{
    struct sht30_data *data;
    int irq, ret;
    u8 reset_cmd[2] = {0x30, 0xA2};

    /* 检查 I²C 功能 */
    if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C))
        return -EOPNOTSUPP;

    data = devm_kzalloc(&client->dev, sizeof(*data), GFP_KERNEL);
    if (!data) return -ENOMEM;

    data->client = client;
    mutex_init(&data->lock);
    i2c_set_clientdata(client, data);

    /* 软复位 */
    i2c_master_send(client, reset_cmd, 2);
    msleep(2);

    /* 获取 ALERT GPIO（如果 DTS 里有配置）*/
    data->alert_gpio = devm_gpiod_get_optional(&client->dev, "alert", GPIOD_IN);
    if (IS_ERR(data->alert_gpio))
        return PTR_ERR(data->alert_gpio);

    /* 注册中断（如果有 ALERT GPIO）*/
    if (data->alert_gpio) {
        irq = gpiod_to_irq(data->alert_gpio);
        ret = devm_request_irq(&client->dev, irq, sht30_alert_handler,
                               IRQF_TRIGGER_HIGH, dev_name(&client->dev), data);
        if (ret) {
            dev_warn(&client->dev, "Failed to request IRQ: %d\n", ret);
            /* 非致命错误，继续不带中断运行 */
        }
    }

    /* 创建 sysfs 属性组 */
    ret = sysfs_create_groups(&client->dev.kobj, sht30_groups);
    if (ret) return ret;

    dev_info(&client->dev, "SHT30 sensor initialized\n");
    return 0;
}

static void sht30_remove(struct i2c_client *client)
{
    sysfs_remove_groups(&client->dev.kobj, sht30_groups);
}

static const struct of_device_id sht30_of_match[] = {
    { .compatible = "sensirion,sht30" },
    { .compatible = "sensirion,sht31" },  /* 兼容 SHT31 */
    { }
};
MODULE_DEVICE_TABLE(of, sht30_of_match);

static const struct i2c_device_id sht30_id[] = {
    { "sht30", 0 },
    { }
};
MODULE_DEVICE_TABLE(i2c, sht30_id);

static struct i2c_driver sht30_driver = {
    .driver = {
        .name           = "sht30",
        .of_match_table = sht30_of_match,
    },
    .probe    = sht30_probe,
    .remove   = sht30_remove,
    .id_table = sht30_id,
};
module_i2c_driver(sht30_driver);
```

---

## 练习

- [ ] 如果没有 SHT30，可以用 imx6ull 板载的任意 I²C 设备（许多开发板有温度传感器，或者用 AT24C02 EEPROM 代替，只做读写不用解析温度）
- [ ] 先用 `i2cdetect -y 1`（I²C 总线 1）扫描，确认设备地址
- [ ] 用 `i2cdump -y 1 0x44`（SHT30 地址）读取原始寄存器数据，手工验证换算公式
- [ ] 加载驱动后，`cat /sys/bus/i2c/devices/1-0044/temperature` 读取温度
- [ ] 用 ftrace（Week 4 第一个任务的技能）追踪一次 sysfs read 从用户态到 `sht30_read_measurement` 的完整调用链

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| *Linux Device Driver Development* Madieu | Ch.9 "Writing I²C Device Drivers" | I²C 驱动最详细的现代讲解 |
| 《Linux 设备驱动开发详解》宋宝华 | 第 15 章 | I²C 子系统 + 实战例子 |
| *Linux Device Drivers* LDD3 | Ch.15 "Memory Mapping and DMA" | 综合参考 |
| 内核源码 | `drivers/iio/humidity/sht3x.c` | 内核自带的 SHT3x 驱动，是你的参考实现 |
| 内核文档 | `Documentation/i2c/writing-clients.rst` | I²C 驱动官方指南 |
| SHT30 数据手册 | https://sensirion.com/media/documents/213E6A3B/63A5A569/Datasheet_SHT3x_DIS.pdf | 硬件手册，查命令格式和换算公式 |
