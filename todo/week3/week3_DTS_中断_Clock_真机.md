# Day 15–16 · Device Tree 深度与 Overlay

**预计时长**：2 小时 / 天，共 4 小时  
**类型**：理论 + 代码阅读

---

## 做什么

你已经接触过 DTS，今天要加深：`of_match_table` 的完整匹配机制、驱动中各类 OF API 的用法、YAML binding 文档格式、以及 DT Overlay 的使用场景（对 H618 和快速迭代开发非常有用）。

---

## 要了解什么

### 1. `compatible` 的格式惯例

```dts
/* 格式：vendor,device[-variant] */
compatible = "nxp,imx6ul-gpio";        /* NXP 的 imx6ul GPIO */
compatible = "arm,pl011";              /* ARM PrimeCell UART */
compatible = "simple-bus";             /* 通用总线，无需专属驱动 */

/* 多个值：从最具体到最通用（降级匹配）*/
compatible = "myvendor,spi-flash-v2", "jedec,spi-nor";
/* 驱动先尝试匹配 v2，失败则尝试通用 jedec 驱动 */
```

### 2. 驱动中常用 OF API

```c
#include <linux/of.h>
#include <linux/of_gpio.h>
#include <linux/of_irq.h>

/* 读取属性值 */
u32 val;
of_property_read_u32(np, "clock-frequency", &val);

const char *str;
of_property_read_string(np, "label", &str);

u32 arr[4];
of_property_read_u32_array(np, "reg", arr, 4);

/* 检查属性是否存在（bool 属性）*/
bool flag = of_property_read_bool(np, "wakeup-source");

/* 获取 GPIO */
struct gpio_desc *gpiod;
gpiod = devm_gpiod_get(&pdev->dev, "reset", GPIOD_OUT_LOW);
/* 对应 DTS 中的 reset-gpios = <&gpio1 5 GPIO_ACTIVE_LOW>; */

/* 获取中断 */
int irq = of_irq_get(np, 0);  /* 或 platform_get_irq(pdev, 0) */

/* 遍历子节点 */
struct device_node *child;
for_each_child_of_node(np, child) {
    /* 处理每个子节点 */
    of_node_put(child);  /* 用完要 put */
}
/* 或用安全版本（遍历中可 break）*/
for_each_available_child_of_node(np, child) { ... }
```

### 3. YAML Binding 文档

现代内核（5.x+）要求为每个 DTS 节点类型写 YAML binding 文档，放在 `Documentation/devicetree/bindings/` 下，用 `dt-schema` 工具验证。

```yaml
# Documentation/devicetree/bindings/leds/myvendor,my-led.yaml
%YAML 1.2
---
$id: http://devicetree.org/schemas/leds/myvendor,my-led.yaml#
$schema: http://devicetree.org/meta-schemas/core.yaml#

title: MyVendor LED Controller

properties:
  compatible:
    const: myvendor,my-led

  reg:
    maxItems: 1

  gpios:
    description: GPIO controlling the LED
    maxItems: 1

  label:
    description: LED label for sysfs

required:
  - compatible
  - gpios

additionalProperties: false

examples:
  - |
    my_led: led@0 {
        compatible = "myvendor,my-led";
        gpios = <&gpio1 5 GPIO_ACTIVE_HIGH>;
        label = "status";
    };
```

验证：
```bash
make dt_binding_check DT_SCHEMA_FILES=Documentation/devicetree/bindings/leds/myvendor,my-led.yaml
```

### 4. DT Overlay：运行时修改设备树

DT Overlay 允许在系统运行时动态加载/卸载设备树片段，而不需要重启。在 H618 的 SBC 板子上修改外设配置时极其有用（类似树莓派的 `config.txt overlays`）。

```dts
/* my-i2c-sensor.dts （overlay 格式）*/
/dts-v1/;
/plugin/;

&i2c1 {
    /* 向已有的 i2c1 节点添加子节点 */
    my_sensor: sensor@48 {
        compatible = "ti,tmp102";
        reg = <0x48>;
    };
};
```

