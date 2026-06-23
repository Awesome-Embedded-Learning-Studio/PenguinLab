---
title: 网络命名空间：容器网络的根基，内核怎么造一个独立网络栈
slug: net-netns
difficulty: intermediate
tags: [网络栈, network namespace, netns, 容器网络, cgroups, 通知链]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/01-net-overview
related:
  - /tutorials/kernel/net/01-net-overview
  - /tutorials/kernel/net/09-net-netlink
sources:
  - notes: document/notes/linux_kernel_networking/ch14.md
  - notes: document/notes/linux_kernel_networking/ch14_3.md
  - notes: document/notes/linux_kernel_networking/ch14_4.md
  - notes: document/notes/linux_kernel_networking/ch14_5.md
  - notes: document/notes/linux_kernel_networking/ch14_10.md
---

# 网络命名空间：容器网络的根基，内核怎么造一个独立网络栈

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。核心数据结构 `struct net`、`copy_net_ns()`/`setup_net()`/`cleanup_net()` 生命周期、pernet 回调、`netdev_chain` 通知链都已对齐 6.19 的 `net/core/net_namespace.c` 与 `include/net/net_namespace.h`。一处提醒：旧笔记里写「lo 钉死靠 `NETIF_F_NETNS_LOCAL` 特性位」——这个 feature 位在 6.19 已删，改成了 `net_device->netns_immutable` 字段（见下文「搬设备的规矩」）。

## 为什么网络栈需要被「复制」

我们前面几篇把网络栈当成一台机器上独此一份的东西在讲——一张网卡、一张路由表、一套 iptables。这在传统服务器时代没问题：一台物理机就跑几个服务，网络栈确实是全局唯一的。

可一旦进了容器和虚拟化的世界，这套假设就崩了。一台宿主机上可能同时跑着一两百个容器，每个容器都觉得自己是网络的主人：它要有自己的 `eth0`、自己的默认路由、自己的防火墙规则，容器 A 里跑的 80 端口和容器 B 里的 80 端口绝对不能打架。要是所有容器共用一套网络栈，光端口号冲突就够你喝一壶的。

内核解这个题的路子很暴力也很优雅：**别共享了，给每个隔离环境拷一份完整的网络栈出来。** 这就是网络命名空间（network namespace，netns）。它不是改改配置文件那种浅隔离，而是把网卡、路由表、邻居表（ARP/NDISC）、Netfilter 规则、socket、`/proc/net` 视图整一套都深拷贝一遍——你可以把它理解成「凭空变出一台独立的虚拟路由器」。

这篇我们就钻进 `net/core/net_namespace.c`，看看内核到底是怎么把这份「独立世界」造出来、又怎么管它的生死。

## `struct net`：一个 netns 就是一个上帝对象

万丈高楼从 `struct net` 起。每创建一个网络命名空间，内核就分配一个 `struct net`，它就是那个「独立世界」的总账本——所有和网络相关的状态都挂在它身上。定义在 `include/net/net_namespace.h`（Linux 6.19）：

```c
struct net {
	refcount_t		passive;	/* 决定 netns 何时真正释放 */
	/* ... */
	unsigned int		dev_base_seq;
	u32			ifindex;        /* 本 netns 内分配设备索引的计数器 */

	struct list_head	list;		/* 串起所有 netns 的全局链表 */
	struct list_head	exit_list;	/* 销毁时挂上 pernet exit 列表 */

	struct user_namespace   *user_ns;	/* 拥有它的 user namespace */
	struct ucounts		*ucounts;
	struct idr		netns_ids;	/* 给其它 netns 起的本地编号 */
	struct ns_common	ns;		/* 通用 namespace 句柄 */

	struct list_head	dev_base_head;	/* 本 netns 所有网设备的链表头 */
	struct hlist_head	*dev_name_head;	/* 按名字哈希查设备 */
	struct hlist_head	*dev_index_head;/* 按 ifindex 哈希查设备 */
	struct raw_notifier_head	netdev_chain; /* 本 netns 的设备通知链 */

	struct net_device	*loopback_dev;	/* 回环设备，钉死不能搬 */

	struct netns_ipv4	ipv4;		/* IPv4 私有世界：路由表/iptables/sysctl */
#if IS_ENABLED(CONFIG_IPV6)
	struct netns_ipv6	ipv6;
#endif
	/* ... netfilter / sctp / xfrm / bpf ... */
	struct net_generic __rcu	*gen;	/* 可选子系统的私有数据兜底 */
};
```

