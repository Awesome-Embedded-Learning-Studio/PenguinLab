---
title: Netlink：用户态与内核的双向 socket
slug: net-netlink
difficulty: intermediate
tags: [Netlink, 网络栈, 通用 netlink, 内核通信]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/01-net-overview
related:
  - /tutorials/kernel/net/01-net-overview
sources:
  - notes: document/notes/linux_kernel_networking/ch02.md
  - notes: document/notes/linux_kernel_networking/ch02_2.md
  - notes: document/notes/linux_kernel_networking/ch02_3.md
  - notes: document/notes/linux_kernel_networking/ch02_4.md
  - notes: document/notes/linux_kernel_networking/ch02_5.md
  - notes: document/notes/linux_kernel_networking/ch02_6.md
---

# Netlink：用户态与内核的双向 socket

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构/协议号已逐条 grep 核对，行号归为「待 QEMU 亲测核对」口径）；命令输出待亲测。

## 内核为什么不用 ioctl 了

写网络相关的东西时，用户态迟早要跟内核「商量」：加一条路由、把网卡 up 起来、问内核「现在 socket 都长什么样」。20 年前干这活的利器是 ioctl——你 `open("/dev/whatever")`，然后一个 `ioctl(fd, CMD, arg)`，内核回一句，你接着问下一句。

ioctl 这套传声筒的毛病在于：**它是单向、一次性、硬编码的**。你想加一条路由，得为「加路由」专门编一个 ioctl 号；你想知道网卡状态变了，没门，ioctl 不会主动喊你，你只能不停轮询。更要命的是，ioctl 号是个全局稀缺资源，每个新功能都要往里挤一个魔数，几版内核下来就乱成一锅粥。

Netlink 就是为治这些毛病生的。它本身是个**正经的 socket**（`AF_NETLINK`），所以天然支持双向、支持多播、支持异步——内核干完活可以**主动广播**「我刚加了一条路由，关心的人都听好了」，用户态的守护进程（NetworkManager、路由守护进程 bird）只管竖着耳朵听，不用再傻乎乎地去轮询 `/proc` 或 `/sys`。这一篇我们就钻进源码，看这套双向通道在内核里到底是怎么搭起来的。

## Netlink socket：AF_NETLINK 与 netlink_create

用户态这边发起一个 Netlink 通道，就是一句普通的 `socket()`：

```c
int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
```

第三个参数是**协议号**——它决定这条 socket 跟内核里哪个子系统对话。`NETLINK_ROUTE` 管网络配置，`NETLINK_GENERIC` 是后面要讲的「万能插座」，还有 `NETLINK_AUDIT`（审计）、`NETLINK_KOBJECT_UEVENT`（热插拔事件）等二十来个。这套协议号在用户态头文件里写死（`include/uapi/linux/netlink.h`），`NETLINK_GENERIC` 是 16，而总量被一个 `MAX_LINKS` 卡死——只有 **32 个**（`include/uapi/linux/netlink.h:35`）。这 32 个坑位就是后面「通用 netlink」要解决的根源。

用户态 `socket()` 进内核后，最终落在 `net/netlink/af_netlink.c:644` 的 `netlink_create()`。它干的头一件事是查这张 socket 要的协议合不合法：

```c
if (protocol < 0 || protocol >= MAX_LINKS)
    return -EPROTONOSUPPORT;          /* af_netlink.c:659 */
```

合法之后，它会去 `nl_table` 这个全局表里找这个协议有没有被内核注册过（`nl_table[protocol].registered`，af_netlink.c:665）。没注册的话还会触发一次 `request_module("net-pf-%d-proto-%d", ...)`，按需把对应模块拉起来——所以 Netlink 协议族是**可以做成模块按需加载**的。注册过了，就调 `__netlink_create()`（af_netlink.c:618）真正 `sk_alloc` 出一个 `struct sock`，把 `sock->ops` 挂成 `netlink_ops`，协议号塞进 `sk->sk_protocol`。

到这一步，用户态手里有了一个 fd，内核里多了一个 `struct sock`——双向管道的两头都接好了。

## Netlink 消息结构：nlmsghdr + TLV 载荷

socket 是管道，管道里流的是「消息」。Netlink 的消息有严格的封装格式，最外层是固定的 16 字节头部 `struct nlmsghdr`（`include/uapi/linux/netlink.h:52`）：

```c
struct nlmsghdr {
    __u32 nlmsg_len;   /* 整条消息总长，含本头部 */
    __u16 nlmsg_type;  /* 消息类型 */
    __u16 nlmsg_flags; /* 标志位 */
    __u32 nlmsg_seq;   /* 序列号，用于匹配请求/应答 */
    __u32 nlmsg_pid;   /* 发送方的 port ID */
};
```

