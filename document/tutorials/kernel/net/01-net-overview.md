---
title: 网络栈全景：一个包的内核漂流
slug: net-overview
difficulty: intermediate
tags: [网络栈, net_device, NAPI, sk_buff]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
related:
  - /tutorials/foundations/07-kernel-module-hello
sources:
  - notes: document/notes/linux_kernel_networking/ch01_1.md
  - notes: document/notes/linux_kernel_networking/ch01_2.md
  - notes: document/notes/linux_kernel_networking/ch01_3.md
---

# 网络栈全景：一个包的内核漂流

> 🔨 **整理中** · 本篇函数签名/字段/数值已对照 Linux 6.19 源码校订（读书笔记基于较早内核版本，部分接口已演进）；具体行号仍待 QEMU 亲测核对。这篇是从读书笔记（`linux_kernel_networking` ch01 系列，主章只算目录页，实质内容在 ch01_1/1_2/1_3 三个子章）提炼的全景骨架，L2-L4 铁三角、`net_device`/NAPI/`sk_buff` 的"为什么"已经讲透；但收发旅程里那些函数名的真实落点、`/proc/net/dev` 的样例输出，还没在 QEMU 里亲手验过。等我们在 QEMU 上 `tcpdump` + 内核模块 trace 跑过一遍真实收发，再升级成 ✅ 已锤炼。

## 网络栈为什么是"黑盒"

写用户态网络程序的时候，我们大多数人脑子里只有两个洞：一个叫 `socket()`，一个叫 `read()/write()`。TCP 客户端写得再漂亮，并发模型再优雅，高吞吐下就是跑不满带宽；`iptables` 规则配了，包却像长了翅膀一样飞过去——这时候继续在用户态打转是没用的，**答案藏在内核源码的深处**。

我们这章要做的，就是把这个黑盒子撬开。

但撬开之前先建立坐标系。教科书的 OSI 七层模型像贴在墙上的旧海报，挂着没人看：物理层、数据链路层、网络层、传输层、会话层、表示层、应用层，七层齐齐整整。可是当你真去翻内核代码，会发现现实根本分不这么清楚。

内核真正操心的只有三层——**L2（链路层）、L3（网络层）、L4（传输层）**。它是一个夹心饼干：上面的 L5-L7（会话/表示/应用）交给用户态程序，下面的 L1（物理层）交给硬件和驱动工程师，内核只夹在中间这层"软肋"里做 L2 到 L4 的博弈。会话层、表示层在真实实现里基本被合并或忽略，应用协议自己管自己。

记住这张图：教科书七层是抽象坐标，内核铁三角才是代码现实。

## Linux 网络栈分层全景

从上往下，内核网络栈大致是这么几层（这是地图，后面的篇章逐层下钻）：

1. **VFS socket 层**：用户态程序调 `socket()/send()/recv()` 的入口，把"文件描述符"和"网络连接"接起来。这一层是用户态和内核态的边界。
2. **协议族 / 传输层**：`net_protocol`（如 IPv4、IPv6 注册的 `ip_rcv()`）管 L3 入口分发，TCP/UDP 管 L4 的端到端可靠/不可靠传输。
3. **IP 层**：做路由决策、分片重组、TTL 递减、Netfilter 防火墙钩子，是整个网络子系统的核心战场。
4. **网络设备驱动**：通过 `net_device` 把物理网卡抽象成软件对象，用 NAPI 收发真实帧。

每一层之间都不是"直线通行"。包在 L2→L4 之间穿梭时会被反复安检和整形：被 NAT 改写 IP 地址、被 IPsec 加密、被防火墙丢掉、过大被分片、每层都要算一遍 checksum——内核本质上是一个"在协议栈各层间对数据包反复安检和修饰的精密工厂"。

## 一个包的内核漂流（接收方向）

先把接收路径从下到上走一遍（笔记里最详细的一条线，函数名已对照 6.19 源码，行号待亲测核对）：

