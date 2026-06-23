---
title: mac80211：内核怎么管一块无线网卡
slug: net-mac80211
difficulty: intermediate
tags: [无线网络, mac80211, cfg80211, 802.11n, MLME, 节电]
architectures: [arm64, x86_64, riscv]
kernel_version: "6.19"
maturity: drafting
prerequisites:
  - /tutorials/kernel/net/01-net-overview
related:
  - /tutorials/kernel/net/01-net-overview
sources:
  - notes: document/notes/linux_kernel_networking/ch12.md
  - notes: document/notes/linux_kernel_networking/ch12_1.md
  - notes: document/notes/linux_kernel_networking/ch12_2.md
  - notes: document/notes/linux_kernel_networking/ch12_3.md
  - notes: document/notes/linux_kernel_networking/ch12_4.md
  - notes: document/notes/linux_kernel_networking/ch12_5.md
  - notes: document/notes/linux_kernel_networking/ch12_6.md
  - notes: document/notes/linux_kernel_networking/ch12_7.md
---

# mac80211：内核怎么管一块无线网卡

> 🔨 **整理中** · 这篇是从读书笔记整理出来的骨架，**函数与数据结构已对照 Linux 6.19 源码核对**（cfg80211/mac80211 的 API、省电常量、聚合流程都已逐条验过）；但**具体行号与命令输出待 QEMU 亲测核对**——行号会随版本漂，等我们在 `mac80211_hwsim` 上跑通再固化。笔记里有些老版本结论（如省电缓冲 128 包、A-MSDU 只在 RX 支持）在 6.19 已经变了，下文按 6.19 实际情况讲。

## 无线不是以太网的一个变种

很多人第一反应是：无线网卡嘛，不就是个插上驱动、起个 `wlan0`、能发包的以太网卡？真这么想，写驱动会死得很惨。

无线和有线在 `/etc/network/interfaces` 里长得像，但内核眼里是两个物种。两个根本差异决定了它必须有自己的一套子系统：

1. **共享介质，没法边说边听**。以太网用 CSMA/CD——我说话时撞了车我立刻知道（Collision Detection）。无线不行：设备一发射，自己的发射功率把整个信道盖住，根本听不见别人。而且还有"隐藏节点"——你离 A 近、离 B 远，A、B 同时说，你只听见 A，以为空闲就开口，结果在 B 那里成了干扰。所以 802.11 改用 **CSMA/CA（Collision Avoidance，冲突避免）**：发之前先听，发了之后等对方回 ACK，没回就默认撞了、重传。这一下，内核就得替每张网卡维护**重传队列、定时器、状态机**——以太网里完全不用操心的事。
2. **链路天生不可靠**。空气里微波炉、蓝牙、隔壁路由器都在抢通道，丢包是常态。802.11 强制（除广播/组播外）每个收到的帧都回 ACK。于是无线驱动不是在搬运数据，是在不停握手。

再加上**移动性**（手机端着走要换 AP）和**省电**（电池设备要时不时关接收机），无线复杂度直接起飞。Linux 给它单开了一层：**mac80211**（软 MAC 框架），上面还有 **cfg80211**（配置框架）。这篇就顺着这两个子系统，把机制扒到底。

## cfg80211：配置框架（net/wireless/）

cfg80211 是无线世界的"户籍处 + 规矩办"：它定义了**用户态和内核沟通无线事务的统一 API**（nl80211 这个 netlink 家族），管着**监管域（Regulatory，哪些频段/功率在哪个国家合法）**，还维护着所有无线设备（`wiphy`）的全局列表。

核心数据结构是 `struct wiphy`（`include/net/cfg80211.h`），你可以理解成"一块无线硬件的身份证"——它装着这张卡能干什么（支持的接口模式、频段、加密能力）。每注册一个 `wiphy` 都对应一个内部包装结构 `struct cfg80211_registered_device`（`net/wireless/core.c`，用 `LIST_HEAD(cfg80211_rdev_list)` 在 `core.c:46` 串成全局链表）。

驱动（包括 mac80211）要接入 cfg80211 的标准三步：

