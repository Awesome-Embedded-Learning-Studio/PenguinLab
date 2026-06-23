---
title: IPv4 协议层：包的接收与发送
slug: net-ipv4
difficulty: intermediate
tags: [网络栈, IPv4, 协议注册, 分片重组]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/01-net-overview
related:
  - /tutorials/kernel/net/01-net-overview
  - /tutorials/kernel/net/02-net-sk-buff
sources:
  - notes: document/notes/linux_kernel_networking/ch04.md
---

# IPv4 协议层：包的接收与发送

> 🔨 **整理中** · 这篇是从读书笔记 `ch04`（4.1 头部与协议注册、4.2 接收 `ip_rcv`、4.5 发送 `ip_queue_xmit`、4.6/4.7 分片重组、4.8 转发）提炼出来的骨架，IPv4 包怎么进、怎么发、怎么切的机制讲透了。本篇函数签名/字段/数值已对照 Linux 6.19 源码校订（读书笔记基于较早内核版本，部分接口已演进）；具体行号仍待 QEMU 亲测核对。但动手部分——`tcpdump` 抓 IP 头逐字段、改 TTL 看转发与 ICMP、在 QEMU 上 `cat /proc/net/snmp` 看计数器跳动——还没亲手跑过。等我们在 QEMU 双机环境里验过，就升级成 ✅ 已锤炼。

## IP 层到底是干嘛的

上一篇我们站在了网络栈的全景上。现在要钻进其中一层——**IPv4 协议层**，把这一层彻底拆开看。

先说 IP 层的定位，方便脑子里有个"最终样子"：把链路层（以太网那些）和传输层（TCP/UDP）连起来的中间人。它干三件事：**接收**（收上来的包，校验、判定是给我还是让我转发）、**发送**（传输层要往外发，给它套上 IP 头、查好路由送出去）、**分片重组**（包太大就切，到了对面再拼）。转发（当路由器）可以理解为"接收 + 发送"的合体，只不过目的地不是本机。

这一层所有操作，在内核眼里就是折腾一个东西——`struct iphdr`，也就是 IPv4 头部。我们从这张"脸"开始解剖。

## IPv4 头部逐字段：那张最熟悉的脸

IPv4 头部是网络层最核心的数据结构，内核里抽象成 `struct iphdr`，定义在 `include/uapi/linux/ip.h`（Linux 6.19）。最小 20 字节、最大 60 字节（带选项），按 4 字节为单位计数。逐个字段过一遍：

- **version / ihl**：挤在一个字节里，还得看字节序（大端小端排布不同）。`version` 必须是 4，不是 4 直接扔。`ihl`（Internet Header Length）是头部长度，但**单位是 4 字节不是字节**——所以 20 字节头部 `ihl=5`，最大 `ihl=15`（60 字节）。这个"单位是 4 字节"的坑后面在 `ip_queue_xmit` 里还会再踩一次。
- **tos**：8 位，历史上被反复"再利用"。最初（RFC 791）是 QoS"加急章"，后来前 6 位重定义为 **DSCP**（差分服务），最后 2 位拿来做 **ECN**（显式拥塞通知）——路由器拥塞时不丢包而是标这一位，告诉收方"慢点发"。
- **tot_len**：整个 IP 包（头+数据）长度，16 位，最大 64KB。注意以太网 MTU 通常 1500，超了就得切，但 `tot_len` 记的是切片前的总长，接收端靠它判断重组是否完成。
- **id**：16 位标识。一个包被切成多片时，所有片共享同一个 `id`，对面重组就靠它认亲。
- **frag_off**：16 位里塞了两样东西——**高 3 位是标志**，**低 13 位是偏移量**（单位是 8 字节，不是字节）。这里口径容易绕晕，两套说法并列记最稳：
  - **逻辑位**（按 `frag_off` 高 3 位排）：MF（还有片）= `0b001`、DF（别切我）= `0b010`、CE（拥塞）= `0b100`；
  - **网络字节序字段值**（`include/net/ip.h`，6.19 line 142-145）：`IP_MF=0x2000`、`IP_DF=0x4000`、`IP_CE=0x8000`、`IP_OFFSET=0x1FFF`。
  - 抓包看到 `frag_off=8192` 别以为偏移很大，`8192=0x2000=IP_MF`，表示"后面还有分片"；要看 DF 得认 `0x4000=16384`。看分片偏移必须做掩码剥离高 3 位（`& htons(IP_OFFSET)`）。
