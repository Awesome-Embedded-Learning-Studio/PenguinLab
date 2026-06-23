---
title: RDMA 与 InfiniBand：绕过内核的零拷贝传输
slug: net-rdma-infiniband
difficulty: intermediate
tags: [网络栈, RDMA, InfiniBand, RoCE, 零拷贝]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/01-net-overview
related:
  - /tutorials/kernel/net/01-net-overview
sources:
  - notes: document/notes/linux_kernel_networking/ch13.md
  - notes: document/notes/linux_kernel_networking/ch13_1.md
  - notes: document/notes/linux_kernel_networking/ch13_2.md
  - notes: document/notes/linux_kernel_networking/ch13_3.md
  - notes: document/notes/linux_kernel_networking/ch13_5.md
  - notes: document/notes/linux_kernel_networking/ch13_6.md
  - notes: document/notes/linux_kernel_networking/ch13_7.md
---

# RDMA 与 InfiniBand：绕过内核的零拷贝传输

> 🔨 **整理中** · 本篇机制对照 Linux 6.19 源码讲解（函数/数据结构已核对）；具体行号与命令输出待 QEMU 亲测核对。

## RDMA 到底绕过了什么

先用一句大白话把 RDMA（Remote Direct Memory Access，远程直接内存访问）钉死：**它让一块网卡不经过 CPU、不经过内核协议栈，直接把这台机器的用户内存 DMA 读写到另一台机器的用户内存里。** 传统 socket 发一个包要交多少"税"？三次握手、用户态/内核态上下文切换、数据在内核缓冲区之间来回拷贝、网卡驱动每个包都中断一次 CPU。对普通业务这点税忍忍就过去了，但高频交易、大规模分布式存储、百万节点的 HPC 集群——这点税就是不可接受的死罪。

RDMA 的承诺听起来像在作弊：数据只在"本地用户内存"和"远程用户内存"之间搬一次，中间没有任何副本；CPU 卸载给网卡的专用处理器去算校验、重传、原子操作；延迟可以低到几百纳秒，带宽轻松上 100 Gbps。

但自由是有代价的。RDMA 抛弃了内核协议栈的"保姆式服务"，把连接管理、内存注册、错误处理这些脏活全甩给了开发者——内核退居二线，只负责**建路不管运货**。

## 三种网络，一套 Verbs

支持 RDMA 的网络协议主流三种，底层物理链路天差地别，但对外暴露的 API 是统一的：

1. **InfiniBand（IB）**：从头设计的全新高性能网络架构，规范由 IBTA 维护。交换机很"笨"——不学 MAC、不跑生成树，转发表由一个叫 SM（Subnet Manager）的上帝视角实体远程配好，只负责查表转发，转发延迟极低。
2. **RoCE（RDMA over Converged Ethernet，读作 "Rocky"）**：既然 IB 交换机太贵，那就在现有以太网/IP 链路层之上跑 RDMA，属于混血方案。
3. **iWARP（Internet Wide Area RDMA Protocol）**：直接在标准 TCP/IP 协议栈之上实现 RDMA，适合不想动底层网络、只想在广域网上玩 RDMA 的场景。

这套统一 API 叫 **Verbs**，可以理解成 RDMA 世界里的"系统调用表"。无论哪种网络，客户端代码都只通过 `ib_*` 系列函数操作硬件，底层差异由内核模块屏蔽。

> ⚠️ **历史包袱**：API 虽统称 RDMA，但大量内核函数/结构体/文件名仍以 `ib_`（InfiniBand）开头。比如 `ib_register_client` 一样能注册 RoCE 设备。别被名字误导，把它们当通用 RDMA 接口就行——`include/rdma/ib_verbs.h`（Linux 6.19）里的 `ib` 是通用的。

## 绕过内核的代价：内核只管建路

内核里的 RDMA 栈几乎全藏在 `drivers/infiniband/` 下（名字同样误导，里头也有 RoCE/iWARP 的逻辑）。拆开看像一栋大厦：

- **`core/`** 是地基和管道：`core/cm.c`（Communication Manager，建连接时协商参数、交换密钥的"媒人"）、`core/verbs.c`（核心 Verbs 实现）、`core/uverbs_*.c`（用户态 Verbs，让用户程序通过 `ioctl` 直接跟硬件打交道，彻底绕过内核）、`core/mad.c`（管理数据报，处理配置交换机、查端口状态这类管理包）。
- **`hw/`** 是各厂商（Mellanox、Intel 等）的 HCA（Host Channel Adapter，"超级网卡"）硬件驱动，挂在 PCIe 上，自带 DMA 引擎和内存管理单元。
- **`ulp/`** 是住客：`ipoib`（IP over InfiniBand，让 IB 网卡看起来像普通网卡跑 TCP/IP）、`iser`（iSCSI over RDMA）、`srp`（SCSI RDMA Protocol）。

