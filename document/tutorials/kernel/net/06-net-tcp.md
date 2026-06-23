---
title: TCP 传输层：三次握手与收发内核视角
slug: net-tcp
difficulty: intermediate
tags: [TCP, 传输层, 三次握手, 网络栈]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
related:
  - /tutorials/kernel/net/04-net-ipv4
sources:
  - notes: document/notes/linux_kernel_networking/ch11.md
---

# TCP 传输层：三次握手与收发内核视角

> 🔨 **整理中** · 这篇是从读书笔记（ch11 的 socket/TCP 子章）整理出来的骨架，连接建立、收发包路径、定时器的脉络已经讲透；但动手部分（QEMU 里 `ss -ti` 看 TCP 内部状态、`tcpdump` 抓三次握手、`cat /proc/net/tcp` 看连接表）还没亲手跑过。等我们在 QEMU 里验过真实输出，就升级成 ✅ 已锤炼。**本篇函数签名/字段/数值已对照 Linux 6.19 源码校订（读书笔记基于较早内核版本，部分接口已演进）；具体行号仍待 QEMU 亲测核对。**

## socket vs sock：一个端点为什么长着两张脸

UDP 那篇我们说过它是“发完即忘”的乐天派，TCP 则恰好相反——它是网络协议世界里最严重的强迫症患者。但在钻进 TCP 的复杂之前，得先把一个横亘在整个网络栈门口的谜题解开：用户态一个 `socket()` 调用，内核里到底造出了什么。

内核的哲学是“一切皆文件”，所以网络通信得能 `read()`/`write()`，得有个文件描述符。可一旦你真正 `socket(AF_INET, SOCK_STREAM, 0)`，内核并没有只建一个 inode，而是策划了一场“分裂”——它同时造了两样东西：**`struct socket`** 和 **`struct sock`**。这俩名字只差一个字母，却是两个物种，让无数初学者晕头转向。

为什么要拆成两个？因为一个套接字得同时扮演两个截然相反的角色：

- **`struct socket`** 是面向**用户空间**的“门面”（`net/socket.c`、`include/linux/net.h`）。它带着 `state`（`SS_UNCONNECTED` / `SS_CONNECTED`）、`type`（`SOCK_STREAM` 之类）、一个 `file *` 指针（这就是它能被 `read`/`write` 的原因），还有一张回调表 `ops`（`proto_ops`，装着 `connect`/`listen`/`sendmsg`/`recvmsg`）。注意 TCP 的 `ops` 里有真正的 `inet_listen()`/`inet_accept()`，而 UDP 这俩回调被设成 `sock_no_listen()`——唯一动作就是返回 `-EOPNOTSUPP`，因为明信片根本不需要接电话。
- **`struct sock`** 是面向**网络层（L3）** 的“引擎房”（`include/net/sock.h`），协议无关。它才是承载连接状态的实体：`sk_receive_queue`（收到的包先挂这儿等用户读）、`sk_write_queue`（准备发出去的包排这儿）、`sk_rcvbuf`/`sk_sndbuf`（收发缓冲区大小）、`sk_protocol`、`sk_type`，还有回调 `sk_data_ready`（“有货了”）和 `sk_write_space`（“能继续写了”）。

`struct socket` 里有个 `sk` 指针，把这俩绑在一起。在 IPv4 里，`inet_create()`（`net/ipv4/af_inet.c`）负责分配 `socket` 的同时把那个 `sock` 也建好。所以用户手里那个 `sockfd` 是文件凭证，凭证背后是 `struct socket`，`struct socket` 再指向真正干活的 `struct sock`——三层套娃，才维持住“socket 就是个文件”的体面假象。

## TCP 头：比 UDP 重得多的行囊

认清 TCP 之前，先认清它的脸。UDP 头只有 8 字节，短小精悍；TCP 头不含选项就 20 字节，带上选项最多 60 字节。每一比特都有用武之地（`include/uapi/linux/tcp.h` 的 `struct tcphdr`）：