我们把关键字段拆开看，它们正好把「隔离」这件事一层层落地：

- **`dev_base_head` / `dev_name_head` / `dev_index_head`**：本 netns 的设备库房。`dev_base_head` 是全设备链表头，另两个是哈希表，分别按名字和 ifindex 快速查设备。注意 `ifindex` 是**虚拟化**的——netns A 和 netns B 里的 lo 都可以是 1，各自的 `eth0` 也可以重号，互不干扰。
- **`loopback_dev`**：回环设备，每个新 netns 里**唯一**默认存在的设备，在 `loopback_net_init()`（`drivers/net/loopback.c`）里挂上去。它有个铁律：**lo 设备禁止跨 netns 搬运**，是钉死在户籍里的（6.19 靠的是 `net_device->netns_immutable` 字段，下面细讲）。
- **`ipv4` / `ipv6` / `nf` / `ct` / `xfrm`**：各大协议栈的「私人地盘」。光一个 `struct netns_ipv4`（`include/net/netns/ipv4.h`）里就装着 FIB 路由表、Netfilter 表（`iptable_filter`/`nat_table`）、一堆 `sysctl_tcp_*` 调节旋钮。回到「虚拟路由器」那个比喻：这就是那台虚拟路由器的路由面板、防火墙面板和 TCP 参数旋钮。
- **`gen`（`struct net_generic`）**：工程上的妥协。要是每个可选子系统都往 `struct net` 塞字段，这结构体早膨胀成垃圾场了。于是内核搞了个通用指针数组，那些非核心子系统（比如 sit、pppoe）在这里申请一个 ID，存自己的私有数据，不污染 `struct net` 本体。分配逻辑在 `net_namespace.c` 的 `net_alloc_generic()` / `net_assign_generic()`。

> 笔记里写的 `atomic_t count` 在 6.19 已经换成 `refcount_t passive` 了——这是这些年 refcount 加固的成果，机制不变：`get_net()` 增、`put_net()` 减，归零触发清理。读源码时拿笔记的旧字段名对照新字段，别犯愣。

## 一个 netns 的生死：`copy_net_ns` → `setup_net` → `cleanup_net`

光有数据结构不够，得看它怎么生、怎么死。netns 的生命周期全在 `net/core/net_namespace.c` 里。

**生**：当你 `unshare(CLONE_NEWNET)` 或 `ip netns add`，系统调用最终走到 `copy_net_ns()`（`net_namespace.c`，Linux 6.19）。它的骨架很清楚：

```c
struct net *copy_net_ns(u64 flags, struct user_namespace *user_ns,
                        struct net *old_net)
{
    struct ucounts *ucounts;
    struct net *net;

    if (!(flags & CLONE_NEWNET))
        return get_net(old_net);          /* 没要新 netns，复用旧的 */

    ucounts = inc_net_namespaces(user_ns); /* 用户能建的 netns 数有上限 */
    if (!ucounts)
        return ERR_PTR(-ENOSPC);

    net = net_alloc();                     /* 从 net_cachep slab 分配 */
    /* ... preinit_net(): 初始化 user_ns/passive/idr/nsid_lock ... */
    rv = setup_net(net);                   /* 挨个跑 pernet_list 的 init */
    /* ... 失败就走 put_userns/dec_ucounts 回滚 ... */
    return net;
}
```

第一个 `if` 是关键：不带 `CLONE_NEWNET` 标志位就只是给旧 netns 加个引用计数走人。真要造新世界，得先过 `ucounts` 这一关——每个 user namespace 能创建的 netns 数量是有限额的（防恶意进程无限造命名空间耗资源）。

造的核心在 `setup_net()`：它持着 `pernet_ops_rwsem` 读锁，遍历全局的 `pernet_list`，挨个调用每个 `pernet_operations` 的 `init` 回调，最后把新 netns 挂进全局 `net_namespace_list`：

```c
static __net_init int setup_net(struct net *net)
{
    const struct pernet_operations *ops;
    /* ... */
    net->net_cookie = ns_tree_gen_id(net);

    list_for_each_entry(ops, &pernet_list, list) {
        error = ops_init(ops, net);        /* 跑每个子系统的 init */
        if (error < 0)
            goto out_undo;                 /* 哪步失败就逆序回滚 */
    }
    down_write(&net_rwsem);
    list_add_tail_rcu(&net->list, &net_namespace_list); /* 上户口 */
    up_write(&net_rwsem);
    /* ... */
}
```

