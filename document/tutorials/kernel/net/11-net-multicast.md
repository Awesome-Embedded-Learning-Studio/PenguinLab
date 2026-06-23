---
title: 组播路由：一对多的高效投递
slug: net-multicast
difficulty: intermediate
tags: [网络栈, 组播, IGMP, 多路径路由]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
related:
  - /tutorials/kernel/net/04-net-ipv4
sources:
  - notes: document/notes/linux_kernel_networking/ch06.md
  - notes: document/notes/linux_kernel_networking/ch06_1.md
  - notes: document/notes/linux_kernel_networking/ch06_2.md
  - notes: document/notes/linux_kernel_networking/ch06_3.md
  - notes: document/notes/linux_kernel_networking/ch06_4.md
  - notes: document/notes/linux_kernel_networking/ch06_5.md
  - notes: document/notes/linux_kernel_networking/ch06_6.md
  - notes: document/notes/linux_kernel_networking/ch06_7.md
  - notes: document/notes/linux_kernel_networking/ch06_8.md
---

# 组播路由：一对多的高效投递

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数名/数据结构/CONFIG/行号已逐条核对过 `net/ipv4/ipmr.c`、`net/ipv4/igmp.c`、`net/ipv4/route.c`、`net/ipv4/fib_semantics.c`）；动手部分（加组、tcpdump 抓 IGMP、多路径配置）还没在 QEMU 上亲手跑过，输出仍是参考样例。

## 一场直播流，凭什么不把光纤烧干

单播的世界观很朴素：要给一百个人发同一封邮件，就发一百次。逻辑上没毛病，可一旦换成 NFL 直播流——服务器得为每个在线观众单独拉一根网线，带宽直接爆炸。我们需要让网络理解「这封信属于某一群人」，然后只在必要的分叉口才复制。

这就是**组播（multicast）**。IPv4 用 D 类地址 `224.0.0.0/4`（首段 224~239）专门承载这种「一对多」流量，OSPF 的 `224.0.0.5`、视频流的 `239.x.x.x` 都住在这片地界。

但组播比单播难得多：路由器得时刻追踪「谁想听」「谁不想听了」「谁在发」。管不好，组播包就像洪水漫灌，把交换机活活撑死。这一篇我们就拆 Linux 内核这套系统怎么转——IGMP 怎么管「成员名单」、内核那张特殊的组播路由表长啥样、一个组播包进来后怎么被分发到成千上万个出口。IPv6 那套叫 MLD（基于 ICMPv6），留到以后。

## IGMP：主机举手报名

要在 IPv4 玩组播，主机和路由器都绕不开 **IGMP（Internet Group Management Protocol）**。它的活很纯：建立并维护组播成员关系。协议迭代了三版，每版都在补上一版的漏洞。

- **IGMPv1（RFC 1112）**：只有两种消息——主机喊「我要加入」的 Membership Report、路由器问「这局域网还有人听吗」的 Membership Query。Query 发给 `224.0.0.1`（`IGMP_ALL_HOSTS`，所有人），TTL 锁死为 1，永远出不了本地网段——防噪声。
- **IGMPv2（RFC 2236）**：v1 最大的坑是「沉默就是离开」——主机关机拔网线时没法说再见，路由器只能干等超时。v2 加了 **Leave Group（0x17）**，主机礼貌退群，路由器立刻停止转发，不必傻等。同时 Query 拆出 General Query 和 Group-Specific Query 两个子类。
- **IGMPv3（RFC 3376）**：引入**源过滤**——不光能说「我要听 239.1.1.1」，还能说「我只信 10.0.0.1 这个源发的」（Include）/「除了 10.0.0.2 谁都行」（Exclude）。代价是 Socket API 也得扩展（`IP_ADD_SOURCE_MEMBERSHIP` 等）。

内核视角下，IGMP 报文进栈后落到 `igmp_rcv()`（`net/ipv4/igmp.c:1075`，Linux 6.19），它按消息类型分发。路由器定期发 Query，主机收到 `IGMP_HOST_MEMBERSHIP_QUERY` 后调 `igmp_heard_query()`（`igmp.c:947`）——这个方法就是主机说「我在听」的触发器，它会重置本机定时器、准备回 Report，保证网段里只要有活人，路由器就知道这个组还在。

