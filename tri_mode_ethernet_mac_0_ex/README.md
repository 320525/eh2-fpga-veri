# Tri-Mode Ethernet MAC 示例工程

这是 Xilinx Tri-Mode Ethernet MAC 的示例/参考工程，目标器件保持原始 `xcvu19p-fsva3824-2-e`，顶层为 `tri_mode_ethernet_mac_0_example_design`。

工程中的 `imports/` 包含 AXI-Lite 配置状态机、收发 FIFO、测试图样、时钟/复位和示例约束，主要用于：

- 参考 TEMAC AXI-Lite 初始化顺序；
- 参考 MAC client FIFO 和 RGMII 接法；
- 为 `mac_fifo_dma_proj` 和 `eth_tx` 提供仿真与结构参考。

Vivado 工程入口为 `tri_mode_ethernet_mac_0_ex.xpr`。该示例没有针对当前 VeriTiger 板卡完成独立板级适配，因此仓库不提供它的上板比特流。

