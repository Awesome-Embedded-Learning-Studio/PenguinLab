---
title: ICMP：网络的诊断与控制协议
slug: net-icmp
difficulty: intermediate
tags: [ICMP, 网络栈, 邻居发现, PMTU]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
related:
  - /tutorials/kernel/net/04-net-ipv4
sources:
  - notes: document/notes/linux_kernel_networking/ch03.md
  - notes: document/notes/linux_kernel_networking/ch03_1.md
  - notes: document/notes/linux_kernel_networking/ch03_2.md
  - notes: document/notes/linux_kernel_networking/ch03_3.md
---

# ICMP：网络的诊断与控制协议

> 🔨 **整理中** · 这篇是从读书笔记（linux_kernel_networking/ch03）整理出来的骨架，本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。等我们在 QEMU 里 `tcpdump` 抓过 echo、跑过 traceroute，就升级成 ✅ 已锤炼。

## ICMP 到底是干嘛的：IP 层的维保工

IP 协议是"尽力而为"——它只管把包扔出去，不管有没有人收、走的路对不对。如果没有任何反馈机制，整个互联网就是一个丢包了也没人知道的黑盒。ICMP（Internet Control Message Protocol）就是给这个黑盒装的"神经系统"，专门传错误报告和诊断信息。

我们天天用的 `ping` 和 `traceroute` 底层全是它。但记住一点：这篇讲的不是这两个工具怎么用，而是**内核收到一个 ICMP 包之后到底干了什么**——`icmp_rcv` 怎么收、`__icmp_send` 怎么发、查哪张表分发到哪个 handler。每个机制都对着源码讲。

## ICMPv4：收发两条主干道

ICMP 是 IP 层的协议，协议号是 1（`IPPROTO_ICMP`）。它和 TCP/UDP 一样要往内核协议分发表里注册一个处理器：

```c
static const struct net_protocol icmp_protocol = {
    .handler        = icmp_rcv,
    .err_handler    = icmp_err,
    .no_policy      = 1,
};
```

（结构体定义在 `net/ipv4/af_inet.c`，Linux 6.19）。当 IP 层剥完 IP 头发现协议字段是 1，就跳到 `icmp_rcv`。`no_policy = 1` 是个优化——在 `ip_local_deliver_finish()` 里看到这标志会跳过 IPsec 策略检查，因为对 ICMP 这种控制消息，安全策略通常不是首要矛盾。

发方向上有个反直觉的设计：**内核给每个 CPU 单独建了一个 Raw Socket 用来发 ICMP**。看 `net/ipv4/icmp.c` 的 `icmp_init()`：

```c
for_each_possible_cpu(i) {
    err = inet_ctl_sock_create(&sk, PF_INET,
                               SOCK_RAW, IPPROTO_ICMP, &init_net);
    ...
    per_cpu(ipv4_icmp_sk, i) = sk;
    ...
    inet_sk(sk)->pmtudisc = IP_PMTUDISC_DONT;
}
```

6.19 里这块 socket 数组是 `static DEFINE_PER_CPU(struct sock *, ipv4_icmp_sk)`，不再是老的 `net->ipv4.icmp_sk[i]`（那是基于老旧书籍笔记的说法，源码已经变了，咱们以源码为准）。为什么要 per-CPU？因为多核下所有 CPU 抢一个 socket 发包，锁竞争会爆炸。每个 CPU 用自己的 socket，谁发的谁排队，互不干扰。`pmtudisc = IP_PMTUDISC_DONT` 关掉 PMTU 发现——错误报告要尽量送达，不能因为 MTU 问题被分片或丢弃。

> 注意名字坑：6.19 里**创建 socket 的是 `icmp_init()`**，而 `icmp_sk_init()` 只负责初始化一堆 sysctl 默认值（`icmp_ratelimit`、`icmp_ratemask` 等）。老笔记把这俩混着讲，我们这次照源码拆开了。

## 报文头部：`struct icmphdr`

每个 ICMP 包头部是同一副骨架（`include/uapi/linux/icmp.h`）：8 位 type、8 位 code、16 位 checksum，外加一个 32 位"可变部分"——内容随类型变：

```c
struct icmphdr {
    __u8      type;
    __u8      code;
    __sum16   checksum;
    union {
        struct { __be16 id; __be16 sequence; } echo;
        __be32  gateway;
        struct { __be16 __unused; __be16 mtu; } frag;
    } un;
};
```

