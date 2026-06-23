---
title: 邻居子系统与 ARP：IP 怎么找到 MAC
slug: net-neighbor
difficulty: intermediate
tags: [邻居子系统, ARP, NDISC, NUD 状态机]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/01-net-overview
related:
  - /tutorials/kernel/net/01-net-overview
sources:
  - notes: document/notes/linux_kernel_networking/ch07.md
  - notes: document/notes/linux_kernel_networking/ch07_1.md
  - notes: document/notes/linux_kernel_networking/ch07_2.md
  - notes: document/notes/linux_kernel_networking/ch07_3.md
  - notes: document/notes/linux_kernel_networking/ch07_4.md
  - notes: document/notes/linux_kernel_networking/ch07_5.md
---

# 邻居子系统与 ARP：IP 怎么找到 MAC

> 🔨 **整理中** · 这篇是从读书笔记（`ch07` 全章 + 四个子章）整理出来的骨架，邻居表、NUD 状态机、ARP/NDISC 数据通路都讲透了；但动手部分（QEMU 上 `ip neigh show` 看表、`arping` 抓请求应答、故意改 MAC 触发 STALE）还没亲手跑过。等我们在 QEMU 里验过，就升级成 ✅ 已锤炼。
>
> 本篇函数签名/字段/数值已对照 Linux 6.19 源码校订（读书笔记基于较早内核版本，部分接口已演进）；具体行号仍待 QEMU 亲测核对。

## 网络课没讲透的那一步：IP 撞上 MAC

我们 ping 一个 IP，路由表查完了，下一跳清清楚楚，可网卡偏偏就是不发包。它在等什么？等一个答案——那个 IP 对应的 MAC 地址到底是什么。

这就是邻居子系统存在的全部理由。**IP 是网络层（L3）的逻辑地址，方便我们规划网络；但网卡只认 MAC（L2），它根本不知道 IP 是什么东西。** 在最后那一跳，IP 地址其实毫无用处。内核必须把"下一跳 IP"翻译成"对端 MAC"，数据包才出得去网卡。

这道翻译由两个协议干：IPv4 用 **ARP**（1982 年的 RFC 826），IPv6 用 **NDISC**（RFC 4861）。它们名字不同、报文格式不同、严谨程度差着好几个量级，但内核里被同一套框架收编——**邻居子系统（neighbouring subsystem）**。这篇我们就拆这个黑盒子。

## 邻居表 `neigh_table`：IP→MAC 的缓存仓库

每个协议族一张表：IPv4 的是 `arp_tbl`，IPv6 的是 `nd_tbl`。两者结构几乎一模一样，核心定义分别在 `net/ipv4/arp.c` 和 `net/ipv6/ndisc.c`（Linux 6.19）。

每张表的关键成员：

- **哈希表**：邻居条目（`struct neighbour`）挂在哈希桶里，按 L3 地址（IPv4 是 4 字节 IP、IPv6 是 `struct in6_addr`）做 key 查找。条目多了会自动 `neigh_hash_grow()` 扩容。
- **`gc_thresh1/2/3`**：垃圾回收的三道闸，6.19 里 ARP 和 NDISC 默认都是 128 / 512 / 1024（`arp.c:181-183`、`ndisc.c:140-142`）。条目到 `gc_thresh3`（硬上限）还想新建，直接拒绝。
- **`constructor` 回调**：协议特定的构造函数，ARP 是 `arp_constructor()`、NDISC 是 `ndisc_constructor()`，负责填协议专属字段、挑 `neigh_ops` 操作集。

核心数据结构定义在 `include/net/neighbour.h`，三套源码分别躲在 `net/core/neighbour.c`（通用框架）、`net/ipv4/arp.c`、`net/ipv6/ndisc.c`。

## 创建一个邻居：先跟 GC 搏斗

入口是 `__neigh_create()`（签名见 `include/net/neighbour.h:346`）：拿到表 `tbl`、L3 关键字 `pkey`、出站网卡 `dev`、是否要引用计数 `want_ref`。它第一步就调 `neigh_alloc()`，而 `neigh_alloc()`（`neighbour.c:497`）一上来不是分内存，是先把**用于 GC 门控的条目计数** `atomic_inc_return(&tbl->gc_entries)` 拿在手里（`neighbour.c:508`），然后盯着阈值脸色行事：