挨个看这五个字段为什么这么设计。`nlmsg_len` 是**整条消息**的长度（含头部），解析器靠它知道读多少字节该停、下一条从哪开始——所以**一个 buffer 里可以塞多条消息**，这是 Netlink 区别于「一问一答」的小心思。`nlmsg_type` 决定这条消息干啥：小于 `NLMSG_MIN_TYPE`（0x10）的是通用控制类型，比如 `NLMSG_ERROR`（出错/ACK）、`NLMSG_DONE`（多段转储结束标记）；≥ 0x10 的则是各协议族自己的「方言」，`NETLINK_ROUTE` 在这儿定义 `RTM_NEWLINK`、`RTM_NEWROUTE` 一大堆。

`nlmsg_flags` 是行为指令：`NLM_F_REQUEST`（这是请求）、`NLM_F_ACK`（请回我个确认）、`NLM_F_DUMP`（把整张表倒给我）、`NLM_F_MULTI`（这是多段消息中的一段）、`NLM_F_CREATE`/`NLM_F_EXCL`/`NLM_F_REPLACE`（增改时的语义）。`nlmsg_seq` 给用户态做请求-应答配对用，内核层面不强制连续。`nlmsg_pid` 是发送方「端口」：**内核发的消息这个字段恒为 0**，用户态发的通常是进程 PID，内核回包时直接抄这个值当目标地址——所以内核天生知道该把回复塞给谁。

头部之后是**载荷**，但 Netlink 不让你把数据硬塞进去，而是规定了一套自描述的 **TLV（Type-Length-Value）** 编码：每个属性前面有个小头 `struct nlattr`（`nla_len` + `nla_type`），值可以是 `NLA_U32`、`NLA_STRING`，甚至 `NLA_NESTED`——属性里再嵌一套 TLV，能搭出树状结构。**每个属性必须按 `NLA_ALIGNTO = 4` 字节对齐**（netlink.h:248），手动拼包忘了补 padding，内核解析时会错位、丢包或读出乱码。内核收到消息后，会用一张 `struct nla_policy` 数组逐个验证属性的类型和长度（`nla_policy.type` / `.len`），验证不过直接拒收——这就是内核那道「海关」。

## NETLINK_ROUTE：iproute2 的底层通道

协议号里最重量级的是 `NETLINK_ROUTE`（rtnetlink）。别被名字骗了，它管的不止路由表，还攥着网卡（LINK）、IP 地址（ADDR）、邻居表/ARP（NEIGH）、策略路由规则（RULE）、QoS 排队（QDISC/TCLASS）一大家子。消息类型遵循 CRUD 套路：`RTM_NEWXXX`（建）、`RTM_DELXXX`（删）、`RTM_GETXXX`（查）；LINK 家族因为常常要「只改一个 MTU」而不是删了重建，额外多了一个 `RTM_SETLINK`（改）。

你每天敲的 `ip` 命令，底层就是 iproute2 打开一个 `NETLINK_ROUTE` socket、拼一条 `RTM_NEWROUTE` 消息扔进内核。内核侧这个 socket 是在网络命名空间初始化时建好的，`net/core/rtnetlink.c:7032` 的 `rtnetlink_net_init()`：

```c
struct netlink_kernel_cfg cfg = {
    .groups = RTNLGRP_MAX,
    .input  = rtnetlink_rcv,
    .flags  = NL_CFG_F_NONROOT_RECV,
    .bind   = rtnetlink_bind,
};
sk = netlink_kernel_create(net, NETLINK_ROUTE, &cfg);
net->rtnl = sk;
```

注意几点：`input` 回调是 `rtnetlink_rcv`——所有从用户态上来的 `NETLINK_ROUTE` 消息都进它；`net->rtnl` 把这个 sock 指针存进**网络命名空间对象**，所以容器里配网卡只动容器自己的 `struct net`，宿主机不受影响，Netlink 从设计上就是命名空间感知的。`NL_CFG_F_NONROOT_RECV` 让普通用户也能 bind 多播组收事件（uevent、ss 也靠这个）。

`rtnetlink_rcv`（rtnetlink.c:6983）把活外包给通用的 `netlink_rcv_skb()`（af_netlink.c:2524）——它在一个 `while` 循环里按 `nlmsg_len` 切 buffer，对每条消息调你给的回调 `cb`，出错就 `netlink_ack` 回报错包。rtnetlink 的回调 `rtnetlink_rcv_msg` 会查 `rtnl_msg_handlers` 这张「协议号 × 消息类型」二维表，把活派给具体函数——`RTM_NEWROUTE` 派给 `net/ipv4/fib_frontend.c` 的 `inet_rtm_newroute()`，真正往 FIB 路由表里插记录。表是子系统们用 `rtnl_register()` 早早填好的函数指针格子。