错误消息后面通常还跟一截"罪魁祸首"原始包的 IP 头和载荷。RFC 1812 要求整个 ICMP 错误报文总长不超过 576 字节（IPv4 最小 MTU），保证任何设备都处理得了。代码里这截体现在 `__icmp_send` 里的 `room` 计算（见后文）。

`include/linux/icmp.h` 还有个好用的辅助 `icmp_is_err(int type)`，它用一个 `switch` 把五种错误类型（`ICMP_DEST_UNREACH`/`ICMP_SOURCE_QUENCH`/`ICMP_REDIRECT`/`ICMP_TIME_EXCEEDED`/`ICMP_PARAMETERPROB`）判出来——ICMPv4 没有"最高位区分错误/信息"这种简单规则，得逐个枚举。

## 一个 ping 的旅程：echo request → echo reply

ping 程序做的事很简单：发一个 `ICMP_ECHO`（type 8）请求，等对端回 `ICMP_ECHOREPLY`（type 0）。对端内核收到后走 `icmp_rcv`，最终命中 `icmp_echo` handler，它把 type 从 ECHO 翻成 ECHOREPLY 再 `icmp_reply` 发回去：

```c
static enum skb_drop_reason icmp_echo(struct sk_buff *skb)
{
    ...
    if (READ_ONCE(net->ipv4.sysctl_icmp_echo_ignore_all))
        return SKB_NOT_DROPPED_YET;        /* "隐身模式"：直接不理 */
    ...
    if (icmp_param.data.icmph.type == ICMP_ECHO)
        icmp_param.data.icmph.type = ICMP_ECHOREPLY;    /* 翻转 type */
    ...
    icmp_reply(&icmp_param, skb);
    return SKB_NOT_DROPPED_YET;
}
```

`sysctl_icmp_echo_ignore_all` 写 1 就是"隐身"——收到 ping 也不回，但这只代表不响应 echo，不代表主机真的不可达。`icmp_rcv` 在分发前还有几道安检：先 `__ICMP_INC_STATS(net, ICMP_MIB_INMSGS)` 计数，再 `skb_checksum_simple_validate(skb)` 校验和，错了就跳到 `csum_error` 分支静默丢弃（`icmp_rcv` 永远不返回负值——返回负值会让 `ip_local_deliver_finish` 尝试重处理，对一个坏掉的 ICMP 包纯属浪费）。还有一个广播/组播抑制：`sysctl_icmp_echo_ignore_broadcasts`（默认 1），防止有人 ping 广播地址触发全网响应的风暴。

有意思的是 echo reply 的处理：6.19 里 `icmp_rcv` 没走 `icmp_pointers` 分发表，而是单独拎出来直接调 `ping_rcv(skb)`（`net/ipv4/ping.c`，双栈文件，IPv6 的 echo reply 也走这里）。这是因为 ICMP Sockets 机制让非 root 用户也能发 ping，回来的 reply 没法匹配到传统 Raw Socket，得专门处理。

## `icmp_pointers`：一张分发表

收到的包该给谁处理？查表。`net/ipv4/icmp.c` 里定义了：

```c
struct icmp_control {
    enum skb_drop_reason (*handler)(struct sk_buff *skb);
    short error;      /* 该类型是否归类为错误消息 */
};

static const struct icmp_control icmp_pointers[NR_ICMP_TYPES + 1] = {
    [ICMP_ECHOREPLY]    = { .handler = ping_rcv },
    [ICMP_DEST_UNREACH] = { .handler = icmp_unreach, .error = 1 },
    [ICMP_REDIRECT]     = { .handler = icmp_redirect, .error = 1 },
    [ICMP_ECHO]         = { .handler = icmp_echo },
    [ICMP_TIME_EXCEEDED]= { .handler = icmp_unreach, .error = 1 },
    [ICMP_PARAMETERPROB]= { .handler = icmp_unreach, .error = 1 },
    [ICMP_TIMESTAMPREPLY] = { .handler = icmp_discard },   /* 历史遗留，NTP 顶替了 */
    ...
};
```

以类型为索引，`error` 字段标记是不是错误消息（防"错误报告套错误报告"死循环，后面讲）。`icmp_discard` 就是装样子的成功——现代网络用 NTP 取代了 ICMP 时间戳，用 DHCP 取代了 ICMP 问子网掩码，这些类型内核收到直接扔。