```
gc_entries >= gc_thresh3
  OR (gc_entries >= gc_thresh2 且 距上次清理 > 5*HZ)
  → 触发同步 GC neigh_forced_gc()
     → 清完还 >= gc_thresh3 → 直接拒绝分配（out_entries）
```

这里有个 6.x 起拆出来的细节：**门控判定用的是 `gc_entries`，而 `tbl->entries`（条目总数）要等分配成功后才在 `neighbour.c:544` 递增**。两者不是一回事——GC 看的是"算上门槛预占"的那本账。

`neigh_forced_gc()` 是个暴力拆迁队：所有非 `NUD_PERMANENT`、引用计数为 1 的条目，统统标 `dead=1` 释放掉。分配完内存，还要调协议的 `constructor`（`neighbour.c:668`），它顺手处理两类**不需要 ARP** 的特殊地址：

- **多播**：`RTN_MULTICAST` 类型的地址（往 `224.0.0.1` 发包不问"你是谁"），直接 `arp_mc_map()` 算出多播 MAC 填进 `ha`，状态标 `NUD_NOARP`（`arp.c:269-271`）。
- **广播**：`RTN_BROADCAST`（`255.255.255.255` 这种）或点对点设备，把网卡广播地址 `dev->broadcast` 抄进 `ha`，同样 `NUD_NOARP`（`arp.c:275-278`）。

> IPv6 没有传统广播概念（`ff02::1` 等被归为多播），所以 `ndisc_constructor()` 里没有这段广播逻辑。

最后还有个反直觉的小细节：新条目的 `confirmed` 字段被设成**过去的时间**（`neighbour.c:688`，`jiffies - base_reachable_time*2`）。意思是"我虽然是新生的，但我现在就需要你验证我"——别让一个空壳子被当成可信的长期缓存。

## NUD 状态机：疑神疑鬼的守门人

邻居条目的核心是 `nud_state` 字段，这是一套状态机，内核靠它时刻怀疑"邻居是不是还活着"：

| 状态 | 含义 |
|:---|:---|
| `NUD_INCOMPLETE` | 刚建，MAC 还没解析出来 |
| `NUD_REACHABLE` | 最近确认过可达，直接发 |
| `NUD_STALE` | 有一阵没用过了，缓存可能过期 |
| `NUD_DELAY` | 用到了，先延迟一会儿 |
| `NUD_PROBE` | 真的开始发探测包验证 |
| `NUD_FAILED` | 验证失败，准备清掉 |
| `NUD_NOARP` | 多播/广播，不需要解析 |
| `NUD_PERMANENT` | 用户手动加的静态条目 |

典型流转：建表时 `INCOMPLETE` → 收到回应变 `REACHABLE` → 一段时间不用变 `STALE` → 下次发包触发 `DELAY` → 计时器到点进 `PROBE` → 探测成功回 `REACHABLE`，失败进 `FAILED`。

这种"信任但验证"是必须的——局域网里拔网线不需要打招呼，内核只能靠不停试探维持现实一致。每个邻居自带定时器，闹铃响了由 `neigh_timer_handler()` 推动状态流转。

## ARP 流程：内核不知 MAC 时怎么喊话

发包走 `ip_finish_output2()`（`net/ipv4/ip_output.c:200`）时，手里只有下一跳 IP。6.19 的代码已经不像老内核那样直接 `__ipv4_neigh_lookup_noref`/`__neigh_create` 一把梭，而是收敛进一个助手 `ip_neigh_for_gw()`，一把把邻居拿过来再交给 `neigh_output()`：

```c
/* net/ipv4/ip_output.c:230 */
rcu_read_lock();
neigh = ip_neigh_for_gw(rt, skb, &is_v6gw);   /* 网关邻居（IPv4/IPv6 网关都走这里） */
if (!IS_ERR(neigh)) {
    sock_confirm_neigh(skb, neigh);
    res = neigh_output(neigh, skb, is_v6gw);   /* 跨协议网关时不走 hh 缓存 */
    rcu_read_unlock();
    return res;
}
```

