---
title: Netfilter：网络栈的钩子框架
slug: net-netfilter
difficulty: intermediate
tags: [Netfilter, 网络栈, 连接跟踪, NAT]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
related:
  - /tutorials/kernel/net/04-net-ipv4
sources:
  - notes: document/notes/linux_kernel_networking/ch09.md
  - notes: document/notes/linux_kernel_networking/ch09_2.md
  - notes: document/notes/linux_kernel_networking/ch09_4.md
  - notes: document/notes/linux_kernel_networking/ch09_6.md
  - notes: document/notes/linux_kernel_networking/ch09_7.md
---

# Netfilter：网络栈的钩子框架

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数名 / 超时值 / 挂载点均已逐条 grep 核对）；具体行号与命令输出待 QEMU 亲测核对。

## Netfilter 是网络栈的「检查站体系」

上一篇我们追着包从 `ip_rcv` 一路走到 `ip_output`，把 IPv4 收发路径的骨架摸了一遍。但那条路径上其实埋着一整套「海关系统」——每个包进站、出站、转发时，都要被一排检查员拦下来过一遍：查身份、改地址、记流水、决定放行还是扔掉。这套系统就是 **Netfilter**。

它是 Linux 防火墙、NAT、流量整形的共同地基。你在用户空间敲的 `iptables`、`nft`、`conntrack`，底下全是它。但 Netfilter 本身**不做任何具体策略**——它只提供「在协议栈关键路口插钩子」的能力，把活儿派给注册进来的模块。理解了这层「框架 vs 客户」的关系，后面看 conntrack、NAT、iptables 都会顺理成章。

## 五个挂载点：包一生要过的五个检查站

Netfilter 在 IPv4/IPv6 协议栈里钉了五个统一的钩子点，定义在 `include/uapi/linux/netfilter.h`（Linux 6.19）的 `enum nf_inet_hooks`：

```c
enum nf_inet_hooks {
    NF_INET_PRE_ROUTING,
    NF_INET_LOCAL_IN,
    NF_INET_FORWARD,
    NF_INET_LOCAL_OUT,
    NF_INET_POST_ROUTING,
    NF_INET_NUMHOOKS,
    NF_INET_INGRESS = NF_INET_NUMHOOKS,
};
```

把包想象成一列火车，这五个就是铁轨上的检查站，顺序严格由「铁轨物理连接」决定：

- **`PRE_ROUTING`**：所有入站包的**第一站**，嵌在 `ip_rcv()` 里。此刻内核还没查路由表，连包是发给本机还是要转发都不知道——所以是「通用捕包」的最佳位置。
- **`LOCAL_IN`**：嵌在 `ip_local_deliver()` 里。只有路由判决后确认「目的地是本机」的包才走这里。
- **`FORWARD`**：嵌在 `ip_forward()` 里，专给「过路车」——路由判决要转发的包走这条专用线。这是 Linux 当路由器的核心路径。
- **`LOCAL_OUT`**：嵌在 `__ip_local_out()` 里，本机进程发出的包的**始发站**。
- **`POST_ROUTING`**：嵌在 `ip_output()` 里，所有出站包的**最后一站**。转发包（刚过 FORWARD）和本机生成的包（刚过 LOCAL_OUT）在这里汇合。

于是三条包的旅行路线就清楚了：发给本机走 `PRE_ROUTING → LOCAL_IN`；本机发出走 `LOCAL_OUT → POST_ROUTING`；转发走 `PRE_ROUTING → FORWARD → POST_ROUTING`。你在 `LOCAL_IN` 里等一个转发的包，永远等不到——物理上不通。

## `nf_hook_ops`：注册一个钩子，靠它拿到通行证

光有检查站概念不够，内核得有一套机制把代码真正挂上去。这就是 `struct nf_hook_ops`——你的「派工单」。它定义在 `include/linux/netfilter.h`：

```c
struct nf_hook_ops {
    struct list_head    list;
    struct rcu_head     rcu;
    /* User fills in from here down. */
    nf_hookfn           *hook;
    struct net_device   *dev;
    void                *priv;
    u8                  pf;
    enum nf_hook_ops_type hook_ops_type:8;
    unsigned int        hooknum;
    /* Hooks are ordered in ascending priority. */
    int                 priority;
};
```

关键字段三件套：`pf`（协议族，`NFPROTO_IPV4`/`NFPROTO_IPV6`）+ `hooknum`（五个点之一）+ `priority`（优先级）一起决定了「把 `hook` 这个回调函数派到哪个检查站的哪个位置」。