这套「遍历 pernet_list 跑 init」的机制是 netns 可扩展性的根基——任何网络子系统只要注册一个 `pernet_operations`，就能在「每个新 netns 创建时」拿到通知做自己的初始化（建 `/proc/net/xxx`、分配私有数据等）。

**死**：netns 销毁是异步的。当引用计数 `passive` 归零，`__put_net()` 把它挂到全局 `cleanup_list` 上，调度 workqueue 上的 `net_cleanup_work`，最终跑 `cleanup_net()`。这函数先把待死的 netns 从全局列表摘掉、清掉它们对别的 netns 的编号引用（`unhash_nsid()`），再**逆序**（和注册顺序相反）跑每个 pernet ops 的 `exit` 回调，最后 `rcu_barrier()` 等所有 RCU 回调跑完才真正释放内存。逆序是规矩：你后注册的子系统可能依赖先注册的，拆的时候得反过来拆，先拆依赖方。

> 为什么销毁要异步、要 RCU？因为 netns 在数据包收发的热路径上被无数处 RCU 读侧引用着（`skb`、`sock` 都攥着 netns 指针）。直接在 `put_net` 里同步释放，会踩到还在用它的 CPU，所以甩给 workqueue，再配 `rcu_barrier` 兜底。

## pernet 回调：子系统怎么搭上 netns 这趟车

上面反复提到的 `pernet_operations`，是子系统接入 netns 的统一接口。定义在 `include/net/net_namespace.h`：

```c
struct pernet_operations {
    struct list_head list;
    int  (*init)(struct net *net);
    void (*exit)(struct net *net);
    void (*exit_batch)(struct list_head *net_exit_list);
    void (*pre_exit)(struct net *net);
    /* ... */
    int    *id;
    size_t  size;
};
```

子系统填好回调，再选注册方式：

- `register_pernet_subsys(&ops)`：注册「子系统」类回调，netns 创建时跑 `init`、销毁时跑 `exit`，**不**涉及网络设备本身。
- `register_pernet_device(&ops)`：注册「设备」类回调，插在 `pernet_list` 末尾（通过 `first_device` 指针分割前后段），保证设备相关的 init 晚于普通子系统跑、exit 早于它们跑。

看个笔记里的经典例子——PPPoE 模块要往每个 netns 的 `/proc/net` 下导出 `pppoe` 文件，于是定义：

```c
static struct pernet_operations pppoe_net_ops = {
    .init = pppoe_init_net,
    .exit = pppoe_exit_net,
    .id   = &pppoe_net_id,
    .size = sizeof(struct pppoe_net),
};
```

`init` 里 `proc_create("pppoe", ..., net->proc_net, ...)` 建文件，`exit` 里 `remove_proc_entry` 删文件。`.id`/`.size` 配合 `net_generic`：`size` 是该子系统在每个 netns 里要的私有数据大小，内核给它在 `net->gen` 数组里预留一个槽位（`ops_init()` 里 `kzalloc(ops->size)` + `net_assign_generic()`）。

netns 模块自己也走这套——`net_ns_ops` 在 `net_ns_init()` 里 `register_pernet_subsys(&net_ns_ops)`，每个新 netns 创建时跑 `net_ns_net_init()`（6.19 里主要是建 debugfs ref-tracker 符号链接）。

## 用户态怎么玩：`ip netns` 背后的三件事

理论够了，回到命令行。99% 的时候我们用 `iproute2` 的 `ip netns`，不直接 `unshare()`。

```bash
ip netns add ns1
```

这行命令背后干三件事：① 在 `/var/run/netns/` 下建 `ns1` 文件；② `unshare(CLONE_NEWNET)` 让内核造新 netns（最终就是上面的 `copy_net_ns`）；③ **把 `/proc/self/ns/net` 绑定挂载（bind mount）到那个文件上**。

