---
title: IPv6：不只是更长的地址
slug: net-ipv6
difficulty: intermediate
tags: [IPv6, 邻居发现, 组播, 网络协议栈]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
  - /tutorials/kernel/net/03-net-neighbor
related:
  - /tutorials/kernel/net/04-net-ipv4
  - /tutorials/kernel/net/03-net-neighbor
sources:
  - notes: document/notes/linux_kernel_networking/ch08.md
  - notes: document/notes/linux_kernel_networking/ch08_1.md
  - notes: document/notes/linux_kernel_networking/ch08_2.md
  - notes: document/notes/linux_kernel_networking/ch08_3.md
  - notes: document/notes/linux_kernel_networking/ch08_4.md
  - notes: document/notes/linux_kernel_networking/ch08_5.md
  - notes: document/notes/linux_kernel_networking/ch08_6.md
  - notes: document/notes/linux_kernel_networking/ch08_7.md
  - notes: document/notes/linux_kernel_networking/ch08_8.md
---

# IPv6：不只是更长的地址

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数名/数据结构/CONFIG/sysctl 已核对）；具体行号与命令输出待 QEMU 亲测核对。等我们在 QEMU 里跑通 `ip -6 addr` / `ping6` / `ip -6 neigh`，把 NDISC 和 SLAAC 的真实报文抓下来，就升级成 ✅ 已锤炼。

## 从一个幽灵数字说起

有一个数字像幽灵一样盘旋在网络工程的上空：$2^{32}$——IPv4 地址的理论总量。2011 年地址池正式宣告耗尽，从那以后整个互联网靠 NAT 这台透析机勉强吊着命。但 NAT 本质是个 Hack，它砸碎了互联网端到端的设计哲学，让 P2P 和协议设计都变得别扭。

IPv6 看起来只是把地址从 32 位拉到 128 位，但真正进了内核代码你会发现——它不是在 IPv4 后面打补丁，而是站在老兵肩膀上做的一次重构。变量名往往只多一个 `6`，函数名换个前缀，这种相似性有欺骗性。剥开外壳，IPv6 把 IPv4 几十年的历史包袱砍掉了：路由器不再分片、扩展头代替 Options、主机不需要 DHCP 也能拿到全球地址。这篇我们就钻进 `net/ipv6/`，看看这些机制在内核里到底怎么实现。

## 地址：从门牌号到坐标

先看内核怎么装这个 128 位的怪兽。在 `include/uapi/linux/in6.h` 里，`struct in6_addr` 是一个 union，把同一块 16 字节切成三种视角：

```c
struct in6_addr {
    union {
        __u8        u6_addr8[16];   // 按字节 memcpy
        __be16      u6_addr16[8];   // 16 位分段
        __be32      u6_addr32[4];   // 按位/掩码运算
    } in6_u;
};
```

这是内核网络代码的常见手法——为了性能，直接按字长操作内存，而不是在那儿移位。`__be` 前缀提醒你这些是网络字节序（大端），跨架构移植时别填本地整数。

> ⚠️ **读头文件别被骗**：上面是**内核内部视图**，三个成员都可见。但在 uapi 头里，`u6_addr16`/`u6_addr32` 被包在 `#if __UAPI_DEF_IN6_ADDR_ALT` 里——用户态默认这个宏为 0，所以 glibc 程序 `#include` 后**只能看到 `u6_addr8`**（配合 `s6_addr` 这类宏访问）。只有进了内核态（`__UAPI_DEF_IN6_ADDR_ALT` 为 1）三视图才全露出来。你拿 uapi 头自己编译用户态程序只看到 `u6_addr8`，不是头文件坏了。

IPv6 地址分三类，而且**取消了广播**。单播一对一；任播一对最近的一个（像连锁店，你找的是"麦当劳"这个品牌，但只走进最近的那家）；组播一对多。为什么砍掉广播？因为 IPv4 里 ARP 一次广播喊醒整个网段太吵了，IPv6 干脆用组播代替——你只朝自己关心的那个组喊，不是组成员的设备可以继续睡觉。

几个必须刻进肌肉记忆的特殊地址：链路本地 `fe80::/64`（只能在本链路用，路由器绝不转发，是邻居发现和自动配置的根基）；全球单播（公网身份证，`全局路由前缀 + 子网 ID + 接口 ID` 三段千层饼）；环回 `::1`；未指定 `::`（DAD 时当源地址，意思是"我还没地址，正在占坑"）。

