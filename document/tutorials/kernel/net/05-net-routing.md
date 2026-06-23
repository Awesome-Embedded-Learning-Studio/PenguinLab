---
title: IPv4 路由子系统：包该往哪走
slug: net-routing
difficulty: intermediate
tags: [网络栈, 路由, FIB, 策略路由]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
related:
  - /tutorials/kernel/net/04-net-ipv4
sources:
  - notes: document/notes/linux_kernel_networking/ch05_1.md
  - notes: document/notes/linux_kernel_networking/ch05_2.md
  - notes: document/notes/linux_kernel_networking/ch05_3.md
  - notes: document/notes/linux_kernel_networking/ch05_4.md
  - notes: document/notes/linux_kernel_networking/ch05_5.md
  - notes: document/notes/linux_kernel_networking/ch05_6.md
---

# IPv4 路由子系统：包该往哪走

> 🔨 **整理中** · 这篇是从《Linux 内核网络》第 5 章读书笔记整理出来的骨架，转发/FIB/`fib_lookup`/`fib_info`/`fib_nh`/policy routing 这条主线已经讲透了；但动手部分（QEMU 上 `ip route`、`ip rule`、strace 发送路径）还没亲手跑过核对。等我们在 QEMU 双网卡拓扑里验过、把真实输出贴进来，就升级成 ✅ 已锤炼。下面凡是命令输出样例，都标注「待亲测核对」。
>
> 本篇函数签名/字段/数值已对照 Linux 6.19 源码校订（读书笔记基于较早内核版本，部分接口已演进）；具体行号仍待 QEMU 亲测核对。

## 路由到底要解决什么

一个 IP 包到达 IP 层，内核要在三种命运里挑一个：

1. **本机处理**——目标地址就是我，把包往上传给传输层（socket 那头有人在等）。
2. **转发**——目标不是我，我是过路的路由器，要选一个出口网卡把它扔给下一站。
3. **丢弃**——既不是我的、也无处可转，直接进垃圾桶。

判定走哪条，靠的就是**路由查找**。如果判定是转发，内核还得回答两个问题：从哪块网卡出？下一跳（next hop）是谁？这就是路由子系统（routing subsystem）的活儿——它手里攥着一张决定数据包生死的「藏宝图」，叫 **FIB（Forwarding Information Base，转发信息库）**。

先刻一个直觉：路由器眼里**转发流量根本不会爬到 Layer 4**。没人会在 socket 那头等一个过路包，把它送到传输层是纯浪费 CPU。过路流量在 Layer 3（网络层）就被截停，查完路由直接从另一块网卡甩出去——高效、冷酷，不带一丝情感。

## FIB：路由表在内核里长什么样

FIB 不是一个扁平数组，而是几层结构叠出来的：

- **`fib_table`**：一整本路由册子。没有策略路由时内核只有两张表——**Local 表**（ID 255，内核私有领地，只放本机 IP 的路由，管理员塞不进去）和 **Main 表**（ID 254，你 `ip route add` 配的路由大多在这）。开启了策略路由能扩到最多 255 张表。这两个 ID 不是凭空定的，`include/uapi/linux/rtnetlink.h` 里写死了 `RT_TABLE_LOCAL=255`、`RT_TABLE_MAIN=254`、`RT_TABLE_DEFAULT=253`。
- **`fib_info`**：册子里某一条具体路由的「身份证」，记录这条路怎么走——从哪个设备出、优先级、协议来源、作用域、性能度量。它不存「目的地」，目的地是 `fib_alias` 的活。
- **`fib_alias`**：一个轻量级挂钩。当好几条路由**除了 TOS/优先级/类型等少量可挂 alias 的属性不同、其余路径参数（网关、出口、metrics）完全相同时**，它们共享一份胖大的 `fib_info`，各自挂一个小 `fib_alias` 记自己的差异化属性。这是典型的「提取公因式」省内存设计。

为什么这么分？因为 BGP 场景下一张表能有几万条路由，很多只是优先级不同，要是每条都复制一份完整的 nexthop+metrics，内存早炸了。共享一份 `fib_info`、用引用计数 `fib_treeref` 守住它的命，是工程上的优雅解。而这个「共享」的判据不是我们拍脑袋想的——`fib_find_info()`（`net/ipv4/fib_semantics.c`）逐项比对 protocol、scope、prefsrc、priority、**type**、tb_id、metrics、flags 和整套 nexthop，全相等才复用。也就是说，连 `RTN_UNICAST` 和 `RTN_PROHIBIT` 这种同网关但 type 不同的路由，只要路径参数一致也能共享 `fib_info`。

## 路由查找 fib_lookup：最长前缀匹配

查表的大脑是 `fib_lookup()`：