第③步是点睛之笔。netns 在内核里是漂浮在内存的对象，创建它的进程一退出，引用归零它就没了。bind mount 那个文件相当于在文件系统里留了个「传送门锚点」——文件系统对它持有引用，netns 就赖着不走，之后随时能 `ip netns exec` 找回去。所以 `ip netns list` 本质就是 `ls /var/run/netns/`；你用 `unshare --net bash` 硬造的「隐形」netns 不会出现在列表里，因为它没留锚点。

进 netns 跑命令是 `ip netns exec ns1 bash`：打开锚点文件拿 fd → `setns()` 关联当前进程到这个 fd 指向的 netns → `fork()`+`execve()` 你要的命令。`setns` 走的是 `netns_operations.install`（`net_namespace.c`），它会检查 `CAP_SYS_ADMIN` 能力，然后 `nsproxy->net_ns = get_net(net)` 换掉进程的网络栈归属。

> 进去后 `ip addr` 通常只看到孤零零一个 lo（还是 DOWN 状态）。这就是个刚拆封的空网络世界。

## veth pair：连两个 netns 的「跨世界网线」

空 netns 没法通信，得拉根「网线」。这就是 **veth（Virtual Ethernet）**——它**永远成对**出现，一头塞数据，另一头立刻收到，像一根管子贯穿两个世界。

典型搭桥流程（两 netns 互通的基础）：

```bash
ip netns add ns1
ip netns add ns2
# 在主空间建一对 veth
ip link add if_one type veth peer name if_one_peer
# 把一头扔进 ns1，另一头扔进 ns2
ip link set if_one netns ns1
ip link set if_one_peer netns ns2
# 各自配 IP、起来
ip netns exec ns1 ip addr add 10.0.0.1/24 dev if_one
ip netns exec ns1 ip link set if_one up
ip netns exec ns2 ip addr add 10.0.0.2/24 dev if_one_peer
ip netns exec ns2 ip link set if_one_peer up
# 互通
ip netns exec ns1 ping 10.0.0.2
```

这就是 Docker、Kubernetes 那套容器网络（CNI）的地基：每个容器一个 netns，靠 veth 把容器 netns 和宿主机网桥（bridge）连起来，再由网桥/路由/iptables 转发出去。搞懂 veth pair，你就懂了容器网络一半的「线缆」。

## 搬设备的规矩：谁也不能带走 lo

网卡能在 netns 之间搬：`ip link set eth0 netns ns1`。但有个硬限制——被标记为「本地户籍不可搬运」的设备（lo、bridge、bond、vrf、hsr、各种 fb_tunnel 等）**禁止搬运**，内核直接返回 `-EINVAL`。

这里有个版本变化要特别注意：旧笔记和老资料里都写「靠 `NETIF_F_NETNS_LOCAL` 这个 feature 位判定」。但 **这个 feature 位在 Linux 6.19 已经被彻底删除**（`grep -rn NETIF_F_NETNS_LOCAL` 在整个源码树里零匹配）。6.19 改成了 `struct net_device` 里的一个 1-bit 字段 `netns_immutable`（`include/linux/netdevice.h`，注释写着 `interface can't change network namespaces`）。判定的闸门在 `__dev_change_net_namespace()`（`net/core/dev.c:12495`，Linux 6.19）：

```c
int __dev_change_net_namespace(struct net_device *dev, struct net *net,
                               const char *pat, int new_ifindex,
                               struct netlink_ext_ack *extack)
{
    /* ... */
    /* Don't allow namespace local devices to be moved. */
    err = -EINVAL;
    if (dev->netns_immutable) {
        NL_SET_ERR_MSG(extack, "The interface netns is immutable");
        goto out;
    }
    /* ... 真正切换：dev_net_set(dev, net) ... */
}
```

> 注：对外的 wrapper 叫 `dev_change_net_namespace()`（`include/linux/netdevice.h:4299`），它是上面 `__dev_change_net_namespace()` 的一层封装，参数更简单（只传 `dev/net/pat`）。真带闸门、带全套切换逻辑的是那个双下划线的内部函数。

那些「本地户籍」设备在各自初始化时主动把自己钉死。比如 lo 在 `loopback_net_init()` 里 `dev->netns_immutable = true`（`drivers/net/loopback.c:176`）、网桥在 `br_dev_setup()` 里同样置位（`net/bridge/br_device.c:493`），bond/team/vrf/hsr、以及 ipmr/ip6mr 的 fb_tunnel、sit/ip6_gre 的 fb_tunnel、amt、batman-adv 的 mesh 接口、OVS 内部端口也都这么做。读源码时拿 `grep -rn 'netns_immutable = true'` 就能拉出 6.19 的完整「钉死名单」。