## 源码里的核心结构：`struct ipv6hdr`

来看内核眼里的 IPv6 包长什么样，`include/uapi/linux/ipv6.h`（Linux 6.19）：

```c
struct ipv6hdr {
#if defined(__LITTLE_ENDIAN_BITFIELD)
    __u8            priority:4, version:4;
#elif defined(__BIG_ENDIAN_BITFIELD)
    __u8            version:4, priority:4;
#endif
    __u8            flow_lbl[3];
    __be16          payload_len;
    __u8            nexthdr;
    __u8            hop_limit;
    __struct_group(, addrs, , struct in6_addr saddr; struct in6_addr daddr;);
};
```

**固定 40 字节，雷打不动。** 这是 IPv6 第一刀——IPv4 头部长度可变（有 Options），所以必须有 `IHL` 字段告诉内核头有多长；IPv6 直接砍掉这个字段，40 字节写死。

第二刀更狠：**IPv6 头部没有校验和**。IPv4 每经过一个路由器 TTL 减 1 就得重算整个头部校验和，在老式软件路由器上是不小的开销。IPv6 把这活儿甩给了二层（以太网 CRC）和四层（TCP/UDP 校验和）。后果是路由器改 `hop_limit` 不用重算校验和——纯软件转发实打实的提速。副作用：IPv6 里 UDP 校验和强制开启（除极少数隧道场景），因为没人再给你兜底了。

那个被切分的字节很有意思。RFC 2460 标准说 4 位 Version + 8 位 Traffic Class + 20 位 Flow Label。但 Linux 实现把第一个字节拆成 `priority:4` + `version:4`，剩下的 4 位 Traffic Class 塞进了 `flow_lbl[0]` 的高 4 位。`priority` 加 `flow_lbl[0]` 高 4 位才拼出完整的 8 位 Traffic Class（留给 DiffServ 做 QoS）。

字段一一过：`version` 必须 6；`flow_lbl` 是流标签，让路由器按标签快转（RFC 6437，通用互联网上很少大规模用）；`payload_len` 只算载荷不含头部，16 位最大 65535，再大靠 Hop-by-Hop 的 Jumbo Payload 选项；`hop_limit` 就是改了名字的 TTL；`nexthdr` 是全篇的核心，下面单讲。

## `nexthdr` 与扩展头链：链接式扩展

`nexthdr` 取代了 IPv4 的 Protocol 字段，但它更灵活——它像链表节点的 `next` 指针，指向紧跟其后的下一个头部类型。没有扩展头时，它就是上层协议号（`IPPROTO_TCP`=6、`IPPROTO_UDP`=17）；有扩展头时，它指向第一个扩展头。

```
[ IPv6 Header (nexthdr=Routing) ]
    -> [ Routing Header (nexthdr=TCP) ]
        -> [ TCP Segment ]
```

每个扩展头的第一个字节都是自己的 `Next Header` 字段，一路串到底，最后一个才指向真正的上层协议。这种设计带来的好处很实在：中间路由器除了极个别的 Hop-by-Hop 头，根本不解析这些中间头，直接跳过去转发——比 IPv4 那个让硬件加速痛苦万分的变长 Options 强太多。

几种核心扩展头（类型号定义在 `include/net/ipv6.h`，不是 uapi 头）：**Hop-by-Hop**（`NEXTHDR_HOP`=0）是唯一特权阶级，必须紧挨 IPv6 头、强迫路径上每个路由器处理，常用于 Router Alert 和 Jumbo Payload，滥用会拖垮转发效率；**Routing**（`NEXTHDR_ROUTING`=43）是 IPv4 源站选路的继任者，Type 0 因反射攻击风险被 RFC 5095 废弃；**Fragment**（`NEXTHDR_FRAGMENT`=44）是分片机制核心；**Destination Options**（`NEXTHDR_DEST`=60）是唯一允许出现两次的头（Routing 前给中转路由器看，Routing 后给最终目标看）。

> ⚠️ **踩坑**：MTU 是 IPv6 故障头号杀手。IPv6 规定**中间路由器绝对不分片**。包比 MTU 大？路由器不切碎，直接扔掉并回一个 ICMPv6 "Packet Too Big"。源主机收到后才缩小包重发，这就是强制的 Path MTU Discovery。所以**千万别封 ICMPv6**——一旦 "Packet Too Big" 回不来，源主机一直发大包全在半路被无声丢弃，表现就是小包通大包丢，典型 PMTU 黑洞。