```c
static inline int fib_lookup(struct net *net, const struct flowi4 *flp,
                             struct fib_result *res, unsigned int flags);
```

它吃四个参数：**线索** `flowi4`（一张查表申请单，关键字段是目标地址、源地址、TOS）、**结果容器** `fib_result`，以及一个 **flags**（常见的如 `FIB_LOOKUP_NOREF`，表示查找时不给 `fib_info` 的引用计数加一）。找到就返回 0，把结果填进 `res`。读书笔记里那个 3 参的 `fib_lookup` 是早年形态——6.19 内核里末尾那个 `flags` 已经是标配，`include/net/ip_fib.h` 里单表 inline 版和多表版（走 `__fib_lookup`）签名都是四参。

查找过程走**最长前缀匹配（LPM）**，但「先翻 Local、没命中再翻 Main」这个说法得拆开讲，单表和多表完全是两套机制：

1. **不开 `CONFIG_IP_MULTIPLE_TABLES`**：inline 版 `fib_lookup()`（`include/net/ip_fib.h`）**只查 Main 表**（`fib_get_table(net, RT_TABLE_MAIN)`），并不显式先翻 Local。本机地址的命中是靠 `fib_add_ifaddr()`（`net/ipv4/fib_frontend.c`）在配置 IP 时就把 local 项提前注入到 Main 表里——所以我们「感觉到」的 Local 优先，其实是注入时就已经摆好了。
2. **开了 `CONFIG_IP_MULTIPLE_TABLES`**：真正的顺序由 `fib_rules` 按优先级决定。`fib_default_rules_init()`（`net/ipv4/fib_rules.c`）登记三条默认规则——Local 优先级 **0**、Main **0x7FFE**、Default **0x7FFF**，查找时按优先级从小到大走，自然是先查 Local 表、再查 Main 表。

底层那棵高效的树叫 **LC-trie**（在 `net/ipv4/fib_trie.c`），查找复杂度是 O(key length)，不随路由表规模线性增长——这是 3.6 之后能砍掉路由缓存的底气。

`fib_result` 里最关键的字段是 `type`，它直接定包的生死：

| type | 含义 |
|:---|:---|
| `RTN_LOCAL` | 发往本机，往上传 |
| `RTN_UNICAST` | 普通单播，转发或直连 |
| `RTN_BROADCAST` / `RTN_MULTICAST` | 广播 / 组播 |
| `RTN_UNREACHABLE` | 不可达，回 ICMP 目标不可达 |
| `RTN_PROHIBIT` | 禁止，回 ICMP "Packet Filtered" |

`type` 不是靠一堆 `if` 判出来的——内核查一张 `fib_props[]` 配置表（在 `net/ipv4/fib_semantics.c`），把每种 type 映射到对应的 error 码和 scope。比如 `fib_props[RTN_PROHIBIT].error` 是 `-EACCES`、`fib_props[RTN_UNREACHABLE].error` 是 `-EHOSTUNREACH`。这种「数据驱动」设计内核里到处都是：不写死逻辑，去查配置数组。

查完 `fib_result`，内核把它加工成一个 `dst_entry`（嵌在更大的 `rtable` 里）挂在 SKB 身上。`dst_entry` 最值钱的是两个函数指针 `input` 和 `output`——**在代码里，路由选择本质上就是「选函数」**：目标是本机就把 `input` 挂成 `ip_local_deliver()`；要转发就挂 `ip_forward()`；本机发出就 `output` 挂 `ip_output()`。包拿着这张「路条」，直接调函数，剩下的路自动走完。

## 路由缓存那点旧历史

3.6 之前，路由查找分两步：先翻**路由缓存（route cache）**，没命中再翻 FIB。缓存是一张哈希表，能极大加速热路径查找。

3.6 起这块缓存被**整个移除**，每次直接查 FIB TRIE。两个原因：

- **性能**：互联网核心路由表条目极多，维护庞大哈希缓存及其一致性（失效、更新）的开销越来越大；而 LC-trie 本身够快，缓存层变得多余。
- **安全**：路由缓存容易吃 **「Shadow Master」类 DoS**——攻击者狂发随机目标 IP，逼内核不断 cache miss + 填缓存，耗光内存和 CPU。直接查 FIB TRIE 消除了这个攻击面。

注意，现在内核里**还有缓存，但不是那个被移除的旧 route cache**，而是基于 nexthop 的细粒度缓存（见下节），不能混为一谈。

## nexthop fib_nh：最后一公里

`fib_info` 是路由的「母亲」，`fib_nh`（next hop）是她牵着的「孩子」。决定真正发包时，内核那一纳秒只关心两件事：**从哪个设备出、发给谁**。这就是 `fib_nh` 的全部意义。

但要小心：6.19 的 `struct fib_nh`（`include/net/ip_fib.h`）内核字段其实长这样：

