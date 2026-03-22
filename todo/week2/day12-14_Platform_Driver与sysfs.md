# Day 12–13 · Platform Driver 模型

**预计时长**：2 小时 / 天，共 4 小时  
**类型**：理论 + 代码阅读

---

## 做什么

理解嵌入式 Linux 驱动的核心组织模型：platform_device + platform_driver 的匹配机制。重点是 `probe` 函数的调用时机、资源获取方式、以及 `devm_` 系列的 managed resource 思想。

---

## 要了解什么

### 1. 为什么需要 Platform Driver？

字符设备驱动有个问题：驱动和硬件是硬编码绑定的（写死寄存器地址、中断号）。如果换一块板子，就得改驱动代码。

Platform Driver 把这两件事分开：
- **平台设备（platform_device）**：描述硬件资源（寄存器基地址、中断号、时钟等），由 Device Tree 或板级代码提供
- **平台驱动（platform_driver）**：只写操控硬件的逻辑，不包含具体地址

内核在两者之间做**匹配（match）**，匹配成功后调用驱动的 `probe` 函数。

### 2. 匹配机制

```c
static const struct of_device_id my_of_match[] = {
    { .compatible = "myvendor,my-peripheral" },  // 匹配 DTS 中的 compatible
    { .compatible = "myvendor,my-peripheral-v2", .data = &v2_config },
    { /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, my_of_match);  // 让 modprobe 知道这个模块匹配哪些设备

static struct platform_driver my_driver = {
    .probe  = my_probe,
    .remove = my_remove,
    .driver = {
        .name           = "my-peripheral",
        .of_match_table = my_of_match,
    },
};
```

匹配顺序（优先级递减）：
1. DTS 的 `compatible` 属性 vs `of_match_table`
2. `platform_device.name` vs `platform_driver.driver.name`

### 3. `probe` 函数的职责

`probe` 是驱动最核心的函数，在设备和驱动成功匹配后被调用。它需要完成：

```c
static int my_probe(struct platform_device *pdev)
{
    struct my_priv *priv;
    struct resource *res;
    int irq, ret;

    /* 1. 分配私有数据（用 devm_，让内核管理生命周期） */
    priv = devm_kzalloc(&pdev->dev, sizeof(*priv), GFP_KERNEL);
    if (!priv) return -ENOMEM;

    /* 2. 获取并映射寄存器（iomem） */
    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);  // 第 0 个 MEM 资源
    priv->base = devm_ioremap_resource(&pdev->dev, res);
    if (IS_ERR(priv->base)) return PTR_ERR(priv->base);

    /* 3. 获取中断号 */
    irq = platform_get_irq(pdev, 0);
    if (irq < 0) return irq;

    /* 4. 请求中断 */
    ret = devm_request_irq(&pdev->dev, irq, my_irq_handler,
                           IRQF_SHARED, dev_name(&pdev->dev), priv);
    if (ret) return ret;

    /* 5. 获取时钟、复位等其他资源 */
    priv->clk = devm_clk_get(&pdev->dev, "apb_pclk");
    if (IS_ERR(priv->clk)) return PTR_ERR(priv->clk);

    /* 6. 使能时钟，初始化硬件 */
    ret = clk_prepare_enable(priv->clk);
    if (ret) return ret;

    /* 7. 保存私有数据到设备 */
    platform_set_drvdata(pdev, priv);

    dev_info(&pdev->dev, "probe success\n");
    return 0;
}
```

### 4. `devm_` 系列：Managed Resources 思想

`devm_`（device-managed）函数分配的资源由内核跟踪，在 `remove` 调用或 `probe` 失败时**自动释放**，不需要手动 `kfree`/`iounmap`/`free_irq`。

```c
// 传统方式（需要手动释放，容易内存泄漏）
priv = kzalloc(sizeof(*priv), GFP_KERNEL);
priv->base = ioremap(res->start, resource_size(res));
request_irq(irq, handler, 0, name, priv);
// remove 里必须手动：kfree + iounmap + free_irq

// devm 方式（自动释放，强烈推荐）
priv = devm_kzalloc(&pdev->dev, sizeof(*priv), GFP_KERNEL);
priv->base = devm_ioremap_resource(&pdev->dev, res);
devm_request_irq(&pdev->dev, irq, handler, 0, name, priv);
// remove 里什么都不用写（或者只需要做业务层面的清理）
```