主机自己想加入一个组，是应用层发起的：`setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, ...)`，最终进 `ip_mc_join_group()`（`igmp.c:2313`），把组地址挂到网卡 `in_device` 的成员链表上，同时回发一个 IGMP Report。**有个历史遗留限额**：同一 socket 最多加 20 个组，硬编码在 `sysctl_igmp_max_memberships`（`igmp.c:2294` 用 `count >= READ_ONCE(net->ipv4.sysctl_igmp_max_memberships)` 判断），超了直接 `-ENOBUFS`——20 个对普通应用够用，做组播网关就得多开 socket 或改 `/proc/sys/net/ipv4/igmp_max_memberships`。

## 组播路由表：`mr_table` 调度中心

IGMP 是「举手报名」，组播路由表就是那个拿着花名册的「点名员」。内核里这张表是 `struct mr_table`（`include/linux/mroute_base.h:246`，Linux 6.19）：

```c
struct mr_table {
    struct list_head    list;
    possible_net_t      net;        // 网络命名空间，容器隔离用
    u32                 id;         // 表身份证号，单表模式常是 RT_TABLE_DEFAULT(253)
    struct sock __rcu  *mroute_sk;  // 用户空间路由守护进程的 socket 引用
    struct timer_list   ipmr_expire_timer; // 定时清垃圾
    struct list_head    mfc_unres_queue;   // 未解析条目队列
    struct vif_device   vif_table[MAXVIFS]; // 虚拟接口表（最多 32 个）
    struct rhltable     mfc_hash;          // 组播转发缓存（哈希表）
    struct list_head    mfc_cache_list;    // 缓存条目链表
    int                 maxvif;
    atomic_t            cache_resolve_queue_len;
    bool                mroute_do_assert;  // 是否在入接口错误时通知用户空间
    bool                mroute_do_pim;     // 是否收 PIMv1
    int                 mroute_reg_vif_num; // PIM register vif 索引
};
```

> ⚠️ 这里有个版本坑：老书和老笔记写的是 `mfc_cache_array[MFC_LINES]`（64 槽位数组）。Linux 6.19 早已换成 `rhltable mfc_hash`（可扩缩的哈希表）+ `mfc_cache_list` 链表，不再是固定数组。老笔记这块没跟上，我们按现网代码讲。

每个字段都埋着机制。**`net`** 是网络命名空间指针（容器化网络隔离的关键），**`id`** 是表身份证。**`mroute_sk`** 最有意思——它指向内核保留的一个用户空间 socket 引用。这里有个关键交互：用户空间的组播路由守护进程（`mrouted`/`pimd`）启动时调 `setsockopt(..., MRT_INIT, ...)`，内核就把当前 socket 存进 `mroute_sk`，认定它是「总指挥」；守护进程退出调 `MRT_DONE`，内核清空这个指针。

为什么这么设计？**内核自己不跑路由协议**，只管转发；策略决策（怎么转、建什么树）由用户空间守护进程算好，通过 `setsockopt`/ioctl 喂给内核。反过来，内核遇到不会转的包，也通过这个 socket 把消息（`sock_queue_rcv_skb`）塞回守护进程。

**独占性**是硬规矩：同一时间只能有一个组播路由守护进程。`MRT_INIT` 时第一件事就是查 `mroute_sk` 占没占坑，占了直接 `-EADDRINUSE`（`ipmr.c:1413`：`if (rtnl_dereference(mrt->mroute_sk)) ret = -EADDRINUSE`）。同时内核会把 `IPV4_DEVCONF_ALL(net, MC_FORWARDING)` 自增 1（`ipmr.c:1421`）——这文件只读，因为它是**状态不是配置**，只有 `MRT_INIT` 发生时才翻转，防止没守护进程时强行开转发。