- **source / dest**：源/目的端口，传输层的多路复用钥匙，决定数据归哪个进程。
- **seq / ack_seq**：序号与确认号，各 32 位，是可靠性的基石。注意 `ack_seq` 只有在 ACK 标志为 1 时才有效，它告诉对方“这之前的我都收到了，接下来我期待这个序号”。
- **doff**：数据偏移，4 位，单位是 4 字节——其实就是头部长度。因为 TCP 头变长（有选项），得靠它告诉内核“真正的数据从哪开始”，最小 5（20 字节），最大 15（60 字节）。
- **标志位**（每个 1 比特，每个都能改写状态机走向）：`SYN`（握手同步序号）、`ACK`（确认号有效，几乎除第一个包外都带）、`FIN`（“我发完了，准备关门”）、`RST`（“连接出错，立刻重启”，紧急刹车）、`PSH`（“别缓存，立刻推给应用层”）、`URG`（紧急指针有效），外加 `ECE`/`CWR` 这俩显式拥塞通知（ECN，RFC 3168）标志——网络拥堵时不用靠丢包就能互相提醒，比以前野蛮丢包文明多了。（`include/uapi/linux/tcp.h` 里这一组 bitfield 最前面还塞了个 `ae` 位，是 TCP-AO/AccECN 之类的新活儿，咱们先不展开。）
- **window**：接收窗口（16 位），流量控制的阀门——“我的接收缓冲区还剩这么多空位，你别超发”。
- **check / urg_ptr**：校验和（覆盖头部和数据）、紧急指针（仅 URG 置位时有意义）。

复杂性意味着开销，但也意味着控制力。UDP 用速度换了放弃控制，TCP 则紧紧抓住每一个比特，不让你的包迷失在网络荒原里。

## 注册与初始化：把一个复杂灵魂塞进内核

TCP 这么复杂，初始化自然不能像 UDP 那样随便。两步走：

第一步，定义并注册一个 `net_protocol` 对象（`net/ipv4/af_inet.c`），用 `inet_add_protocol()` 在 `inet_init()` 里挂上协议链表。注意 6.19 里它已经不是当年那个挂满回调的大胖子了——`struct net_protocol`（`include/net/protocol.h`）瘦得只剩 `.handler`/`.err_handler` 和两个 bit 位（`.no_policy`/`.icmp_strict_tag_validation`），而且整体塞进了 per-netns 的 `net_hotdata`：

```c
net_hotdata.tcp_protocol = (struct net_protocol) {
        .handler                = tcp_v4_rcv,      /* 收包入口 */
        .err_handler            = tcp_v4_err,
        .no_policy              = 1,
        .icmp_strict_tag_validation = 1,
};
if (inet_add_protocol(&net_hotdata.tcp_protocol, IPPROTO_TCP) < 0)
        pr_crit("%s: Cannot add TCP protocol\n", __func__);
```

那些年笔记里爱写的 `.early_demux = tcp_v4_early_demux`、`.netns_ok = 1` 已经不复存在了。`tcp_v4_early_demux()` 这个函数本身还在（`net/ipv4/tcp_ipv4.c`），但调用点**上移到了 IP 层**——`net/ipv4/ip_input.c` 在 `ip_rcv_finish` 那段会按 `sysctl_tcp_early_demux` 决定要不要提前做一次 socket 预查找。换句话说，早分流不再是 L4 协议结构体的事，而是 IP 层抢着干了。

第二步，注册 socket 层操作的 `proto` 对象 `tcp_prot`（`net/ipv4/tcp_ipv4.c`），用 `proto_register()`。注意 `.init = tcp_v4_init_sock` 这一回调——UDP 那节没展开类似的 `.init`，但 UDP 其实也有（`udp_prot.init = udp_init_sock`），只是它做的事很轻（端口查找表、destruct 钩子），TCP 不一样，`tcp_v4_init_sock` 要初始化定时器、缓冲区、拥塞窗口一整套，重得多——这才是对比点。