1. **网卡中断**：包从网线进来，网卡触发硬件中断，CPU 跑到驱动的中断处理函数。在 NAPI 模型下，驱动会暂时关中断，告诉内核"我现在有一堆包，你定期来轮询我拿"。
2. **NAPI 轮询收包**：驱动用 `netdev_alloc_skb()`（老代码里叫 `dev_alloc_skb()`，6.19 里它退化成包着 `netdev_alloc_skb` 的 legacy helper）分配一个 `sk_buff`，把 DMA 搬进来的帧数据塞进去。
3. **L2 处理 `eth_type_trans()`**：驱动调它判定包类型、剥掉以太网头。在 6.19 里它的实现是分两步走的（`net/ethernet/eth.c:155`）：先调 `eth_skb_pull_mac(skb)`——这个 inline helper（`include/linux/etherdevice.h:639`）内部就是 `skb_pull_inline(skb, ETH_HLEN)`，把 `skb->data` 往后挪 14 字节（`ETH_HLEN = 14`）跳过以太网头，这就是"剥洋葱"，剥掉 L2 露出 L3；再调 `eth_skb_pkt_type(skb, dev)`（`etherdevice.h:622`）依据目的 MAC 判定 `pkt_type`——组播 `PACKET_MULTICAST`、广播 `PACKET_BROADCAST`、别的主机 `PACKET_OTHERHOST`（目的 MAC 命中本机时不改写，`pkt_type` 在收包早期就预置成默认的 `PACKET_HOST = 0`，代表"是给我的"）。至于以太网头 Type 字段（`0x0800` 是 IPv4，`0x86DD` 是 IPv6）填进 `skb->protocol`，是 `eth_type_trans` 的返回值干的事。
4. **`netif_receive_skb`**：包交给网络核心，按 `skb->protocol` 分发。IPv4 的包会被扔给 `ip_rcv()`，IPv6 扔给 `ipv6_rcv()`——这两个协议处理函数是**协议模块**（如 IPv4 的 inet 初始化在 `net/ipv4/af_inet.c` 里）通过 `dev_add_pack()` 注册进 `ptype_all`/`ptype_base` 链表的（`net/ipv4/af_inet.c:2013` 那行 `dev_add_pack(&ip_packet_type)`，IPv6 同理在 `net/ipv6/af_inet6.c`）。注意挂 `ip_rcv` 进 ptype 链表的不是网卡驱动，驱动只负责 NAPI 收包与 `eth_type_trans`，把 L3 入口分发函数挂上去是协议栈自己的初始化职责。
5. **`ip_rcv()` → `ip_rcv_finish()`**：先做一堆 sanity checks（健康检查），如果没被 Netfilter 的 `NF_INET_PRE_ROUTING` 钩子拦下，就进入 finish。在这里查路由子系统，构建一个 `dst_entry`（目标缓存项），决定这个包下一步往哪走——是留给本机继续往上，还是转发。
6. **`tcp_v4_rcv`（传输层）→ socket 接收队列**：本机接收的包继续往上，TCP 头被剥掉，最终塞进对应 Socket 的接收队列，等用户态程序 `read()` 来取。

转发路径在 L3 就分叉了：查完路由表后不往上走，直接回头塞回 L2 发送队列，从另一张网卡发出去——转发包的 `skb->sk` 是 **NULL**，因为它是"过路客"，不归任何本地 socket 管。

> ⚠️ **待亲测**：上面这条收发链路的函数名已经对照 6.19 源码核对过，但每一步的具体行号、`tcp_v4_rcv` 与 socket 入队之间的真实调用顺序，要我们在 QEMU 上挂 `kprobe` 逐个跑一遍才算锤炼落地。

## 一个包的内核漂流（发送方向）

发送就是接收的镜像，从上往下走：