`icmp_rcv` 的核心一行就是 `reason = icmp_pointers[icmph->type].handler(skb);`——查表分派。超过 `NR_ICMP_TYPES`（18）的未知类型按 RFC 1122 静默丢弃。

## `__icmp_send`：内核什么时候主动发错误

发 ICMP 错误靠 `__icmp_send`（6.19 里 `icmp_send` 是个宏，包一层 `__icmp_send`，Netfilter 场景还有个 `icmp_ndo_send` 会做 NAT 反向翻译）。原型：

```c
void __icmp_send(struct sk_buff *skb_in, int type, int code, __be32 info,
                 const struct inet_skb_parm *parm);
```

`skb_in` 是"罪魁祸首"原始包，内核从里面剥 IP 头做诊断、再把它嵌进新错误包的数据部分；`info` 常用来传 MTU 值。几个经典触发场景（都在协议层调 `__icmp_send`）：

- **协议不可达（Code 2）**：`ip_local_deliver_finish()` 查 `inet_protos[protocol]` 查不到（比如 IP 头写了个内核没注册的协议号），回 `ICMP_DEST_UNREACH`/`ICMP_PROT_UNREACH`。
- **端口不可达（Code 3）**：UDP 包发到一个没人监听的端口，`__udp4_lib_rcv()` 查 socket 查不到，回 `ICMP_PORT_UNREACH`——这是日常最常见的错误包。
- **需要分片（Code 4）**：`ip_forward()` 里发现 `skb->len > dst_mtu()` 且 DF 置位，不能分片只能丢，回 `ICMP_FRAG_NEEDED`，并把正确的 MTU 塞进 `info`（`htonl(dst_mtu(&rt->dst))`）。这就是 **PMTU 发现的核心**。
- **TTL 超时（Type 11）**：转发时 TTL 减到 0，`ip_forward()` 回 `ICMP_TIME_EXCEEDED`/`ICMP_EXC_TTL`——**traceroute 就靠这个**：发 TTL=1 的包，第一跳回超时；发 TTL=2，第二跳回……一路拼出路由图。

`__icmp_send` 里几道关键防雪崩检查（`net/ipv4/icmp.c`）：收到的是不是广播/组播（`pkt_type != PACKET_HOST` 直接走人）、是不是非首片（`iph->frag_off & htons(IP_OFFSET)`）、以及"错误报告套错误报告"——`if (icmp_pointers[type].error)` 判断要发的是错误，且原始包本身就是 ICMP，那就再扒一层看内层是不是又是错误包，是就放弃（`*itp > NR_ICMP_TYPES || icmp_pointers[*itp].error` → `goto out`），避免错误风暴。最后还有 `room` 限制：`if (room > 576) room = 576;`，给原始包留的载荷最多 576 减去头，符合 RFC。

## 速率限制：别让错误报告变成错误炸弹

ICMP 不限速会雪崩——某根线断了，路由器对每个丢包都回不可达，回包本身又压垮网络。`__icmp_send` 走两级限流：全局令牌桶 `icmp_global_allow()`（`sysctl_icmp_msgs_per_sec`，默认 1000/s、burst 50）和按目标的 `icmpv4_xrlim_allow()`（`sysctl_icmp_ratelimit`，默认 `1*HZ`）。但三种情况**跳过限流**（`icmpv4_mask_allow` 里写死）：

1. **PMTU 发现消息**（`ICMP_DEST_UNREACH` + `ICMP_FRAG_NEEDED`）——被限流丢了 TCP 连接就彻底断了，必须及时发。
2. **loopback 设备**——本机自己转，无所谓拥塞。
3. **`icmp_ratemask` 没置位的类型**（默认 `0x1818`，主要限错误消息）。

调这些旋钮不用重编内核，`/proc/sys/net/ipv4/icmp_*` 实时改。`icmp_ratemask` 是位掩码，每一位对应一个 type；`icmp_echo_ignore_broadcasts` 务必保持默认 1，否则一条 ping 广播的病毒能把整个二层网搞瘫。

## ICMPv6：IPv6 世界的瑞士军刀

