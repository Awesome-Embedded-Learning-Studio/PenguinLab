---
title: sk_buff：贯穿网络栈的快递盒
slug: net-sk-buff
difficulty: intermediate
tags: [网络栈, sk_buff, 数据结构, 缓冲区管理]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/01-net-overview
related:
  - /tutorials/kernel/net/01-net-overview
sources:
  - notes: document/notes/linux_kernel_networking/ch01_2.md
  - notes: document/notes/linux_kernel_networking/ch01_3.md
  - notes: document/notes/linux_kernel_networking/ch04_2.md
  - notes: document/notes/linux_kernel_networking/ch04_5.md
  - notes: document/notes/linux_kernel_networking/ch04_6.md
  - notes: document/notes/linux_kernel_networking/ch04_9.md
---

# sk_buff：贯穿网络栈的快递盒

> 🔨 **整理中** · 这篇是从《Linux 内核网络》ch01（Socket Buffer 节）和 ch04（IPv4 收发/分片）读书笔记整理出来的骨架，sk_buff 的四指针模型、收包剥头/发包加头那套机制已经讲透了。**本篇函数签名/字段/数值已对照 Linux 6.19 源码校订（读书笔记基于较早内核版本，部分接口已演进）；具体行号仍待 QEMU 亲测核对。** 但动手部分还没在 QEMU 里亲跑过——下一步要写个内核模块 `alloc_skb` 出来，把 `head/data/tail/end` 四个指针在 `reserve/put/push/pull` 一步步移动的真实数值打出来核对。验过就升级成 ✅ 已锤炼。

## sk_buff 不是包，是包的「快递盒 + 运单」

刚翻进网络栈，第一个撞上的就是 `sk_buff`（社区里都叫它 **SKB**）。很多人第一反应是：「这不就是装数据包的那块内存吗？」——错。**SKB 不是包本身，它是包的「快递盒 + 运单」。** 数据包字节躺在盒子里那块叫线性区的内存里（有时还搭几页零散的 frags），而 SKB 这个结构体本身，是一堆指针和元数据，记录着「这货从哪来、往哪去、现在头部指向第几层、归谁所有」。

笔记里 `ch01_2` 直接把话挑明了：SKB 是「数据包在内核里的肉身」——不管这包刚被网卡驱动捞上来、还是正准备从 TCP 层发出去，它在内核里都是一个 SKB。盒子里装的字节可以一层一层剥、一层一层加，但盒子始终是同一个，这就是它能在协议栈各层之间高速传递而不需要反复拷贝的关键。

## 为什么不直接用裸 buffer

如果只是装字节，一个 `char *` 数组不就够了吗？干嘛要套这么复杂一层结构。三个理由：

1. **分层元数据**：网络栈是 L2/L3/L4 三层流水线。每一层都要知道自己关心的头部在哪、协议类型是什么、关联哪张网卡。这些信息塞进裸 buffer 里没法分层管理，所以单独拎出来做成 SKB 的字段（`dev`、`protocol`、那一串 `*_header` 偏移）。
2. **跨层零拷贝传递**：收包是从 L2 往 L4 剥头、发包是从 L4 往 L2 加头。如果每过一层都拷贝整个包，千兆网卡下 CPU 早被搬数据的活儿压垮了。SKB 靠挪指针（不动数据）实现「层层蜕变」，数据本身始终待在原处。
3. **引用计数共享**：组播要一份包同时发往多个目的地，或者 netfilter/抓包工具想顺手看一眼包——总不能每次都深拷贝。SKB 自带引用计数（`users` 字段，6.19 里是 `refcount_t` 类型），可以克隆共享。

> ch01_3 的「要点提炼」里那句话很到位：SKB 通过维护 `head`、`data`、`tail` 等指针灵活处理协议头部的剥除与添加，让收包时能层层「剥皮」，实现了协议层级间零拷贝的高性能。

## 关键字段巡礼