**规则：在 `probe` 里全部用 `devm_`，`remove` 里用于回滚 `probe` 中的业务逻辑，不用操心资源释放。**

---

## 练习

### 练习 1：阅读真实驱动 `leds-gpio.c`

```bash
less ~/kernel/linux-stable/drivers/leds/leds-gpio.c
```

带着以下问题阅读（约 250 行，半小时可读完）：

- [ ] 找到 `of_match_table` 中的 `compatible` 字符串，它对应 DTS 里的哪个属性？
- [ ] 找到 `probe` 函数，它用了哪些 `devm_` 函数？
- [ ] 找到 `struct gpio_leds_priv`，理解它是如何通过 `platform_get_drvdata` 在 probe 和其他函数间传递的
- [ ] 找到如何从 DTS 读取 GPIO 属性（`devm_gpiod_get` 相关）

### 练习 2：写一个最小 platform driver 框架

```bash
mkdir -p ~/labs/platform_demo
```

**platform_demo.c**：

```c
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/io.h>

MODULE_LICENSE("GPL");

struct demo_priv {
    void __iomem *base;
    int irq;
};

static int demo_probe(struct platform_device *pdev)
{
    struct demo_priv *priv;
    struct resource *res;

    dev_info(&pdev->dev, "probe called!\n");

    priv = devm_kzalloc(&pdev->dev, sizeof(*priv), GFP_KERNEL);
    if (!priv) return -ENOMEM;

    /* 尝试获取第一个 MEM 资源（QEMU 里没有真实硬件，这会返回 NULL） */
    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    if (res) {
        dev_info(&pdev->dev, "MEM resource: 0x%llx - 0x%llx\n",
                 (u64)res->start, (u64)res->end);
        priv->base = devm_ioremap_resource(&pdev->dev, res);
        if (IS_ERR(priv->base))
            return PTR_ERR(priv->base);
    } else {
        dev_info(&pdev->dev, "No MEM resource (running in QEMU?)\n");
    }

    priv->irq = platform_get_irq(pdev, 0);
    dev_info(&pdev->dev, "IRQ: %d\n", priv->irq);

    platform_set_drvdata(pdev, priv);
    return 0;
}

static int demo_remove(struct platform_device *pdev)
{
    dev_info(&pdev->dev, "remove called\n");
    // devm_ 资源自动释放，这里不需要做什么
    return 0;
}

static const struct of_device_id demo_of_match[] = {
    { .compatible = "my,platform-demo" },
    { }
};
MODULE_DEVICE_TABLE(of, demo_of_match);

static struct platform_driver demo_driver = {
    .probe  = demo_probe,
    .remove = demo_remove,
    .driver = {
        .name           = "platform-demo",
        .of_match_table = demo_of_match,
    },
};

module_platform_driver(demo_driver);
// 等价于手写 module_init/module_exit，调用 platform_driver_register/unregister
```

- [ ] 编译并在 QEMU 中加载，确认 `probe` 被调用（dmesg 里看到 "probe called!"）
- [ ] 卸载后确认 "remove called" 出现

### 练习 3：在 DTS 中创建 platform_device 节点

在 QEMU 的 DTS（或直接修改 `/sys/firmware/devicetree/base/`）中添加节点，使其与你的驱动匹配：

```dts
/* 在 QEMU virt 的 DTS 中添加（找到 qemu-virt.dts 或直接在 QEMU -append 里指定 dtb） */
my_demo_device: demo@12340000 {
    compatible = "my,platform-demo";
    reg = <0x12340000 0x1000>;
    interrupts = <0 32 4>;
};
```

- [ ] 重新编译 QEMU 使用的 DTB，观察 probe 是否被自动调用（不需要手动 insmod 额外操作）

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| *Linux Device Drivers* LDD3 | Ch.14 "The Linux Device Model" | 设备模型基础 |
| 《Linux 设备驱动开发详解》宋宝华 | 第 11 章 | platform 驱动详解 |
| *Linux Device Driver Development* Madieu | Ch.6 "Introduction to Devices, Drivers..." | 现代 platform 驱动 |
| 内核文档 | `Documentation/driver-api/driver-model/platform.rst` | 官方 platform driver 文档 |
| LWN.net | https://lwn.net/Articles/448499/ | "The platform device API" |