- **ttl**：生存时间，每过一跳减 1，归零销毁，防路由环路死包。`traceroute` 就靠故意递增 TTL 触发 `Time Exceeded` 来探路径。
- **protocol**：告诉内核肚子里装啥——`IPPROTO_TCP`(6)、`IPPROTO_UDP`(17)、`IPPROTO_ICMP`(1) 等，定义在 `include/uapi/linux/in.h`（注意是 `uapi` 那份，`include/linux/in.h` 里只是几个 inline case，不含 `#define`）。
- **check**：**只校验头部**的校验和，错一个比特就丢。因为 TTL 每跳都变，路由器转发必须重算校验和（后面会讲内核用增量技巧，不用遍历整头）。
- **saddr / daddr**：32 位源/目的地址，路由的核心依据。

> 源码引用：`include/uapi/linux/ip.h` 看 `struct iphdr`；标志位字段值宏 `IP_DF/IP_MF/IP_CE/IP_OFFSET` 在 `include/net/ip.h`（6.19 line 142-145）。行号待亲测核对。

## 协议注册：内核怎么认领 IP 包

回到一个更基础的问题：网卡收上来一个帧，内核怎么知道它是 IPv4 而不是 ARP 或 IPv6？

答案在以太网头的 `type` 字段——IPv4 是 `0x0800`。内核需要把"0x0800"和"IPv4 处理函数"绑起来，这就是 `ip_packet_type` 干的事，定义在 `net/ipv4/af_inet.c`（Linux 6.19）：

```c
static struct packet_type ip_packet_type __read_mostly = {
    .type = cpu_to_be16(ETH_P_IP),  // 0x0800
    .func = ip_rcv,                 // 处理函数指针
};
```

在 IPv4 协议栈初始化 `inet_init()` 里，`dev_add_pack(&ip_packet_type)` 把它挂到内核全局的协议处理哈希表（`ptype_base`）上。从此每个进来的包，内核瞄一眼以太网类型，是 `0x0800` 就调 `.func`——也就是 `ip_rcv()`。这就是 IPv4 故事的起点：**`ip_rcv` 是 IPv4 王国的"海关"**。

至于肚子里装的是 TCP 还是 UDP，那要等后面到了传输层，靠 `protocol` 字段查 `inet_protos` 表再分发——这是另一张注册表，本篇先不展开，详见后续 TCP/UDP 章节。

## 接收路径 ip_rcv：看门人 + 路由判定

进了 `ip_rcv`，直觉以为它负责拆包送上层，**恰恰相反**——它更像**看门人**，只关心"这是不是合法 IPv4 包"，真正的活交给下一棒。函数本身在 6.19 里瘦得只剩骨架：先调 `ip_rcv_core()` 做 sanity check，再过一个 Netfilter 钩子。两个函数中间夹着 `NF_INET_PRE_ROUTING`（源码在 `net/ipv4/ip_input.c`，行号待亲测核对）：

1. **头部格式**（在 `ip_rcv_core` 里）：`iph = ip_hdr(skb)`，查 `iph->ihl < 5 || iph->version != 4` 直接 `goto drop`，计 `IPSTATS_MIB_INHDRERRORS`。
2. **校验和**（同在 `ip_rcv_core`）：`ip_fast_csum()` 只算头部，失败同样丢弃（RFC 1122 要求默默丢，不发错误包）。
3. **放行关卡**（`ip_rcv` 里）：`NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING, ...)`——这是 `NF_INET_PRE_ROUTING` 钩子点（包刚进栈、还没路由判定前）。iptables/nf_conntrack 就插在这里。返回 `NF_DROP` 包就没了，`NF_STOLEN` 被钩子"偷走"，`NF_ACCEPT` 才继续调 `ip_rcv_finish`。

过了海关，`ip_rcv_finish`（6.19 里是层薄壳）把真正的路由查找活儿派给 `ip_rcv_finish_core()`：若 SKB 上还没挂路由结果，调 `ip_route_input_noref()` 拿目的地址、源地址、**DSCP（由 `tos` 高 6 位派生，6.19 传的是 `ip4h_dscp(iph)` 而非裸 `tos`）** 去查表。查完给 SKB 绑一个 `dst` 对象，关键是 `dst->input` 这个回调函数指针——**路由表查的是"数据"，返回的却是"代码"**，C 语言多态的经典用法：