照着 `include/linux/skbuff.h`（Linux 6.19）里的 `struct sk_buff` 定义，挑核心成员点一遍（行号待亲测核对）：

```c
struct sk_buff {
    /* ... */
    struct sock             *sk;            /* 拥有这个包的套接字      */
    struct net_device       *dev;           /* 关联的网卡设备          */
    /* ... */
    __u8                    pkt_type:3;     /* 包类型（单播/组播/广播）*/
    /* ... */
    __be16                  protocol;       /* 协议类型               */
    /* ... */
    sk_buff_data_t          tail;           /* 尾部指针                */
    sk_buff_data_t          end;            /* 结束指针                */
    unsigned char           *head,
                            *data;          /* 头部和数据指针          */
    __u16                   transport_header; /* L4 头部偏移          */
    __u16                   network_header;  /* L3 头部偏移          */
    __u16                   mac_header;      /* L2 头部偏移          */
    /* ... */
};
```

几个最常打交道的：

- **`next` / `prev`**：SKB 自带链表指针，可以串成队列（比如 socket 的接收队列、发送队列 `sk_write_queue`）。一个 IP 包分片就是一串挂在 `frag_list` 上的 SKB 链。
- **`dev`**：这个包归哪张网卡。收上来的包记输入网卡，发出去的包记输出网卡——内核要根据这张网卡的 MTU 决定要不要切片。
- **`sk`**：拥有这个包的 socket。**转发的包 `sk` 是 `NULL`**，因为它不是本地生的，只是个「过路客」（ch01_2 原话）。
- **`pkt_type` / `protocol`**：收包时由 `eth_type_trans()` 填，前者区分单播/组播/广播（`PACKET_HOST`/`PACKET_MULTICAST`/`PACKET_BROADCAST`），后者记以太网 Type（`0x0800` 是 IPv4，`0x86DD` 是 IPv6）。
- **`transport_header` / `network_header` / `mac_header`**：三层头部各自在缓冲区里的偏移位置。要拿对应层头部用配套的取值宏，不直接读指针。

> 字段类型对齐 6.19：三层 `*_header` 偏移字段都是 `__u16`（偏移量足够小，省内存）；`head`/`data` 是 `unsigned char *` 指针；`tail`/`end` 是 `sk_buff_data_t`（64 位内核下就是 `unsigned int`，同样是偏移量）。完整定义在 `include/linux/skbuff.h`，远不止这些——笔记建议遇到卡壳就回附录 A 翻「字典」。

## 房间四指针：head / data / tail / end

整个 SKB 内存区想象成一间「房间」，四面墙各立一根标尺：

- **`head`**：房间最左边的墙，缓冲区起始。分配后就固定不动。
- **`data`**：当前有效数据的起点。这根线是「活动」的——收包剥头往后挪、发包加头往前挪。
- **`tail`**：当前有效数据的终点。往里塞数据就往后挪。
- **`end`**：房间最右边的墙，缓冲区终止。

`head` 和 `end` 围出整个缓冲区；`data` 和 `tail` 之间是**当前装着的数据**；`head` 到 `data` 之间那块叫 **headroom**（预留的头空间），`tail` 到 `end` 之间那块叫 **tailroom**（预留的尾空间）。这两块预留是后面 `push`/`put` 操作能成立的物理基础。

收包时 L2 头在最前面，`data` 指着 L2 头；发包时是反着来的，先把数据放中间，头从前往后 push。同一块缓冲区，两种方向都能玩，全靠这四根线配合。

## 房间伸缩四件套

这四个操作是 SKB 的「黄金法则」——笔记 ch01_2 反复警告：**千万别手动 `skb->data++`**，一切走配套 API。因为它们除了挪指针，还得维护 SKB 内部那个线性区和分页结构的账。