当你 `socket(AF_INET, SOCK_STREAM, 0)` 时，内核最终调到 `tcp_v4_init_sock()` → `tcp_init_sock()`（`net/ipv4/tcp.c`），把一个空壳 `struct sock` 变成一个有状态的 TCP 实体：

1. 状态这时是 `TCP_CLOSE`（这是 `sk_alloc()` 给每个新 `sock` 的默认初值，`net/core/sock.c`，`tcp_init_sock` 依赖这个起点）。
2. **初始化定时器**（`tcp_init_xmit_timers()`）——TCP 极度依赖定时器，没了它们就不知道该重传还是该放弃。
3. 设置收发缓冲区：默认发送缓冲 16KB（`sysctl_tcp_wmem[1]`，`net/ipv4/tcp.c`）、接收 128KB（`sysctl_tcp_rmem[1]`，即 `131072` 字节），可经 `/proc/sys/net/ipv4/tcp_wmem`、`tcp_rmem` 调优。（笔记里那个“接收 87KB”的数字在 6.19 源码里查无实据，是早年版本的旧值，已弃用。）
4. 初始化乱序队列（`tp->out_of_order_queue = RB_ROOT`）与重传队列（`sk->tcp_rtx_queue = RB_ROOT`）。**注意：曾经笔记爱提的 prequeue 在现代内核已经退场**——6.19 的 `tcp_init_sock` 里没有任何 prequeue 初始化，收包路径也没有，别去源码里找它了。
5. 把初始拥塞窗口设为 10 个段（`tcp_snd_cwnd_set(tp, TCP_INIT_CWND)`，`TCP_INIT_CWND` 定义为 10，对齐 RFC 6928）。

没有这一步，后面的 `connect()`/`listen()` 都无从谈起。这步对 IPv6 同理（走 `tcp_v6_init_sock`）。

## 三次握手内核视角：状态机的流转

教科书里三次握手是“交换三个包”，但在内核里它更是状态和内存结构的转换。socket 任意时刻都处在一个状态（`TCP_LISTEN`、`TCP_SYN_SENT` 等），存在 `struct sock` 的 `sk_state` 里。

1. **客户端发 SYN**：`connect()` 发出 SYN，客户端 `TCP_CLOSE` → `TCP_SYN_SENT`。
2. **服务端收 SYN，回 SYN-ACK**：服务端在 `TCP_LISTEN`（`listen()` 进入）。这里有个关键设计——**内核不会把监听 socket 本身变成已连接**，因为监听 socket 得服务所有客户端。它转而创建一个新的 `request_sock`（请求 sock）代表这个半成品连接，状态设为 `TCP_SYN_RECV`，然后回送 SYN-ACK。这批 `request_sock` 排在**半连接队列（SYN queue）**里。
3. **客户端收 SYN-ACK，发 ACK**：客户端 `TCP_SYN_SENT` → `TCP_ESTABLISHED`，发出最后的 ACK。
4. **服务端收 ACK**：`request_sock` 完成使命，内核基于它创建一个完整的子 socket（child socket），状态置 `TCP_ESTABLISHED`，放进**全连接队列（accept queue）**，等应用层 `accept()` 取走。

整个状态机流转的总控是 `tcp_rcv_state_process()`（`net/ipv4/tcp_input.c`）——除了 `ESTABLISHED` 状态的快路径，绝大部分状态变迁都经它手。行号待亲测核对。

## 收包 tcp_v4_rcv：从 IP 层上来后

连接建好了，数据开始流。当 IP 层的 `struct sk_buff` 到达，TCP 的入口是 `tcp_v4_rcv()`（`net/ipv4/tcp_ipv4.c`）：

**第一步：sanity 检查 + 找 socket。** 包是不是发给我们的、长度够不够一个 TCP 头，然后最关键——调 `__inet_lookup_skb(&tcp_hashinfo, ...)` 在 hash 表里找归属。先查 established 表找已连接 socket，找不到再查 listening 表找监听 socket；都找不到就是瞎发的，丢弃。

**第二步：socket 被用户占着吗？** 用 `sock_owned_by_user()` 判断。