到 IPv6 这边，ICMP 角色彻底变了。IPv4 里 ARP 管地址解析、IGMP 管组播、ICMP 管报错，分工明确；IPv6 把 ARP 和 IGMP 全砍了，统一收编进 ICMPv6。没有 ICMPv6，IPv6 连邻居都找不到，一步都迈不出去。

实现主要在 `net/ipv6/icmp.c` 和 `net/ipv6/ip6_icmp.c`，同样编进内核不能做成模块。注册方式跟 v4 如出一辙，协议号 `IPPROTO_ICMPV6 = 58`：

```c
static const struct inet6_protocol icmpv6_protocol = {
    .handler = icmpv6_rcv,
    .err_handler = icmpv6_err,
    .flags = INET6_PROTO_NOPOLICY | INET6_PROTO_FINAL,
};
```

`INET6_PROTO_NOPOLICY` 同样跳过 IPsec——处理网络层错误报告时，不能因为 IPsec 验证失败把错误报告本身丢了，否则永远不知道网络出什么事。

### 类型编号的聪明分界线

ICMPv6 报头 `struct icmp6hdr`（`include/uapi/linux/icmpv6.h`）字段一样：type、code、checksum。但 type 的解释有条 RFC 4443 定的聪明线——**最高位为 0（0~127）是错误消息，最高位为 1（128~255）是信息消息**。内核用掩码 `ICMPV6_INFOMSG_MASK`（0x80）一次位与就判出来，比 v4 那个枚举优雅多了。常见类型：

| Type | 宏 | 类别 | 含义 |
|:---:|:---|:---:|:---|
| 1 | `ICMPV6_DEST_UNREACH` | Error | 目的不可达 |
| 2 | `ICMPV6_PKT_TOOBIG` | Error | 包太大（**独立 type**，不是 code） |
| 3 | `ICMPV6_TIME_EXCEED` | Error | 超时（Hop Limit 用完） |
| 4 | `ICMPV6_PARAMPROB` | Error | 参数问题 |
| 128/129 | `ICMPV6_ECHO_REQUEST`/`REPLY` | Info | ping |
| 133-137 | `NDISC_ROUTER_SOLICIT`... | Info | **邻居发现 ND**（替代 ARP） |

后半截全是 ND 协议消息（路由器请求/通告、邻居请求/通告），印证那句"在 IPv6 里 ICMP 就是邻居发现的载体"。

### 接收分发：`switch` 而非查表

和 v4 的 `icmp_pointers` 查表不同，ICMPv6 用一个巨大的 `switch(type)` 分发（`net/ipv6/icmp.c` 的 `icmpv6_rcv`）。关键分支：echo request 走 `icmpv6_echo_reply`、echo reply 走 `ping_rcv`、ND 消息（133-137）全交给 `ndisc_rcv`（`net/ipv6/ndisc.c`，IPv6 地址解析核心）、MLD 组播消息走 `igmp6_event_query/report`。`default` 分支有个精巧逻辑：未知**信息类**消息（最高位 1）静默 `break`（多点噪音无所谓），未知**错误类**消息必须 `icmpv6_notify()` 往上报给上层（Raw Socket），因为 RFC 4443 要求未知错误也得让上层有机会处理。

### PMTU：v4 和 v6 的关键分野

这是 v4/v6 最大区别之一。IPv4 路由器包太大可以分片（除非 DF=1）；**IPv6 路由器禁止分片，分片是发送端自己的事**。所以 IPv6 路由器发现包比出口 MTU 大，唯一选择就是丢包并回 `ICMPV6_PKT_TOOBIG`，把正确 MTU 塞进消息（`ip6_forward()` 里 `icmpv6_send(skb, ICMPV6_PKT_TOOBIG, 0, mtu)`）。对比 v4 发的是 `ICMP_DEST_UNREACH`+`ICMP_FRAG_NEEDED`，v6 直接给独立 type——因为这事太常发生了。

发送限流逻辑同样跳过三类：信息类消息、`ICMPV6_PKT_TOOBIG`、loopback。错误报文长度硬性不超过 1280 字节（IPv6 最小 MTU `IPV6_MIN_MTU`），原始包太长就截断。

## ICMP Sockets：让普通用户也能 ping

