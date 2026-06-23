---
title: 内核子系统
description: 调度器、内存管理、文件系统、网络栈——内核核心原理
maturity: drafting
---

# 内核子系统

> 深入内核核心原理：调度器、内存管理、文件系统、网络栈。🔨 调度器演进系列整理中，其余持续铺开。

## 调度器 🔨 整理中

- 🔨 [演进（一）：O(1) 调度器——从遍历到位图的跨越](./sched/sched-evolution-01-o1)
- 🔨 [演进（二）：SD/RSDL 风波——一位麻醉医生挑战内核权威](./sched/sched-evolution-02-sd-rsdl)
- 🔨 [演进（三）：CFS 诞生——62 小时重写调度器](./sched/sched-evolution-03-cfs)
- 🔨 [演进（四）：EEVDF——从虚拟公平到虚拟截止时间](./sched/sched-evolution-04-eevdf)
- 🔨 [演进（五）：sched_ext——BPF 可编程调度器的争议之路](./sched/sched-evolution-05-sched-ext)

## 内存管理 🔨 整理中

- 🔨 [伙伴系统：内核怎么管物理页](./mm/01-mm-buddy)
- 🔨 [Slab 分配器：内核怎么管小对象](./mm/02-mm-slab)
- 🔨 [vmalloc：只要虚拟连续就行](./mm/03-mm-vmalloc)
- 🔨 [页面回收与 kswapd：内存紧张时怎么办](./mm/04-mm-page-reclaim)
- 🔨 [OOM Killer：回收也扛不住时的最后防线](./mm/05-mm-oom)

## 文件系统 📚 规划中

VFS、Ext4、页缓存、写时复制。

## 网络栈 🔨 整理中

- 🔨 [网络栈全景：一个包的内核漂流](./net/01-net-overview)
- 🔨 [sk_buff：贯穿网络栈的快递盒](./net/02-net-sk-buff)
- 🔨 [邻居子系统与 ARP：IP 怎么找到 MAC](./net/03-net-neighbor)
- 🔨 [IPv4 协议层：包的接收与发送](./net/04-net-ipv4)
- 🔨 [IPv4 路由子系统：包该往哪走](./net/05-net-routing)
- 🔨 [TCP 传输层：三次握手与收发内核视角](./net/06-net-tcp)
- 🔨 [UDP：无连接的轻量传输](./net/07-net-udp)
- 🔨 [Netfilter：网络栈的钩子框架](./net/08-net-netfilter)
- 🔨 [Netlink：用户态与内核的双向 socket](./net/09-net-netlink)
- 🔨 [ICMP：网络的诊断与控制协议](./net/10-net-icmp)
- 🔨 [组播路由：一对多的高效投递](./net/11-net-multicast)
- 🔨 [IPv6：不只是更长的地址](./net/12-net-ipv6)
- 🔨 [IPsec 与 XFRM：内核怎么给数据包穿装甲](./net/13-net-ipsec)
- 🔨 [mac80211：内核怎么管一块无线网卡](./net/14-net-wireless)
- 🔨 [RDMA 与 InfiniBand：绕过内核的零拷贝传输](./net/15-net-rdma)
- 🔨 [网络命名空间：容器网络的根基](./net/16-net-namespace)

XDP 持续铺开。