| 操作 | 干什么 | 形象 | 典型场景 |
|:---|:---|:---|:---|
| `skb_reserve(skb, len)` | `data` 和 `tail` 同时往后挪 len 字节 | 在房间前部空出预留区 | 分配后立刻预留头空间 |
| `skb_put(skb, len)` | `tail` 往后挪 len，扩展数据区 | 尾部放大装数据 | 往包里 append 数据 |
| `skb_push(skb, len)` | `data` 往前挪 len，吃掉一段 headroom | 前推加一层协议头 | 发包层层加头（L4→L3→L2）|
| `skb_pull(skb, len)` | `data` 往后挪 len，剥掉一段头部 | 收缩剥头 | 收包层层剥头（L2→L3→L4）|

**收包：层层剥头。** 最经典的例子是驱动把包交给 L3 那一刻。笔记 ch01_2 写得很细：以太网帧进内存时 `skb->data` 指着 L2 头，但交给 L3 时内核希望 `data` 指着 L3（IP）头。**在 6.19 里这一跳经了一层包装**：`eth_type_trans()`（`net/ethernet/eth.c`）自己负责 `skb_reset_mac_header()`、`eth_skb_pkt_type()`（填 `pkt_type`）、判断协议填 `protocol`；真正剥 L2 头的活儿它转手交给了内联函数 `eth_skb_pull_mac()`（`include/linux/etherdevice.h`），后者就一句 `skb_pull_inline(skb, ETH_HLEN)`——正好是 14 字节——指针往后一跳，跳过 L2 头。

```c
/* include/linux/etherdevice.h：eth_skb_pull_mac，剥掉 14 字节以太网头 */
static inline struct ethhdr *eth_skb_pull_mac(struct sk_buff *skb)
{
    struct ethhdr *eth = (struct ethhdr *)skb->data;
    skb_pull_inline(skb, ETH_HLEN);   /* ETH_HLEN == 14 */
    return eth;
}
```

笔记的比喻依然成立：「你在剥洋葱，剥掉一层（L2），手里剩下的刚好是下一层（L3）。」只是别去 `eth_type_trans()` 函数体里找 `skb_pull_inline` 这行——它在 `etherdevice.h` 里。

ch04_2 的 `ip_rcv()` 拿到包时，L2 头已经剥掉了，`skb->data` 正指着 IPv4 头，`ip_hdr(skb)` 取出来的就是 IP 头——这是收包剥头的接力。（顺带一提：6.19 里 `ip_rcv()` 把实际处理塞进了 `ip_rcv_core()` 辅助函数，但「L2 已剥、data 指 IP 头」这个接力关系不变。）

**发包：层层加头，顺序相反。** `__ip_queue_xmit()`（`net/ipv4/ip_output.c`，对外导出包装是 `ip_queue_xmit()`，ch04_5 笔记记的就是这条 TCP 路径）里写得明明白白：SKB 从传输层下来时 `data` 指着 TCP 头，要给 IP 头腾位置就得 `skb_push()`：

```c
/* net/ipv4/ip_output.c：TCP 层下来的 skb，data 指着传输层头，往前推腾出 IP 头 */
skb_push(skb, sizeof(struct iphdr) + (inet_opt ? inet_opt->opt.optlen : 0));
skb_reset_network_header(skb);
iph = ip_hdr(skb);
```

push 完，`data` 往前挪到了 IP 头的位置，正好把 TCP 头「盖」在前头。到了 L2 还会再 push 一次以太网头。整条发包路径是「数据放中间，头部从外向内一层层 push 包上去」。

> 想拿各层头还有配套取值宏：`skb_transport_header()` 拿 L4、`skb_network_header()` 拿 L3、`skb_mac_header()` 拿 L2；还有 `skb_reset_*` 系列重置对应偏移。

## 分配与释放

**分配**收包路径上，驱动用 `netdev_alloc_skb()`（老代码里还常能见到薄包装 `dev_alloc_skb()`，6.19 里它仍以 legacy helper 形式保留）分配 SKB，见 ch01_2。分片慢路径里能看到最底层的 `alloc_skb()` 用法——下面这段忠实还原笔记 ch04_6 贴的较早内核 `ip_fragment()` 写法，把四件套里的两个串起来了：