---

# Day 14 · sysfs 与 debugfs 接口

**预计时长**：1.5 小时  
**类型**：实验

---

## 做什么

给字符设备驱动加上 sysfs 属性（通过 `/sys/` 读写驱动状态），以及 debugfs 接口（暴露内部调试信息）。这两个接口在 BSP 开发中天天用到。

---

## 要了解什么

### sysfs：用户态 ↔ 内核驱动的标准接口

sysfs 挂载在 `/sys/`，将内核对象（devices、buses、drivers）以文件系统形式暴露。每个文件对应一个属性，读写操作映射到 `show` / `store` 回调。

```c
// 使用 DEVICE_ATTR_RW 宏（最简方式）
static ssize_t my_value_show(struct device *dev,
                              struct device_attribute *attr, char *buf)
{
    struct my_priv *priv = dev_get_drvdata(dev);
    return sysfs_emit(buf, "%d\n", priv->value);  // 用 sysfs_emit 代替 sprintf
}

static ssize_t my_value_store(struct device *dev,
                               struct device_attribute *attr,
                               const char *buf, size_t count)
{
    struct my_priv *priv = dev_get_drvdata(dev);
    int val;
    if (kstrtoint(buf, 10, &val))  // 安全的字符串转整数
        return -EINVAL;
    priv->value = val;
    return count;
}

static DEVICE_ATTR_RW(my_value);    // 生成 dev_attr_my_value，权限 0644
static DEVICE_ATTR_RO(my_status);   // 只读，权限 0444
static DEVICE_ATTR_WO(my_command);  // 只写，权限 0200

// 在 probe 中注册
device_create_file(&pdev->dev, &dev_attr_my_value);
// 或用属性组（推荐，可一次注册多个）
static struct attribute *my_attrs[] = {
    &dev_attr_my_value.attr,
    &dev_attr_my_status.attr,
    NULL,
};
static const struct attribute_group my_attr_group = { .attrs = my_attrs };
sysfs_create_group(&pdev->dev.kobj, &my_attr_group);
```

访问方式：
```bash
cat /sys/devices/platform/my-device/my_value
echo 42 > /sys/devices/platform/my-device/my_value
```

### debugfs：内部调试信息暴露

debugfs 挂载在 `/sys/kernel/debug/`，用于暴露任意调试信息，无格式限制，不需要严格遵守 sysfs 的"每个文件一个值"原则。

```c
#include <linux/debugfs.h>

struct dentry *debugfs_dir;
u32 debug_value = 0;

// 在 probe 或 init 中创建
debugfs_dir = debugfs_create_dir("my_driver", NULL);  // /sys/kernel/debug/my_driver/
debugfs_create_u32("value", 0644, debugfs_dir, &debug_value);  // 直接暴露变量
debugfs_create_file("dump", 0444, debugfs_dir, priv, &my_dump_fops);  // 自定义文件

// 在 remove 中清理
debugfs_remove_recursive(debugfs_dir);
```

---

## 练习

- [ ] 给 Day 10-11 的字符设备驱动加一个 sysfs 属性 `buf_len`（只读），暴露当前缓冲区内容长度
- [ ] 加一个 sysfs 属性 `clear`（只写），写入任意内容后清空驱动内部缓冲区
- [ ] 用 debugfs 暴露一个整数计数器 `read_count`，记录 `read` 被调用的次数
- [ ] 验证：加载驱动后，`cat /sys/...`、`echo > /sys/...`、`cat /sys/kernel/debug/my_driver/read_count` 都正确工作

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| 内核文档 | `Documentation/filesystems/sysfs.rst` | sysfs 官方规范 |
| 内核文档 | `Documentation/filesystems/debugfs.rst` | debugfs 使用指南 |
| *Linux Device Driver Development* Madieu | Ch.14 "Linux Kernel Debugging" | debugfs 实战 |
| LWN.net | https://lwn.net/Articles/31185/ | "The sysfs filesystem" |
