# eth_tx Vivado 工程

本工程基于 `mac_fifo_dma_proj` 的 TEMAC、DP83867 初始化、板级接口和
RGMII 时序设计，并采用 `tri_mode_ethernet_mac_0_ex` 的 TX client FIFO
及对应 CDC 约束。器件为 `xcvu19p_CIV-fsva3824-1-e`。

## 功能

复位释放后自动执行：

1. 原 MAC 工程的 System-Init ATG 配置 TEMAC；
2. `dp83867_phy_init.v` 初始化 DP83867，重启自动协商，并持续轮询 BMSR；
3. 链路和自动协商均完成且连续稳定 100 ms 后，允许发送通路启动；
4. 第二个 System-Init ATG 配置 8-bit Streaming ATG；
5. Streaming ATG 产生 10 个 64-byte payload transaction；
6. 帧格式器添加 14-byte Ethernet header，经 TX FIFO 送入 TEMAC；
7. TEMAC 通过 RGMII 发送，自动添加 preamble、SFD、FCS 和 IFG。

MAC client 侧每帧共 78 字节：

- 目的 MAC：`FF:FF:FF:FF:FF:FF`
- 源 MAC：`02:12:34:56:78:FF`
- EtherType：`16'h88B5`，线上字节顺序 `88 B5`（本地实验 EtherType，便于
  Wireshark/Npcap 和以太网测试软件识别）
- Payload：64 字节，内容 `00 01 02 ... 3F`
- 共发送：10 帧

TX FIFO 是 8-bit AXI4-Stream 用户接口，不需要宽度转换器；后续可直接
连接支持 8-bit MM2S stream 的 DataMover。

## 与参考 MAC/PHY 的一致性

- TEMAC XCI：1 Gbps、RGMII、MDIO、Management enabled、full duplex。
- TEMAC TX 配置：原初始化在 `0x408` 写入 `0x90000000`，其中 bit28
  为 TX enable，bit31 为 TX reset，half-duplex bit26 为 0。
- PHY 初始化寄存器序列与原工程一致；新增 BMSR 轮询和 100 ms 链路稳定
  等待，避免 PHY 重新自动协商期间提前发完一次性的 10 帧。
- PHY 自动协商：原代码对 BMCR 执行 `(BMCR & 16'hF3FF) | 16'h1200`，
  即开启并重启自动协商；不额外强制 duplex。
- PHY RGMII delay：TX 2.00 ns、RX 1.50 ns，与原工程一致。
- FPGA RGMII RX IDELAY：5 个单元均为 1100 ps。
- RGMII RX clock root：固定为原工程实际使用的 `X3Y2`；两个同源 BUFG
  在优化后合并为一个。
- TEMAC 物理 wrapper 与原工程逐字节一致，TXC 不使用 FPGA ODELAY，
  TX clock skew 由 DP83867 提供。
- Ethernet 引脚、IOSTANDARD、DRIVE、SLEW 与原工程相同。
- RX client FIFO 仍保留原工程的 8-to-16 设计；新增发送通路不修改其
  RTL、PHY RX 配置或 RGMII RX 时序数值。

## 验证结果

Vivado 2023.2，2026-07-23（链路等待修正版）：

- 前仿：PASS，逐字节检查 10 × 78-byte 帧、TLAST、TUSER、EtherType
  `88B5`、TX FIFO 被 MAC 消费、TX statistics 和 RGMII 活动。
- 综合：完成。
- 布局布线：4970/4970 routable nets 完全路由，0 routing errors。
- Post-route WNS：`+0.196 ns`。
- Post-route WHS：`+0.014 ns`。
- TNS / THS：`0 / 0`。
- DRC Error：0。
- DRC 仅有一个 `RTSTAT-10` Warning，为两个 ATG 内未使用的 external
  start 同步寄存器无可路由负载，不影响功能或比特流生成。
- 比特流 SHA-256：
  `CB222974A61A5AF3585A452A2272B328CFB7FD9194D1BB309958A5D01078E252`

## 主要文件

- Vivado 工程：`project/eth_tx.xpr`
- 顶层：`rtl/eth_tx_board_top.v`
- 核心：`rtl/eth_tx_core.v`
- MAC/FIFO wrapper：`rtl/eth_tx_mac_fifo_block.v`
- 帧格式器：`rtl/eth_tx_frame_formatter.v`
- PHY 初始化：`rtl/dp83867_phy_init.v`
- Testbench：`tb/eth_tx_core_tb.sv`
- 板级约束：`constraints/eth_tx_board.xdc`
- PHY/RGMII 时序：`constraints/rgmii_phy_timing.xdc`
- TX FIFO CDC：`constraints/tx_fifo_cdc.xdc`
- RX clock root：`constraints/rgmii_rx_clock_placement.xdc`
- 前仿日志：`project/eth_tx.sim/sim_1/behav/xsim/simulate.log`
- Post-route 时序：`reports/post_route_timing_summary.rpt`
- DRC：`reports/post_route_drc.rpt`
- Routed checkpoint：`checkpoints/post_route.dcp`
- 比特流：`output/eth_tx_board_top.bit`

## 板上操作和 LED

`sw3_1` 与 `sw4_1` 同时为高时释放系统复位。工程会先完成 MAC 配置和
DP83867 自动协商；只有链路、自动协商均完成并稳定 100 ms 后，才发送10帧。
之后无需外部控制。

- `led_t[0]`：MAC 配置完成且无错误
- `led_t[1]`：PHY 初始化成功，且链路和自动协商已稳定
- `led_t[2]`：TX ATG 配置完成且状态正常
- `led_t[3]`：FIFO/MAC 均计数到 10 帧且无 ATG、FIFO overflow、帧长错误

## 复现命令

在 Vivado 2023.2 Tcl 环境执行：

```tcl
source D:/eh2_fpga/eth_tx/scripts/run_front_sim.tcl
source D:/eh2_fpga/eth_tx/scripts/run_build.tcl
```

`run_build.tcl` 会重新综合、实现、检查 WNS/WHS、DRC、RX clock root、
RX IDELAY，并只在全部通过后写出比特流。