`priority` 是个很容易翻车的点：**数值越小越先调用**。一个检查站上可能同时有查毒品、查关税、查违禁品的几拨人在执勤，谁先查由它定。内核给了标准常量（`NF_IP_PRI_FIRST`、`NF_IP_PRI_CONNTRACK`、`NF_IP_PRI_NAT_SRC` 等，定义在 `include/uapi/linux/netfilter_ipv4.h`）。要是你把过滤规则的优先级排得比连接跟踪还高，conntrack 可能直接失效——包还没被记录就被你 DROP 或改写了。

注册 API 在 `net/netfilter/core.c`：

```c
int nf_register_net_hook(struct net *net, const struct nf_hook_ops *reg);
int nf_register_net_hooks(struct net *net, const struct nf_hook_ops *reg, unsigned int n);
```

后者注册一组（数组），要么全成功要么全失败回滚，原子性好，多个点一起挂时用它。

### 钩子按优先级排序：`nf_hook_entries` 的 grow 逻辑

注册不是简单地往链表尾巴上塞。`nf_register_net_hook` 会调 `__nf_register_net_hook` → `nf_hook_entries_grow`，按 `priority` 把新回调**插到有序位置**，生成一份全新的 `struct nf_hook_entries`（柔性数组，`num_hook_entries` + `hooks[]`），再用 RCU 原子替换旧表（`rcu_assign_pointer`），旧表通过 `call_rcu` 延迟释放。整个替换是**无锁读、互斥写**——`nf_hook_mutex` 只保护注册/注销，包路径全程走 RCU 读锁。

一个细节：注销时不能直接删条目（怕有读者正在遍历），于是用 `WRITE_ONCE` 把该位回调换成 `accept_all`、`ops` 指针换成 `&dummy_ops`（`dummy_ops` 是那个永远返回 `NF_ACCEPT` 的占位，`net/netfilter/core.c`），**数组长度当场不变**。真正的「压缩」要等下一次有新钩子注册、`nf_hook_entries_grow` 重建这张表时，跳过 `dummy_ops` 条目，顺带把空位挤掉（`core.c` 里多次 `if (orig_ops[i] == &dummy_ops)` 跳过）。并没有一条独立的 shrink 路径——这是源码里那句注释「Hook unregistration must always succeed」的来由。

## 包过检查站：`NF_HOOK` 宏 → `nf_hook_slow`

协议栈在每个检查站都硬编码了 `NF_HOOK` 宏（`include/linux/netfilter.h`）。比如 `ip_local_deliver` 里：

```c
NF_HOOK(NFPROTO_IPV4, NF_INET_LOCAL_IN, net, sk, skb, in, out, okfn);
```

`NF_HOOK` 展开后先调 `nf_hook()`：它在 RCU 读锁下，按 `pf` 找到本网络命名空间 `net->nf.hooks_ipv4[hook]`（或 `hooks_ipv6`）这张表，初始化一个 `struct nf_hook_state`（装着 hook 号、入/出网卡、`okfn` 等），然后调 `nf_hook_slow(skb, &state, hook_head, 0)`。

> 一个性能优化很巧：开了 `CONFIG_JUMP_LABEL` 时，`nf_hook()` 开头先用静态键 `nf_hooks_needed[pf][hook]` 判断——如果这个检查站压根没注册任何钩子，直接返回 1，连 RCU 锁都不上。注册钩子时 `nf_static_key_inc` 才把静态键打开。零钩子的检查站近乎零开销。

`nf_hook_slow`（`net/netfilter/core.c`）就是遍历这张表，按优先级顺序逐个调回调，根据返回值决定走不走下一个：

```c
int nf_hook_slow(struct sk_buff *skb, struct nf_hook_state *state,
                 const struct nf_hook_entries *e, unsigned int s)
{
    unsigned int verdict;
    for (; s < e->num_hook_entries; s++) {
        verdict = nf_hook_entry_hookfn(&e->hooks[s], skb, state);
        switch (verdict & NF_VERDICT_MASK) {
        case NF_ACCEPT:
            break;            /* 继续下一个回调 */
        case NF_DROP:
            kfree_skb_reason(skb, SKB_DROP_REASON_NETFILTER_DROP);
            ...
            return ret;        /* 死刑，走人 */
        case NF_QUEUE:
            ret = nf_queue(skb, state, s, verdict);
            ...
        case NF_STOLEN:
            return NF_DROP_GETERR(verdict);  /* 被劫持，本模块接管 */
        ...
        }
    }
    return 1;   /* 全放行，调 okfn 继续原路 */
}
```