1. **socket write**：用户态 `send()/write()` 下发数据到 socket 层。
2. **传输层封装**：L4（TCP/UDP）给它加 TCP/UDP 头。
3. **IP 层封装 + 路由**：L3 加 IP 头，查路由决定从哪张网卡出，过大就分片，过 Netfilter 的 `POST_ROUTING` 钩子。
4. **邻居子系统填 MAC**：靠 ARP（IPv4）或 NDISC（IPv6）把"下一跳 IP"翻译成目标 MAC 地址，补上以太网头。
5. **驱动发送**：最终通过 `net_device_ops` 里的发送回调（`ndo_start_xmit`）交给网卡驱动，驱动把帧 DMA 出去（老代码里这个回调曾叫 `hard_start_xmit`，现统一为 `net_device_ops->ndo_start_xmit`，`hard_start_xmit` 在 6.19 里只剩注释里的历史名字残留）。

笔记对发送方向的函数级落点讲得不如接收方向细，这里只给方向、不给具体函数名（比如 `tcp_sendmsg`/`ip_queue_xmit` 这类名字的真实对应关系），等我们读 `net/ipv4/tcp_output.c` 等源码亲测核对后再补上。**拿不准的宁可写"详见 X"，也不编造数据通路。**

## net_device：网卡的"身份证"

内核眼里没有"网卡硬件"这个概念，一张网卡就是一个巨大的 `struct net_device` 实例。它装着这张网卡的全部"身家性命"：

- **硬件 IRQ 号**：CPU 靠它知道网卡有活干。
- **MTU**：以太网默认 1500 字节，超过就得分片。
- **MAC 地址**（`dev_addr`，48 位）、**设备名**（`eth0`/`wlan0`）、**标志位**（UP/DOWN/RUNNING）。
- **`net_device_ops` 回调集**：网卡的操作手册，含打开/停止/发送/改 MTU 的函数指针——发送就是这里的 `ndo_start_xmit`。
- **硬件特性**：是否支持 GSO/GRO 卸载、多队列（现代万兆卡有多 Tx/Rx 队列）、时间戳。
- **ethtool 回调**：这就是 `ethtool eth0` 能读出一堆寄存器信息的原因。

有个特别容易忽略的细节：**混杂模式计数器 `promiscuity` 为什么是个计数器（`unsigned int`）而不是 `bool`？** 在 6.19 里 `include/linux/netdevice.h` 把它声明成 `unsigned int promiscuity`，配套的 `dev_set_promiscuity(dev, int inc)` / `netif_set_promiscuity(dev, int inc)` 入参才是带符号 `int`。想象两个抓包工具同时开：`tcpdump` 启动 `+1`（变 1）→ `wireshark` 启动 `+1`（变 2）→ `tcpdump` 退出 `-1`（变 1，网卡仍混杂）→ `wireshark` 退出 `-1`（变 0，才退出混杂）。用布尔值的话，第二个工具一关就把第一个也带没了。这是"多用户共享资源状态"的经典设计，抓包工具能并发跑全靠它。

## NAPI：为什么不能每个包一个中断

旧时代的网卡驱动简单粗暴：来一个包，发一个中断。包来了 → 中断 → CPU 保存上下文 → 跑中断处理 → 拿包 → 恢复上下文。平时上网没事，可一旦碰上 DDoS 或海量小包流量，CPU 就崩了——每秒几十万个中断，光"进场退场"（保存/恢复寄存器）就把算力耗光，正事根本干不动。这在操作系统里叫**中断活锁**。

NAPI（New API）的解法是**根据负载动态切换策略**：

- **低负载**：还是用中断，没包就不打扰 CPU，省电且响应快。
- **高负载**：切换到**轮询**。中断触发一次后驱动关掉该中断，告诉内核"我这有一堆包，你自己定期来轮询我拿"。

效果就是把"N 个包 = N 次中断上下文切换"变成"N 个包 = 1 次中断 + 轮询"。代价是延迟会涨一点（要等轮询周期）。对延迟极致敏感、愿意挥霍 CPU 的场景（高频交易），内核还有 Busy Polling on Sockets（应用通过 `SO_BUSY_POLL` 把套接字切到主动轮询，6.19 文档里归在 NAPI busy polling 一类），那是更偏门的优化，留到后面专章。