## 错误与 ACK：那张退件单

Netlink 的报错机制很体贴，封装在 `struct nlmsgerr` 里（`error` + 触发错误的原始 `nlmsghdr`）。内核回包时类型设成 `NLMSG_ERROR`，实现在 `af_netlink.c:2463` 的 `netlink_ack()`：

```c
if (err && !test_bit(NETLINK_F_CAP_ACK, &nlk->flags))
    payload += nlmsg_len(nlh);   /* 出错时把原始请求头也贴回来 */
errmsg->error = err;
errmsg->msg = *nlh;
```

**反直觉的点**：成功（ACK）和失败，回包**类型都是 `NLMSG_ERROR`**，区分只看 `error` 字段——为 0 就是「签收单」（成功），非 0（如 `-EINVAL`）才是「退件单」，而且只有退件单才把你的原始请求头贴回来，方便你按 `nlmsg_seq` 对号入座查是哪条炸了。

## 通用 netlink：用名字换 ID 的多路复用

标准协议号只有 32 个坑，早就被 `NETLINK_ROUTE` 这些大个子占光了。如果你写个驱动想给自己加个 Netlink 控制接口，没坑位给你。**通用 netlink（genetlink）**就是来解决这个「插座荒」的：它只占 `NETLINK_GENERIC` 这一个标准坑位，但在上面挂了无数个自定义「家族」，本质是个**多路复用器**。

核心思路是把「硬编码的协议号」换成「运行时动态分配的 ID」。你给家族起个**名字**（如 `"nl80211"`、`"nlctrl"`），内核注册时用 `idr_alloc_cyclic()`（net/netlink/genetlink.c:816）在 `GENL_START_ALLOC`（19）到 `GENL_MAX_ID`（1023）之间循环分配一个唯一数字 ID（这套 `idr` 机制见 `include/uapi/linux/genetlink.h`：`GENL_MIN_ID`/`GENL_MAX_ID`/`GENL_START_ALLOC`）。开头三个号是预留的——`GENL_ID_CTRL`（16，总服务台）、`GENL_ID_VFS_DQUOT`（17）、`GENL_ID_PMCRAID`（18），所以普通家族从 19 起。**6.19 里没有「填 0 让内核分配」的老套路了**——族 ID 一律由 `idr_alloc_cyclic` 动态决定，不存在静态 ID 的家族（那三个预留除外）。（注：另有个 `find_first_zero_bit()` 只用在**多播组**号的分配上，genetlink.c:408，跟族 ID 是两码事，旧笔记容易把两者混为一谈。）

用户态不知道数字是多少没关系——先问那个固定 ID 的「总服务台」Controller（`nlctrl`，`GENL_ID_CTRL = 0x10`）：「`nl80211` 的 ID 是几？」Controller 查 `genl_fam_idr` 表回一个动态分配的数字（历史上常见是 21，但具体值取决于注册顺序，不是写死的常量），用户态再拿这个 ID 发真正的命令。

内核侧 genetlink 的入口 socket 在 `net/netlink/genetlink.c:1878` 的 `genl_pernet_init()` 里建，`input` 回调是 `genl_rcv`，锁用专属的 `genl_mutex`（genetlink.c:27）。Controller 家族本身在 genetlink.c:1799 定义，`.id = GENL_ID_CTRL`、`.name = "nlctrl"`——**它是唯一硬编码 ID 的家族**，没有它整个查找流程就转不起来（6.19 里它改用 `split_ops`，机制不变）。

家族之上挂的是操作 `struct genl_ops`（`include/net/genetlink.h:213`），每个 op 有 `.cmd`（命令号）、`.doit`（单体操作，如「设 SSID」）、`.dumpit`（列表转储，如「列出所有扫描到的 AP」）、`.policy`（属性校验）。**doit 和 dumpit 至少填一个**，否则注册时 `-EINVAL` 拒绝。消息格式是俄罗斯套娃：外层标准 `nlmsghdr`，往里一层是 genetlink 特有的 `struct genlmsghdr`（`cmd` + `version` + `reserved`，uapi/genetlink.h:13），再往里才是 TLV 载荷。谁走这套？`iw`（无线工具，走 `NETLINK_GENERIC` 的 `nl80211` 家族）是典型。**注意 `ss` 不走 genetlink**——它走的是另一个专用协议族 `NETLINK_SOCK_DIAG`（协议号 4，`net/core/sock_diag.c` 里直接 `netlink_kernel_create(net, NETLINK_SOCK_DIAG, &cfg)` 建的），不是 genetlink 家族、不挂 `genl_ops`，但「注册 handler 表 + 按协议族分发」的设计思路（`sock_diag_handler`）跟 genetlink 一脉相承。