`ip_neigh_for_gw()`（`include/net/route.h:412`）根据路由里的网关族（`rt_gw_family` 是 IPv4 还是 IPv6）分别调 `ip_neigh_gw4()`/`ip_neigh_gw6()`，没设网关就把目标地址当直连。`is_v6gw` 这个布尔会一路传给 `neigh_output()` 当 `skip_cache`——跨协议（比如 IPv4 over IPv6 隧道网关）时不能复用缓存的 L2 头。

`neigh_output()`（`include/net/neighbour.h:543`）做关键判断：只有 `nud_state & NUD_CONNECTED` 且有缓存的 L2 头（`hh->hh_len` 非零）时才走快路径 `neigh_hh_output()`；否则调 `n->output`，ARP 这边指向 `neigh_resolve_output()`。

```c
/* include/net/neighbour.h:543 */
static inline int neigh_output(struct neighbour *n, struct sk_buff *skb,
                               bool skip_cache)
{
    const struct hh_cache *hh = &n->hh;
    if (!skip_cache &&
        (READ_ONCE(n->nud_state) & NUD_CONNECTED) &&
        READ_ONCE(hh->hh_len))
        return neigh_hh_output(hh, skb);
    return READ_ONCE(n->output)(n, skb);
}
```

> 老内核里这块用的是 `dst_neigh_output()`、声明在 `include/net/dst.h`，6.x 早已经迁走、全树搜不到 `dst_neigh_output`。如果你看的是更早的笔记/书（包括本站的 ch07_3），那里写的 `dst_neigh_output` 在 6.19 已是历史名字。

`neigh_resolve_output()` 干一件容易被忽略的事——**把数据包暂存到 `neigh->arp_queue` 队列里**。它调 `neigh_event_send()`，后者实际进 `__neigh_event_send()`（`neighbour.c:1200`）。这一次调用里**同时**做两件事：把 skb `__skb_queue_tail()` 进 `arp_queue`（`neighbour.c:1264`），并在状态允许时触发 `neigh_probe()`（`neighbour.c:1271`）去解析。也就是说"入队 + 触发解析"是同一拍完成的，但**解析结果回来、状态机往前推**是另一拍——后续由 `neigh_timer_handler()` 在定时器里推进，不是同步等来的。

`arp_queue` 有长度上限（按 `QUEUE_LEN_BYTES` 字节限流，`neighbour.c:1252`），解析一直不出来就持续往里塞，满了就 `__skb_dequeue()` 丢老的（`SKB_DROP_REASON_NEIGH_QUEUEFULL`）——表现为 ping 不通、但没报错，包在黑洞里消失。

`neigh_probe()` 调协议的 `solicit` 回调，ARP 就是 `arp_solicit()`。它干三件事：

1. **选源 IP**：受 sysctl `arp_announce`（`IN_DEV_ARP_ANNOUNCE`）控制——0 用任意本地地址、1 尽量同子网、2 只用主地址（`arp.c:349-370` 的 switch 注释原文如此）。
2. **单播 vs 广播**：若旧条目里还有 MAC 记录，先省着用单播探测（`UCAST_PROBES` 次），减少广播风暴；用完了才广播（`arp.c:376` 起的 `probes -= UCAST_PROBES` 判断）。
3. 调 `arp_send()` 把请求扔出去。

收包端 `arp_rcv()` 拦下以太网类型 `ETH_P_ARP`（`0x0806`）的帧，合法性检查后交给 `arp_process()`（`arp.c:702`）。这是 ARP 的大脑，要处理三种情况：发给本机的请求（要回 Reply）、发给本机的响应（更新表）、需要转发的请求（Proxy ARP）。

`arp_process()` 里有个很实用的机制叫**被动学习**：只要收到 ARP 包（不管请求还是响应），顺手把发送者（SHA+SIP）记进邻居表。好比有人敲门问路，你答他的同时把他的长相也记下了。还有一个 `locktime`（默认 `1*HZ`，`arp.c:177`）防飘移：短时间内（`jiffies - n->updated < LOCKTIME`）收到多个不同 Reply，只认第一个（`override` 标志的判定见 `arp.c:925-928`），免得被一串 proxy agent 的应答来回刷。