## 进入内核：`ipv6_rcv()` 的入口

讲了这么多结构，来看系统怎么启动。`net/ipv6/af_inet6.c`（Linux 6.19）里，IPv6 子系统的总指挥是 `inet6_init()`，它注册 TCPv6/UDPv6 协议处理器、启动邻居发现和路由子系统。最关键一步是告诉网络核心："收到以太网类型 `0x86DD` 的帧，交给我"——通过 `dev_add_pack()` 完成，和 IPv4 一模一样：

```c
static struct packet_type ipv6_packet_type __read_mostly = {
    .type = cpu_to_be16(ETH_P_IPV6), /* 0x86DD */
    .func = ipv6_rcv,
    .list_func = ipv6_list_rcv,
};

static int __init ipv6_packet_init(void)
{
    dev_add_pack(&ipv6_packet_type);
    return 0;
}
```

从此只要网卡收到 EtherType 是 `0x86DD` 的帧，内核就跳进 `ipv6_rcv()`。这是所有 IPv6 包（单播和组播，IPv6 没有广播）的必经之路。

`ipv6_rcv()` 的活儿是**第一道安检**（实现在 `net/ipv6/ip6_input.c`）：版本号必须 6（`hdr->version != 6` 直接丢）；从外面进来的包不能带环回地址（`ipv6_addr_loopback(&hdr->saddr/daddr)`）；源地址不能是组播（`ipv6_addr_is_multicast`）。过检后，如果 `nexthdr == NEXTHDR_HOP` 立刻调用 `ipv6_parse_hopopts()` 解析逐跳选项，失败就统计 `IPSTATS_MIB_INHDRERRORS` 丢包。最后甩给 Netfilter 钩子 `NF_HOOK(NFPROTO_IPV6, NF_INET_PRE_ROUTING, ..., ip6_rcv_finish)`——你的 iptables/nftables raw 表 PREROUTING 链就在这里触发。

放行后进 `ip6_rcv_finish()`，这才是决定包**命运**的岔路口：还没绑目的缓存就调 `ip6_route_input()` 查路由表（底层走 `ip6_route_input_lookup()` → `fib6_rule_lookup()`，开了多路由表时先过 policy rule 再查 FIB6），拿到结果后调 `dst_input(skb)`。`dst_input` 是个神奇的小函数，它直接调用路由结果里预设的 `input` 回调：本地的扔进 `ip6_input`（本地投递）、给别人的扔进 `ip6_forward`（转发）、给一群人的扔进 `ip6_mc_input`（组播）、找不到路的扔进 `ip6_pkt_discard` 顺便回个 ICMPv6 不可达。本地投递路径里 `ip6_input_finish()` 会像剥洋葱一样顺着 `nexthdr` 链解扩展头，最后交给上层（`tcp_v6_rcv`/`udpv6_rcv`）。

## SLAAC：无状态自动配置的魔法

最让人困惑的反直觉现象：你根本没 `ip addr add`，`ip addr show` 里却已经躺着一个长得吓人的 128 位地址。没人配，地址哪来的？这就是 IPv6 的 **SLAAC（无状态地址自动配置）**，四步仪式。

**第一步，本地低调起步。** 系统启动时 IPv6 协议栈先给自己造个临时身份证——链路本地地址，前缀 `fe80::/64` 接上自己的 EUI-64 接口 ID。此时地址被打上 `IFA_F_TENTATIVE`（试探性）标记，只能处理邻居发现消息，不能收发普通流量。为什么？因为你得先确认屋里没有另一个同名者——这就是 DAD（重复地址检测），承接 03-net-neighbor 那一篇讲过的机制。DAD 通过、标志移除，地址才上岗。

**第二步，寻找指路人。** 链路本地地址确立后，主机（如果它不是路由器）主动调 `ndisc_send_rs()` 发 **Router Solicitation（RS）**，目标 `ff02::2`（所有路由器组播），ICMPv6 Type 133。像在走廊喊一嗓子"这儿有台机器要上网，路由器谁在？"