1. `wiphy_new_nm(&ops, sizeof_priv, name)` —— 申领一个 `wiphy`，绑一组 `struct cfg80211_ops` 回调（`net/wireless/core.c`，`wiphy_new_nm` 在第 446 行附近）。
2. 填好 `wiphy` 的能力字段（bands、cipher_suites、interface_modes 等）。
3. `wiphy_register(wiphy)` —— 上户口（第 732 行附近），从此对用户态可见。

mac80211 自己就是 cfg80211 的一个"客户端驱动"——`net/mac80211/main.c` 里 `ieee80211_alloc_hw_nm()` 调的就是 `wiphy_new_nm(&mac80211_config_ops, ...)`。

> 顺便钉个概念：上层常说的"Channel 6"，硬件只认"Frequency 2.437 GHz"，二者靠 `ieee80211_channel_to_frequency()`（`net/wireless/util.c`）翻译。给寄存器塞 Channel 6 它一脸懵。

## mac80211：MAC 层驱动框架（net/mac80211/）

cfg80211 只管"配置"。真正干协议脏活的是 mac80211——它是个**软 MAC 框架**：把扫描、认证、关联、加密、重传、聚合这些通用逻辑全搬进内核，驱动只负责和硬件打交道（收发原始帧、切信道、设密钥）。

这背后是话语权的转移。早年 FullMAC 驱动把 MLME（MAC 层管理）全丢给闭源固件，结果 802.11 修正案（a/b/g/e/i/n...）铺天盖地而来，固件跟不上。mac80211（2007 年并进 2.6.22，前身 Devicescape 的 d80211）把控制权夺回开源内核。现在主流无线驱动（Intel iwlwifi、ath9k/ath10k/ath11k...）都是 mac80211 的 SoftMAC 驱动。

### 入口：ieee80211_alloc_hw_nm() 与 ieee80211_hw

一切始于 `struct ieee80211_hw`（`include/net/mac80211.h`）——硬件设备的身份证。它有个 `void *priv` 指针，是驱动的私房钱，内核完全不看里面是什么，只有驱动自己知道（Intel 的 `iwl_priv`、Atheros 的私有结构都挂这儿）。通用框架和私有实现被切得干干净净。

驱动初始化标准三步（`net/mac80211/main.c`）：

1. `ieee80211_alloc_hw(priv_data_len, &ops)` → 实际调 `ieee80211_alloc_hw_nm()`（第 791 行）。
2. `ieee80211_register_hw(hw)`（第 1120 行）—— 上户口。
3. 收到包时调 `ieee80211_rx_irqsafe(hw, skb)`（中断上下文安全版，`net/mac80211/rx.c:5584`，内部转调 `ieee80211_rx_list()`）。

`ieee80211_alloc_hw_nm()` 里有个漂亮设计：它把 `struct wiphy` + `struct ieee80211_local` + 驱动私有数据**三件套打包成一块连续内存**，靠 `ALIGN(sizeof(*local), NETDEV_ALIGN)` 卡出对齐边界（`main.c:834` 那段注释画了那张内存图）。`local->hw.priv = (char *)local + ALIGN(...)`（第 928 行）——一句指针算术，零拷贝拿到私有区。

进去第一件事是个硬性体检（`main.c:800`）：

```c
if (WARN_ON(!ops->tx || !ops->start || !ops->stop || !ops->config ||
            !ops->add_interface || !ops->remove_interface ||
            !ops->configure_filter || !ops->wake_tx_queue))
    return NULL;
```

这 8 个回调是 mac80211 的命根子，少一个直接拒绝注册。

### 驱动的承诺书：struct ieee80211_ops

`struct ieee80211_ops`（`include/net/mac80211.h:4515`）是一堆函数指针，是驱动写给内核的承诺书。核心几个：

- **`tx()`**（结构体首个成员，`mac80211.h:4516`）：每次内核要发包都调它，正常返回 `NETDEV_TX_OK`。
- **`start()`（`mac80211.h:4519`）/ `stop()`（`mac80211.h:4520`）**：电源开关。`start()` 激活硬件开接收，`stop()` 关机断电。
- **`add_interface()` / `remove_interface()`**：`ifconfig wlan0 up` 时触发——"我要把虚拟网卡绑上来了，硬件那边准备好接客没？"
- **`config()`**：调参旋钮。切信道（CH6→CH11）就是内核调它通知硬件改频率。
- **`configure_filter()`**：看门狗设置——"我只要这几种包，其余别吵我"。