## ARP 包结构：八个小字段

ARP 报文头部是 `struct arphdr`（`include/uapi/linux/if_arp.h`）：

```c
struct arphdr {
    __be16        ar_hrd;   /* 硬件类型，以太网 0x01        */
    __be16        ar_pro;   /* 协议类型，IPv4 是 0x0800     */
    unsigned char ar_hln;   /* 硬件地址长度，MAC 是 6       */
    unsigned char ar_pln;   /* 协议地址长度，IPv4 是 4       */
    __be16        ar_op;    /* 操作码：1=请求, 2=应答        */
};
/* 紧跟在后面的变长字段（不属结构体，手动算偏移读）：
   SHA 发送方 MAC / SIP 发送方 IP / THA 目标 MAC / TIP 目标 IP */
```

关键就 `ar_op`：`ARPOP_REQUEST`(1) 是"谁有这个 IP"的喊话，`ARPOP_REPLY`(2) 是"我有，MAC 是 X"的举手。`arp_process()` 里因为 SHA/SIP/THA/TIP 不在结构体里，得用 `arp_ptr = (unsigned char *)(arp + 1)` 手动逐字段抠出来。

## 缓存老化与 GC：为什么不永久保留

如果邻居表永久保留，设备离线、网卡换 MAC、机器搬家之后，内核还死抱着一个失效的 MAC 不放，结果就是发包发出去没人收——网络黑洞。所以邻居条目必须能老化、能回收。

两条 GC 路径：同步暴力的 `neigh_forced_gc()`（`neighbour.c:254`，分配时 `gc_entries` 满了触发，踢掉非永久条目）；异步温和的 `neigh_periodic_work()`（`neighbour.c:976`，由 `tbl->gc_work` 周期性调度，清过期条目）。配合 `NUD` 状态机，内核做到了"最近用过的留、太久没用的过期、空间紧张时优先牺牲陈旧的"。统计可以看 `/proc/net/stat/arp_cache` 和 `/proc/net/stat/ndisc_cache`。

## NDISC：IPv6 用 NS/NA 替掉广播

ARP 太糙——没有验证，谁都能喊"我是网关"（ARP 欺骗）。IPv6 换成 NDISC，走 ICMPv6（类型 133-137），其中跟地址解析对应的是 **NS（邻居请求，135）** 和 **NA（邻居通告，136）**，RS/RA/Redirect 留给路由那章讲。

最大的区别：**NDISC 不广播，改用组播**。问"谁有 IP X"，不是全局域网喊，而是发到 X 对应的 Solicited-Node 组播地址（`addrconf_addr_solict_mult()` 算出来），只有 X 的主人会被叫醒。

发送路径 `ip6_finish_output2()`（`net/ipv6/ip6_output.c:120` 起）和 IPv4 不太一样，6.19 里它**仍然直接调** `__ipv6_neigh_lookup_noref()`/`__neigh_create(&nd_tbl,...)`/`neigh_output()`（没有像 IPv4 那样收进一个 `ip_neigh_for_gw`）：

```c
/* net/ipv6/ip6_output.c:124-136 */
neigh = __ipv6_neigh_lookup_noref(dev, nexthop);
if (IS_ERR_OR_NULL(neigh)) {
    if (unlikely(!neigh))
        neigh = __neigh_create(&nd_tbl, nexthop, dev, false);
    ...
}
sock_confirm_neigh(skb, neigh);
ret = neigh_output(neigh, skb, false);   /* IPv6 这里固定 skip_cache=false */
```

`ndisc_solicit()` 也是先试单播（有旧记录）、用完再组播。接收走 `icmpv6_rcv()` → `ndisc_rcv()`（`ndisc.c:1801`）→ 分发 `ndisc_recv_ns()` / `ndisc_recv_na()`。

NDISC 比 ARP 严谨的地方，全在细节里：

