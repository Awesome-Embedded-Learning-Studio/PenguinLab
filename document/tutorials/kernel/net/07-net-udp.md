---
title: UDP：无连接的轻量传输
slug: net-udp
difficulty: intermediate
tags: [网络栈, UDP, 传输层, socket]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
related:
  - /tutorials/kernel/net/04-net-ipv4
  - /tutorials/kernel/net/06-net-tcp
sources:
  - notes: document/notes/linux_kernel_networking/ch11.md
  - notes: document/notes/linux_kernel_networking/ch11_1.md
  - notes: document/notes/linux_kernel_networking/ch11_2.md
  - notes: document/notes/linux_kernel_networking/ch11_3.md
---

# UDP：无连接的轻量传输

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## UDP 在内核里扮演什么角色

我们顺着上一篇 IPv4 的路子往上爬一层，到了传输层。先挑 UDP 这个「最直来直去」的家伙开刀——它没什么花哨状态机，几乎就是 IP 层上面裹的一层薄纸，只多做了一件事：**加端口号**。

UDP 的设计哲学是「尽力而为」：不保证送达、不保证顺序、甚至不保证连接还在。它把可靠性整个甩给了应用层，自己只管把数据报怼出去。这种"不负责任"反而让它成了对延迟敏感场景的宠儿——DNS 一问一答、DHCP 开局找地址、视频流丢两帧无所谓、QUIC 干脆在 UDP 上重建了一套可靠的传输。VoIP 里的 RTP 也是 UDP 跑的：实时音频丢几个包顶多声音卡一下，为了重传而延迟两秒那才叫灾难。

RFC 768 把它在 1980 年就钉死了，头部就那么点东西。接下来我们从头部开始，一路追到内核怎么发、怎么收。

## 头部：8 字节，四个字段

UDP 头部固定 8 字节，比 TCP 那个 20 字节起步、还能带一堆选项的头部寒酸得多。内核里就一个结构（`include/uapi/linux/udp.h`，Linux 6.19）：

```c
struct udphdr {
	__be16	source;     // 源端口
	__be16	dest;       // 目的端口
	__be16	len;        // 长度（含头部）
	__sum16 check;      // 校验和
};
```

四个 16 位字段：源端口、目的端口、长度、校验和。注意 `len` 只有 16 位，所以单个 UDP 包（含头）最大 65535 字节——这点会直接变成后面 `udp_sendmsg` 里的长度检查。`check` 字段是校验和，IPv4 里**理论上可以置 0 表示不算**（UDP-Lite 变体还能只校验一部分，详见 RFC 3828，内核里它复用 UDP 代码，主要在 `net/ipv4/udplite.c`）。

内核解析 UDP 头部靠 `udp_hdr()`（`include/linux/udp.h`），本质就是从 SKB 的传输层头部位置强转出来：

```c
static inline struct udphdr *udp_hdr(const struct sk_buff *skb)
{
	return (struct udphdr *)skb_transport_header(skb);
}
```

而每个 UDP socket 在内核里还挂着一个更大的 `struct udp_sock`（同样在 `include/linux/udp.h`），它把 `inet_sock` 包在第一个成员里，再多出 UDP 特有的状态：`len`（cork 时攒包的总长度）、`pending`（有没有挂着的待发包）、`encap_type`（隧道封装用，比如 VXLAN/QUIC 都靠它把 UDP 当集装箱）、`reader_queue`（接收快队列）等等。这是 socket 侧的状态仓，头部那 8 字节是线上的真实报文。

## 注册到内核：两张表，两条入口

UDP 要干活，得在内核的两张表里登记。这两张表对应它的两张「脸」——一张面向网络层（收包），一张面向 socket 系统调用（发包/收包）。

**第一张表：网络层协议表。** 内核在 `inet_init()` 里（`net/ipv4/af_inet.c`）注册一个 `net_protocol` 结构，告诉 IP 层：「收到协议号 `IPPROTO_UDP` 的包，调我这个 handler」（Linux 6.19）：