## 网络拓扑：STA / IBSS / AP / Mesh / WDS

帧不是在真空中飞的，是在某种"社会关系"里产生消费的。802.11 定义了几种身份，内核里对应 `enum nl80211_iftype`（`include/uapi/linux/nl80211.h`：注释从 3617 起，枚举本体在 3645 行）：

| 模式 | 宏 | 干什么 |
|:---|:---|:---|
| Managed(STA) | `NL80211_IFTYPE_STATION` | 客户端，你手机连 WiFi 就是它 |
| AP | `NL80211_IFTYPE_AP` | 接入点，网卡变路由器 |
| Ad Hoc(IBSS) | `NL80211_IFTYPE_ADHOC` | 无政府，没 AP 大家平等 |
| Mesh | `NL80211_IFTYPE_MESH_POINT` | 网状网，路由和传输纠缠 |
| WDS | `NL80211_IFTYPE_WDS` | 无线分发系统，做桥接 |
| Monitor | `NL80211_IFTYPE_MONITOR` | 嗅探者，空中所有包都收 |

**Infrastructure BSS（基础架构模式）** 是绝大多数人的日常：一个 AP（中心节点）围着一圈 client station，构成一个 BSS。关联是排他的——一个客户端同时只能绑一个 AP。AP 会发一个 **AID（Association ID，1~2007，上限 `IEEE80211_MAX_AID`）** 在 BSS 内唯一标识你。多 AP 用网线连起来覆盖大区域叫 **ESS**。注意 BSS A 的广播飘到 BSS B，BSS B 的站点会因 BSSID 对不上而**丢弃**——"隔壁教室点名，不是叫我"。

**IBSS（Ad Hoc）** 没人管事，BSSID 用 `get_random_bytes()` 随机生成 48 位地址。命令行 `iw wlan0 ibss join 名字 2412` 一敲，内核走 `ieee80211_ibss_join()` → `ieee80211_sta_create_ibss()`（`net/mac80211/ibss.c:1287`），网络就诞生了。麻烦的省电协调（ATIM 机制）mac80211 **不支持**，这个坑别指望。

AP 本质就是块加了以太网口/LED 的无线网卡，真正让它变 AP 的是用户态的 **hostapd**——它通过 nl80211 注册自己，专门收管理帧，是那个"窗口后盖章的人"。

## MLME：扫描/认证/关联/漫游

MAC 层管理实体（MLME）像个接线员，处理连网那些琐事。

**扫描**有两种：**被动扫描**（闭嘴听 Beacon）和**主动扫描**（跳信道、发 Probe Request、等 Probe Response）。决定走哪条的是**信道（channel）上的 flag**，不是模式开关——5GHz 高端频段、DFS 信道这类法律禁止乱喊的，会带 `IEEE80211_CHAN_NO_IR`（No Initiating Radiation，不主动辐射，`include/net/cfg80211.h:132`），DFS 频段还会同时带 `IEEE80211_CHAN_RADAR`；`net/mac80211/scan.c` 里多处就是判 `(flags & (IEEE80211_CHAN_NO_IR | IEEE80211_CHAN_RADAR))` 直接走被动路径（scan.c:856、918、1047）。主动扫描由 `ieee80211_request_scan()` 触发，"喊一嗓子"是 `ieee80211_send_probe_req()`，切信道调 `ieee80211_hw_config(... IEEE80211_CONF_CHANGE_CHANNEL)`。

> ⚠️ **别认错标志名**：网上老资料（和旧版代码）里见过 `IEEE80211_CHAN_PASSIVE_SCAN` 这个名字，但它在当前 mac80211/cfg80211 的 channel flag 里**已经不存在**了——`grep` 整个 `net/mac80211/`、`net/wireless/`、`include/net/cfg80211.h` 全是空。它只剩个废弃别名残留在 nl80211 用户态 ABI 里（`NL80211_FREQUENCY_ATTR_PASSIVE_SCAN = NL80211_FREQUENCY_ATTR_NO_IR`，`nl80211.h:4503`）。现役机制认 `IEEE80211_CHAN_NO_IR`。