**第三步，路由器布道。** 路由器回 **Router Advertisement（RA）**，源是路由器的链路本地地址，目标 `ff02::1`（所有节点），ICMPv6 Type 134。Linux 里这个角色通常由用户空间的 `radvd` 守护进程扮演，配置文件里写前缀（如 `2001:db8:abcd::/64`），它定期广播并响应 RS。RA 手里攥着主机最想要的两样东西：前缀信息，以及标志位（告诉你能用 SLAAC 无状态配，还是必须找 DHCPv6）。

**第四步，地址合成。** 主机收到 RA 拿到前缀，简单拼装：`IPv6 地址 = Prefix (from RA) + Interface ID`。前缀必须 64 位，Interface ID 通常是 MAC 算出来的 EUI-64。

但这里有个隐患：Interface ID 直接用 MAC，意味着你走到哪儿地址后 64 位都不变，Google、广告商换个 Wi-Fi 也能通过这串尾巴追踪到你。Linux 的解法是 **Privacy Extensions**（RFC 4941），靠 sysctl `net.ipv6.conf.<iface>.use_tempaddr` 开启——在前缀后面接一个**随机**的 Interface ID 而不是 MAC，而且这个临时地址定期过期换新的。

> ⚠️ **别去 `make menuconfig` 翻 `CONFIG_IPV6_PRIVACY`**：这个 Kconfig 选项在 6.19 源码里**不存在**（`grep net/ipv6/Kconfig` 全空）。Privacy Extensions 是**运行期**开关，由 sysctl `use_tempaddr` 控制——置为 0 表示禁用，>0 才生成临时地址；`ipv6_create_tempaddr()` 在 `use_tempaddr <= 0` 时会直接打日志 `"use_tempaddr is disabled"` 退出（`net/ipv6/addrconf.c`，6.19 已核对）。顺带一提，6.19 里网卡创建时的默认 `addr_gen_mode` 已经是 `IN6_ADDR_GEN_MODE_STABLE_PRIVACY`（稳定隐私地址，靠 HMAC 算接口 ID），跟 `use_tempaddr` 的 RFC 4941 临时地址是两套机制，别混了。

地址不是永久的，`struct inet6_ifaddr`（`include/net/if_inet6.h`，第 39-40 行，已核对）里的 `valid_lft`/`prefered_lft` 字段对应 RA 里的两个生命周期：`valid_lft` 到期地址直接消失，`prefered_lft` 更短、一到点进入 deprecated 不再主动发起新连接但还能收。这套机制还能让网管只改 `radvd` 配置就平滑全网重编号（换 ISP 前缀），主机自动让旧地址过期、配上新前缀。

## NDISC 与 MLD：组播代替了广播

**NDISC（邻居发现）** 承接 03-net-neighbor，基于 ICMPv6 承载，彻底替代了 IPv4 的 ARP。它最精巧的设计是 **Solicited-Node 组播地址**：当接口配了一个单播/任播地址，内核必须算出一个对应的组播组加进去。算法在 `include/net/addrconf.h` 的 `addrconf_addr_solict_mult()` 里——保留单播地址的**低 24 位**，拼上固定前缀 `ff02::1:ff00::/104`。这样你找 `2001:db8::1234:5678` 的 MAC 时，不用广播吵醒全网，只往 `ff02::1:ff34:5678` 喊一声 NS 消息即可，碰撞概率 1/2²⁴ 可忽略。加入这个组的动作由 `addrconf_join_solict()` 完成（`net/ipv6/addrconf.c`）。NDP、自动配置的"悄悄话"全在链路本地范围内进行。

> ⚠️ **踩坑**：配置防火墙时很多人只盯着 Global 地址，把 `fe80::/10` 流量给封了，结果邻居发现挂了 ping6 不通——相当于在家把电话线掐了还奇怪快递员打不通电话。

**MLD（组播监听发现）** 是 IGMP 的 IPv6 版本，但塞进了 ICMPv6 口袋里（抓包看到的 MLD 上层协议永远写 ICMPv6，控制平面统一简化）。MLDv1（RFC 2710）只支持 ASM（任意源，大锅饭照单全收）；MLDv2（RFC 3810）引入 SSM（源特定组播），允许主机用 INCLUDE/EXCLUDE 精确指定只听谁或屏蔽谁，这才是现在的标准。