- **情况 A：没人用** → 直接 `tcp_v4_do_rcv()` 走正常流程。这里得专门提一句：早年内核（约 3.x/4.x）会在这一步先把包塞进 **prequeue** 缓存队列、等用户进程下次碰 socket 时批量处理，但**这套 prequeue 优化在 6.19 已经基本移除**（源码里 `grep prequeue` 只剩注释），现在没人占着就直接进处理函数，不再有那个中间层。
- **情况 B：被用户进程锁住** → 不能乱动它的数据结构，调 `tcp_add_backlog()` 把包暂时塞进 **backlog** 队列；backlog 都满了就只能丢包，并统计 `LINUX_MIB_TCPBACKLOGDROP`。

不管哪条路，最终都在 `tcp_v4_do_rcv()` 里分拣：`TCP_ESTABLISHED`（快路径）走 `tcp_rcv_established()`；`TCP_LISTEN` 先调 `tcp_v4_cookie_check()`（处理 SYN cookie / `request_sock`），再喂给 `tcp_child_process()` 处理子 socket（**注意：笔记里常写的 `tcp_v4_hnd_req()` 在 6.19 已彻底删除**，`grep` 全树无命中，别再去找它）；其他状态走大管家 `tcp_rcv_state_process()`。

## 发包：socket write 到 ip_queue_xmit

用户态 `send()`/`sendmsg()` 最终落到 `tcp_sendmsg()`（`net/ipv4/tcp.c`），比 UDP 复杂得多——它不是把指针指过去就完事：从用户空间拷数据到 `skb`、处理 Nagle 算法（立刻发还是攒一攒）、按 MSS 拆段、检查 `sk_sndbuf`。组装好放 `skb` 后，一路走 `tcp_push_one()` → `tcp_write_xmit()` → **`tcp_transmit_skb()`**（`net/ipv4/tcp_output.c`）。

最后一跃交给 IP 层的那行（6.19 实际形态，带 `INDIRECT_CALL_INET` 优化包装）：

```c
err = INDIRECT_CALL_INET(icsk->icsk_af_ops->queue_xmit,
                         inet6_csk_xmit, ip_queue_xmit,
                         sk, skb, &inet->cork.fl);
```

注意签名里 `queue_xmit` 现在是三参的（`sk, skb, fl`），不是早年笔记里那个只剩 `skb, fl` 的两参版本——别照抄老行号。`icsk_af_ops` 是面向地址族的操作对象，IPv4 TCP 指向 `ipv4_specific`（`net/ipv4/tcp_ipv4.c`），其 `queue_xmit` 回调就是通用的 `ip_queue_xmit()`。至此 TCP 层交差，数据包正式移交 IP 层。

## 定时器：TCP 是有记忆、有时间的协议

TCP 的可靠性很大一部分建立在“等待”和“重试”上，这些都由 `net/ipv4/tcp_timer.c` 里的定时器管，每个针对一种“焦虑症”：

1. **重传定时器**：最焦虑的一个。每发一段就启动，超时没收到 ACK 就重发——包丢了它是最后救命稻草。
2. **延迟 ACK 定时器**：较佛系。收到数据不必立刻回 ACK，可以稍等（比如 200ms）看有没有数据能捎带回去，减少小包。
3. **保活定时器（keepalive）**：防“僵尸连接”。两端长期无数据，中间路由器可能断了、对端可能断电，谁也不知道对方还活着没——keepalive 定期探测，发现没反应就调 `tcp_send_active_reset()` 干掉连接。
4. **零窗口探测定时器（persistent）**：经典死锁防止。接收方缓冲满了告诉发送方“窗口为 0 别发了”，发送方就停。可万一接收方腾出空间后发的“窗口更新”包半路丢了？发送方以为还是 0 继续等、接收方以为通知过了继续等数据——死锁。于是发送方不干等，启动这个定时器，时不时发个小包戳一下“喂，窗口开没？”，收到非零响应再继续传。

## 小结