**认证**——注意**认证≠加密**。WPA2/3 的密钥协商在四步握手阶段，这里的 MLME 认证更像"敲门问好"。`ieee80211_send_auth()`（`net/mac80211/util.c:1076`）发 `IEEE80211_STYPE_AUTH` 帧。最古老的 **Open System（`WLAN_AUTH_OPEN`）** 是世上最虚伪的安全机制：客户端说"我想认证"，AP 说"通过"。零安全性，但协议必经——哪怕后面 WPA2 加密，第一步也得走它把状态机推过去。

**关联**是正式入座登记。`ieee80211_send_assoc()`（`net/mac80211/mlme.c:2141`）发 `IEEE80211_STYPE_ASSOC_REQ`，帧里带速率集、11n/ac/ax 能力、要不要省电等。AP 回 Response 带状态码 0 表示成功，给你分配 AID。

**漫游**本质是同一 ESS 内换 AP，走 **Reassociation**，复用 `ieee80211_send_assoc()`，只是子类型换成 `IEEE80211_STYPE_REASSOC_REQ`，帧里多带一个"我上一个连的 AP 的 BSSID"——新 AP 拿着它去老 AP 那里把缓存数据同步过来，实现无缝切换。

## 节电模式（Power Save）：AP 当保姆

电池设备得时不时关接收机睡觉。问题来了：**你睡觉时别人发给你的微信怎么办？** 有线网那头永远有电，无线这是个大问题。

**进入节电**：客户端发一个 **Null Data**（空数据包，`IEEE80211_STYPE_NULLFUNC`，只有头没载荷），把帧控制里的 **PM（Power Management）位置 1**，AP 就懂"这哥们睡了"。AP 在内核里为每个关联站点维护一个**省电缓冲队列 `ps_tx_buf`**，把发给睡眠站点的单播包存起来。

⚠️ **注意版本差异**：笔记写"每站 128 包"，但 **6.19 实际是 `STA_MAX_TX_BUFFER = 64`**（`net/mac80211/sta_info.h:860`），而且是**每 AC 一个队列** `ps_tx_buf[IEEE80211_NUM_ACS]`（sta_info.h:739）——QoS 优先级分开放，不是单链表。组播/广播走共享的 `bc_buf`，上限 `AP_MAX_BC_BUFFER = 128`（`net/mac80211/ieee80211_i.h:46`）；还有个全局总量 `TOTAL_MAX_TX_BUFFER = 512`（ieee80211_i.h:51）。超了就 FIFO 丢老的——睡死过去的手机醒来可能丢最早几条消息，永远找不回。

**醒来取货**：AP 周期性（通常 100ms）广播 **Beacon**，里头带 **TIM（Traffic Indication Map）**——一个 2008 位的位图，对应 AID 0~2007，你的队列有货就把你的位置 1。客户端醒来抓 Beacon，用 `ieee80211_check_tim()`（`include/linux/ieee80211.h:2836`）查自己那一位，是 1 就发 **PS-Poll** 控制帧去提货。AP 发货时每个包帧控制里带 `IEEE80211_FCTL_MOREDATA`：1 表示"还有货接着 Poll"，0 表示"最后一个拿完睡吧"。组播包的 AID=0，配 **DTIM**（每几个 Beacon 出现一次）周期性批量倒 `bc_buf`，极大省电。

> 别把 **Power Save Mode**（协议层，运行时睡几毫秒、AP 缓存）和 **Power Management**（系统层，合盖 suspend、`net/mac80211/pm.c` 的 suspend/resume 回调）搞混——在 suspend 回调里处理 TIM 位图是走错房间。

## 802.11n High Throughput：MIMO + 帧聚合

802.11n（2009 定稿）把无线拖进高速时代，物理层速率理论上飙到 600 Mbps。两大杀器：

**MIMO（多输入多输出）**：AP 和客户端两边都装多根天线，"你三四张嘴一起喊，我三四只耳朵同时听"，距离更远、速度更快。同时霸占 2.4G 和 5G 两个频段。