守护进程还要把物理网卡注册成组播接口，靠 `MRT_ADD_VIF` 命令填一张 `struct vifctl` 表，内核调 `vif_add()` 把设备挂进 `vif_table`。每个 VIF 可以是真实网卡，也可以是 IPIP 隧道（`VIFF_TUNNEL`），跨不支持组播的公网时靠它封装。`vif_add()` 还会调 `dev_set_allmulti(dev, 1)`——告诉网卡驱动「别光收单播，把路过的组播包都递上来」，否则硬件层直接丢，内核根本没机会转发。

## MFC：组播转发缓存

`mr_table` 是调度中心，真正的转发决策在 **MFC（Multicast Forwarding Cache）**。每个组播包进来都要在这里问路。条目最小单位是 `struct mfc_cache`（`include/linux/mroute.h:80`，Linux 6.19），它本身只装两个键值字段 + 一个内嵌的通用基底：

```c
struct mfc_cache {              // mroute.h:80，键值字段（mfc_cache 自有）
    struct mr_mfc _c;           // ← 通用基底，继承自它
    union {                     // cmparg 用于哈希比较
        struct {
            __be32 mfc_mcastgrp; // 组地址
            __be32 mfc_origin;   // 源地址
        };
        struct mfc_cache_cmp_arg cmparg;
    };
};
```

而 `mfc_parent`、`mfc_un`（unres/res）这些干活字段都不在 `mfc_cache` 本体，而在它内嵌的 `struct mr_mfc _c` 里（`include/linux/mroute_base.h:135`）：

```c
struct mr_mfc {                 // mroute_base.h:135，通用基底
    // ...（list/hash 链表、refcount 等）
    unsigned short mfc_parent;  // 入接口（VIF 索引），访问写成 c->_c.mfc_parent
    union {
        struct { ... } unres;   // 未解析态：expires + unresolved 包队列
        struct { ... } res;     // 已解析态：bytes/pkt/wrong_if 统计 + ttls[MAXVIFS]
    } mfc_un;
};
```

所以真实代码里访问转发字段一律走 `_c` 间接：`c->_c.mfc_parent`、`c->_c.mfc_un.res.ttls[ct]`、`c->_c.mfc_un.res.maxvif`。哈希键只吃两个值：**源地址 + 组地址**——一条组播流由 `(S, G)` 唯一确定。`mfc_parent` 是入接口：组播路由关心源（后面讲 RPF 会用），必须知道包最初从哪个 VIF 进来，防环路防重复。`mfc_un` 那个 union 是个薛定谔盒子——**`unres`（未解析）**态挂着过期时间 `expires` 和一个 `unresolved` 包队列；**`res`（已解析）**态塞满干活数据：`bytes`/`pkt`/`wrong_if` 统计、还有关键的 `ttls[MAXVIFS]`——记录每个虚拟接口的 TTL 阈值，包能不能从某接口出，全看这个数组里值和包的 TTL 谁大。

理论上流程是「包来 → 查 MFC → 命中 → 转发」，现实往往是「没命中」。这时 `ipmr_cache_unresolved()` 登场，务实得甚至卑微：建/找一个未解析条目、把包挂进 `unresolved` 队列、通过 `mroute_sk` 给守护进程发 `IGMPMSG_NOCACHE`——「大哥，这有个包不知去哪，快来看看」。

> **⚠️ 踩坑预警：只有 3 个名额。** `ipmr.c:1176` 那行硬逻辑：`if (c->_c.mfc_un.unres.unresolved.qlen > 3)`，同一流的迷路包队列里蹲了 3 个，第 4 个直接 `kfree_skb` 丢、返回 `-ENOBUFS`。同时未解析条目有个 **10 秒最后通牒**——`ipmr_cache_alloc_unres()` 里 `c->_c.mfc_un.unres.expires = jiffies + 10 * HZ`（`ipmr.c:992`），10 秒内守护进程不回填路由，条目就被 `ipmr_expire_timer` 清掉。这是保护机制：守护进程挂了或太慢，内核不能让未解析队列无限膨胀吃光内存。

## 组播接收路径：从网卡到转发队列