```c
/* 分片慢路径：为每个碎片新分配 SKB（结构对应较早内核；6.19 等价代码见下注） */
if ((skb2 = alloc_skb(len + hlen + ll_rs, GFP_ATOMIC)) == NULL) {
    err = -ENOMEM;
    goto fail;
}
ip_copy_metadata(skb2, skb);
skb_reserve(skb2, ll_rs);          // 先预留链路层头空间
skb_put(skb2, len + hlen);         // 尾部放大，装 IP 头 + 数据
skb_reset_network_header(skb2);
skb2->transport_header = skb2->network_header + hlen;
```

先 `skb_reserve` 在前部留出 L2 头空间（发包时要 push 以太网头进去），再 `skb_put` 把数据区撑开。注意这里用的 `GFP_ATOMIC`——分片可能持着锁，不能睡眠。

> **6.19 对齐**：这段对应的是较早期内核的 `ip_fragment()`。在 6.19 里，分片主入口拆得更细了：`ip_fragment()`（`ip_output.c`）先判断 DF 位，把真正的切包活儿转交给 `ip_do_fragment()`；而上面这段 alloc/reserve/put 的代码已经被抽进辅助函数 `ip_frag_next()`（`ip_output.c`），`ip_do_fragment()` 的 `while` 循环里就一句 `skb2 = ip_frag_next(skb, &state)`。但 `alloc_skb + skb_reserve + skb_put + skb_reset_network_header` 这套四件套用法**一字未改**——`ip_frag_next()` 里逐行对得上。所以学四件套看这段老代码反而更直白。

**释放**有两套。普通丢弃用 `kfree_skb()`（DF 位置位拒绝分片那条路径里直接 `kfree_skb(skb)` 扔包）；如果是正常消费完（数据已发出去、引用该回收了）用 `consume_skb()`。分片收尾就是 `consume_skb(skb)` 释放原始大包（`ip_do_fragment()` 成功收尾处）。两者区别在语义和统计计数——`kfree_skb` 通常意味着「异常丢弃」，`consume_skb` 意味着「正常用完」。

> 更精确地说，6.19 里 `kfree_skb()` 是 `kfree_skb_reason(skb, SKB_DROP_REASON_NOT_SPECIFIED)` 的内联包装，**会走 skb drop reason 子系统、记进丢包统计**；而 `consume_skb()` 是成功路径的引用回收，**不记丢包**。所以这俩不止是命名差异，连计数器都分得清清楚楚。

**headroom / tailroom 预留的意义**：分配时故意多留一段头空间（`netdev_alloc_skb` 这类会预留 `NET_SKB_PAD`——6.19 里定义为 `max(32, L1_CACHE_BYTES)`），就是为了后面发包时 `skb_push` 加各层头不用重新分配内存。如果头空间不够 push，会触发代价昂贵的 `__pskb_pull_tail` / `pskb_expand_head` 重新分配——高性能路径要极力避免。

## 共享与克隆

同一个包想被多方同时看一眼（组播、netfilter、抓包），就得能共享。SKB 有两套拷贝机制，笔记里能拼出来：

- **`skb_clone(skb, gfp)`**：浅拷贝。**只复制 SKB 这个结构体本身，底层数据共享同一块缓冲区**。两个 SKB 各自有独立的元数据（指针、头部偏移可以各挪各的），但指向的数据是同一份、只读。引用计数管理，谁都不许改共享数据。适合「我只想偷看一眼这个包」。
- **`pskb_copy(skb, gfp)`** / **`skb_copy(skb, gfp)`**：深拷贝。连数据区一起复制一份，两个 SKB 彻底独立。代价大，只有真要改数据时才用。

引用计数是这套共享的命根子——`skb->users`（6.19 里是 `refcount_t`）。`kfree_skb` / `consume_skb` 不是直接释放，而是先把引用计数减一，减到 0 才真释放底层数据。所以「持有 SKB 的各方各自管理自己的引用」是铁律。

## 小结

