---
title: "IPsec 与 XFRM：内核怎么给数据包穿装甲"
slug: net-ipsec-xfrm
difficulty: intermediate
tags: [网络栈, IPsec, XFRM, ESP, NAT-T, VPN]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/04-net-ipv4
related:
  - /tutorials/kernel/net/04-net-ipv4
sources:
  - notes: document/notes/linux_kernel_networking/ch10.md
  - notes: document/notes/linux_kernel_networking/ch10_1.md
  - notes: document/notes/linux_kernel_networking/ch10_3.md
  - notes: document/notes/linux_kernel_networking/ch10_4.md
  - notes: document/notes/linux_kernel_networking/ch10_5.md
  - notes: document/notes/linux_kernel_networking/ch10_6.md
  - notes: document/notes/linux_kernel_networking/ch10_7.md
  - notes: document/notes/linux_kernel_networking/ch10_8.md
---

# IPsec 与 XFRM：内核怎么给数据包穿装甲

> 🔨 **整理中** · 本篇机制对照 **Linux 6.19** 源码讲解，函数名 / 数据结构 / 字段已经逐一在 `net/xfrm/`、`net/ipv4/esp4.c`、`net/ipv4/xfrm4_input.c` 里核对过；但具体行号、`ip xfrm` 命令输出、strongSwan 跑隧道这些动手环节，等我们在 QEMU 里亲测过再升级成 ✅ 已锤炼。

## IPsec 到底在防谁

先回答一个老问题：**有了 HTTPS（TLS），为啥还要 IPsec？**

TLS 保护的是"某一条连接"——它长在应用层和传输层之间，应用得主动配合才行。但如果你想让两台机器之间**所有**流量都加密（SSH、ICMP、甚至某个不走 TLS 的老旧服务），靠应用自己加 TLS 是不现实的。IPsec 干的就是这件事：它长在 **IP 层（L3）**，把"加密"这件事下沉到内核，应用完全无感——你的 TCP、UDP、ICMP 透明地被套上了装甲。

所以 IPsec 是企业 VPN 的事实标准。这一篇我们钻进内核，看一台 Linux 机器是怎么把一个明文 IP 包变成密文、又怎么在收到时还原的。整个引擎有个名字：**XFRM**（读作 transform）。

## 两种模式：传输 vs 隧道

IPsec 加密 IP 包，但"加密到哪一层"有两种选择，这就是传输模式和隧道模式的区别。

**传输模式（transport）**：原 IP 头不动，只加密 IP 载荷（也就是 TCP/UDP 头之后的内容）。像给快递员穿防弹衣——人还是那个人，路线不变，只是身体被保护了。适合端到端加密，IP 头必须能正常路由用，所以不能用私有地址。

**隧道模式（tunnel）**：把**整个原始 IP 包**（连同原 IP 头）当载荷加密，再套一个全新的 IP 头出去。新 IP 头是网关地址。像把装甲车再装进火车车厢——外面只看到一列火车从 A 地开往 B 地，车厢里装了什么谁也不知道。VPN 几乎都走隧道模式，因为它能把私有地址（`192.168.x.x`）藏在公网传输的新头后面。

模式信息存在 SA 的属性里：`struct xfrm_state` 的 `props.mode` 字段（`XFRM_MODE_TRANSPORT` / `XFRM_MODE_TUNNEL`）。这个字段后面在接收路径里会决定内核怎么"拆封装"。

## AH 和 ESP：ESP 才是主角

IPsec 协议族有两个成员：

- **AH（Authentication Header）**：只做完整性 + 认证，不加密。像透明封套——能看但改不了。因为 AH 会校验 IP 头本身，NAT 一改地址就完蛋，所以实际几乎没人用。
- **ESP（Encapsulating Security Payload）**：既加密又认证，协议号 **50**（`IPPROTO_ESP`）。这是真正的重头戏，也是本篇主角。

ESP 包是个"夹心饼干"，结构长这样（RFC 4303）：

```
[ SPI(4B) | Seq | 加密载荷 | Padding | PadLen | NextHdr | ICV ]
```

- **SPI**（Security Parameter Index）：32 位，配合目的地址 + 协议号唯一标识一个 SA，是查表的钥匙。
- **Seq**（序列号）：抗重放攻击，收端维护滑动窗口，重复或太旧的包直接丢。
- **ICV**（Integrity Check Value）：防篡改指纹，改一个字节就对不上。

性能上有条演进线：老式做法是"先 AES-CBC 加密、再 HMAC-SHA 算 ICV"，数据要扫两遍。现代内核偏好 **AEAD** 算法（如 AES-GCM），加密和认证一次搞定，配合 AES-NI 指令集，跑好几 Gbit/s 轻轻松松。