内核两条加入路径。**路径 A 内核自动加入**：网卡一活过来，`ipv6_add_dev()` 立刻 `ipv6_dev_mc_inc()` 加入 `ff01::1`（接口本地所有节点）和 `ff02::1`（链路本地所有节点）这两个大喇叭频道，这是强制的，否则连 NDP 都做不了。若开了 `forwarding`，`dev_forward_change()` 会再加 `ff02::2`/`ff01::2`/`ff05::2` 三个所有路由器组。**路径 B 用户态请求**：`setsockopt(..., IPV6_JOIN_GROUP, ...)` 进内核的 `ipv6_sock_mc_join()`，既更新硬件过滤又把 socket 挂到成员列表上，同时发一个 MLDv2 Report——注意它的目标不是你加入的那个组，而是 `ff02::16`（所有 MLDv2 路由器），还带 Hop-by-Hop 的 Router Alert 选项（沿途路由器"别光转发，停下来看看"），ICMPv6 Type 143。调试时 `cat /proc/net/mcfilter6` 是最好用的账本，INCLUDE/EXCLUDE 源列表一目了然。

## 动手验证（待亲测）

不写完整 `example/mini` 代码，先把验证方案钉死，等 QEMU 跑通再填真实输出。

**目标**：亲眼看到 SLAAC 全过程 + NDISC 表项 + MLD 组成员。

**步骤（待亲测输出）**：
1. `ip -6 addr show eth0` —— 看链路本地 `fe80::` 是否在 SLAAC 跑通前就出现（DAD 后 `tentative` 标志消失）。
2. 在另一端起 `radvd` 广播前缀，观察主机自动合成全球单播地址。
3. `ping6 ff02::1%eth0` —— 向所有节点喊话，看链路上 IPv6 邻居响应。
4. `ip -6 neigh show` —— 看 NDISC 维护的邻居表（替代 `arp -n`），注意地址解析走的是 Solicited-Node 组播而非广播。
5. `tcpdump -ni eth0 'icmp6'` —— 抓 RS（133）/RA（134）/NS（135）/NA（136），验证"IPv6 控制平面全是 ICMPv6"这件事。
6. `cat /proc/net/mcfilter6` —— 看主机默认加入了哪些组播组（至少有 `ff02::1`）。
7. `sysctl net.ipv6.conf.eth0.use_tempaddr` —— 验证 Privacy Extensions 开关（默认 0，设 >0 后看临时地址生成）。

> ⚠️ **待亲测**：以上输出全是占位。我们会拿到 QEMU ARM64 上把每条命令的真实输出记下来，重点验证 `ipv6_rcv` 那几道 sanity check 在抓包里的体现，以及关掉 ICMPv6 后 SLAAC 是否真的"静默失败"。

## 小结

IPv6 绝不是"IPv4 加长版"。它的设计哲学是**精简骨架、把复杂性交给扩展**：固定 40 字节头部去掉校验和，用 `nexthdr` 串起扩展头链让路由器轻松转发；取消广播，用 Solicited-Node 组播把 ARP 的以太网噪音压到极小；禁止中间路由器分片，强制 PMTUD；SLAAC 让主机即插即用拿到全球地址，Privacy Extensions 防追踪；NDISC 和 MLD 统统收编进 ICMPv6，控制平面大一统。

记住三件最容易翻车的事：**封 ICMPv6 必死**（PMTU 黑洞）、**关 forwarding 才是纯主机**（开了 forwarding 进路由器模式后，即使 `accept_ra` 还开着，RA 带来的地址/默认路由接纳行为也会受限——抓包里 RA 帧还在，但主机不再照单全收）、**链路本地地址是 NDISC 的命根子**（防火墙别封 `fe80::/10`）。

## 延伸阅读