- 发给本机 → `dst->input = ip_local_deliver`（送上去给传输层，顺带处理分片重组）；
- 要转发 → `dst->input = ip_forward`（帮它送去隔壁）；
- 组播 → `ip_mr_input`。

最后 `dst_input(skb)` 就是执行那个函数指针。中途还有个 **RPF（反向路径过滤）**：进来和回去的接口不一致，怀疑伪造源地址，丢掉——在 6.19 里这表现为路由层返回 `SKB_DROP_REASON_IP_RPFILTER` 这个 drop reason（早期内核用错误码 `-EXDEV`，6.19 已改成 drop reason 体系），命中就计 `LINUX_MIB_IPRPFILTER`。顺带一提，`ihl > 5` 时还会调 `ip_rcv_options()` 处理 IP 选项。

## 发送路径 ip_queue_xmit：查路由 → 套头 → 送出

把角色反过来——传输层要往外发包，IP 层怎么打包。发送主要两条路（源码在 `net/ipv4/ip_output.c`，行号待亲测核对）：

- **操心型的 TCP** 走 `ip_queue_xmit()`：TCP 自己管分段，不希望 IP 插手。
- **甩手掌柜型的 UDP/ICMP** 走 `ip_append_data()` + `ip_push_pending_frames()`：把数据塞 `sk_write_queue` 队列，再触发发送（2.6.39 后 UDP 又有 `ip_make_skb()` 的无锁快速通道）。Raw Socket 带 `IP_HDRINCL` 时连这条路都不走，直接 `raw_send_hdrinc()` 丢给 `LOCAL_OUT` 钩子——这就是 `ping -t 128` 能手改 TTL 的原因，头根本不是内核造的。

重点看 `ip_queue_xmit`（TCP 主场）。它一上来先解决"发往哪"：`__sk_dst_check()` 查路由缓存，没缓存就构造 `flowi4`、调 `ip_route_output_flow()` 查表（6.19 实际调的是 `_flow` 这层；`ip_route_output_ports()` 是 route.h 里再包一层的 inline，最终还是走 `ip_route_output_flow`）；失败 `goto no_route` 返回 `-EHOSTUNREACH`，靠 TCP 重传。有个隐蔽坑——同时开严格源路由（SSRR）和网关会自相矛盾，直接拒绝。

路由搞定后装箱：`skb_push()` 往前腾 IP 头位置，填字段。有一行看着晕的位运算 `htons((4 << 12) | (5 << 8) | (tos & 0xff))` 一次性把 version+ihl+tos 塞进前 16 位。DF 标志靠 `ip_dont_fragment()` 判断写进 `frag_off`。**关键的 ihl 坑又来了**：有 IP 选项时 `iph->ihl += inet_opt->opt.optlen >> 2`——因为 ihl 单位是 4 字节，选项 20 字节右移 2 位得 5，加基础 5 成 10（头部 40 字节）。最后 `ip_select_ident_segs()` 选包 ID（6.19；旧内核笔记里写的 `ip_select_ident_more` 已不存在，重命名为 `ip_select_ident_segs`，按 GSO 段数 `gso_segs ?: 1` 选）、`ip_local_out()` 送出门。

## 分片与重组：路太窄怎么办

以太网 MTU 通常 1500，但 IP 包能到 64KB。超了怎么办？两条路：要么发 ICMP "Fragmentation Needed" 劝对方切小（PMTU Discovery），要么自己 `ip_fragment()` 切碎（`net/ipv4/ip_output.c`，行号待亲测核对）。注意 6.19 的 `ip_fragment()` 一进来先看 DF：没设 DF 才走 `ip_do_fragment()` 切；设了 DF 又超 MTU，内核**不切**，直接 `icmp_send()` 扔回 `ICMP_FRAG_NEEDED` 然后 `kfree_skb`。这解释了为啥防火墙禁掉 ICMP 大包就发不出去：内核想告诉你"路太窄"，你把它嘴堵了。