## XFRM 框架：策略当老板，状态当员工

XFRM 的设计哲学是"协议无关"——通用逻辑（策略管理、状态维护、垃圾回收）复用在 `net/xfrm/` 下，具体协议实现（ESP4/ESP6/AH4）单独放。它维护两本账：

**SPD（Security Policy Database，安全策略库）**——这是"法律"，决定哪些包该被 IPsec 处理。一条策略是 `struct xfrm_policy`，靠 **selector**（`struct xfrm_selector`，含源/目的地址、端口、协议、前缀长度）来匹配流量，`xfrm_selector_match()` 做比对。策略有个 `action` 字段：`XFRM_POLICY_ALLOW` 放行、`XFRM_POLICY_BLOCK` 拦截。策略不直接指定密钥，它只挂"模板"（`xfrm_vec[]`，最多 `XFRM_MAX_DEPTH` 个），把"先 ESP 再封装"这种复合动作描述出来。

**SAD（Security Association Database，安全关联库）**——这是"武器"，真正干活的家伙。一个 SA 是 `struct xfrm_state`，里面装满敏感信息：算法指针（`aalg`/`ealg`/`aead`）、重放窗口（`replay_window`）、模式（`props.mode`）、身份证 `id`（目的地址 + SPI + 协议号三元组）。**SA 是单向的**，双向通信要两个 SA（一进一出）。

SA 在内核里挂三张哈希表（在 `struct netns_xfrm` 里）：`state_bydst`、`state_bysrc`、`state_byspi`——三把钥匙开同一扇门，根据手头线索选入口。`xfrm_state_lookup()` 走 `state_byspi`，是接收路径最常用的。

用户空间怎么跟内核对话？靠 **Netlink**（`NETLINK_XFRM`）。你在命令行敲 `ip xfrm state add ...`，会变成 `XFRM_MSG_NEWSA` 消息飞进内核，被 `xfrm_netlink_rcv()` 接住。密钥协商（IKE）那部分是用户空间守护进程（strongSwan / Charon）的活，谈完结果通过 Netlink 下发给内核，内核只管执行。

## SA 的生命周期：状态机长什么样

SA 不是凭空冒出来的。`xfrm_state_alloc()`（`net/xfrm/xfrm_state.c:731`，Linux 6.19）负责分配：从 slab 缓存 `xfrm_state_cache` 拿一块内存，引用计数 `refcnt` 初始化为 1，给三张哈希表的节点和两个定时器（`mtimer` 管寿命、`rtimer` 管重放）挂上回调，生命周期限制 `lft` 默认填 `XFRM_INF`（无限）。

协商好的 SA 通过 `xfrm_state_add()`（`xfrm_state.c:1887`）插入 SAD，内部走 `__xfrm_state_insert()`（`xfrm_state.c:1721`），把节点同时挂进三张哈希表。SA 有个状态字段 `km.state`：`XFRM_STATE_VALID`（可用）、`XFRM_STATE_ACQ`（正在协商的"幼虫"态）、`XFRM_STATE_DEAD`（已死）等。接收路径里如果查到 SA 但状态不是 `VALID`，直接记一笔 `XFRMINSTATEINVALID` 然后丢包。

删除不直接释放内存。`__xfrm_state_delete()`（`xfrm_state.c:811`）先把状态置成 `XFRM_STATE_DEAD`、从哈希表摘下来；真正的内存回收走延迟路径——`__xfrm_state_destroy()`（`xfrm_state.c:800`）把对象塞进 GC 链表 `xfrm_state_gc_list`，再 `schedule_work()` 异步清理。这是内核老套路：热路径里只摘链表，把昂贵的 `kfree` 推到工作队列，避免抖动。

## ESP 怎么挂钩进协议栈

ESP 协议处理器要"双向注册"——既告诉 XFRM 自己的处理函数，又告诉 IP 协议栈"协议号 50 的包交给我"。6.19 里这步在 `esp4_init()`（`net/ipv4/esp4.c:1184`）：

```c
// net/ipv4/esp4.c:1165 —— ESP 的"功能说明书"
static const struct xfrm_type esp_type = {
    .owner      = THIS_MODULE,
    .proto      = IPPROTO_ESP,
    .flags      = XFRM_TYPE_REPLAY_PROT,   // 我支持抗重放
    .init_state = esp_init_state,
    .destructor = esp_destroy,
    .input      = esp_input,               // 接收时的解密回调
    .output     = esp_output,
};

// net/ipv4/esp4.c:1176 —— 注册给 IP 协议栈的入口
static struct xfrm4_protocol esp4_protocol = {
    .handler       = xfrm4_rcv,   // 收到 proto=50 的包调它
    .input_handler = xfrm_input,  // 通用 XFRM 接收中心
    .cb_handler    = esp4_rcv_cb,
    .err_handler   = esp4_err,
    .priority      = 0,
};
```