**Packet Aggregation（帧聚合）**：以前一封信一封信寄，信封本身有成本；现在塞一本厚书一次发走。配 **Block Ack（BA）**——发一堆包，对方回一个 BA 说"那十个我都收到了"，省掉中间傻等的间隔。两种聚合别搞混：

- **A-MSDU**：多个上层包捏一起、外面只包一个 MAC 头。mac80211 里**接收方向支持**；发送方向在 6.19 也有条件支持——`net/mac80211/tx.c` 的 fast-xmit 路径里有 `drv_can_aggregate_in_amsdu()`（tx.c:3489）+ `ieee80211_amsdu_prepare_head()`（tx.c:3333），能把多个上层包在 TX 侧聚成 A-MSDU，但依赖驱动/硬件支持。**不依赖 Block Ack**。
- **A-MPDU**：多个已包好 MAC 头的完整 MPDU 打包，**必须配 Block Ack**——本节主角。

> 💡 **旧结论要更新**：不少老资料（含我们这份笔记）写"A-MSDU 只在 RX 方向支持"——这在老版本对，但 6.19 已经变了，TX 侧的 A-MSDU 聚合是现役代码。读源码别照搬过时结论。

**建立 BA 会话**绑定在某个 **TID**（流量标识符）上，分**发起侧**和**响应侧**两半，代码分别在两个文件里（别当成一锅炖）：

- **发起侧（`net/mac80211/agg-tx.c`）**：发起者 `ieee80211_start_tx_ba_session()`（agg-tx.c:600）置状态位 `HT_AGG_STATE_WANT_START`，调 `ieee80211_send_addba_request()`（agg-tx.c:61）发 **ADDBA Request**（带 Buffer Size、TID）。发完一波 A-MPDU 后发 **BAR**（`ieee80211_send_bar()`，agg-tx.c:103）催确认，BAR 里带 **SSN（起始序列号）**，结构体是 `struct ieee80211_bar`（`include/linux/ieee80211-ht.h:47`，不在 `ieee80211.h` 里）。
- **响应侧（`net/mac80211/agg-rx.c`）**：本机作为响应者收到对方的 ADDBA Request 时，`ieee80211_process_addba_request()`（agg-rx.c:471）处理，置 `HT_AGG_STATE_OPERATIONAL`，`ieee80211_send_addba_resp()`（agg-rx.c:233）发响应成交。

BA 有 Immediate（立即回，性能好）和 Delayed（先 ACK 缓会再回）两种。结束时 `ieee80211_send_delba()` 收场。**1 秒**没回音定时器触发、掐死会话。边界：A-MPDU 最大 65535 字节；聚合只支持 **AP 和 Managed 模式**，IBSS 规范不支持。

## RX/TX 流水线与责任链

收包主角是 `ieee80211_rx_list()`（`net/mac80211/rx.c:5417`）——6.19 早不是老的单一 `ieee80211_rx()`，而是 list 化批量处理，`ieee80211_rx_irqsafe()`（rx.c:5584）内部转调它。驱动把 SKB 递上来时，在 SKB 控制缓冲区塞了张小纸条 `ieee80211_rx_status`（用 `IEEE80211_SKB_RXCB()` 抽出来），写着 FCS 校验、信号强度等。flag 带 `RX_FLAG_FAILED_FCS_CRC` 就是废包。

收发都用**责任链模式**：一串处理器各看一眼包，返回三类结果（`net/mac80211/drop.h:86` 附近）：

- `RX_CONTINUE` —— 没我的事，下一个继续。
- `RX_QUEUED` —— 我接管了。
- `RX_DROP` —— 垃圾，丢。

比如 `ieee80211_rx_h_mgmt_check()`（`rx.c:3490`）检查"号称管理帧但连 24 字节都没有"，直接返回 `RX_DROP`——层层过滤保证非法包跑不满 CPU。6.19 起 `RX_DROP` 不是光秃秃一个值了，底层带**细分 drop reason code**（`drop.h` 里 2023 年重构过的一套，`R(RX_DROP_U_RUNT_ACTION)` 这种就是它），把"为什么丢"记进 SKB 给监控/统计用。TX 侧 `ieee80211_tx()` → `__ieee80211_tx_prepare()` → `invoke_tx_handlers()`（`CALL_TXH` 串起来），绿灯后 `__ieee80211_tx()` 真正推向驱动 `tx()` 回调。