```bash
# 编译 overlay
dtc -@ -I dts -O dtb -o my-i2c-sensor.dtbo my-i2c-sensor.dts
# -@ 选项保留符号，供 overlay 引用父树节点

# 在运行中加载（需要 CONFIG_OF_OVERLAY=y）
mkdir /sys/kernel/config/device-tree/overlays/my_sensor
cat my-i2c-sensor.dtbo > /sys/kernel/config/device-tree/overlays/my_sensor/dtbo
# 卸载
rmdir /sys/kernel/config/device-tree/overlays/my_sensor
```

---

## 练习

- [ ] 在 imx6ull DTS 中找到 `fsl,imx6ul-iomuxc` 节点，理解 `fsl,pins` 属性的格式（引脚复用配置）
- [ ] 写一个最小 DT Overlay，在 QEMU 的 virt 平台上添加一个 `my,platform-demo` 节点（Week 2 的驱动），编译 dtbo 并加载，验证驱动 probe 被调用
- [ ] 阅读 `Documentation/devicetree/bindings/gpio/gpio.txt`，理解 GPIO specifier 格式（`<&gpio1 5 GPIO_ACTIVE_LOW>` 各字段含义）
- [ ] 用 `dtc -I dtb -O dts` 把已有的 imx6ull DTB 反编译回 DTS 阅读，找到 UART1 节点，理解 `pinctrl-0` 和 `pinctrl-names` 的关系

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| *Mastering Embedded Linux Programming* Simmonds | Ch.3 "All About Bootloaders" & Ch.11 "Interfacing with Device Drivers" | DTS 实战，覆盖 overlay |
| 《嵌入式 Linux 设备驱动程序开发》Alberto Liberal | 第 5 章 | DTS 深度，含 binding 文档写法 |
| 内核文档 | `Documentation/devicetree/usage-model.rst` | DTS 使用模型官方文档 |
| 内核文档 | `Documentation/devicetree/bindings/` | 所有 binding 的参考实例 |
| devicetree.org | https://www.devicetree.org/specifications/ | DTS 规范原文（PDF） |

---

# Day 17–18 · 中断子系统全链路

**预计时长**：2 小时 / 天，共 4 小时  
**类型**：理论（核心知识点）

---

## 做什么

搞清楚从硬件中断信号到你的 `irq_handler` 函数的完整调用链，以及中断处理的上下文限制（这些限制是驱动 bug 的最大来源之一）。

---

## 要了解什么

### 1. 中断的完整路径

```
外设产生中断信号
       │
       ▼
  GIC（通用中断控制器）
  汇集所有中断源，分配优先级，路由到 CPU
       │
       ▼
  CPU 跳转到异常向量表（arch/arm/kernel/entry-armv.S）
       │
       ▼
  内核通用中断入口（handle_IRQ）
       │
       ▼
  IRQ Domain 查表（硬件 IRQ 号 → Linux virtual IRQ 号）
       │
       ▼
  中断描述符（irq_desc）→ 调用 irq_handler_t
       │
       ▼
  你的 irq_handler 函数
```

### 2. IRQ Domain：硬件中断号 vs 虚拟中断号

不同硬件的中断号编号方式不同（GIC、PIC、GPIO 中断控制器各有各的编号）。IRQ Domain 做翻译：

```c
/* 硬件给 GIC 的中断号（hwirq）→ Linux 内核的软件中断号（virq）*/
/* 驱动无需关心这个翻译，platform_get_irq() 直接返回 virq */
int irq = platform_get_irq(pdev, 0);
```

### 3. 注册中断处理函数