真正切分有快慢两条路。**快路径**：SKB 的 `frag_list` 已挂好预切片（GSO/UDP 来的），只需给每节贴新 IP 头、设偏移（`offset>>3`，单位 8 字节）、打 `IP_MF` 标志、重算校验和，**不拷数据**。**慢路径**：手里一个大块 SKB，得 `alloc_skb`+`skb_copy_bits` 一片片割，`len &= ~7` 强制 8 字节对齐。慢路径里 `GFP_ATOMIC` 分配（可能持锁不能睡）、`skb_set_owner_w` 把内存算在 Socket 头上防 DoS，都是工程细节。

重组是 `ip_fragment` 的逆运算，在 `ip_local_deliver()` 里触发（`net/ipv4/ip_fragment.c`，行号待亲测核对）。`ip_is_fragment()` 判断是不是碎片——只要 MF 或偏移量任一非零就是。重组靠**四维坐标**（id、saddr、daddr、protocol，外加 user/vif 辅助位）算哈希找归属队列。在 6.19 里这套坐标被收进一个 key 结构 `frag_v4_compare_key`（`include/net/inet_frag.h`，含 saddr/daddr/user/vif/id/protocol），挂在 `struct ipq` 内嵌的 `inet_frag_queue.q.key.v4` 上——所以别再按旧内核去 `struct ipq` 里找 saddr/daddr 这些成员了，6.19 的 `ipq` 只剩 `ecn`/`max_df_size`/`iif`/`rid`/`peer` 几个重组状态字段（这套 `inet_frag_queue` 框架 IPv6 也在共用）。`ip_defrag()` 先 `ip_evictor()` 扫地（内存紧了踢老队列），再 `ip_find()` 找/建队列，`ip_frag_queue()` 处理乱序和重叠插入，最后 `meat == len` 且收到最后一片就 `ip_frag_reasm()` 拼回整包（超 65535 直接丢）。每个队列默认 30 秒超时（`IP_FRAG_TIME = 30 * HZ`，`/proc/sys/net/ipv4/ipfrag_time` 可调），防 Teardrop 那种恶意重叠碎片的资源耗尽攻击。

## 转发 ip_forward：接收+发送的合体

当路由判定"这货不是给我的"，`dst->input` 就是 `ip_forward()`（`net/ipv4/ip_forward.c`，行号待亲测核对）。转发路径检查一长串，**顺序以 6.19 源码为准**：

- **pkt_type 检查**（第一关）：不是 `PACKET_HOST` 直接 `goto drop`——本来就不该交给我转发。
- **本地生成包拦截**：`unlikely(skb->sk)` 非空就丢——本机自己生成往外发的包不走转发路径，这是笔记里漏掉的一道。
- **拦 LRO**：`skb_warn_if_lro(skb)` goto drop——LRO 合并的大包转发时出口 MTU 装不下又拆不干净，GRO 才考虑了转发。
- **xfrm4 策略检查**：`xfrm4_policy_check(NULL, XFRM_POLICY_FWD, skb)`——IPsec 策略过滤，不通过就丢（笔记也没提）。
- **Router Alert**：`IPCB(skb)->opt.router_alert` 且 `ip_call_ra_chain()` 把带 `IPOPT_RA` 的包喂给挂在 `ip_ra_chain` 上的 Raw Socket。
- **TTL 审判**：`ttl <= 1` goto `too_many_hops`，发 `ICMP_TIME_EXCEEDED`。
- **严格源路由 vs 网关**：`is_strictroute && rt_uses_gateway` 冲突 goto `sr_failed`，发 `ICMP_SR_FAILED`。
- **MTU + DF 进退两难**：`ip_exceeds_mtu()` 命中发 `ICMP_FRAG_NEEDED`（PMTUD 核心）；但 `skb_is_gso()` 且 GSO 段长度能过 MTU 的包放过（还没真正分片）。

挺过检查后 `skb_cow()` 做 COW 副本（要改头了），`ip_decrease_ttl()` 减 1 并用 RFC 1624 增量技巧更新校验和（只改一字节不必遍历整头）；若 `IPCB(skb)->flags & IPSKB_DOREDIRECT` 且非源路由、非 IPsec 路径，就 `ip_rt_send_redirect()` 发 ICMP Redirect；`sysctl_ip_fwd_update_priority` 打开时 `skb->priority = rt_tos2priority(iph->tos)`（转发的包没 Socket，按 tos 查表定优先级），最后过 `NF_INET_FORWARD` 钩子（防火墙最常拦的点）进 `ip_forward_finish()`，`dst_output()` 送入发送路径。