## 动手验证方案（待亲测）

下面这些命令等我们在 QEMU + `mac80211_hwsim`（虚拟无线网卡模块，内核自带）上亲测后填真实输出：

- **加载虚拟网卡**：`modprobe mac80211_hwsim radios=2`，看是否冒出 `phy0`/`phy1`、`wlan0`/`wlan1`。
- **看能力**：`iw list`（看 `wiphy` 的 bands、interface_modes、cipher_suites）。
- **扫描**：`iw dev wlan0 scan`（主动扫描触发 `ieee80211_send_probe_req`）。
- **看 mac80211 日志**：`echo 0x7fff > /sys/module/mac80211/parameters/debug`，开 debugfs `/sys/kernel/debug/ieee80211/phy0/`，挖 `total_ps_buffered`、`statistics/`、`rc/name`。
- **待亲测**：在 `example/mini/` 下落一个最小 mac80211 SoftMAC 驱动骨架（填 `ieee80211_ops` 那 8 个命根子回调 + `ieee80211_alloc_hw`/`register_hw`），跑通 QEMU 收发——验证"alloc_hw 三件套内存布局"和"责任链收包"。

## 小结

无线不是以太网的变种：共享介质逼出 CSMA/CA 和 ACK 重传状态机，移动性和省电又叠了 MLME 和 Power Save。Linux 用两层子系统扛这套复杂度——**cfg80211**（`net/wireless/`）管配置和监管，核心是 `wiphy` + `wiphy_new_nm`/`wiphy_register`；**mac80211**（`net/mac80211/`）是软 MAC 框架，靠 `ieee80211_alloc_hw_nm` 把 wiphy + local + 私有数据三件套打包、`ieee80211_ops` 那 8 个命根子回调挂驱动。省电靠 AP 缓存（`ps_tx_buf` 每站 64/AC、`bc_buf` 128、全局 512），802.11n 靠 MIMO + A-MPDU/Block Ack 提速、A-MSDU 在 RX 和（有条件的）TX 都支持。被动扫描认 `IEEE80211_CHAN_NO_IR`（不是已消失的 `IEEE80211_CHAN_PASSIVE_SCAN`）。看源码时记住一条主线：**驱动只碰硬件，所有协议逻辑都在 mac80211 的责任链里。**

## 延伸阅读

- 源码（Linux 6.19）：
  - `net/mac80211/main.c` —— `ieee80211_alloc_hw_nm`、`ieee80211_register_hw`、`ieee80211_ops` 体检。
  - `net/wireless/core.c` —— cfg80211 核心，`wiphy_new_nm`、`wiphy_register`、`cfg80211_rdev_list`。
  - `include/net/mac80211.h` —— `struct ieee80211_ops`（4515 行）、`struct ieee80211_hw`。
  - `include/net/cfg80211.h` —— `struct wiphy`、`IEEE80211_CHAN_NO_IR`（132 行）、监管 API。
  - `net/mac80211/mlme.c` —— MLME（`ieee80211_send_assoc`、`ieee80211_send_auth`）。
  - `net/mac80211/agg-tx.c` —— A-MPDU/Block Ack 发起侧（`start_tx_ba_session`、`send_addba_request`、`send_bar`）。
  - `net/mac80211/agg-rx.c` —— A-MPDU/Block Ack 响应侧（`process_addba_request`、`send_addba_resp`）。
  - `net/mac80211/tx.c` —— TX A-MSDU 聚合（`drv_can_aggregate_in_amsdu`、`ieee80211_amsdu_prepare_head`）。
  - `net/mac80211/rx.c` —— RX 责任链（`ieee80211_rx_list`、`ieee80211_rx_irqsafe`、`ieee80211_rx_h_mgmt_check`）。
  - `net/mac80211/drop.h` —— 6.19 drop-reason 重构（`RX_CONTINUE`/`RX_QUEUED`/`RX_DROP` + 细分 reason code）。
  - `net/mac80211/ibss.c` —— IBSS（`ieee80211_sta_create_ibss`）。
  - `include/linux/ieee80211-ht.h` —— `struct ieee80211_bar`。