## sk_buff：贯穿全栈的"快递盒"

收发旅程里那个从网卡一路被传到 socket 的东西，就是 `sk_buff`（简称 SKB）——内核网络栈里最核心、最复杂、也最令人头秃的数据结构。无论包刚被驱动捞上来，还是正要从 TCP 发出去，它的"肉身"都是一个 SKB。

SKB 靠 `head`/`data`/`tail`/`end` 一组指针，加上 L2/L3/L4 三个 header 偏移，灵活地处理协议头的剥除与添加。新手最容易犯的错是手动 `skb->data++`——千万别。内核有一套严格的 API：剥头用 `skb_pull()`，预留头用 `skb_push()`，取各层头用 `skb_transport_header()`/`skb_network_header()`/`skb_mac_header()`。遵守它才能管好 SKB 内部那个线性区 + 分页结构。

这篇只点到为止。SKB 的指针布局、零拷贝、clone/clone-with-fragments，下一篇 `02-net-sk-buff` 会掰开揉碎讲。

## 本藤地图

这篇是全景鸟瞰，把铁三角的形状、`net_device`/NAPI/`sk_buff` 是干嘛的、一个包怎么漂的，先在脑子里建立起来。后面是一条逐层下钻的藤蔓：

- **`02-net-sk-buff`**：SKB 指针布局与零拷贝 API。
- **邻居子系统**：ARP/NDISC 怎么把 IP 翻译成 MAC。
- **IPv4 / 路由**：`ip_rcv` 之后的路由决策、`dst_entry`、FIB。
- **TCP**：可靠传输、拥塞控制、`tcp_v4_rcv` 之后的那些事。

## 小结

Linux 网络栈不是一块铁板，而是一条由无数挂钩组成的流水线：从 NAPI 的中断/轮询混合收包开始，包被抬起 → 经 Netfilter 防火墙过滤 → 穿路由岔路口 → 经邻居子系统找下一跳 MAC → 最后落进 Socket 被用户态接住。内核只管 L2-L4，上面是应用，下面是硬件，它夹在中间做高速流动、反复校验与转发的精密加工。

记住三个主角：`net_device`（网卡的身份证，`promiscuity` 是 `unsigned int` 计数器，是共享状态经典）、NAPI（负载自适应的中断+轮询，解掉中断风暴）、`sk_buff`（贯穿全栈的快递盒，操作必须走 `skb_pull/push` API 不能乱改指针）。还有一条认知：**内核网络开发是双轨制江湖**（`net` 管修复、`net-next` 管新特性，`netdev` 邮件列表 + `checkpatch.pl`/`get_maintainer.pl` 是入场券），但那是写代码给主线的事，读懂栈先用不到，先存着。

## 延伸阅读

- 源码（Linux 6.19，行号待亲测核对）：
  - `net/core/dev.c`——`netif_receive_skb`、`dev_add_pack`、设备注册核心。
  - `net/ipv4/ip_input.c`——`ip_rcv`/`ip_rcv_finish`。
  - `net/ipv4/tcp_ipv4.c`——`tcp_v4_rcv` 入口。
  - `include/linux/netdevice.h`——`struct net_device`（`unsigned int promiscuity`）、`net_device_ops`、`ndo_start_xmit`。
  - `include/linux/skbuff.h`——`struct sk_buff`、`skb_pull`/`skb_push` 等操作 API。
  - `net/ethernet/eth.c` + `include/linux/etherdevice.h`——`eth_type_trans` 及 `eth_skb_pull_mac`/`eth_skb_pkt_type` 两个 helper。
  - `Documentation/networking/napi.rst`——NAPI 与 busy polling 官方说明。
- kernel.org 稳定文档索引：[Networking documentation](https://docs.kernel.org/networking/index.html)、[Kernel networking — core API](https://docs.kernel.org/networking/kernel.html)。
- 进一步（持续铺开）：`02-net-sk-buff` 详讲 SKB，邻居子系统（ARP/NDISC），IPv4 与路由子系统，TCP 收发。