```c
net_hotdata.udp_protocol = (struct net_protocol) {
	.handler =	udp_rcv,
	.err_handler =	udp_err,
	.no_policy =	1,
};
if (inet_add_protocol(&net_hotdata.udp_protocol, IPPROTO_UDP) < 0)
	pr_crit("%s: Cannot add UDP protocol\n", __func__);
```

注意 6.19 这里它被收进了 `net_hotdata.udp_protocol`（热数据结构，省一次缓存行跳转），handler 就是接收入口 `udp_rcv`，`err_handler` 是 `udp_err`（处理 ICMP 报错）。`no_policy = 1` 表示不做 XFRM 策略检查，省点开销。

**第二张表：socket 操作表。** `struct proto udp_prot`（`net/ipv4/udp.c`）把 socket 系统调用映射到 UDP 的具体实现（Linux 6.19）：

```c
struct proto udp_prot = {
	.name           = "UDP",
	.close          = udp_lib_close,
	.connect        = udp_connect,
	.disconnect     = udp_disconnect,
	.ioctl          = udp_ioctl,
	.sendmsg        = udp_sendmsg,   // 发包入口
	.recvmsg        = udp_recvmsg,   // 收包入口
	.get_port       = udp_v4_get_port,
	.obj_size       = sizeof(struct udp_sock),
	...
};
```

用户态调 `send()`/`sendto()`/`sendmsg()` 最终都汇到 `.sendmsg = udp_sendmsg`；收包同理落到 `udp_recvmsg`。UDP 的 `.connect` 不是握手——它只是给 socket 写死一个默认对端（给明信片提前写好收件人），后续 `send()` 不用每次填地址。

登记完，收发两条路就通了。先看发包。

## 发送：`udp_sendmsg` 的快路与慢路

`udp_sendmsg()` 是 UDP 发包的总指挥（`net/ipv4/udp.c`，Linux 6.19）。注意现在的签名已经比老书上的干净了——不再有 `kiocb`：

```c
int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
	struct inet_sock *inet = inet_sk(sk);
	struct udp_sock *up = udp_sk(sk);
	...
	int corkreq = udp_test_bit(CORK, sk) || msg->msg_flags & MSG_MORE;
	...
	if (len > 0xFFFF)
		return -EMSGSIZE;
```

第一件事是算 `corkreq`——要不要「软木塞」。UDP 默认即发即走：给 10 字节就立刻发一个 10 字节的小包。但有时你想把多次小写攒成一个大包再发（应用层自己拼数据时常见），这就靠 `UDP_CORK` socket 选项或 `MSG_MORE` flag。`corkreq` 决定了走快路还是慢路。

紧接着是长度检查 `len > 0xFFFF → -EMSGSIZE`，这就是头部 `len` 只有 16 位的硬约束——超 64KB 直接拒，原因就在头部那 4 个字段的宽度上。

接下来确定「发给谁」。两种情况：用户在 `msg->msg_name` 里直接塞了 `sockaddr_in`（带目的 IP/端口，端口不能为 0），或者没塞——那这个 socket 必须之前 `connect()` 过，状态被标成 `TCP_ESTABLISHED`（UDP 借这个名字只表示「已指定默认对端」，跟 TCP 那种真握手没关系），否则报 `-EDESTADDRREQ`。

地址搞定后，解析辅助数据（`msg_controllen` 非空就 `ip_cmsg_send()`，比如用 `IP_PKTINFO` 指定源地址），再做路由查找（`ip_route_output_flow()`，构造 `flowi4` 四元组去查路由表）。路由结果 `rt` 是后面构建 SKB 的依据。

**快路（无锁，Kernel 2.6.39 引入）**：没开 cork，就没必要拿那把沉重的 socket 锁，直接构建并发出（Linux 6.19）：

```c
/* Lockless fast path for the non-corking case. */
if (!corkreq) {
	struct inet_cork cork;
	skb = ip_make_skb(sk, fl4, getfrag, msg, ulen,
			  sizeof(struct udphdr), &ipc, &rt,
			  &cork, msg->msg_flags);
	...
	if (!IS_ERR_OR_NULL(skb))
		err = udp_send_skb(skb, fl4, &cork);
	goto out;
}
```