视角切到路由器。组播包抵达网卡后，在 `ip_route_input_mc()`（`net/ipv4/route.c:1742`，Linux 6.19）里初始化 `rtable` 时，有个关键微调：**开了 `CONFIG_IP_MROUTE` 且目标不是本地链路组播（`!ipv4_is_local_multicast`，排除 `224.0.0.x` 这类）且入接口 `IN_DEV_MFORWARD` 开启时，才把 `rth->dst.input` 改指向 `ip_mr_input`**（`route.c:1775`）：

```c
#ifdef CONFIG_IP_MROUTE
	if (!ipv4_is_local_multicast(daddr) && IN_DEV_MFORWARD(in_dev))
		rth->dst.input = ip_mr_input;
#endif
```

这「三个条件缺一不可」也顺带解释了为什么 IGMP（`224.0.0.1`）这类本地组播根本不进 ipmr 转发——它们被 `ipv4_is_local_multicast` 直接挡掉，留给 `igmp_rcv` 自己处理。

`ip_mr_input()`（`ipmr.c:2144`）身兼两职——既转发又本地投递（路由器自己可能也是组成员）。它先做几道关卡：

1. **防重复转发**：`if (IPCB(skb)->flags & IPSKB_FORWARDED) goto dont_forward;`——这包已被我转过一次了（可能因网桥/VLAN 绕回来），再转就是死循环。
2. **查表**：`mrt = ipmr_rt_fib_lookup(net, skb)`，普通配置下直接返回 `net->ipv4.mrt`。
3. **Router Alert 特快通道**：IGMPv2/v3 在 JOIN/LEAVE 报文 IPv4 头里盖个 Router Alert 印章（`IPCB(skb)->opt.router_alert`），`ip_call_ra_chain()` 直接把包塞给守护进程的 raw socket。代码里有段精彩注释吐槽 Cisco IOS ≤11.2(8) 这种不守规矩的老设备不设 RA，内核只能「夹带私货」——直接拿 `mrt->mroute_sk` 强行 `raw_rcv()` 发给守护进程，保证**无论设备多老、守护进程一定要收到 IGMP**。
4. **查 MFC**：`ipmr_cache_find(mrt, saddr, daddr)`，键是 `(S,G)`。命中就转给 `ip_mr_forward()`；没命中先查通配源 `ipmr_cache_find_any`，还找不到就走 `ipmr_cache_unresolved()` 收留+报警。

命中后直接 `ip_mr_forward(net, mrt, dev, skb, cache, local)`（`ipmr.c:2227`）——此时外层 `ip_mr_input` 已持有 `rcu_read_lock()`，函数注释里写明 `/* Called with mrt_lock or rcu_read_lock() */`，所以这里**不再额外加 `mrt_lock`**；若包也要本地投递（`local` 为真），再走 `ip_local_deliver(skb)`。

## `ip_mr_forward()`：分发肌肉

`ip_mr_input` 是决策大脑，`ip_mr_forward`（`ipmr.c:1996`）是干脏活的肌肉——按 MFC 指示把包复制并转发到所有该去的 VIF。这里最著名的是**入接口验明正身（Wrong VIF）**：`if (rcu_access_pointer(mrt->vif_table[vif].dev) != dev)`——路由条目说你该从 eth0 进来，结果你从 eth1 冒头。这分两种情况：本机发出包绕回来的「回环噩梦」直接 `dont_forward`（注释里直呼 "Very complicated situation..."）；真走错门则统计 `wrong_if`，凑齐「接口有效 + 允许 assert +（PIM 或 TTL 合理）+ 距上次吵架超 `MFC_ASSERT_THRESH`」四连条件，就发 `IGMPMSG_WRONGVIF` 让守护进程吵一架（PIM Assert）。

通过入接口检查后进 `forward` 标签，核心是个**遍历 VIF 表的转发循环**（`ipmr.c:2082` 起，按 6.19 真实代码）：

```c
for (ct = c->_c.mfc_un.res.maxvif - 1; ct >= c->_c.mfc_un.res.minvif; ct--) {
    /* For (*,G) entry, don't forward to the incoming interface */
    if ((c->mfc_origin != htonl(INADDR_ANY) || ct != true_vifi) &&
        ip_hdr(skb)->ttl > c->_c.mfc_un.res.ttls[ct]) {
        if (psend != -1) {            // 之前攒了个待发接口
            struct sk_buff *skb2 = skb_clone(skb, GFP_ATOMIC);
            if (skb2)
                ipmr_queue_fwd_xmit(net, mrt, true_vifi, skb2, psend);
        }
        psend = ct;
    }
}
```