以前 ping 要 root 权限——创建 Raw Socket（`SOCK_RAW`）需要 `CAP_NET_RAW`，所以 `/bin/ping` 传统上带 `setuid root` 位。2011 年左右内核引入 **ICMP Sockets（Ping Sockets）**：`socket(PF_INET, SOCK_DGRAM, IPPROTO_ICMP)`，特殊 Datagram Socket，不一定需要 root。代码在 `net/ipv4/ping.c`（双栈，IPv6 也调这里）。

内核检查调用方的 GID 是否落在 `/proc/sys/net/ipv4/ping_group_range`（默认 `1 0` 意为"没人能用"）。想放开：`echo 1000 1000 > .../ping_group_range`。`ping_supported()` 还卡一道：这种 socket 只能发标准 echo（`type == ICMP_ECHO && code == 0`），不能用来发 redirect 或 dest unreach——给了普通用户诊断权，但不给 DoS 武器。这就是现代发行版"无 root ping"的秘密。

## 动手验证方案（待亲测）

下面这几条等我们在 QEMU 跑一遍记下真实输出再填实，先列方案：

- **ping 抓 echo**：QEMU 双机/双 netns 之间 `ping <对端>`，对端 `tcpdump -ni any icmp` 抓 type 8 request 和 type 0 reply；顺便 `cat /proc/net/snmp | grep -A1 '^Icmp:'` 看 `InEchos`/`OutEchoReplies` 计数跳动。
- **隐身模式**：对端 `echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all`，再 ping，观察请求仍在、应答消失、`InErrors`/`OutMsgs` 变化。
- **traceroute 看 time exceed**：本机 `traceroute <多跳目标>`（或自建中转路由器），同时 `tcpdump 'icmp[icmptype] == icmp-timexceed'`，核对每一跳返回的就是 Type 11。
- **端口不可达**：对端不开任何服务，本机 `nc -u <对端> 8888` 发个 UDP 包，抓 `icmp[icmptype] == icmp-unreach`（Type 3 Code 3）。
- **PMTU**：中间路由器接口 MTU 压到 1400，本机 `ping -M do -s 1472 <对端>` 强制不分片，抓 `ICMP_FRAG_NEEDED` 并看 `info` 字段里的 MTU 值。

> ⚠️ **待亲测**：以上命令与计数器输出是整理时的方案设计，尚未在本机 QEMU 验证。验完会补真实 tcpdump 片段和 `/proc/net/snmp` 计数。

## 小结

ICMP 是 IP 层的维保工：`icmp_rcv` 收、`__icmp_send` 发，靠 `icmp_pointers` 表分发到各 handler。错误报告带 per-CPU socket 防锁竞争、带双重速率限制防雪崩、带"错误不套错误"防风暴。ICMPv6 比 v4 重得多——它把 ARP（邻居发现 ND）和 IGMP（组播 MLD）全收编了，用"最高位判错误/信息"的简洁规则和 `switch` 分发取代了 v4 的查表。记住两个工程教训：**PMTU 消息必须放行**（否则大包静默黑洞），以及**防火墙优先 REJECT 而非 DROP**——礼貌回个不可达，客户端立刻知道此路不通，比让它干等到超时强得多。

## 延伸阅读

- 源码（Linux 6.19）：
  - `net/ipv4/icmp.c` — `icmp_rcv`、`__icmp_send`、`icmp_unreach`、`icmp_echo`、`icmp_pointers[]`、`icmp_init`
  - `net/ipv6/icmp.c` — `icmpv6_rcv`、`icmpv6_send`、`icmpv6_echo_reply`
  - `include/uapi/linux/icmp.h` / `include/uapi/linux/icmpv6.h` — `struct icmphdr`、`struct icmp6hdr`
  - `include/linux/icmp.h` — `icmp_is_err()`、`icmp_hdr()`
  - `net/ipv4/ping.c` — `ping_rcv`、`ping_supported`（ICMP Sockets 双栈实现）
- kernel.org 稳定文档：[Networking — IP-Sysctl](https://docs.kernel.org/networking/ip-sysctl.html)（`icmp_*` 旋钮的权威说明）、[Linux Networking and Network Devices](https://docs.kernel.org/networking/index.html)（网络子系统总入口）。
- RFC：792（ICMPv4）、4443（ICMPv6）、1812（路由器要求，含 ICMP 速率限制）。
- 进一步（持续铺开）：`ip_forward` 路由转发、IPv6 邻居发现（`ndisc.c`）、PMTU 发现的传输层联动。