TCP 是内核里最复杂的协议之一：它把一个套接字拆成对上的 `struct socket` 和对下的 `struct sock`；头部带着序号/确认号/窗口/一排标志位，换来可靠与可控；初始化时注册 `net_hotdata.tcp_protocol`/`tcp_prot`（注意 6.19 的 `net_protocol` 已精简、`early_demux` 上移 IP 层），靠 `tcp_v4_init_sock` 把空壳变成有状态的实体；连接建立是一场状态机流转，半连接队列存 `TCP_SYN_RECV` 的 `request_sock`、全连接队列存就绪的 child socket；收包从 `tcp_v4_rcv` 入口、按四元组查 socket、按占用情况分流 backlog/`tcp_v4_do_rcv`（prequeue 已退场）；发包从 `tcp_sendmsg` 一路走到 `tcp_transmit_skb` 再交 `ip_queue_xmit`；而贯穿全程的是重传/延迟 ACK/keepalive/零窗口这四个定时器——TCP 之所以可靠，是因为它有记忆、有时间。

记住三件事：**socket/sock 双胞胎**（门面 vs 引擎房）、**两次队列分流**（半连接 vs 全连接；正常路径 vs backlog）、**定时器撑起可靠性**（TCP 没时间感就不叫 TCP）。

## 动手待亲测（验证方案）

这部分还没在 QEMU 里跑过，下面是验证清单，等亲测后填真实输出：

- `ss -ti`：看 TCP 内部状态机字段（cwnd、rtt、重传计数），核对与笔记里“状态保存在 `sk_state`”的对应。
- `tcpdump -i any -n 'tcp port <port>'`：抓三次握手，核对 SYN → SYN-ACK → ACK 三个包与状态 `TCP_SYN_SENT`/`TCP_SYN_RECV`/`TCP_ESTABLISHED` 的对应。
- `cat /proc/net/tcp`：看连接表，关注第 2 列状态码（`01`=ESTABLISHED、`06`=TIME_WAIT、`0A`=LISTEN 等），核对半连接与全连接。
- 调 `/proc/sys/net/ipv4/tcp_wmem`、`tcp_rmem` 观察缓冲区默认值（应看到第二列是 16KB / 128KB，验证源码里的 `sysctl_tcp_wmem[1]`/`sysctl_tcp_rmem[1]`）。

> ⚠️ **待亲测**：上面 `ss`/`tcpdump`/`/proc/net/tcp` 的输出我们会在 QEMU ARM64 上跑一遍记下真实结果，再把“状态机/队列分流”亲眼看到，然后升级到 ✅ 已锤炼。

## 延伸阅读

- 源码：`net/ipv4/tcp_ipv4.c`（Linux 6.19，`tcp_v4_rcv`/`tcp_v4_do_rcv`/`tcp_v4_init_sock`/`tcp_v4_cookie_check`/`tcp_prot`）、`net/ipv4/tcp_input.c`（`tcp_rcv_state_process` 状态机）、`net/ipv4/tcp_output.c`（`tcp_transmit_skb` 发包）、`net/ipv4/tcp.c`（`tcp_sendmsg`/`tcp_init_sock`/`sysctl_tcp_wmem`/`sysctl_tcp_rmem`）、`net/ipv4/tcp_timer.c`（四种定时器）、`net/ipv4/af_inet.c`（`net_hotdata.tcp_protocol` 注册与 `inet_create`）、`net/ipv4/ip_input.c`（`early_demux` 上移后的调用点）、`include/net/protocol.h`（精简后的 `struct net_protocol`）、`include/net/sock.h`（`struct sock`）、`include/uapi/linux/tcp.h`（`struct tcphdr`）。
- kernel.org：[Linux networking subsystem](https://docs.kernel.org/networking/index.html)。
- RFC 793（TCP）、RFC 6928（初始拥塞窗口 10 段）、RFC 3168（ECN）。
- 进一步（持续铺开）：SCTP/DCCP 这种 TCP/UDP 之间的“混血儿”、TCP 拥塞控制算法（Cubic/BBR）、四挥与 TIME_WAIT/2MSL 的关闭流程。