```c
struct fib_nh {
    struct fib_nh_common nh_common;   /* 真正的家当都在这 */
    struct hlist_node   nh_hash;
    struct fib_info     *nh_parent;
    /* ... 其余是源地址相关 */
};
```

真正承载 dev/oif/gw 这些「出口信息」的是 `fib_nh_common`（IPv4/IPv6 共用的那一层）。我们平时写代码念叨的 `fib_nh_dev`、`fib_nh_oif`、`fib_nh_gw4` 其实都是**宏**，转发到 `nh_common.nhc_*`：

- **`nhc_dev`**（宏 `fib_nh_dev`）：出口设备的 `net_device *`，内核抓着它才能调驱动把包扔出去。
- **`nhc_oif`**（宏 `fib_nh_oif`）：出口接口的索引（Interface Index），手里只有 ID 时用它反查设备。
- **`nhc_gw.ipv4`**（宏 `fib_nh_gw4`）：下一跳网关 IP。直连路由这里填 0；要经过路由器跳一下，这里就是路由器的 IP。
- **`nh_parent`**：回指 `fib_info` 的指针，双向链接方便反查（这个是真字段，不是宏）。

旧笔记里那种 `nh_dev`/`nh_oif`/`nh_gw` 直接挂在 `fib_nh` 上的写法，是重构成 `fib_nh_common` 之前的形态，现在源码里已经找不到了——读老资料时心里要有这个版本差。

普通路由一个 `fib_info` 只牵一个 `fib_nh`；开了多路径路由（`CONFIG_IP_ROUTE_MULTIPATH`），`fib_info` 末尾是个柔性数组 `fib_nh[]`，内核按权重/哈希把包分到不同出口上。

还有两个现代缓存，它们挂在 `fib_nh_common` 上（注意是 `nhc_` 前缀，不是旧笔记的 `nh_`）：收包路径结果缓在 **`nhc_rth_input`**，发包路径缓在 **`nhc_pcpu_rth_output`**——注意那个 `pcpu`，是**每 CPU 一份**缓存，多核并发发包不抢锁，这是 Linux 高吞吐转发的性能魔法之一。

设备掉线（`ip link set eth0 down`）时，通过**通知链（notifier chain）**机制，FIB 的 `fib_netdev_event()` 回调收到 `NETDEV_DOWN`，最终调到 `fib_disable_ip()`（`net/ipv4/fib_frontend.c`）。这里**不是**线性的三连操作，而是一个条件分支外加一步必经的清理：

```c
static void fib_disable_ip(struct net_device *dev, unsigned long event, bool force)
{
    if (fib_sync_down_dev(dev, event, force))   /* 给用这台设备的 fib_nh 打 RTNH_F_DEAD */
        fib_flush(dev_net(dev));                /* 有路由因此死亡 → 彻底清 FIB */
    else
        rt_cache_flush(dev_net(dev));           /* 否则只刷缓存 */
    arp_ifdown(dev);                            /* 无论如何都清 ARP 邻居 */
}
```

也就是说，`fib_sync_down_dev()` 先把相关 `fib_nh` 打上 `RTNH_F_DEAD`，然后**二选一**——它的返回值告诉你「有没有路由因此彻底死亡」，有就走重口味的 `fib_flush`，没有就只 `rt_cache_flush` 刷缓存。最后无论哪条分支，`arp_ifdown(dev)` 都得跑一遍，把这台设备的 ARP 邻居也清掉——人走茶凉，路由表和邻居表一气呵成。

## policy routing：不止一张默认表

前面说默认只有 Local + Main 两张表。开了 `CONFIG_IP_MULTIPLE_TABLES`，世界变了——支持最多 255 张表，启动默认初始化 Local(255)、Main(254)、Default(253) 三张（`fib_default_rules_init`）。历史包袱：2.6.25 之前这两张表还是全局变量，后来重构成统一用 `fib_get_table(net, id)` 取表指针，给多表铺了路。

但光有表还不够——**该在什么时候查哪张表？** 这套规则才是策略路由的灵魂，由 `ip rule` 管理（`fib_rules`，下一章细聊）。典型场景：双网卡机器，目标地址一样，但备份流量想走贵的 `eth1`、普通浏览走 `eth0`——只看目的地的传统路由表无能为力，得靠规则按源地址/协议来分流。

顺带一提：`ip route add` 背后其实是 **Netlink** 的 `RTM_NEWROUTE` 消息，内核由 `inet_rtm_newroute()`（`net/ipv4/fib_frontend.c`）接手；老派的 `route` 命令走的是另一条 **IOCTRL**（`SIOCADDRT`）路径，由 `ip_rt_ioctl()` 处理。而路由守护进程（BGP/OSPF，如 Bird/Quagga）也是狂发 `RTM_NEWROUTE`——对内核来说，管理员手敲的和协议算出来的，最终都是一样的 `fib_info` 挂在同一张表里。