## 与邻居/路由的衔接

这一篇反复出现"查路由""下一跳"，得把 IP 层和邻居子系统的衔接点钉死：**IP 层只决定"下一跳的 IP 是谁"**（查路由表拿到 `rt->dst`），但光有下一跳 IP 没法封装以太网帧——还得知道这个 IP 对应哪个 MAC。把下一跳 IP 翻译成 MAC 是**邻居子系统（ARP/邻居表）**的活，这一步发生在 IP 层把包往下送、进链路层之前。换句话说：IP 层管"逻辑路径"（下一跳 IP），邻居子系统管"物理寻址"（MAC）。这块单独成篇（邻居/ARP），这里先埋个伏笔。

## 动手待亲测（QEMU 双机环境）

> ⚠️ 以下方案还没在 QEMU 上亲手跑过，等亲测后再把真实输出补进正文。

1. **抓 IP 头逐字段**：QEMU 双机间 ping，主机上 `tcpdump -i tap0 -x -nn icmp` 抓一个包，逐字节对照 `struct iphdr`——验证 `ihl=5`、`protocol=1`（ICMP）、TTL、校验和。
2. **改 TTL 看转发与 ICMP**：把其中一台 QEMU 当路由器（`echo 1 > /proc/sys/net/ipv4/ip_forward`），另一台发 `ping -t 1`，应触发 `ICMP_TIME_EXCEEDED`；用 `tcpdump` 同时看 ICMP 报错。对照 `/proc/net/snmp` 里 `InHdrErrors`、`OutForwDatagrams`、`FragFails` 等计数器跳动。
3. **分片观察**：`ping -s 3000` 打超 MTU 的大包，`tcpdump` 应看到多个带相同 `id`、`IP_MF` 标志（注意是 `0x2000` 不是 `0x4000`）、偏移量递增的分片；改抓 DF 行为可对照 `FragCreates`/`FragOks`。

真实命令输出待亲测核对。

## 小结

IPv4 层是链路层和传输层之间的中间人，核心就是折腾 `struct iphdr`。接收上 `ip_rcv` 是看门人（`ip_rcv_core` 三步 sanity check + PRE_ROUTING 钩子），`ip_rcv_finish`/`ip_rcv_finish_core` 查路由决定本机收（`ip_local_deliver`）还是转发（`ip_forward`）；发送上 TCP 走 `ip_queue_xmit`（查路由→套头→`ip_local_out`），UDP 走 `ip_append_data` 攒包路径。包超 MTU 时 `ip_fragment`/`ip_do_fragment` 快慢两路切、`ip_defrag` 靠四维坐标拼回，转发路径则要在 TTL、MTU、DF、LRO、xfrm 之间做一堆生死判断。记住一条主线：**IP 层只决定下一跳 IP，MAC 交给邻居子系统**。

## 延伸阅读

- 源码：`net/ipv4/ip_input.c`（`ip_rcv`/`ip_rcv_core`/`ip_rcv_finish`/`ip_rcv_finish_core`/`ip_local_deliver`）、`net/ipv4/ip_output.c`（`ip_queue_xmit`/`ip_fragment`/`ip_do_fragment`/`ip_local_out`）、`net/ipv4/ip_fragment.c`（`ip_defrag`/`ip_frag_queue`/`ip_find`）、`net/ipv4/ip_forward.c`（`ip_forward`）、`net/ipv4/af_inet.c`（`ip_packet_type` 注册）、`include/uapi/linux/ip.h`（`struct iphdr`）、`include/net/ip.h`（`IP_DF/IP_MF/IP_CE/IP_OFFSET` 字段值、`IP_FRAG_TIME`）、`include/net/inet_frag.h`（`frag_v4_compare_key`）——均 Linux 6.19，行号待亲测核对。
- kernel.org 文档：[Networking documentation index](https://docs.kernel.org/networking/index.html)（找 IPv4/分片/路由相关稳定索引页）。
- 进一步（持续铺开）：IPv4 路由子系统（`fib`/路由缓存）、邻居与 ARP、TCP/UDP 传输层发送路径、Netfilter 与 `nf_hook` 机制。