`ip_make_skb()` 把数据从用户态拷进 SKB、贴上 IP+UDP 头，组装好但不发；`udp_send_skb()` 填 UDP 校验和（`udp_csum`，覆盖伪首部+UDP 头+数据）后交给 `ip_send_skb` 进 IP 层发送队列。一气呵成，全程不持锁——这就是「寄一封扔邮筒一封」。

**慢路（cork，上锁）**：开了软木塞就得维护状态，必须上锁（Linux 6.19）：

```c
lock_sock(sk);
...
WRITE_ONCE(up->pending, AF_INET);
do_append_data:
	up->len += ulen;
	err = ip_append_data(sk, fl4, getfrag, msg, ulen, ...);
	if (err)
		udp_flush_pending_frames(sk);      // 出错就冲掉攒的包，防内存泄漏
	else if (!corkreq)
		err = udp_push_pending_frames(sk); // 真正触发发送+分片
```

`ip_append_data()` 不发，只把数据拷到 `sk->sk_write_queue` 队列里攒着；等攒够了或取消 cork，`udp_push_pending_frames()` 一次性触发发送。这是「攒一摞信打成一个包裹再叫快递」。

## 接收：`udp_rcv` → 查 socket → 入队列

接收是发包的反向，但多了个关键动作：**根据四元组找 socket**。

入口 `udp_rcv()` 极简，就是个二传手（`net/ipv4/udp.c`，Linux 6.19）：

```c
int udp_rcv(struct sk_buff *skb)
{
	return __udp4_lib_rcv(skb, dev_net(skb->dev)->ipv4.udp_table, IPPROTO_UDP);
}
```

真正干活的是 `__udp4_lib_rcv()`。它先做校验：`pskb_may_pull` 确认 SKB 装得下 UDP 头、`ulen = ntohs(uh->len)` 取长度、`udp4_csum_init()` 初始化校验和验证。然后是广播/组播的分支（`__udp4_lib_mcast_deliver`），单播则走核心逻辑——查 socket（Linux 6.19）：

```c
sk = inet_steal_sock(net, skb, sizeof(struct udphdr), saddr, uh->source,
		     daddr, uh->dest, &refcounted, udp_ehashfn);
...
if (sk) {
	...
	ret = udp_unicast_rcv_skb(sk, skb, uh);
	return ret;
}
if (rt->rt_flags & (RTCF_BROADCAST|RTCF_MULTICAST))
	return __udp4_lib_mcast_deliver(net, skb, uh, saddr, daddr, udptable, proto);

sk = __udp4_lib_lookup_skb(skb, uh->source, uh->dest, udptable);
if (sk)
	return udp_unicast_rcv_skb(sk, skb, uh);
```

`__udp4_lib_lookup_skb()`（底层是 `__udp4_lib_lookup`）在 UDP 哈希表 `udp_table` 里用四元组（源 IP、源端口、目的 IP、目的端口）匹配 socket。哈希表本身是 `struct udp_table`（`udp.c` 里的全局 `udp_table`，每 netns 一份 `net->ipv4.udp_table`），由 `udp_hashfn()` 这类函数算槽位。

**找到了 socket**：说明有应用在这个端口监听。链路是 `udp_unicast_rcv_skb` → `udp_queue_rcv_skb`（带 BPF filter/封装检查）→ `__udp_queue_rcv_skb` → `__udp_enqueue_schedule_skb`，最终把 SKB 挂到 `sk->sk_receive_queue`（以及接收快队列 `reader_queue`）的尾巴上，等用户态 `recvmsg` 来取。

**没找到 socket**：地址对、端口没人收。这时不能悄无声息地丢。内核先 `udp_lib_checksum_complete()` 复查校验和——错了直接丢；没错就礼貌地给发信方回一个 ICMP Destination Unreachable（Code 3: Port Unreachable），并递增 `UDP_MIB_NOPORTS` 计数器（`netstat -su` 能看到）（Linux 6.19）：

```c
__UDP_INC_STATS(net, UDP_MIB_NOPORTS, proto == IPPROTO_UDPLITE);
icmp_send(skb, ICMP_DEST_UNREACH, ICMP_PORT_UNREACH, 0);
```

所以你拿 UDP 探一个没人监听的端口，是会收到 ICMP 回声的——这就是「端口不可达」的来源。