注意两点：(1) 转发字段一律经 `_c` 间接访问（`c->_c.mfc_un.res.maxvif` / `c->_c.mfc_un.res.ttls[ct]`），键值字段才直接挂在 `mfc_cache` 上（`c->mfc_origin`）；(2) 真正发货的函数叫 `ipmr_queue_fwd_xmit()`，比很多老笔记写的 `ipmr_queue_xmit` 多一个 `in_vifi`（入接口索引）参数——那个老函数名在 6.19 里**根本不存在**，别照着老资料找。每个潜在出口 `ct` 过两道生死关：**是不是回头路**（`(*,G)` 不能发回进来的接口 `true_vifi`）和 **TTL 够不够**——每接口一个阈值 `ttls[ct]`，只有包 TTL **大于**它才允许出。这就是组播控范围、防泛滥的最有效手段。

循环结束后还有个 `last_forward:` 标签处理最后一个攒在 `psend` 里的待发口（`ipmr.c:2098`）：若也要本地投递（`local` 为真），就 `skb_clone()` 一份发出、原 skb 留给本地；否则直接拿原 skb 发出后 `return`。

### 发货其实分两步：`ipmr_prepare_xmit` 备货，`ipmr_queue_fwd_xmit` 发货

老资料把它说成一个 `ipmr_queue_xmit` 全包圆，其实 6.19 拆成了**备货**和**发货**两环。`ipmr_queue_fwd_xmit()`（`ipmr.c:1935`）本身很瘦：先试硬件卸载（`ipmr_forward_offloaded`），不成再调 `ipmr_prepare_xmit()` 备货，备好了打 `IPSKB_FORWARDED` 标记、过 `NF_HOOK(NF_INET_FORWARD)`，放行后交给 `ipmr_forward_finish()` → `dst_output()` 出网卡。真正干「查路由、判 MTU、套隧道头」重活的是 `ipmr_prepare_xmit()`（`ipmr.c:1857`）：

- **隧道 vs 物理口**：VIF 是隧道（`VIFF_TUNNEL`）就走 `IPPROTO_IPIP` 查到隧道对端（`vif->remote`）的单播路由，并预留 `encap = sizeof(struct iphdr)`（`ipmr.c:1888`）给新 IP 头腾地方；物理接口就查到组地址（`iph->daddr`）的路由。
- **反直觉的 MTU 处理**：MTU 不够且带 DF 位时——**什么都不做，直接丢，不发 ICMP**（`ipmr.c:1898`，注释直白："Do not fragment multicasts. Alas, IPv4 does not allow to send ICMP, so that packets will disappear to blackhole."）。组播接收者成千上万，一条路径 MTU 变小就向源头灌 ICMP 是灾难（ICMP 风暴 + 没法满足所有人）。所以「组播不切片，包消失进黑洞」——RFC 规定，沉默是金。
- 随后 `ip_decrease_ttl()`、隧道则 `ip_encap()` 套新头，备货就算齐活。

**TTL 在组播里有两层含义**：第一层是跳数限制（防环路），第二层是范围阈值——Steve Deering 定的「行政边界」：0=本机、1=同子网、32=同站点、64=同地区、128=同大洲、255=全球。应用层用 `IP_MULTICAST_TTL` 控制包飞多远，设 1 就在局域网晃悠。

## 多路径路由（ECMP）：流量摊开

组播讲完了，把视角拉回单播查表。传统路由只看目的地，但现实常要「把流量摊开」：两条等带宽宽带想都用上、两块网卡接同一交换机想跑满带宽。这就是**多路径路由（multipath / ECMP）**——为一个目的配多个下一跳，加权分担：

```bash
ip route add 192.168.1.10 \
    nexthop via 192.168.2.1 weight 3 \
    nexthop via 192.168.2.10 weight 5
```