`sk_buff` 是网络栈里数据包的唯一肉身：一块缓冲区（head/data/tail/end 四根线围出来），外加一堆元数据（dev、sk、三层 header 偏移、protocol、pkt_type）。它的精妙全在那四根线上——`skb_reserve` 预留、`skb_put` 装数据、`skb_push` 加头、`skb_pull` 剥头，让收包层层剥、发包层层加而数据不动，实现了跨层零拷贝。配合 `alloc_skb`/`kfree_skb`/`consume_skb` 的生命周期和 `skb_clone`/`pskb_copy` 的共享语义，整个网络栈的高数据通路才转得起来。

记住两件事：**一切指针操作走配套 API、绝不手动 `data++`**；以及 **发包是数据在中间头往外 push、收包是头往里 pull 剥掉**——方向相反，但用的是同一块缓冲区、同一套四指针。

## 动手试试

> ⚠️ **待亲测**：下面的方案还没在 QEMU 上跑过，先把骨架立在这。
>
> **目标**：写一个最小内核模块，`alloc_skb` 一个 SKB，把 `reserve/put/push/pull` 四步各执行一次，每步打印 `head/data/tail/end` 四个指针（以及 `skb_headlen`/`skb_tailroom`/`skb_headroom`），肉眼核对指针移动方向是否和正文那张表一致。
>
> **验证清单（待填真实数值）**：
> - [ ] `alloc_skb` 之后 `data == tail`（数据区为空），`headroom == NET_SKB_PAD`、`tailroom == sizeof(skb_shared_info)` 量级
> - [ ] `skb_reserve(skb, 16)` 后 `data`、`tail` 同时 +16，`headroom` 缩 16、数据区仍为空
> - [ ] `skb_put(skb, 20)` 后 `tail` +20，数据区长度变 20，`tailroom` 缩 20
> - [ ] `skb_push(skb, 10)` 后 `data` -10，数据区长度变 30（10+20），`headroom` 缩 10
> - [ ] `skb_pull(skb, 10)` 后 `data` +10，数据区长度回到 20
>
> **踩坑预警（待亲测验证）**：`skb_push`/`skb_pull` 越界会触发 `BUG()`（不是返回错误），所以 reserve 的量必须够 push 用——这正好印证正文那句「headroom 不够就触发 `pskb_expand_head` 重分配」。具体宏的真实行为、`SKB_DATA_ALIGN` 的对齐填充，以及 `dmesg` 里打出来的指针差值，都以 QEMU 亲跑为准，回头补进正文。

## 延伸阅读

- 源码：`include/linux/skbuff.h`（Linux 6.19），`struct sk_buff` 定义 + 全套 `skb_*` 内联函数；`net/core/skbuff.c`，`alloc_skb` / `kfree_skb` / `consume_skb` / `skb_clone` / `pskb_copy` 实现；`include/linux/etherdevice.h`，`eth_skb_pull_mac` / `eth_skb_pkt_type`；`net/ethernet/eth.c`，`eth_type_trans`；`net/ipv4/ip_output.c`，`__ip_queue_xmit` / `ip_do_fragment` / `ip_frag_next`。
- 笔记：`document/notes/linux_kernel_networking/ch01_2.md`（SKB 诞生与黄金法则）、`ch01_3.md`（要点提炼里的四指针总结）、`ch04_2.md`（`ip_rcv` 收包剥头接力）、`ch04_5.md`（发包 `skb_push` 加 IP 头）、`ch04_6.md`（分片慢路径的 `alloc_skb`/`reserve`/`put`）、`ch04_9.md`（IPv4 方法速查，含 `skb_has_frag_list` 改名典故）。
- kernel.org：[Networking documentation](https://docs.kernel.org/networking/index.html)、[Core API](https://docs.kernel.org/core-api/index.html)（持续铺开，skb 详细文档以官方稳定索引页为准）。
- 进一步（待铺开）：`frag_list` / `frags[]` 两种分片方式、`skb_shared_info`、NAPI 收包与 SKB 批量回收。