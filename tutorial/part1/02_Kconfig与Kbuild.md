# Day 3–4 · Kconfig 与 Kbuild 深度

**预计时长**：1.5 小时 / 天，共 3 小时  
**类型**：理论 + 动手

---

## 做什么

彻底搞清楚 Kconfig 和 Kbuild 的工作机制。你以后做 BSP 和内核移植，会频繁修改这两套系统：添加自定义驱动、控制编译条件、裁剪不必要的功能。今天的目标是：能写一个新的 Kconfig 条目 + 对应 Makefile，让它出现在 `menuconfig` 中，并能被编译进内核或编成独立模块。

---

## 要了解什么

### 1. Kconfig 语法核心

Kconfig 文件定义的是**配置项**（Configuration Items），最终生成 `.config` 文件和 `include/generated/autoconf.h`。

**基本类型：**

```kconfig
# bool：只能 y（编入内核）或 n（不编译）
config MY_BOOL_OPTION
    bool "My bool option"
    default n

# tristate：y（编入）/ m（编成模块）/ n（不编译）
config MY_DRIVER
    tristate "My awesome driver"
    default m

# string / int / hex：字符串、整数、十六进制值
config MY_FIRMWARE_PATH
    string "Firmware file path"
    default "/lib/firmware/my.bin"
```

**依赖关系（极重要）：**

```kconfig
# depends on：A 必须先被选中，才能看到 B
config MY_DRIVER
    tristate "My driver"
    depends on I2C && OF

# select：选中 A 时，自动强制选中 B（不推荐滥用！）
config MY_DRIVER
    tristate "My driver"
    select REGMAP_I2C   # 自动拉入 regmap 支持

# imply：建议性选中，用户可以取消
config MY_DRIVER
    tristate "My driver"
    imply HWMON
```

**`select` vs `depends on` 的关键区别**：

- `depends on`：如果依赖项未选中，当前项直接不可见。用户必须先手动选依赖。
- `select`：强制选中依赖项，可能违反依赖项自身的 `depends on`，导致编译错误。**原则：只对"叶子"库（无自身依赖的 helper 库）用 `select`**，对有复杂依赖的子系统用 `depends on`。

### 2. Kbuild：Makefile 体系

内核不用普通的递归 Makefile，用的是 Kbuild 体系。核心语法极简：

```makefile
# 编译进内核（obj-y）
obj-y += my_driver.o

# 根据 Kconfig 决定（obj-$(CONFIG_XXX)）
obj-$(CONFIG_MY_DRIVER) += my_driver.o

# 多文件组合成一个模块
obj-$(CONFIG_MY_DRIVER) += my_driver.o
my_driver-objs := core.o platform.o i2c.o

# 进入子目录
obj-$(CONFIG_MY_SUBSYSTEM) += my_subsystem/
```

`.config` 被展开后，`CONFIG_MY_DRIVER=y` → `obj-y`，`CONFIG_MY_DRIVER=m` → `obj-m`，`CONFIG_MY_DRIVER=n` → 什么都不做。

### 3. 一次 `make` 的完整流程

```
make ARCH=arm menuconfig
         │
         ▼
    读取所有 Kconfig 文件
         │
         ▼
    用户交互修改选项
         │
         ▼
    生成 .config
         │
         ▼
make ARCH=arm zImage
         │
         ▼
    scripts/Makefile.build 递归处理每个目录
         │
         ▼
    根据 .config 决定 obj-y / obj-m / 跳过
         │
         ▼
    编译 → 链接 → vmlinux → zImage（压缩）
```

### 4. `autoconf.h` 的作用

每个 `CONFIG_XXX=y` 都会在 `include/generated/autoconf.h` 生成：

```c
#define CONFIG_MY_DRIVER 1       // y
#define CONFIG_MY_DRIVER_MODULE  // m（额外加 _MODULE）
// n 则什么都不生成
```

所以驱动代码里可以用 `#ifdef CONFIG_MY_FEATURE` 做条件编译，而这个宏正是从 menuconfig 来的。

### 5. 项目脚本速查

PenguinLab 提供了统一的构建脚本 `scripts/linux-action-scripts.sh`：

| 操作 | 命令 |
|------|------|
| 配置 | `LINUX_DEFCONFIG=imx_v6_v7_defconfig ./scripts/linux-action-scripts.sh config` |
| 编译 | `./scripts/linux-action-scripts.sh build` |
| 配置并编译 | `LINUX_DEFCONFIG=imx_v6_v7_defconfig ./scripts/linux-action-scripts.sh config_and_build` |
| 清理 | `./scripts/linux-action-scripts.sh clean` |