内核里路由信息载体是 `struct fib_info`。要分清新老两套载体：**现代主流是 `struct nexthop` 对象**（`fib_info->nh`，`include/net/ip_fib.h:160`），用 `ip nexthop` 命令族管理，可被多条路由共享；**旧式兼容路径**才是 `fib_nh[]` 数组（`fib_info:162`，长度 `fib_nhs`）。两套并存，`fib_select_multipath` 开头先判 `if (unlikely(res->fi->nh))`，有 `nexthop` 对象就走 `nexthop_path_fib_result()`、直接 return；没有才回落到遍历 `fib_nh[]` 数组的老路径。权重字段是个宏 `fib_nh_weight`（`ip_fib.h:126`，展开成 `nh_common.nhc_weight`），不是裸的 `nh_weight`。

路由表只决定「有哪些路可选」，数据包真到了得挑**一条**走，这个黑盒是 `fib_select_multipath()`（`net/ipv4/fib_semantics.c:2165`，Linux 6.19）。它不是简单的「轮流坐庄」——先由 `fib_multipath_hash()` 算一个哈希 `h`，再按 `nh_upper_bound`（累加权重上限）和哈希值匹配选路。**关键修正：默认只哈希三层**。`sysctl_fib_multipath_hash_policy` 默认是 `0`（三层），`fib_multipath_hash()` 在 `case 0` 里只取源 IP + 目的 IP（`route.c:2073` 的 `switch`、`:2080` 用 `fl4->saddr`/`fl4->daddr`）算哈希——对流粘性已经够，且不依赖端口；要端口级分散才设 `fib_multipath_hash_policy=1`（四层，含源/目的端口+协议）或更高。设计目标是**同一条流走同一条路**（否则 TCP 乱序性能暴跌）、**不同流按权重比例分配**。调用点是 `fib_select_path()`（`fib_semantics.c:2209`）：它先看 `if (fl4->flowi4_oif)`——应用若 `bind()`/`sendmsg()` 硬性指定了出口设备，多路径就没意义，直接跳过走指定路；否则在多路径（`fib_info_num_path > 1`）时调 `fib_multipath_hash` + `fib_select_multipath`。

> **版本澄清**：老笔记说多路径用 `jiffies` 做随机种子，那是 2007 年前的老实现。现代内核用 `fib_multipath_hash` 的确定性哈希，保证流内一致性。另外别混淆两个历史删除：2007 年（2.6.23）删的是「多路径路由缓存」（实验性、效果差），2012 年（3.6）删的是「单播路由缓存」（多核同步开销）。现在多路径在 FIB 查找阶段直接完成，没缓存层，逻辑更清爽。多路径代码不像 ipmr.c 那样独立成文件，而是散在通用路由代码里、被大量 `#ifdef CONFIG_IP_ROUTE_MULTIPATH` 包着——它是路由查找的增强特性，不是独立子系统。

## 组播 vs 单播：关键区别

组播路由和单播路由最根本的差异在「建树」逻辑：

- **单播路由按目的建表**——给个目的地，查一个确定的下一跳。
- **组播路由按「组」建转发树**——同一组的不同源可能走不同树，所以 MFC 键是 `(S, G)` 或 `(*, G)`，且必须记 `mfc_parent`（入接口）。

这个「入接口」是 **RPF（Reverse Path Forwarding，反向路径转发）**的核心：组播包只在「从源到本机的最短路径」对应的接口上才被接受转发，从别的接口冒出来的直接判 Wrong VIF 丢掉。这就是 `ip_mr_forward()` 里 `vif_table[vif].dev != skb->dev` 那道关卡的本质——防环路、防重复泛滥。单播转发从不关心包从哪个接口进来，只关心去哪；组播必须双查（从哪来 + 去哪）。

## 动手验证（待亲测）

> ⚠️ 以下方案待 QEMU 亲测，输出是参考样例，跑过再替换成真实数据。

1. **加组播组、看本机成员表**：
   ```bash
   ip maddr add 239.1.1.1 dev eth0
   ip maddr show dev eth0
   ```
2. **tcpdump 抓 IGMP**：在另一终端开抓包，加组后应能看到 Membership Report：
   ```bash
   tcpdump -ni eth0 'igmp' -vv
   # 期望: IP 0.0.0.0 > 239.1.1.1: igmp report v2
   ```