## 校验和：伪首部那点事

UDP 校验和覆盖三段：**伪首部（源 IP + 目的 IP + 协议号 + UDP 长度）+ UDP 头 + 数据**。伪首部不是真实报文的一部分，纯粹是为了让校验和能验证「这个包确实送到了正确的 IP 和协议」。发送侧在 `udp_send_skb` 里通过 `udp_csum()` 算出来填进 `uh->check`；接收侧在 `__udp4_lib_rcv` 开头用 `udp4_csum_init()` 起算、`udp_lib_checksum_complete()` 复查。IPv4 里 UDP 校验和**可选**（可置 0 跳过），IPv6 里则强制——这是两套协议对 UDP 可靠性的取舍差异。

## 跟 TCP 比一比

| | UDP | TCP |
|:---|:---|:---|
| 连接 | 无（`connect` 只设默认对端） | 三次握手建连接 |
| 可靠性 | 不保证送达/顺序 | 重传、序号、ACK |
| 流控 | 没有 | 滑动窗口、拥塞控制 |
| 头部 | 8 字节固定 | 20 字节起步，可带选项 |
| 内核状态 | 几乎无（cork 算一点） | 庞大状态机 |

UDP 什么承诺都不给，换来的是低开销、低延迟、实现简单。代价是「出了事自己兜」——应用层要可靠就得自己加序号、重传、拥塞控制（QUIC 就是这么干的）。所以选 UDP 不是因为它「更好」，而是你**需要自己掌控这些机制**，或者根本不在乎那点丢包。

## 动手验证（待 QEMU 亲测）

> ⚠️ **待亲测**：下面是验证方案占位，等拿到 QEMU 环境实跑后补真实输出。

1. **看 UDP socket**：`ss -u -a` 列出所有 UDP socket，对照 `udp_prot` 的注册，理解每个 socket 背后的 `struct udp_sock`。
2. **写 UDP echo**：用户态 `socket(AF_INET, SOCK_DGRAM, 0)` + `bind` + `recvfrom`/`sendto`，对照 `udp_sendmsg` 快路和 `udp_recvmsg` 路径。
3. **抓包看头**：`tcpdump -i any udp -X` 抓 UDP 包，肉眼数那 8 字节头部（src port/dst port/len/check）。
4. **探空端口**：往一个没人监听的端口发 UDP，`tcpdump` 同步抓，对照 `icmp_send(ICMP_PORT_UNREACH)` 看回的 ICMP。
5. **压限长**：发一个超 65535 字节的 UDP，验证 `-EMSGSIZE`（对应 `len > 0xFFFF` 检查）。

## 小结

UDP 是传输层最薄的一层：头部 8 字节四个字段，靠 `udp_prot`（socket 操作表）和 `net_hotdata.udp_protocol`（IP 层收包入口）两张表注册到内核。发送 `udp_sendmsg` 走无锁快路（`ip_make_skb` + `udp_send_skb`）或有锁 cork 慢路（`ip_append_data` + `udp_push_pending_frames`）；接收 `udp_rcv` → `__udp4_lib_rcv` → 四元组查 `udp_table` → 找到就入 `sk_receive_queue`，找不到就回 ICMP Port Unreachable。它的「轻」换来的是「不可靠」，可靠性得应用层自己补。

## 延伸阅读

- 源码（Linux 6.19）：`net/ipv4/udp.c`（收发主逻辑、`udp_prot`/`udp_table`）、`net/ipv4/udplite.c`（UDP-Lite 变体）、`net/ipv4/af_inet.c`（`inet_init` 里注册 `udp_protocol`）、`include/linux/udp.h`（`struct udp_sock`、`udp_hdr`）、`include/uapi/linux/udp.h`（`struct udphdr`）。
- kernel.org 稳定文档索引：[Networking — kernel documentation](https://docs.kernel.org/networking/index.html)、[Linux Networking and Network Devices APIs](https://docs.kernel.org/networking/netdev-features.html)。
- 进一步（持续铺开）：下一篇 TCP 状态机与重传、UDP GSO/GRO、QUIC 在 UDP 上的封装。