```c
/* 标准注册 */
ret = request_irq(irq, my_handler, IRQF_SHARED, "my-dev", priv);

/* devm 版本（推荐）*/
ret = devm_request_irq(&pdev->dev, irq, my_handler,
                       IRQF_TRIGGER_RISING, dev_name(&pdev->dev), priv);

/* 中断处理函数签名 */
static irqreturn_t my_handler(int irq, void *dev_id)
{
    struct my_priv *priv = dev_id;
    // 读硬件寄存器，清中断标志
    // 唤醒等待队列 or 调度 workqueue 做后续处理
    return IRQ_HANDLED;  // 或 IRQ_NONE（不是我的中断）
}
```

常用 `flags`：
- `IRQF_SHARED`：共享中断线（多设备共用一个 IRQ）
- `IRQF_TRIGGER_RISING/FALLING/HIGH/LOW`：触发方式
- `IRQF_ONESHOT`：配合线程化中断，处理完前不重新使能

### 4. 中断上下文的严格限制

中断处理函数在**中断上下文**（硬中断上下文）中运行：

| 操作 | 硬中断上下文 | 软中断上下文 | 进程上下文 |
|------|:-----------:|:-----------:|:---------:|
| `kmalloc(GFP_KERNEL)` | ❌ | ❌ | ✅ |
| `kmalloc(GFP_ATOMIC)` | ✅ | ✅ | ✅ |
| `msleep()` / `schedule()` | ❌ | ❌ | ✅ |
| `mutex_lock()` | ❌ | ❌ | ✅ |
| `spin_lock()` | ✅ | ✅ | ✅ |
| `spin_lock_irqsave()` | ✅（必须） | ✅ | ✅ |

**如何判断当前是否在中断上下文：** `in_interrupt()`（不推荐直接用，内核代码更多靠设计避免）

### 5. 下半部机制选择

| 机制 | 运行上下文 | 可睡眠 | 适用场景 |
|------|-----------|--------|---------|
| 软中断（softirq） | 软中断上下文 | ❌ | 网络、块设备（内核开发者用） |
| `tasklet` | 软中断上下文 | ❌ | 轻量、不睡眠的下半部 |
| `workqueue` | 内核线程（进程上下文） | ✅ | 需要睡眠、分配内存的下半部 |
| 线程化中断（threaded IRQ） | 内核线程 | ✅ | 现代推荐，最简单 |

**现代推荐做法**：用 `request_threaded_irq`（或 `devm_request_threaded_irq`）：

```c
ret = devm_request_threaded_irq(&pdev->dev, irq,
    my_hard_handler,    /* 上半部：只做最少工作（清中断标志）*/
    my_thread_handler,  /* 下半部：在内核线程中运行，可以睡眠 */
    IRQF_ONESHOT,
    dev_name(&pdev->dev), priv);

/* 上半部 */
static irqreturn_t my_hard_handler(int irq, void *dev_id)
{
    /* 快速读取硬件状态，清除中断 pending 标志 */
    return IRQ_WAKE_THREAD;  /* 告诉内核唤醒线程处理函数 */
}

/* 下半部（线程中运行，可以睡眠）*/
static irqreturn_t my_thread_handler(int irq, void *dev_id)
{
    struct my_priv *priv = dev_id;
    /* 做复杂处理：读取大量数据、分配内存、更新数据结构 */
    return IRQ_HANDLED;
}
```

---

## 练习

- [ ] 在 QEMU 的 shell 里执行 `cat /proc/interrupts`，理解每一列的含义（IRQ 号、CPU 亲和性、处理次数、描述）
- [ ] 修改 platform_demo 驱动，如果 DTS 里有中断资源则注册 threaded IRQ，打印"IRQ registered"
- [ ] 阅读 `drivers/input/keyboard/gpio_keys.c`，找到它的中断处理函数，理解它用的是 threaded IRQ 还是 workqueue
- [ ] 用 `echo 1 > /proc/irq/N/spurious`（N 是某个 IRQ 号）观察虚假中断统计（在 QEMU 里操作）

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| 《Linux 内核设计与实现》Robert Love | 第 7–8 章 | 中断与中断处理、下半部 |
| *Linux Kernel Development* Robert Love | Ch.7–8 | 英文原版同上 |
| 《深入理解 Linux 内核》Bovet & Cesati | 第 4 章 | 中断和异常，最详细 |
| *Understanding the Linux Kernel* Bovet | Ch.4 "Interrupts and Exceptions" | 英文原版 |
| 内核文档 | `Documentation/core-api/genericirq.rst` | IRQ domain 和通用中断框架 |
| LWN.net | https://lwn.net/Articles/302043/ | "Threaded interrupts" |