返回 `1` 是「全部放行」，`NF_HOOK` 宏据此再调 `okfn`（比如 `ip_local_deliver_finish`）让包继续原路旅程。

## 回调的裁决权：五种 verdict

回调函数原型 `nf_hookfn(void *priv, struct sk_buff *skb, const struct nf_hook_state *state)` 必须返回一个裁决值，定义在 `include/uapi/linux/netfilter.h`：

```c
#define NF_DROP    0   /* 丢弃，黑洞，对方啥也收不到 */
#define NF_ACCEPT  1   /* 放行，交给下一个 */
#define NF_STOLEN  2   /* 劫持，本模块全权接管（自己发或自己释放） */
#define NF_QUEUE   3   /* 送用户态队列（nfqueue 机制基础） */
#define NF_REPEAT  4   /* 再审一次 */
```

两个易踩的坑：`NF_STOLEN` 意味着后续协议栈代码再也看不到这个包，**偷了不释放就内存泄漏**；`NF_DROP` 的高 16 位被复用编码 errno（`NF_DROP_ERR` / `NF_DROP_GETERR`），所以 verdict 不是单纯的枚举，是个「编码后的复合值」，`nf_hook_slow` 里用 `verdict & NF_VERDICT_MASK` 取低 8 位判断动作。

## 连接跟踪 conntrack：给包打状态

到这里框架就讲完了——但防火墙光能逐包过滤不够。现实里我们常说「放行已建立连接的回包」，这要求内核知道「这条连接之前来过吗、握手完成没」。这就是 **conntrack（连接跟踪）**，有状态防火墙的基础。

核心数据结构是 `struct nf_conn`（`include/net/netfilter/nf_conntrack.h`），关键字段：

- **`tuplehash[IP_CT_DIR_MAX]`**：双向指纹。一个连接有两个方向——去程和回程，各算一个五元组 tuple，都插进全局哈希表。无论包从哪头来，算哈希都能命中同一个 `nf_conn`。
- **`status`**：状态位图。`IPS_SEEN_REPLY_BIT` 标记「见过回包没」，对应我们熟悉的 `NEW`/`ESTABLISHED`/`RELATED`/`INVALID` 状态。
- **`master`**：主从指针。FTP 这种协议控制连接在 21 端口、数据连接另开端口，conntrack 靠它把「小弟」数据连接挂到「老大」控制连接上。
- **`timeout`**：倒计时定时器。一段时间没流量就销毁回收，UDP 单向（unreplied）30 秒、双向（replied）120 秒这种差异都靠它。

> UDP 超时值核对自 Linux 6.19 源码 `net/netfilter/nf_conntrack_proto_udp.c` 的 `udp_timeouts[]`：`[UDP_CT_UNREPLIED] = 30*HZ`、`[UDP_CT_REPLIED] = 120*HZ`。**双向是 120 秒**（不是 180 秒——180 这个数来自旧笔记里的推测，别被带偏）。这些是内核编译期默认值，实际可经 `/proc/sys/net/netfilter/nf_conntrack_udp_timeout*` 调。TCP 的各状态超时同理在 `nf_conntrack_proto_tcp.c`，行号待亲测核对。

入口函数是 `nf_conntrack_in()`（`net/netfilter/nf_conntrack_core.c`），挂在 `PRE_ROUTING` 和 `LOCAL_OUT`，优先级 `NF_IP_PRI_CONNTRACK`。它干六件事：看 SKB 的 `nfct` 字段有没有已挂的连接（loopback/untracked 跳过）→ 确认 L3/L4 协议号 → L4 协议的 `error()` 合法性检查 → `resolve_normal_ct()` 算哈希查表，查不到就 `init_conntrack()` 建一个（**先进未确认列表**）→ 调协议的 `packet()` 处理函数刷新状态和超时 → 若是首个回包，置 `IPS_SEEN_REPLY_BIT`。

关键的「**两阶段确认**」：新建的 `nf_conn` 不敢直接进哈希表——万一包后面被某条规则 DROP 了，这条记录就不该存在。所以先挂「未确认列表」，等包一路过到 `POST_ROUTING`/`LOCAL_IN` 上的确认钩子，才正式入表。6.19 里这个确认回调叫 **`nf_confirm`**（`net/netfilter/nf_conntrack_proto.c`），分别挂在 `NF_INET_POST_ROUTING` 和 `NF_INET_LOCAL_IN`、优先级 `NF_IP_PRI_CONNTRACK_CONFIRM`；它内部调 `__nf_conntrack_confirm()`（`net/netfilter/nf_conntrack_core.c`）真正完成入表。中途被 DROP 就不 confirm，未确认条目最终被销毁。这就保证了哈希表里只存「真正活着」的连接。