## 动手待亲测

> ⚠️ **以下输出均为整理时的参考样例，待 QEMU 亲测核对后替换为真实输出。**

验证方案（QEMU 双网卡拓扑，ARM64 优先）：

1. **看路由表**：`ip route show`（默认只看 Main 表）；要看 Local 表得 `ip route show table local`。注意 iproute2 的输出格式是 `default via ... dev eth0 proto ... metric ...` 这种键值字段，**没有** `U/G/H` 那套缩写字母——那套 `U` 激活、`G` 走网关、`H` 主机路由的 Flags 缩写是老派 `route -n` / `netstat -r` 的列格式。亲测时想看那套字母，得敲 `route -n`；用 iproute2 就照 `proto`/`scope`/`metric` 字段描述。
2. **看策略规则**：`ip rule show`——列出现在有几条规则、分别查哪张表（默认会看到 priority 0/32766/32767 三条，对应 Local/Main/Default）。
3. **抓一次发送路径**：`strace -e trace=network ping <对端>`，看 socket 发送那一瞬有没有触发路由查找（发送路径里 `dst.output` 回调）。
4. **构造一个 prohibit**：`ip route add prohibit <target>`，再 `ping` 它，观察回的 ICMP "Packet Filtered"（对应 `fib_props[RTN_PROHIBIT]` 的 `-EACCES`）。

亲测阶段还会在 `example/mini/` 落一个配套小模块，把这条主线串成可跑的代码——那篇是亲测完的事，本骨架不展开。

## 小结

IPv4 路由子系统是一条清晰的主线：包到 IP 层 → `fib_lookup()` 拿 `flowi4` 在 FIB 里做最长前缀匹配 → 填出 `fib_result`（`type` 定生死）→ 加工成 `dst_entry`/`rtable`，挂上 `input`/`output` 回调 → 回调指向 `ip_local_deliver`/`ip_forward`/`ip_output`，路由选择本质是「选函数」。

至于「在 FIB 里怎么查」要分清两种模式：单表只查 Main（本机地址靠 `fib_add_ifaddr` 提前注入）；多表由 `fib_rules` 按优先级先查 Local(0) 再查 Main(0x7FFE)。

往下钻：`fib_info` 是路由身份证（含 `fib_metrics` 性能参数 + 引用计数生命周期），`fib_nh` 是最后一公里——出口设备/网关信息实际都在 `fib_nh_common` 里（`fib_nh_dev`/`fib_nh_oif`/`fib_nh_gw4` 都是转发宏），收包缓存在 `nhc_rth_input`、每 CPU 发包缓存在 `nhc_pcpu_rth_output`。3.6 移除的旧 route cache 别和现在基于 nexthop 的缓存混为一谈；`fib_props[]` 数据驱动的 type→行为映射、`fib_nh_common` 上的 nexthop exception 便签本（记 ICMP Redirect 改的网关、PMTU 改的 MTU）都是值得回味的内核设计美学。

记住一件事：**路由决策不是一次简单的匹配，而是「查找 → 缓存 → 动态修正（Redirect/FNHE）」的完整闭环。**

## 延伸阅读

- 源码（Linux 6.19，行号待亲测核对）：`net/ipv4/fib_frontend.c`（FIB 前台，处理 Netlink 的 `ip route add`，含 `inet_rtm_newroute`、`ip_rt_ioctl`、`fib_disable_ip`、`fib_add_ifaddr`）；`net/ipv4/fib_trie.c`（LC-trie 核心查找）；`net/ipv4/fib_semantics.c`（`fib_info` 管理 + `fib_props[]` 映射表 + `fib_find_info` 去重）；`net/ipv4/route.c`（`dst_entry`/`rtable`、per-CPU 缓存）；`net/ipv4/fib_rules.c`（策略路由 + `fib_default_rules_init`，需 `CONFIG_IP_MULTIPLE_TABLES`）。
- 头文件：`include/net/ip_fib.h`（`fib_lookup`/`fib_info`/`fib_nh`/`fib_nh_common`）、`include/net/route.h`、`include/net/flow.h`（`flowi4`）、`include/net/dst.h`（`dst_entry`）、`include/uapi/linux/rtnetlink.h`（`RT_TABLE_*` 表 ID 常量）。
- docs.kernel.org 索引：[Networking](https://docs.kernel.org/networking/index.html)（含 IPv4 路由相关文档入口）。
- 进一步（持续铺开）：邻居子系统（ARP/ND，下一章）、ICMPv4 Redirect、PMTU Discovery 与 FIB nexthop exception 的实战。