- 源码：`net/ipv6/ip6_input.c`（`ipv6_rcv`/`ip6_rcv_finish` 接收路径）、`net/ipv6/ip6_output.c`（转发与输出）、`net/ipv6/route.c`（`ip6_route_input` → `ip6_route_input_lookup` → `fib6_rule_lookup` 收包查路由）、`net/ipv6/addrconf.c`（地址自动配置、`ipv6_add_dev`、MLD 组加入、`ipv6_create_tempaddr` 与 `use_tempaddr`）、`net/ipv6/ndisc.c`（邻居发现）、`net/ipv6/mcast.c`（MLDv2 Report 收发、`ipv6_sock_mc_join`）、`include/uapi/linux/ipv6.h`（`struct ipv6hdr`）、`include/net/ipv6.h`（`NEXTHDR_*` 扩展头类型常量）、`include/net/if_inet6.h`（`struct inet6_ifaddr` 的 `valid_lft`/`prefered_lft`）、`include/net/addrconf.h`（`addrconf_addr_solict_mult`/`addrconf_join_solict`）。
- kernel.org 稳定索引页：[Networking 文档总入口](https://docs.kernel.org/networking/index.html)（在右侧索引找 IPv6 / multicast / neighbor 相关章节）、[IP Sysctl（`/proc/sys/net/ipv6/*` 变量语义）](https://docs.kernel.org/networking/ip-sysctl.html)（含 `forwarding`、`accept_ra`、`use_tempaddr` 各 sysctl）。
- RFC：2460（IPv6 规范，现已被 8200 取代）、8200（IPv6）、4861（NDP）、4862（SLAAC）、3810（MLDv2）、4941（Privacy Extensions）、4291（IPv6 地址架构）。

---
应用了 7 项修改，已与 Linux 6.19 源码核对：

1. **[HIGH] 隐私扩展 / CONFIG** — 移除了错误的 `CONFIG_IPV6_PRIVACY` Kconfig 声明（在 `net/ipv6/Kconfig` 中不存在）。已替换为正确的运行时 sysctl `use_tempaddr`（当 `<=0` 时 `ipv6_create_tempaddr()` 会记录 `"use_tempaddr is_disabled"` — 已在 `net/ipv6/addrconf.c:1378` 核实），并添加了 `⚠️ callout`，以免读者去 `make menuconfig` 中寻找。同时澄清了 6.19 默认的 `addr_gen_mode = IN6_ADDR_GEN_MODE_STABLE_PRIVACY`（`addrconf.c:399`）与 RFC 4941 临时地址是不同的机制。
2. **[MEDIUM] NEXTHDR_* 头文件位置** — 从误导性的 "内核头" / `include/uapi/linux/ipv6.h` 更改为正确的 `include/net/ipv6.h`（`NEXTHDR_HOP`=0 / `NEXTHDR_ROUTING`=43 / `NEXTHDR_FRAGMENT`=44 / `NEXTHDR_DEST`=60，已核实）。扩展阅读部分现在也列出了 `include/net/ipv6.h`。
3. **[MEDIUM] ip6_route_input 后端** — 修正了输入路径的调用链：`ip6_route_input()` → `ip6_route_input_lookup()` → `fib6_rule_lookup()`（`route.c:2627/2341-2350`，已核实）。移除了不正确的 `fib6_lookup()`，该函数实际上属于配置路径（`route.c:3464`）。
4. **[LOW] in6_addr union** — 添加了 `⚠️ callout`，解释了这是仅限内核的视图：`u6_addr16`/`u6_addr32` 在 uapi 头文件中受 `#if __UAPI_DEF_IN_ID_ADDR_ALT` 保护（用户空间默认为 0 → 仅 `u6_addr8` 可见）。已核实。
5. **[LOW] 小结中的转发** — 从绝对化的 "进路由器模式收不到 RA" 放宽为：当 `forwarding=1` 时 RA 帧仍会到达（`ipv6_rcv` 不会丢弃它们），但 RA 地址/默认路由的接纳策略会改变。
6. **[LOW] frontmatter 前置知识** — 在前置知识中添加了 `/tutorials/kernel/net/03-net-neighbor`（本页面在 DAD / Solicited-Node / NDISC 方面明确依赖于它）；相关项保持不变。
7. **[LOW] 延伸阅读链接** — 将 ip-sysctl 页面具有误导性的标题 "Linux IPv6 HOWTO（规范文档列表）" 改为正确的 "IP Sysctl（`/proc/sys/net/ipv6/*` 变量语义）"。Networking 索引和 ip-sysctl URL 均已核实有效。

风格保持不变：保留了 frontmatter 中的英文键，使用半角冒号，`sources:` 使用了 `notes:`，`🔨 整理中` 的 callout 和 6.19 版本提示，折腾博主腔调，章节结构，以及待亲测的 callout。添加了一个验证步骤 (`sysctl use_tempaddr`)，以替换 Kconfig-驱动的框架，替换为实际启用该功能的 sysctl。

相关文件（未修改 — 输出是返回给父级的文本）：`/home/charliechen/PenguinLab/document/tutorials/kernel/net/12-net-ipv6.md`