> 版本提示：旧内核里确认函数叫 `ipv4_confirm`，6.19 起统一改名 `nf_confirm`（IPv4/IPv6 共用同一套实现）。读老书 / 老笔记看到 `ipv4_confirm` 时心里换算一下即可。

## iptables 前端：规则怎么变成钩子回调

iptables 在内核里**没有任何魔法**，它就是 Netfilter 的一个客户。核心代码在 `net/ipv4/netfilter/ip_tables.c`。

每个「表」（filter/nat/mangle）是一个 `struct xt_table`，表定义里用位图 `valid_hooks` 声明自己只在哪些检查站生效。以 filter 表（`net/ipv4/netfilter/iptable_filter.c`）为例：

```c
#define FILTER_VALID_HOOKS ((1 << NF_INET_LOCAL_IN) | \
                            (1 << NF_INET_FORWARD) | \
                            (1 << NF_INET_LOCAL_OUT))
static const struct xt_table packet_filter = {
    .name        = "filter",
    .valid_hooks = FILTER_VALID_HOOKS,
    .af          = NFPROTO_IPV4,
    .priority    = NF_IP_PRI_FILTER,
};
```

初始化时（`iptable_filter.c:86`）用 `xt_hook_ops_alloc(&packet_filter, ipt_do_table)` **一次性为三个 hook 点生成 ops 数组**，回调直接就是 `ipt_do_table` 本身（作为 `nf_hookfn` 传进去）。换句话说，filter / security / raw 这类表根本不套中间包装函数，**直接拿规则引擎当回调**——包走到 `LOCAL_IN` 时被调的正是 `ipt_do_table`，它遍历表里规则逐条匹配。只有 mangle 表会套一层 `iptable_mangle_hook`（因为 mangle 要在 hook 里改包再决定走不走表）。

> 版本提示：旧资料里常提的 `xt_hook_link()` / `iptable_filter_hook()` 在 6.19 源码里已经不存在——`grep xt_hook_link` 全内核无定义（只剩 `x_tables.c` 注释里的历史痕迹）。filter 表现在统一走 `xt_hook_ops_alloc`。

匹配靠 **`xt_match`**（如 `-m conntrack --ctstate`、`-p tcp --dport`），动作靠 **`xt_target`**（如 `-j DROP`、`-j LOG`、`-j SNAT`）。这些扩展各自注册到内核，`ipt_do_table` 把它们串成流水线：match 是「质检传感器」判断成色，target 是「机械臂」做最终处理，返回 verdict。

一条 `iptables -A INPUT -p udp --dport=5001 -j LOG` 的旅行：包过 `PRE_ROUTING`（filter 表没挂这里，无感）→ 路由判决「目的地是本机」→ 进 `LOCAL_IN` → `ipt_do_table` 匹配命中 → LOG target 打 syslog → 返回 `NF_ACCEPT` → `okfn`=`ip_local_deliver_finish` 继续上交 L4。

## NAT：靠 conntrack 记账的地址改写

NAT 干的事就是改写 IP 头的源/目地址（顺带 L4 端口）。改目地址（DNAT）和改源地址（SNAT）是两种基本动作，但它们**不止各挂一个点**——6.19 源码 `net/ipv4/netfilter/iptable_nat.c` 里 NAT 表的 `valid_hooks` 挂的是四个点：

```c
static const struct xt_table nf_nat_ipv4_table = {
    .name        = "nat",
    .valid_hooks = (1 << NF_INET_PRE_ROUTING) |
                   (1 << NF_INET_POST_ROUTING) |
                   (1 << NF_INET_LOCAL_OUT) |
                   (1 << NF_INET_LOCAL_IN),
    ...
};
```

对应的 `nf_nat_ipv4_ops[]` 四条回调（回调同样是直接指向 `ipt_do_table`）：

| hook 点 | 优先级 | 干的活 |
|:---|:---|:---|
| `PRE_ROUTING` | `NF_IP_PRI_NAT_DST` | DNAT：路由前改目地址 |
| `POST_ROUTING` | `NF_IP_PRI_NAT_SRC` | SNAT：出站前改源地址 |
| `LOCAL_OUT` | `NF_IP_PRI_NAT_DST` | DNAT：本机发出包改目地址 |
| `LOCAL_IN` | `NF_IP_PRI_NAT_SRC` | SNAT：送本机包改源地址 |