关键认知：**数据路径上内核基本不介入**——用户态应用直接往映射进用户空间的网卡寄存器下达指令，网卡自己去 DMA 内存。内核只在控制路径上做事：分配 QP 号、建立连接、注册内存。这就是为什么大量 RDMA 应用是纯用户态的，内核只负责"建路"。

## RDMA Device：谁接管这台机器

写第一行 RDMA 代码，第一个问题不是"怎么发数据"，而是"我怎么知道这板子上有 RDMA 网卡，怎么接管它"。这把钥匙就是 **RDMA Device** 对象 `struct ib_device`。

在 `include/rdma/ib_verbs.h:2785`（Linux 6.19）能看到它的全貌——核心字段：`name[IB_DEVICE_NAME_MAX]`（设备名）、`node_guid`（节点全局唯一 ID）、`phys_port_cnt`（物理端口数）、`attrs`（`struct ib_device_attr`，设备的出厂能力）、`ops`（`struct ib_device_ops`，驱动填的函数指针表）、`local_dma_lkey`（设备级 DMA 本地密钥）。每个 HCA 驱动探测到硬件后，填充一个 `struct ib_device` 并调用 `ib_register_device()`（`:2969`）注册进核心层。

客户端（上层消费者模块）想接管设备，要先注册成"客户端"：`ib_register_client()`（`drivers/infiniband/core/device.c:1854`）。它的实现里有一段关键循环——拿到 `devices_rwsem` 写锁后，`xa_for_each_marked(&devices, ...)` 遍历所有已注册设备，挨个调用 `add_client_context()` 触发你注册的 `add` 回调。这意味着**不管你的模块先于还是后于硬件驱动加载，都不会漏掉任何一张网卡**；之后热插拔新网卡，回调照样触发。

`struct ib_client`（`:2895`）就是回调契约：`name`（起个名）、`add(struct ib_device *)`（设备出现）、`remove(struct ib_device *, void *client_data)`（设备消失）。模块卸载必须配对调 `ib_unregister_client()`（`device.c:1901`），它会遍历所有设备逐个触发 `remove`——忘调就是 kernel panic。挂私有上下文用 `ib_set_client_data()`/`ib_get_client_data()`，像给衣服缝口袋。

## Queue Pair：RDMA 的通信端点

设备拿到了，路也认了，但数据到底从哪飞出去？答案是 **Queue Pair（QP，队列对）**。名字里的"对"非常精准——它由两条完全独立的工作队列组成：

- **Send Queue（SQ，发送队列）**：投递请求，告诉网卡"把数据发出去"。
- **Receive Queue（RQ，接收队列）**：投递请求，告诉网卡"我有空地了，把收到的数据放这儿"。

这是最容易踩坑的认知点：**发送和接收完全解耦**。同一队列内部严格保序（SQ 里先投 WR1 再投 WR2，网卡一定先处理 WR1），但 SQ 和 RQ 之间毫无关系，像两条平行的单行道。`struct ib_qp`（`ib_verbs.h:1800`）把这些都钉死了：`qp_num`（`:1825`，设备内唯一的 QP 号，别人找你通信靠它）、`qp_type`（`:1828`，传输类型）、`send_cq`/`recv_cq`（绑定的完成队列）、`srq`（绑定的共享接收队列）、`pd`（所属保护域）。

**传输类型不是随便选的**。`enum ib_qp_type`（`:1128`）列了一桌菜：`IB_QPT_RC`（Reliable Connected，可靠连接，一对一，包丢自动重传、乱序自动重排，支持 SEND/RDMA READ/RDMA WRITE/Atomic 全餐）、`IB_QPT_UC`（不可靠连接，砍掉重传，只支持 SEND/RDMA WRITE）、`IB_QPT_UD`（不可靠数据报，一对多甚至组播，只能 SEND，消息不能分片）、`IB_QPT_XRC_INI/TGT`（扩展可靠连接，配合 SRQ 用，多对一省 QP）。存储和数据库要强一致就选 RC；连接建立前的控制面信息交换用 UD。还有两个端口自带的特殊 QP：`IB_QPT_SMI`（QP0，子网管理）和 `IB_QPT_GSI`（QP1，通用服务）。