`esp4_init()` 先 `xfrm_register_type(&esp_type, AF_INET)` 把类型挂进 XFRM 的 `type_map`，再 `xfrm4_protocol_register(&esp4_protocol, IPPROTO_ESP)` 注册给 IP 栈。注意后半步要是失败了，会 `xfrm_unregister_type()` 回滚前一步——这种"一来一回干干净净"是内核模块注册的范本。（这里得提醒一句：老的 IPsec 书里写的是 `inet_add_protocol()` + `struct net_protocol`，6.19 已经统一成 `xfrm4_protocol` + `xfrm4_protocol_register()` 了，看老书要对齐一下。）

AH、IPCOMP 也都把 `.handler` 指向同一个 `xfrm4_rcv`，因为进门后查表、验证重放这些逻辑是通用的，没必要写三遍。

## 接收路径：xfrm_input 的拆壳之旅

现在真的有一个 ESP 传输模式包到达本机。它在 `ip_local_deliver_finish()` 被发现协议号是 50，于是调用 `xfrm4_rcv()`，转手扔给通用中心 `xfrm_input()`（`net/xfrm/xfrm_input.c:463`）。这是拆壳的核心，走一遍：

**第一步：查 SAD 找钥匙。** 拿 SPI、目的地址、协议号去 `state_byspi` 查：

```c
// xfrm_input.c:590（Linux 6.19）
x = xfrm_input_state_lookup(net, mark, daddr, spi, nexthdr, family);
if (x == NULL) {
    XFRM_INC_STATS(net, LINUX_MIB_XFRMINNOSTATES);   // 静默丢包
    goto drop;
}
```

（老书里这步叫 `xfrm_state_lookup()`，6.19 收敛成了 `xfrm_input_state_lookup()`。）查不到就丢——加密包没法发 ICMP 错误，因为你根本不知道它是谁发的。

**第二步：调协议的解密回调。** 拿着 SA 锁 `spin_lock(&x->lock)`，校验状态 `VALID`、校验 `encap_type` 匹配、`xfrm_replay_check()` 查重放窗口、`xfrm_state_check_expire()` 看寿命，全过了才解密：

```c
// xfrm_input.c:658
nexthdr = x->type->input(x, skb);   // 对 ESP 就是 esp_input()
```

`esp_input()` 调 Crypto API 解密 + 验 ICV。返回的 `nexthdr` 是剥掉 ESP 头尾后内层载荷的协议号（TCP=6、UDP=17）。校验通过就 `xfrm_replay_advance(x, seq)` 推进重放窗口，统计 `x->curlft.bytes += skb->len`、`x->curlft.packets++`。

**第三步：按模式重整包结构。** 关键一句 `XFRM_MODE_SKB_CB(skb)->protocol = nexthdr`（`xfrm_input.c:692`）把内层协议号存进 skb 控制块，然后 `xfrm_inner_mode_input()` 分模式处理。隧道模式（`xfrm4_remove_tunnel_encap`）直接把外层新 IP 头拆掉、露出内层完整 IP 包，`gro_cells_receive()` 重新进栈；传输模式（`xfrm4_transport_input`，`xfrm_input.c:390`）做更精细的活——`memmove` 把 IP 头移回原位、重算 `tot_len`，相当于把快递单上的"协议=ESP"改回"协议=TCP"。

**第四步：重新注入协议栈。** 传输模式最后调 `afinfo->transport_finish()`（`xfrm_input.c:745`），通过 Netfilter `PRE_ROUTING` hook 再扔回 `ip_local_deliver()`。此刻 IP 头的协议号已是 TCP，内核像处理刚从网卡收到的普通包一样交给上层。一次加密包的接收之旅就此结束。

> 关于这部分，老书（包括我们参考的笔记 ch10_5）讲的是 `xfrm4_transport_finish()` 手动改 `iph->protocol`、`ip_send_check()` 重算校验和、再走 `NF_HOOK`。6.19 这套被重构成了上面 `xfrm_inner_mode_input()` + `transport_finish` 的统一接口，思想一样（改头、重注栈），代码组织变了。读到老描述别慌，对照 6.19 源码就是。

## NAT-T：给加密包套个 UDP 信封