反过来，当一个 netns 被销毁时，里面那些**可搬运**的设备会被强制「搬家」回 `init_net`（宿主机默认 netns），不会跟着陪葬；只有本地户籍设备才随 netns 一起销毁。搬家的逻辑在 `default_device_exit_batch()`（`net/core/dev.c`）里，同样是靠这个字段放行——遇到不可搬运的直接略过：

```c
for_each_netdev_safe(net, dev, aux) {
    /* Ignore unmoveable devices (i.e. loopback) */
    if (dev->netns_immutable)
        continue;
    /* ... 其余设备 push 回 init_net ... */
}
```

这就是为什么你 `ip netns del` 一个里面有容器的 netns，物理网卡不会凭空消失的原因。

> ⚠️ **待亲测核验**：上面这份「6.19 钉死名单」是我照着 `grep netns_immutable` 在 6.19 源码里拉的，veth/vxlan/macvlan 这类**可搬运**的虚拟设备没出现在名单里（vxlan 在老 `NETIF_F_NETNS_LOCAL` 时代被算作本地设备，6.19 起不再置 `netns_immutable`，所以现在能搬了）。具体每个设备能不能搬，以你 QEMU 上 `ip link set <dev> netns <ns>` 的实际返回为准。

## netns + cgroups：隔离的墙 + 限流的闸

netns 解决的是「视线隔离」（各看各的网络栈），但它管不住资源争夺——容器里一个进程把带宽/CPU 吃满，宿主机照样卡。补上这块短板的是 **cgroups**。

这里要刻一条铁律：**netns 和 cgroups 是正交的。** 你可以只有 netns 没 cgroups（光隔离不限制），也可以反过来。历史上内核试过搞个 `ns` cgroup 把两者捏一起，后来代码删了——没必要。现代容器（Docker/K8s）是「两者都用」：netns 切网络栈，cgroup 切 CPU/内存/带宽。

cgroups 的设计很 Unix：**不引入新系统调用，把资源管理做成一个可挂载的虚拟文件系统**（`cgroup` fs）。创建分组、限制资源、统计用量，全是 `mkdir`/`echo`/`cat` 文件操作。挂载点通常在 `/sys/fs/cgroup/`。

跟网络直接相关的两个控制器：

- **net_prio**：不改应用代码就能给某个 cgroup 里进程发出的包打优先级。它在每个 `net_device` 上挂一张 `priomap`（按 cgroup id 索引），发包路径 `dev_queue_xmit()` 查表填进 `skb->priority`。
- **net_cls**：给 cgroup 里的包打 `classid`（如 `10:1`），配合 `tc`（Traffic Control）做基于「应用分组」而非「IP/端口」的流量整形。

> netns + cgroups 这对组合，本质上就是容器网络的两条腿：netns 管「能不能看见」，cgroup 管「能吃多少」。后面我们讲 netfilter、netlink 时还会反复回到这套隔离模型上。

## 通知链：netns 里的「神经系统」

最后一个机制，它贯穿整个网络栈而不只是 netns，但在 netns 上下文里尤其关键——**通知链（notifier chain）**。

网络世界是动态的：网线拔了、MTU 改了、设备注销了、netns 被销毁了……这些事件发生时，相关子系统必须立刻知情，否则路由表还在发往死设备、ARP 缓存还在查不存在的端口。通知链就是内核里的「发布-订阅」系统。

每个订阅者填一张 `notifier_block`（`include/linux/notifier.h`）：回调函数指针 `notifier_call`、串链的 `next`、`priority`（数字大先被通知）。事件来了，内核顺着链表挨个拨电话。

网络子系统主要用 **`raw_notifier_chain`**——最宽松、不加锁的那种。因为网络代码路径太复杂，有些场景已经在锁里、有些不能睡眠，raw 链让网络子系统自己决定怎么加锁。前面 `struct net` 里那个 `netdev_chain` 字段（`raw_notifier_head`），就是**每个 netns 自己的一条设备通知链**。