---

# Day 19–20 · Clock 框架与 Pinctrl 框架

**预计时长**：1.5 小时 / 天，共 3 小时  
**类型**：理论

---

## 要了解什么

### Clock 框架（CCF - Common Clock Framework）

imx6ull 有数十个时钟源，CCF 统一管理。

**prepare/enable 两步设计的原因**：
- `clk_prepare()`：可能睡眠（某些时钟需要等待 PLL 锁定），不能在中断上下文调用
- `clk_enable()`：不睡眠，原子操作，可在中断上下文调用（但通常不推荐）
- 实践中通常直接用 `clk_prepare_enable()`（两步合一）

```c
struct clk *clk;

/* probe 中获取时钟 */
clk = devm_clk_get(&pdev->dev, "apb_pclk");  /* DTS 中的 clock-names */
if (IS_ERR(clk)) return PTR_ERR(clk);

/* 使能时钟（一般在 probe 末尾）*/
ret = clk_prepare_enable(clk);
if (ret) return ret;

/* 查询时钟频率 */
unsigned long rate = clk_get_rate(clk);
dev_info(&pdev->dev, "clock rate: %lu Hz\n", rate);

/* remove 中关闭 */
clk_disable_unprepare(clk);
/* 注意：如果用 devm_clk_get，时钟被 devm 管理但不会自动 disable，
   仍需手动 disable（或用 devm_clk_get_enabled）*/
```

DTS 对应写法：
```dts
my_peripheral: periph@12340000 {
    compatible = "myvendor,my-periph";
    reg = <0x12340000 0x1000>;
    clocks = <&ccm IMX6UL_CLK_UART1_IPG>, <&ccm IMX6UL_CLK_UART1_SERIAL>;
    clock-names = "ipg", "per";  /* 对应 devm_clk_get 的第二个参数 */
};
```

### Pinctrl 框架

SOC 的引脚可以复用（同一个 PAD 可以是 GPIO、UART TX、SPI CLK 等），Pinctrl 管理这些复用配置。

```dts
/* imx6ull 风格的引脚配置 */
&iomuxc {
    pinctrl_uart1: uart1grp {
        fsl,pins = <
            MX6UL_PAD_UART1_TX_DATA__UART1_DCE_TX  0x1b0b1
            MX6UL_PAD_UART1_RX_DATA__UART1_DCE_RX  0x1b0b1
        >;
    };
};

&uart1 {
    pinctrl-names = "default";  /* 状态名 */
    pinctrl-0 = <&pinctrl_uart1>;  /* default 状态对应的引脚配置 */
    status = "okay";
};
```

驱动中**不需要主动调用 pinctrl API**——内核在 probe 时自动应用 `default` 状态。只有需要切换引脚状态（如 sleep 模式换引脚配置）时才需要：

```c
struct pinctrl *pctl;
struct pinctrl_state *state_default, *state_sleep;

pctl = devm_pinctrl_get(&pdev->dev);
state_default = pinctrl_lookup_state(pctl, "default");
state_sleep   = pinctrl_lookup_state(pctl, "sleep");

pinctrl_select_state(pctl, state_sleep);  /* 切换到 sleep 状态 */
```

---

## 练习