一句话归纳：**改目（DNAT）在 `PRE_ROUTING` 和 `LOCAL_OUT`，都在路由判决之前；改源（SNAT）在 `POST_ROUTING` 和 `LOCAL_IN`，都在路由判决之后、即将上交 / 离开之际。** 唯独 `FORWARD` 被 NAT 表排除——转发节点上路由已决，NAT 在这个中间地带没活干（这点跟原草稿一致）。

> 之前若记成「SNAT 只在 POST_ROUTING、DNAT 只在 PRE_ROUTING」，那是漏了一半：本机发出的包要 DNAT 得在 `LOCAL_OUT`，送到本机的包要 SNAT 得在 `LOCAL_IN`。把这四个点补齐才完整。

NAT 改完地址，**必须同步更新对应的 conntrack 条目**：`tuplehash` 两个方向的 tuple（改了地址 tuple 就得重算），以及挂在 `nf_conn` 扩展区（`nf_conn_nat`）里的 NAT 映射信息。改了地址忘了更新 conntrack，回包就找不到原连接——那就是灾难。这也是 SNAT/DNAT 强依赖 conntrack 的根本原因：NAT 表本质是「在 conntrack 记录上做地址映射」。

> 注：`nf_nat_hook`（`include/linux/netfilter.h`）是**单个** `const struct nf_nat_hook __rcu *` 指针，不是链表——它只是一组 NAT 回调函数的挂钩点；真正的 NAT 映射存在 conntrack 扩展里，别把「映射记录」和这个 hook 指针搞混。

## 小结

Netfilter 是「协议栈钩子框架 + 注册机制」的地基：五个 `nf_inet_hooks` 检查站、`nf_hook_ops` 派工单（`pf`+`hooknum`+`priority`）、`nf_hook_slow` 按优先级遍历回调、五种 verdict 裁决包命运。它本身不做策略，策略由注册进来的模块提供：conntrack 给包打状态（`nf_conn` 双向 tuple + 两阶段确认，6.19 确认回调统一叫 `nf_confirm`），iptables 用 `xt_table`+`xt_match`+`xt_target` 把用户规则编译成钩子回调（filter 表直接拿 `ipt_do_table` 当回调，`xt_hook_ops_alloc` 生成 ops），NAT 挂在 `PRE_ROUTING`/`POST_ROUTING`/`LOCAL_OUT`/`LOCAL_IN` 四个点改地址并同步更新 conntrack 记账。

记住三件事：**优先级纪律**（数值小先调，过滤别抢在 conntrack 前面）、**FORWARD 上 NAT 无活**（NAT 表的 `valid_hooks` 明确排除 FORWARD）、**UDP conntrack 双向 120 秒**（不是 180，源自 6.19 `nf_conntrack_proto_udp.c`）。

## 延伸阅读

- 源码（Linux 6.19）：
  - `net/netfilter/core.c`（`nf_register_net_hook` / `nf_hook_slow` / 钩子表 grow 与 RCU 替换 / `dummy_ops`+`accept_all` 占位）；
  - `include/linux/netfilter.h`（`struct nf_hook_ops` / `NF_HOOK` 宏 / `nf_hook_state` / `nf_nat_hook`）；
  - `include/uapi/linux/netfilter.h`（`enum nf_inet_hooks` / verdict 常量）；
  - `net/netfilter/nf_conntrack_core.c`（`nf_conntrack_in` / `__nf_conntrack_confirm`）；
  - `net/netfilter/nf_conntrack_proto.c`（确认回调 `nf_confirm`，优先级 `NF_IP_PRI_CONNTRACK_CONFIRM`）；
  - `net/netfilter/nf_conntrack_proto_udp.c`（`udp_timeouts`：unreplied `30*HZ` / replied `120*HZ`）；
  - `net/ipv4/netfilter/ip_tables.c`（`ipt_do_table`）；
  - `net/ipv4/netfilter/iptable_filter.c`（`xt_hook_ops_alloc(&packet_filter, ipt_do_table)`）；
  - `net/ipv4/netfilter/iptable_nat.c`（NAT 表 `valid_hooks` 四点 + `nf_nat_ipv4_ops`）。
- docs.kernel.org：[Netfilter sysctl](https://docs.kernel.org/networking/netfilter-sysctl.html)、[nf_conntrack sysctl](https://docs.kernel.org/networking/nf_conntrack-sysctl.html)、[Networking 子系统文档索引](https://docs.kernel.org/networking/index.html)。
- 进一步（持续铺开）：nftables（iptables 的后继，`nf_tables` 引擎）、conntrack 的 helper/expectation（FTP/IRC 之类 RELATED 连接怎么来）、NAT 回调 `nf_nat_fn` 内部怎么重算校验和。