- **Hop Limit 必须 255**：`ndisc_rcv()` 开头就查（`ndisc.c:1816`，`ipv6_hdr(skb)->hop_limit != 255` 直接丢）。255 意味着包没经任何路由器转发、来自同链路，挡住了远程伪造。
- **NA 三个 flag**（在 `icmp6hdr` 联合体里，定义见 `include/uapi/linux/icmpv6.h:72-74`）：`Router`（我是路由器）、`Solicited`（我是应你请求而来，收到方置 `NUD_REACHABLE`）、`Override`（不管你缓存是啥，以我为准）。
- **强制 DAD**：配 IPv6 地址前必须问"这地址有人用了吗"（发源地址为 `::` 的 NS），没人回才从 `IFA_F_TENTATIVE` 转 `IFA_F_PERMANENT`。`arping -D` 那套在 IPv4 只是可选，IPv6 是强制的。
- **Optimistic DAD**（`CONFIG_IPV6_OPTIMISTIC_DAD`）：DAD 要等，怕卡？RFC 4429 允许先标 `IFA_F_OPTIMISTIC` 顶着用，事后冲突再撤——"先用后付"。

## 动手：等 QEMU 亲测

验证方案（待亲测核对真实输出）：

```
# 1. 看邻居表（新派，带 NUD 状态）
ip neigh show
ip -6 neigh show

# 2. 看邻居表（老派，只 IPv4）
arp -n
cat /proc/net/arp

# 3. 抓 ARP 请求/应答的来回
arping <对端 IP>

# 4. 手动加一条静态邻居，观察 NUD_PERMANENT 不被 GC
ip neigh add 192.168.0.121 dev eth0 lladdr 00:30:48:5b:cc:45 nud permanent

# 5. 故意改对端 MAC，观察条目从 REACHABLE → STALE → 重新探测
```

> ⚠️ **待亲测**：上面命令是整理时的方案清单。我们会在 QEMU 两节点网络里实跑一遍，重点记下 `ip neigh show` 输出里 `REACHABLE/STALE/DELAY` 状态随时间的真实变化，以及 `arping` 抓到的请求/应答报文——把 NUD 状态机亲眼看到。

## 小结

邻居子系统是 L3 到 L2 的翻译层：每协议一张 `neigh_table`（`arp_tbl` / `nd_tbl`）缓存 IP→MAC，靠 `NUD` 状态机（INCOMPLETE→REACHABLE→STALE→DELAY→PROBE）做"信任但验证"，靠两套 GC（同步 `neigh_forced_gc` + 异步 `neigh_periodic_work`）控制表规模。6.19 的 IPv4 出口路径把"查/建邻居"收进了 `ip_neigh_for_gw()`，出口统一过 `neigh_output()`；IPv6 路径仍直接调 `__ipv6_neigh_lookup_noref`/`__neigh_create`/`neigh_output`。IPv4 用 ARP 广播喊话+被动学习填表，IPv6 用 NDISC 组播 NS/NA，外加 Hop Limit 255、三个 NA flag、强制 DAD，把 ARP 那套简单粗暴升级成严密得多的协议。

记三件事：**`arp_queue` 满了会静默丢包**（ping 不通无报错）、**`gc_thresh3` 是硬上限**（满了直接拒新连接）、**ARP 是喊话、NDISC 是点名+验证**。

## 延伸阅读

- 源码（Linux 6.19）：通用框架 `net/core/neighbour.c` + `include/net/neighbour.h`；IPv4 ARP `net/ipv4/arp.c` + `include/net/arp.h` + `include/uapi/linux/if_arp.h`；IPv4 出口路径 `net/ipv4/ip_output.c` + `ip_neigh_for_gw()` 在 `include/net/route.h`；IPv6 NDISC `net/ipv6/ndisc.c` + `include/net/ndisc.h`，IPv6 出口 `net/ipv6/ip6_output.c`。
- 内核文档：[Networking — kernel.org core index](https://docs.kernel.org/networking/index.html)（找 ARP / Neighbor / IPv6 相关条目）。
- 进一步（持续铺开）：路由子系统（下一跳决策）、ICMPv6、IPv6 自动配置与 RA。