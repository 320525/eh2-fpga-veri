# eth_tx 时钟域

## 与 mac_fifo_dma_proj 的关系

以太网/MAC/PHY 相关输入和 TEMAC 派生时钟与 `mac_fifo_dma_proj` 相同：

- `gtx_clk`：125 MHz，`BY44/CA44`；
- `s_axi_aclk`：100 MHz，`BN55/BP55`；
- `refclk`：333.333 MHz，`CA36/CA37`；
- `rgmii_rxc`：由 DP83867 输入的 125 MHz，`BJ43`；
- TEMAC `inst_rgmii_tx_clk`：由 `gtx_clk` 派生的 125 MHz；
- TEMAC `inst_mdc`：由 `s_axi_aclk` 除以 60，约 1.667 MHz；
- TEMAC `inst_rgmii_rx_clk`：125 MHz RGMII RX 输入时序分析使用的虚拟时钟。

整个工程的时钟集合并非与原工程逐项相同，因为这是 TX 测试工程，未实例化
DDR4/MIG、ILA/debug hub，所以原工程的 76.150 MHz DDR 输入、MMCM/PLL UI
时钟和 20 MHz debug 时钟不在本工程中。工程没有新增板级时钟输入；新增 TX
逻辑复用原有的 `s_axi_aclk` 和 `gtx_clk`。

## 时钟域用途

| 时钟域 | 频率 | 当前工程用途 | 与原工程关系 |
|---|---:|---|---|
| `gtx_clk` / `tx_mac_aclk` | 125 MHz | TEMAC TX、TX FIFO 读侧、发送统计 | 相同 |
| `inst_rgmii_tx_clk` | 125 MHz | RGMII TX 输出时序 | 相同派生关系 |
| `rgmii_rxc` / `rx_mac_aclk` | 125 MHz | TEMAC RX、RX FIFO | 相同 |
| `inst_rgmii_rx_clk` | 125 MHz | RXD/RX_CTL 外部输入分析虚拟时钟 | 相同 |
| `s_axi_aclk` | 100 MHz | MAC 配置、PHY 初始化、两个 ATG、帧格式器、TX FIFO 写侧 | 输入相同；新增 TX 逻辑使用此域 |
| `inst_mdc` | 1.667 MHz | MDIO/MDC 管理接口 | 相同，`s_axi_aclk / 60` |
| `refclk` | 333.333 MHz | IDELAYCTRL 校准 | 相同 |

## 跨时钟域

- `s_axi_aclk → gtx_clk`：TX FIFO 数据、帧状态和指针同步；采用
  `tri_mode_ethernet_mac_0_ex` 的异步 TX FIFO，以及其 3.2 ns
  `-datapath_only` CDC 约束。
- `gtx_clk → s_axi_aclk`：TX FIFO 读指针和完成状态返回，同属上述 TX FIFO
  CDC 设计。
- `rgmii_rxc → gtx_clk`：TEMAC 内部 RX/TX flow/statistics 相关同步，使用 TEMAC
  IP 自带约束。
- `s_axi_aclk → rgmii_rxc/gtx_clk`：TEMAC 配置寄存器及状态同步，使用 IP 自带
  同步器/约束。
- `refclk` 仅用于 IDELAYCTRL 校准，不承载帧数据或控制状态。

最终 post-route 全局结果为 WNS `+0.196 ns`、WHS `+0.014 ns`、TNS/THS
均为 0。官方 Vivado 报告位于：

- `reports/clocks.rpt`
- `reports/clock_interaction.rpt`
- `reports/clock_domain_cdc.rpt`
- `reports/clock_domains.csv`