事件码是一张大表（`NETDEV_UP`/`DOWN`、`REGISTER`/`UNREGISTER`、`CHANGEMTU`、`CHANGEADDR`、`BONDING_FAILOVER`…）。比如网桥模块想跟着从口网卡一起改 MTU，就注册一个 `notifier_block` 到 `netdev_chain`（`register_netdevice_notifier()`，本质是 `raw_notifier_chain_register` 的包装），回调里 `switch(event)` 挑关心的处理。6.19 真实代码（`net/bridge/br.c:74`）：

```c
static int br_device_event(struct notifier_block *unused,
                           unsigned long event, void *ptr)
{
    struct net_device *dev = ptr;
    /* ... 找到 dev 所属的桥 br ... */
    switch (event) {
    case NETDEV_CHANGEMTU:
        br_mtu_auto_adjust(br);   /* 按所有从口最小 MTU 重算桥的 MTU */
        break;
    /* ... */
    }
}
```

`br_mtu_auto_adjust()` 定义在 `net/bridge/br_if.c:514`，干的就是「取所有从口里最小的 MTU，把桥设备的 MTU 调成这个值」——语义和直觉一致，6.19 只是把它收进了一个专门函数，没散在回调里。

为什么在 netns 篇提它？因为 netns 的**销毁**本身就伴随着大量通知——所有设备要 `NETDEV_UNREGISTER`、邻居表要清、路由要撤、各子系统的 `exit` 回调要跑。`cleanup_net()` 里那一串 `exit` 回调和 `unhash_nsid` 的通知广播，全靠这套通知机制把「netns 要没了」这件事扩散给每个关心它的子系统。netns 不是孤岛，它靠通知链和整个网络栈保持着神经联系。

## 小结

网络命名空间是容器网络的根基。一个 netns 就是一个 `struct net`——它挂着独立的设备链表（`dev_base_head`）、路由表和 iptables（藏在 `ipv4`/`nf` 里）、独立的 socket、独立的 `/proc/net`。生命周期走 `copy_net_ns` → `setup_net`（跑 pernet init）→ `cleanup_net`（逆序跑 exit + RCU 兜底）；子系统靠 `pernet_operations` 搭车，netns 之间靠 veth pair 连「网线」，带宽/CPU 靠 cgroups 限流，事件靠 `netdev_chain` 通知链广播。

记住三件事：**lo 钉死不能搬**（6.19 靠 `dev->netns_immutable`，老的 `NETIF_F_NETNS_LOCAL` 已删）、**netns 与 cgroups 正交**（隔离的墙 vs 限流的闸）、**销毁是异步 + RCU**（热路径上有无数读侧引用）。

## 延伸阅读

- 源码：`net/core/net_namespace.c`（Linux 6.19），`copy_net_ns`/`setup_net`/`cleanup_net`/`register_pernet_subsys` 全在这；`include/net/net_namespace.h` 看 `struct net` / `pernet_operations`；`include/net/netns/ipv4.h` 看一个 netns 的 IPv4 世界有多大；`net/core/dev.c`（`__dev_change_net_namespace` / `default_device_exit_batch`）看搬设备的闸门。
- docs.kernel.org：[Namespaces admin guide](https://docs.kernel.org/admin-guide/namespaces/index.html)（用户态视角，含 netns 的能力/限制清单）、[Network management cgroup](https://docs.kernel.org/admin-guide/cgroup-v1/net_cls.html)（net_cls 控制器）、[Cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)。注：内核文档里**没有**独立的 netns 机制专页（`Documentation/networking/` 下无 `netns.rst`），netns 的内核侧机制请直接读上面的源码。
- 命令手册：`ip-netns(8)`、`ip-link(8)`（veth 类型）、`unshare(1)`/`setns(2)`——netns 用户态用法的权威来源。
- 待铺开：veth/bridge 内部实现、netfilter 在 netns 里的规则隔离、netlink（本站 [/tutorials/kernel/net/09-net-netlink](/tutorials/kernel/net/09-net-netlink)）如何驱动这套 netns 管理。

> ⚠️ **待亲测**：上面的命令流程会在 QEMU 上跑一遍——`ip netns add ns1/ns2`、建 veth pair 连两个 netns、互 ping 验证、`cat /proc/<pid>/ns/net` 对比 inode、`ip netns identify` 找名字；顺手验证 `ip link set lo netns <ns>` 返回 `-EINVAL`（`netns_immutable` 生效）。跑完记下真实输出，把这篇从 🔨 升级成 ✅。