## 内核侧发消息：netlink_unicast 与广播

内核主动通知用户态，靠的是 `netlink_unicast()`（af_netlink.c:1327）和 `netlink_broadcast()`（af_netlink.c:1554）。`netlink_unicast` 拿目标 portid 找到对端 sock，如果对端是内核 sock 就走 `netlink_unicast_kernel()` 调它的 `netlink_rcv` 回调，否则塞进用户态 socket 的接收队列。广播则遍历多播组成员逐个投递。

典型例子：网卡被 `__dev_open()` 拉起来时（net/core/dev.c），内核调 `rtmsg_ifinfo(RTM_NEWLINK, ...)`，它 `nlmsg_new` 分个 skb、填 `nlmsghdr` + `ifinfomsg`、`rtnl_fill_ifinfo`（rtnetlink.c:2027）灌数据，最后 `rtnl_notify()`（rtnetlink.c:953）→ `nlmsg_notify()` 广播给 `RTNLGRP_LINK` 组。加了路由则广播 `RTNLGRP_IPV4_ROUTE`。这就是 NetworkManager 们能秒级响应网卡/路由变化的根源——**不用轮询，内核直接推**。

## 小结

Netlink 是 Linux 用户态↔内核态网络通信的基石：它用 `AF_NETLINK` socket 取代了单向的 ioctl，用 `nlmsghdr` + TLV 规范了消息格式，靠 `netlink_kernel_create` 在命名空间里建内核侧 socket，靠 `nl_table` 分发协议、`netlink_rcv_skb` 切包分发、`netlink_ack` 报错/ACK。标准协议号只有 32 个，于是有了通用 netlink 这层多路复用——用一个名字换一个 `idr_alloc_cyclic` 动态分配的 ID，让任意驱动都能挂上自己的命令族。记住三件事：**消息可一条 buffer 塞多条**（靠 `nlmsg_len` 切）、**内核主动广播**（这才是它比 ioctl 强的核心）、**genetlink 解决坑位荒**。

## 动手验证（待 QEMU 亲测）

- **抓 rtnetlink 广播**：两个终端，一个 `ip monitor route`（订阅 `RTNLGRP_IPV4_ROUTE`），另一个 `ip route add 192.168.1.10 via 192.168.2.200`，看监听端秒出通知；再 `ip route del` 看带 `Deleted` 前缀的广播。
- **抓 genetlink**：`ip link set eth0 up` 时用 `strace -e socket,sendto,recvfrom ip ...` 观察 `AF_NETLINK`/`NETLINK_ROUTE` 的 syscall 序列；`iw dev wlan0 scan`（若有无线）观察 genetlink 的 `CTRL_CMD_GETFAMILY` 名字解析过程。
- **自发自收**：用 libmnl 或 libnl 写个小程序，`socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE)` → `RTM_GETLINK`（带 `NLM_F_DUMP`）→ 收多段消息直到 `NLMSG_DONE`，打印每个网卡的 ifinfomsg。输出与命令行号待亲测记录。

## 延伸阅读

- 源码（Linux 6.19）：
  - `net/netlink/af_netlink.c` — Netlink socket 核心：`netlink_create`、`netlink_kernel_create`（`__netlink_kernel_create`）、`netlink_unicast`、`netlink_broadcast`、`netlink_ack`、`netlink_rcv_skb`。
  - `net/netlink/genetlink.c` — 通用 netlink：`genl_pernet_init`、`genl_rcv`、`genl_ctrl`、`idr_alloc_cyclic`（族 ID 分配）。
  - `net/core/rtnetlink.c` — `rtnetlink_net_init`、`rtnetlink_rcv`、`rtnetlink_rcv_msg`、`rtnl_register`。
  - `include/uapi/linux/netlink.h`、`include/uapi/linux/genetlink.h`、`include/linux/netlink.h`、`include/net/genetlink.h` — 结构体、协议号、`GENL_START_ALLOC`/`GENL_MAX_ID` 定义。
- kernel.org 文档：
  - [Networking — Generic Netlink](https://docs.kernel.org/networking/generic_netlink.html)（对应源码树 `Documentation/networking/generic_netlink.rst`，正文本身很薄，基本只指向下面这篇 howto）
  - [Generic Netlink HOWTO (Linux Foundation Wiki)](https://wiki.linuxfoundation.org/networking/generic_netlink_howto)（更具体的编程指引）
  - [Networking subsystem documentation index](https://docs.kernel.org/networking/index.html)（搜 "netlink" 找各子系统文档）
- 进一步（持续铺开）：`netlink_diag`/`ss` 的实现（`NETLINK_SOCK_DIAG`，独立协议族）、libnl/libmnl 编程、`nl80211` 无线家族走读。