- kernel.org 文档索引（已核对页面真实存在）：
  - [Linux 802.11 Driver Developer's Guide](https://docs.kernel.org/driver-api/80211/index.html)（含 cfg80211、mac80211、mac80211-advanced 子页）。
  - [mac80211_hwsim](https://docs.kernel.org/networking/mac80211_hwsim/mac80211_hwsim.html) —— 虚拟无线网卡，QEMU 验证用。
- 进一步（持续铺开）：802.11s Mesh（`net/mac80211/mesh_*`）、速率控制算法（`rc80211_*`）、WPA 加密密钥路径。

--- 

以上为修订版全文。逐条修正对照（均已对照 6.19 源码 `third_party/linux` 核实）：

1. **Finding 1（被动扫描标志，HIGH）**：`IEEE80211_CHAN_PASSIVE_SCAN` 全仓库 channel flag 不存在，改为现役 `IEEE80211_CHAN_NO_IR`（cfg80211.h:132）+ `IEEE80211_CHAN_RADAR`，补 scan.c 行号，并加"别认错标志名"callout 指出旧名仅存于 nl80211 废弃别名（nl80211.h:4503）。
2. **Finding 2（A-MSDU，MEDIUM）**：改为"RX 支持 + TX 在 6.19 有 fast-xmit 条件支持"，引 tx.c:3489 `drv_can_aggregate_in_amsdu`、tx.c:3333 `ieee80211_amsdu_prepare_head`，加版本更新 callout。
3. **Finding 3（责任链返回值，MEDIUM）**：删掉 `RX_DROP_MONITOR`/`RX_DROP_UNUSABLE`，改为 `RX_CONTINUE`/`RX_QUEUED`/`RX_DROP`（drop.h:86-88），mgmt_check 改为返回 `RX_DROP`（rx.c:3490→3512 `RX_DROP_U_RUNT_ACTION`），并提 drop.h 2023 年 drop-reason 重构。
4. **Finding 4（ADDBA 文件归属，MEDIUM）**：拆成发起侧（agg-tx.c:600/61）和响应侧（agg-rx.c:471/233），不再打包进 agg-tx.c。
5. **Finding 5（`struct ieee80211_bar` 路径，LOW）**：`include/linux/ieee80211.h` → `include/linux/ieee80211-ht.h:47`。
6. **Finding 6（tx 回调行号，LOW）**：tx 是结构体首个成员（mac80211.h:4516），start 4519/stop 4520，删掉"tx 在其后"。
7. **Finding 7（nl80211_iftype 行号，LOW）**：改为"注释 3617 起，枚举本体 3645"，AID 补 `IEEE80211_MAX_AID` 来源。
8. **Finding 8（callout 收敛）**：callout 从"函数/数据结构已核对"收敛为"函数与数据结构已核对，行号与命令输出待亲测核验"。

其余经源码核对无误、保留原样：省电三常量（STA_MAX_TX_BUFFER=64/STA_MAX_BC_BUFFER=128/TOTAL_MAX_TX_BUFFER=512，已正确）、alloc_hw_nm:791、register_hw:1120、rx_list:5417、rx_irqsafe:5584、send_auth util.c:1076、send_assoc mlme.c:2141、ibss_create:1287、send_bar agg-tx.c:103、WARN_ON main.c:800、wiphy_new_nm:446、wiphy_register:732、三件套内存布局 main.c:834、priv 指针 928、check_tim:2836、AID 2007、RX_FLAG_FAILED_FCS_CRC、IEEE80211_FCTL_MOREDATA、docs.kernel.org 两条链接（`driver-api/80211/index.rst` 与 `networking/mac80211_hwsim/mac80211_hwsim.rst` 均真实存在，原草稿无 netns.html 死链）。frontmatter 英文键名半角冒号、sources 用 `notes:`、折腾博主风格、章节结构均保留。

修订文件路径：`/home/charliechen/PenguinLab/document/tutorials/kernel/net/14-net-wireless.md`