创建 QP 用 `ib_create_qp(pd, init_attr)`，`init_attr` 是 `struct ib_qp_init_attr`（`:1190`）：`qp_type`、`sq_sig_type`（`IB_SIGNAL_ALL_WR` 每个包都通知，调试用；`IB_SIGNAL_REQ_WR` 手动控制通知，生产环境省 CQ 中断）、`cap`（`struct ib_qp_cap`，`:1108`，决定 `max_send_wr`/`max_recv_wr`/`max_send_sge`/`max_recv_sge`）、绑定的 `send_cq`/`recv_cq`/`srq`。

建出来的 QP 是空壳，必须走状态机才能收发。`enum ib_qp_state`（`:1285`）画了那条著名的"俄罗斯方块"路：`RESET`（刚建，啥都不能干，进来的包全丢）→ `INIT`（还不能 SEND，但可以预投 RECV，防止一到 RTR 远端数据就到、RQ 空着触发 RNR 错误）→ `RTR`（Ready To Receive，能处理接收）→ `RTS`（Ready To Send，全速战斗状态），中间还有 `SQD`（发送队列排空，改属性时的过渡态）、`SQE`（UC/UD 发送出错）、`ERR`（不可恢复，必须 RESET 重来）。状态转换不是自动的，靠 `ib_modify_qp()` 一档一档推，每推一档顺便配该档必须的参数（RTR 要配对方的 `dest_qp_num`/`rq_psn`/路径 MTU，RTS 要配超时/重试次数/自己的 PSN）。合法性检查有现成的 `ib_modify_qp_is_ok()`（`:3119`）。

## Memory Region：网卡能 DMA 哪些内存

QP 通了路，但"车"（数据）还得先有地方装——而 RDMA 的内存不是随便扔个指针就行的。你手里的虚拟地址在物理内存里到底在哪？分页机制可能随时把它换到 swap，网卡正 DMA 读着就读到垃圾了。

**Memory Registration** 就是给内存上"双头锁"：一头锁住虚拟到物理地址的映射（Pin 住，禁止换出），另一头生成两把钥匙。这块内存注册成功才变成一个 **MR（Memory Region）**，`struct ib_mr`（`ib_verbs.h:1872`）的核心字段正是那两把钥匙：`lkey`（`:1875`，本地密钥，自己 CPU 填 Work Request 时出示）、`rkey`（`:1876`，远程密钥，交给对方，对方发 RDMA READ/WRITE 时必须带上，否则你的网卡直接拒收），外加 `iova`（IO 虚拟地址）、`length`、`pd`。

注册是"重"操作（拆页、翻译地址、查权限、Pin 住），可能睡眠——所以中断/原子上下文里不能随便注册，那得用 FMR（Fast MR）池预先注册好再快速取用。临时映射一段 `kmalloc` 出来的地址给网卡，用 `ib_dma_map_single()` 拿到网卡能懂的 DMA 地址，用完必须 `ib_dma_unmap_single()` 解映射，否则 DMA 映射表泄露。嫌映射+同步（`ib_dma_sync_single_for_cpu/device`）麻烦，直接 `ib_dma_alloc_coherent()` 分配 CPU 和网卡都能直接访问的一致性内存。

想动态授权又不想反复注销 MR？用 **Memory Window（MW）**：MR 保持注册不动，往 QP 发个特殊的 Bind WR 把 MW 绑到 MR 上生成新 rkey，解绑后 rkey 立即失效——轻量级权限控制。

## SEND/RECV vs READ/WRITE：对端 CPU 在不在场

这是 RDMA 区别于普通网卡的根本，必须讲透。`enum ib_wr_opcode`（`:1336`）把操作码列清楚了：

**带 CPU 的操作**——`IB_WR_SEND`/`SEND_WITH_IMM`：像 socket 的 send，但前提是**远端必须提前摆好接收请求**（往 RQ 投 RECV WR，指定数据落在哪个缓冲区）。远端没准备？要么丢包要么 RNR 错误。`SEND_WITH_IMM` 还能附 32 位带外立即数，直接出现在接收方的 Work Completion 里，不进数据缓冲区——发简短指令/元数据的巧妙机制。

**不带 CPU 的操作**——`IB_WR_RDMA_WRITE`/`RDMA_READ`：这是 RDMA 的灵魂。`RDMA WRITE` 直接把数据写到远端指定内存地址，**远端 CPU 完全不参与**，没有中断、没有上下文切换，只要对方给了 rkey 和地址权限；`RDMA READ` 则是你主动指定远端地址，把数据"拉"回本地。配合 `RDMA WRITE_WITH_IMM`，数据像 WRITE 那样进远端内存，立即数又像 SEND 那样进远端 CQ（但要远端有 RECV 在排队）。还有硬件级原子操作 `IB_WR_ATOMIC_CMP_AND_SWP`（CAS）、`IB_WR_ATOMIC_FETCH_AND_ADD`——分布式系统绕过锁直接操作远端内存。