脚本默认 ARM32（`arm` + `arm-linux-gnueabihf-`），构建输出到 `out/build_latest_arm/`。

切换 ARM64：
```bash
ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- \
  LINUX_DEFCONFIG=defconfig \
  ./scripts/linux-action-scripts.sh config_and_build
```

---

## 练习

### 练习 1：创建你的第一个 Kconfig + Makefile

在内核源码树外创建一个独立目录模拟，理解结构：

```bash
mkdir -p ~/labs/kconfig-demo/mydriver
cd ~/labs/kconfig-demo
```

创建 `mydriver/Kconfig`：

```kconfig
# mydriver/Kconfig
config MYDRIVER_HELLO
    tristate "Hello World driver (练习用)"
    depends on OF
    help
      这是一个练习用的驱动。
      选 M 编成模块，选 Y 编入内核。

config MYDRIVER_DEBUG
    bool "Enable debug output for Hello driver"
    depends on MYDRIVER_HELLO
    default n
    help
      开启后会在 dmesg 中打印调试信息。
```

创建 `mydriver/Makefile`：

```makefile
# mydriver/Makefile
obj-$(CONFIG_MYDRIVER_HELLO) += hello.o
hello-objs := hello_core.o hello_platform.o
```

- [ ] 将 `mydriver/` 目录复制到 `third_party/linux/drivers/misc/mydriver/`
- [ ] 在 `third_party/linux/drivers/misc/Kconfig` 末尾加一行 `source "drivers/misc/mydriver/Kconfig"`
- [ ] 在 `third_party/linux/drivers/misc/Makefile` 末尾加 `obj-$(CONFIG_MYDRIVER_HELLO) += mydriver/`
- [ ] 在 `third_party/linux/` 目录下运行 `make ARCH=arm menuconfig`，进入 `Device Drivers → Misc devices`，找到你的选项
- [ ] 把它设为 `M`，退出保存，检查 `.config`（或 `out/build_latest_arm/.config`）中是否出现 `CONFIG_MYDRIVER_HELLO=m`

### 练习 2：理解 `select` 的危险

在内核源码中搜索一个使用 `select` 出错的案例：

```bash
# 搜索 Kconfig 中同时用了 select 和 depends on 的项
cd third_party/linux
grep -r "select REGMAP" arch/arm/Kconfig drivers/*/Kconfig | head -20

# 看看 REGMAP 自身有什么依赖
grep -A5 "^config REGMAP$" drivers/base/regmap/Kconfig
```

- [ ] 找到至少一个用 `select` 拉入的配置项，追踪它自身的 `depends on`，验证是否满足

### 练习 3：分析 imx6ull 的编译条件

```bash
cd third_party/linux

# 找 imx6ull 相关的所有 Kconfig 条件
grep -r "imx6ul\|imx6ull\|MX6UL" arch/arm/Kconfig arch/arm/mach-imx/ 2>/dev/null | head -30

# 找哪些驱动在 imx6ull 上会被编入
# （如果用项目脚本编译，.config 在构建输出目录）
grep "CONFIG_SOC_IMX6UL" out/build_latest_arm/.config 2>/dev/null || grep "CONFIG_SOC_IMX6UL" .config
```

- [ ] 找到控制 imx6ull GPIO 驱动编译的 `CONFIG_` 项
- [ ] 找到 imx6ull 的 clock 驱动在哪个目录

### 练习 4：`make` 目标速查练习

```bash
cd third_party/linux

# 查看所有可用 make 目标
make help | grep -E "defconfig|config|clean"

# 只编译某个子目录（增量编译）
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- M=drivers/leds

# 查看某个 .o 的编译命令（V=1 显示完整命令）
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- V=1 drivers/leds/leds-gpio.o 2>&1 | tail -5
```

- [ ] 用 `V=1` 看一个驱动的完整编译命令，找出 `-I` 包含了哪些头文件路径

---

## 延伸阅读

| 资料 | 具体位置 | 说明 |
|------|----------|------|
| 《Linux 内核设计与实现》Robert Love | 第 2 章 | 内核源码编译流程 |
| 内核官方文档 | `Documentation/kbuild/kconfig-language.rst` | Kconfig 语法完整参考，必读 |
| 内核官方文档 | `Documentation/kbuild/makefiles.rst` | Kbuild Makefile 完整参考 |
| 《深入 Linux 内核架构》Mauerer | 附录 A | 内核编译系统原理 |
| LWN.net | https://lwn.net/Articles/25432/ | Kconfig 设计哲学（2003，仍有参考价值） |