现实总爱打脸：你在家 NAT 后面起 IPsec VPN，隧道死活起不来。因为 NAT 设备改 IP 地址后必须同步改 TCP/UDP 校验和（校验和覆盖伪首部），可 ESP 把 TCP/UDP 头全加密了，NAT 看不懂也算不了校验和——结果只能丢包。

IETF 的解法是 RFC 3948（**NAT-T，NAT Traversal**）：既然你不认 ESP，那我在 IP 头和 ESP 头之间硬塞一个 **UDP 头**，伪装成你最爱的 UDP。NAT 只看 IP 和 UDP 端口改写，大家皆大欢喜。几个硬规矩：只救 ESP（AH 校验 IP 头，NAT 一改就废）；必须靠 IKEv2 协商开启（不能手动密钥）；UDP 端口固定 **4500**；还要每 20 秒发一次 keepalive 刷存在——保活包载荷就一个字节 `0xFF`。

内核收到这种"穿了马甲"的包，处理在 `xfrm4_udp_encap_rcv()`（`net/ipv4/xfrm4_input.c:161`），核心是 `__xfrm4_udp_encap_rcv()`（`xfrm4_input.c:81`）：

```c
case UDP_ENCAP_ESPINUDP:
    if (len == 1 && udpdata[0] == 0xff)
        return -EINVAL;          // keepalive，吃掉
    else if (len > sizeof(struct ip_esp_hdr) && udpdata32[0] != 0)
        len = sizeof(struct udphdr);  // 真 ESP 包，剥掉 UDP 头
    else
        return 1;                // IKE 包，放行给 UDP
```

剥掉 UDP 头后调 `xfrm4_rcv_encap(skb, IPPROTO_ESP, 0, encap_type)`，剩下就和普通 ESP 包一模一样——查 SA、解密、验证、重组，全复用前面的 `xfrm_input()` 路径。NAT-T 本质就是一层"骗 NAT 的信封"，到了目的地内核撕开信封，照常处理里面的加密文件。

## 小结

IPsec 是长在 IP 层的加密引擎，让应用无感地获得全流量保护。它把"法律"和"武器"分离：**策略（`xfrm_policy`）**定规矩不干活，**状态（`xfrm_state`）**拿密钥和算法真正加解密；两者通过模板 `xfrm_vec` 衔接。ESP（协议号 50）是主角，既加密又认证，现代用 AEAD（AES-GCM）一把梭。

接收路径 `xfrm_input()` 是拆壳核心：查 SA（`state_byspi`）→ 协议解密回调（`esp_input`）→ 按模式重整（传输模式改头、隧道模式剥头）→ 重注协议栈。SA 生命周期靠 slab 分配 + 引用计数 + 异步 GC 管理。NAT-T 给 ESP 套 UDP 信封（端口 4500），骗过 NAT，到了内核 `xfrm4_udp_encap_rcv` 撕掉信封复用解密路径。

记住三个抓手：**策略与状态分离**（老板与员工）、**SA 三张哈希表**（三把钥匙开一门）、**NAT-T 的 UDP 信封**（曲线救国的妥协）。

## 延伸阅读

- 源码：`net/xfrm/xfrm_input.c`（`xfrm_input` 接收主循环）、`net/xfrm/xfrm_state.c`（SA 状态机与 GC）、`net/xfrm/xfrm_policy.c`（策略匹配）；`net/ipv4/esp4.c`（IPv4 ESP 实现，`esp_type` / `esp4_init`）、`net/ipv4/xfrm4_input.c`（NAT-T 的 `xfrm4_udp_encap_rcv`）；头文件 `include/net/xfrm.h`、`include/uapi/linux/xfrm.h`。
- kernel.org 文档：[Networking — IPsec (XFRM) subsystem](https://docs.kernel.org/networking/index.html)（在 networking 总索引里定位 XFRM/IPsec 章节）、[IPsec 通用的 admin-guide 入口](https://docs.kernel.org/admin-guide/index.html)；协议规范 RFC 4303（ESP）、RFC 3948（NAT-T）。
- 用户态实践：strongSwan 官方文档（IKEv2 + NAT-T 默认开启），`iproute2` 的 `ip xfrm state` / `ip xfrm policy` 子命令（`man ip-xfrm`）。

> ⚠️ **动手待亲测**：本篇的命令输出全部留空。计划在 QEMU 里跑两条：① `ip xfrm state add` / `ip xfrm policy add` 手动建一条 SA，`ip xfrm state show` / `cat /proc/net/xfrm_stat`（看 XFRM MIB 计数器对应 `XfrmInNoStates` 等）；② 用 strongSwan 在两台 QEMU 之间起一条隧道，`tcpdump` 抓 ESP 包（隧道模式）和 UDP 4500（NAT-T），把真实抓包贴进来再升级。