3. **看内核参数**：`cat /proc/sys/net/ipv4/conf/all/mc_forwarding`（普通主机应为 0；跑起组播守护进程 `MRT_INIT` 后才翻 1）、`cat /proc/sys/net/ipv4/igmp_max_memberships`（默认 20）。
4. **多路径路由配置 + 哈希策略**：`ip route add default nexthop dev eth0 nexthop dev eth1` 后 `ip route show` 看是否生效（需内核 `CONFIG_IP_ROUTE_MULTIPATH=y`）；`cat /proc/sys/net/ipv4/fib_multipath_hash_policy` 看哈希策略（默认 `0`=三层，端口级分散要设成 `1`）。

## 小结

组播是「一对多」的高效投递：IGMP（`igmp.c`）管主机举手报名，`mr_table`（`mroute_base.h:246`）是调度中心——`mroute_sk` 串起用户空间守护进程、`vif_table` 管出口、`mfc_hash` 存转发决策。每个组播包经 `ip_route_input_mc`（在 `CONFIG_IP_MROUTE` + 非本地组播 + `IN_DEV_MFORWARD` 三条件齐备时）把 `dst.input` 改指向 `ip_mr_input`，查 MFC `(S,G)` 命中就 `ip_mr_forward` 按 `ttls[]` 阈值复制分发到各 VIF；发货分两步，`ipmr_prepare_xmit` 备货（查路由、隧道 IPIP 封装预留 `encap`、MTU+DF 沉默丢弃），`ipmr_queue_fwd_xmit` 打标过 Netfilter 发出（注意：6.19 里没有老资料说的 `ipmr_queue_xmit`，别照着找）。cache miss 有 3 包缓冲 + 10 秒超时的保护机制。组播按「组」建树 + RPF 入接口校验，是与单播「按目的建表」的根本区别。多路径路由（ECMP）则是单播侧的流量摊开——`fib_select_multipath` 按 `fib_multipath_hash_policy`（默认 `0` 只哈希源/目的 IP）算哈希、加权选路，同流同路、异流按权重分；现代实现优先走 `nexthop` 对象（`fib_info->nh`），老式 `fib_nh[]` 数组是兼容路径。

## 延伸阅读

- 源码（Linux 6.19）：`net/ipv4/ipmr.c`（组播路由核心，`ip_mr_input`/`ip_mr_forward`/`ipmr_prepare_xmit`/`ipmr_queue_fwd_xmit`/`ipmr_cache_unresolved`）、`net/ipv4/igmp.c`（IGMP，`igmp_rcv`/`igmp_heard_query`/`ip_mc_join_group`）、`include/linux/mroute_base.h`（`struct mr_table`、`struct mr_mfc`）、`include/linux/mroute.h`（`struct mfc_cache`）、`net/ipv4/fib_semantics.c`（`fib_select_multipath`/`fib_select_path`，多路径）、`net/ipv4/route.c:1742`（`ip_route_input_mc` 把 input 指向 `ip_mr_input`）、`net/ipv4/route.c:2073`（`fib_multipath_hash` 的 `hash_policy` 分支）。
- kernel.org 文档：[Networking — index](https://docs.kernel.org/networking/index.html)（网络子系统文档总索引，本站死链纪律下用它做入口）、[IP Sysctl](https://docs.kernel.org/networking/ip-sysctl.html)（含 `fib_multipath_hash_policy`/`fib_multipath_use_neigh` 等多路径参数，正好支撑正文）。
- 进一步（持续铺开）：策略路由（`ip rule`/`fib_rules.c`）、IPv6 MLD、PIM-SM 协议细节。

> 注：组播专用的 `docs.kernel.org/networking/multicast.html` 和 `routing.html` 在本核对时点（Linux 6.19.9 的 `Documentation/networking/` 下）**并不存在**（目录里既无 `multicast.*` 也无 `routing.*` rst 源），故未引用，改用真实存在的 index.html 和 ip-sysctl.html。发布前建议对每个外链再跑一次 HTTP 200 校验。