投递 Work Request 走 `ib_post_send(qp, wr, &bad_wr)` 或 `ib_post_recv()`，`bad_wr` 在批量投递时告诉你"挂在链上哪个环节断了"。RC 模式下硬件有自动重试：通用重试（超时没收 ACK 就重发）和 RNR 重试（远端没摆盘子回 RNR NACK，发送方等一会儿再重发）。一个 WR 投出去就是 Outstanding，直到在关联 CQ 里 poll 到对应 Work Completion（`struct ib_wc`，`:1032`）才算寿终正寝——这期间它用到的 buffer 绝对不能碰。

## Shared Receive Queue：多 QP 共享接收省内存

服务端要扛上万并发连接时，"每个 QP 配独立接收队列"的规矩就不可理喻了。一万客户端，每个都可能突发，99% 时候沉默——按旧规矩你得为每个 QP 预备满汉全席，结果内存被 9900 桌凉掉的菜耗光。

**SRQ（Shared Receive Queue，共享接收队列）** 的核心思想：接收资源从"私有"变"公有"。所有 QP 连到同一个大池子，谁收到数据谁从池里拿一个缓冲区装。`struct ib_srq`（`:1643`）里 `srq_type`、`event_handler`、`ext.xrc.srq_num` 都备好了。

代价是池化的通病：你不再确切知道是哪个 QP 会拿走缓冲区，所以**所有投到 SRQ 的接收缓冲必须大到能装下所有关联 QP 里最大的消息**（64B 心跳和 4MB 数据块混用就只能全上 4MB，解决办法是分级——小包 QP 挂一个 SRQ、大包 QP 挂另一个）。更棘手的是池子空了所有 QP 都饿死，所以 SRQ 有独门绝技**水位线**：`ib_modify_srq(srq, attr, IB_SRQ_LIMIT)`（`IB_SRQ_LIMIT` 见 `:1079`）设个 `srq_limit` 阈值，剩余请求数跌破就触发异步事件提醒"快没水了赶紧补水"。投递用 `ib_post_srq_recv()`，别等 0 才设水位，给自己留 5%–10% 余量。

## 小结

把这条越狱之路连起来：你先 `ib_register_client()` 接管 `struct ib_device`（建路），建 `struct ib_pd` 当隔离沙箱，注册 `struct ib_mr` 把内存 Pin 住拿 lkey/rkey（装货），创建 `struct ib_qp` 走 RESET→INIT→RTR→RTS 状态机（修管道），最后用 `ib_post_send`/`ib_post_recv` 投 Work Request，硬件绕过内核直接 DMA。理解它分三层：物理结构（SQ/RQ + PD + CQ）、传输类型（RC/UC/UD/XRC，决定能做什么操作）、生命周期（状态机少一步不行快一步也不行）。SRQ 是高并发场景下省接收内存的终极答案。

记住最关键的一点：**SEND/RECV 要对端 CPU 配合摆盘子，RDMA READ/WRITE 直接读写远端内存、对端 CPU 纹丝不动**——这就是 RDMA 性能魔法的根。

## 延伸阅读

- 源码（Linux 6.19）：
  - `include/rdma/ib_verbs.h`——所有核心数据结构与 API 声明（`struct ib_device`/`ib_qp`/`ib_mr`/`ib_pd`/`ib_srq`、`enum ib_qp_state`/`ib_qp_type`/`ib_wr_opcode`）。
  - `drivers/infiniband/core/device.c`——设备/客户端注册（`ib_register_device`、`ib_register_client`、`ib_unregister_client`）。
  - `drivers/infiniband/core/`——`verbs.c`（核心 Verbs）、`cm.c`（连接管理）、`uverbs_*.c`（用户态 Verbs）、`mad.c`（管理数据报）。
  - `drivers/infiniband/hw/`——各厂商 HCA 硬件驱动；`drivers/infiniband/ulp/`——IPoIB/iSER/SRP 等上层协议。
- kernel.org 文档：
  - [InfiniBand 子系统总览](https://docs.kernel.org/infiniband/index.html)
  - [User-space Verbs（用户态如何绕过内核直接操作网卡）](https://docs.kernel.org/infiniband/user_verbs.html)
  - [InfiniBand 驱动 API](https://docs.kernel.org/driver-api/infiniband.html)
- 下一步铺开：CQ（Completion Queue，完成队列与轮询）、RDMA CM（连接管理器用户态 API）、FMR/MW 进阶内存管理。