- [ ] 在 imx6ull DTS 中找 `uart1` 节点，追踪 `pinctrl-0` 引用的 pin group，理解每行 `fsl,pins` 的格式（PAD 宏 + 配置值）
- [ ] 在 QEMU 的 shell 里查看 `/sys/kernel/debug/clk/clk_summary`（需要 `CONFIG_DEBUG_FS=y` 和 `CONFIG_COMMON_CLK=y`），理解时钟树结构
- [ ] 阅读 `drivers/clk/imx/clk-imx6ul.c`，找到 UART1 时钟是如何定义在时钟树中的

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| 内核文档 | `Documentation/driver-api/clk.rst` | CCF 完整文档 |
| 内核文档 | `Documentation/driver-api/pin-control.rst` | Pinctrl 框架文档 |
| LWN.net | https://lwn.net/Articles/472998/ | "The common clock framework" |
| *Linux Device Driver Development* Madieu | Ch.12 "Leveraging the Pinctrl Subsystem" | 实战 |

---

# Day 21 · 驱动上 imx6ull 真机

**预计时长**：2 小时  
**类型**：真机实操

---

## 做什么

把 Week 2 写的字符设备驱动交叉编译，通过 NFS 网络文件系统加载到 imx6ull 真机。同时修改 DTS 添加一个自定义属性，体验完整的「改 DTS → 重编 dtb → U-Boot tftp 下载 → 验证」流程。

---

## 要了解什么

### NFS 挂载根文件系统

NFS 是嵌入式开发最高效的方式：修改文件后无需烧录，直接在主机修改，板子立刻看到新文件。

```bash
# WSL2 主机安装 NFS 服务
sudo apt install nfs-kernel-server

# 创建 NFS 导出目录
sudo mkdir -p /nfs/imx6ull
sudo chown nobody:nogroup /nfs/imx6ull

# 编辑 /etc/exports
echo "/nfs/imx6ull *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -ra
sudo systemctl start nfs-kernel-server

# imx6ull U-Boot 启动参数（通过串口修改 bootargs）
setenv bootargs "console=ttymxc0,115200 root=/dev/nfs nfsroot=<主机IP>:/nfs/imx6ull,v3 ip=dhcp"
```

### 通过 tftp 下载内核和 DTB

```bash
# WSL2 安装 tftp 服务
sudo apt install tftpd-hpa
sudo mkdir -p /srv/tftp
sudo chown tftp:tftp /srv/tftp

# 把内核和 dtb 放入 tftp 目录
cp arch/arm/boot/zImage /srv/tftp/
cp arch/arm/boot/dts/nxp/imx6ull-14x14-evk.dtb /srv/tftp/

# imx6ull U-Boot 命令
setenv serverip <主机IP>
tftp ${loadaddr} zImage
tftp ${fdt_addr} imx6ull-14x14-evk.dtb
bootz ${loadaddr} - ${fdt_addr}
```

---

## 练习

- [ ] 搭建 WSL2 NFS + tftp 环境，把 imx6ull 的根文件系统挂载到 `/nfs/imx6ull`
- [ ] 交叉编译 chardev 驱动，`insmod` 到 imx6ull，`dmesg` 验证
- [ ] 修改 imx6ull DTS，给 uart1 节点添加一个自定义属性 `my-baudrate = <115200>`，重编 DTB，在驱动中用 `of_property_read_u32` 读取并打印
- [ ] 在 imx6ull 上运行 `cat /proc/interrupts`，对比 QEMU 和真机的差异

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| *Embedded Linux Primer* Hallinan | Ch.7 "Bootloaders" + Ch.12 "Embedded Development Environment" | NFS + tftp 开发环境搭建 |
| *Mastering Embedded Linux Programming* Simmonds | Ch.8 "Introducing Buildroot" | 根文件系统构建 |
| i.MX6ULL 参考手册 | Chapter 1 + Chapter on GPIO | NXP 官方文档，imx6ull 外设寄存器 |
