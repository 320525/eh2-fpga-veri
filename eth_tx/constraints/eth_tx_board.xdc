# VeriTiger-V19P-A14 clocks and Ethernet pins.
# The settings below are kept line-for-line equivalent to the active
# ddr4_sodimm1.xdc entries in mac_fifo_dma_proj.

set_property PACKAGE_PIN BY44 [get_ports gtx_clk_p]
set_property PACKAGE_PIN CA44 [get_ports gtx_clk_n]
set_property IOSTANDARD LVDS [get_ports {gtx_clk_p gtx_clk_n}]
create_clock -period 8.000 -name gtx_clk [get_ports gtx_clk_p]

set_property PACKAGE_PIN BN55 [get_ports s_axi_aclk_p]
set_property PACKAGE_PIN BP55 [get_ports s_axi_aclk_n]
set_property IOSTANDARD LVDS [get_ports {s_axi_aclk_p s_axi_aclk_n}]
create_clock -period 10.000 -name s_axi_aclk [get_ports s_axi_aclk_p]

set_property PACKAGE_PIN CA36 [get_ports refclk_p]
set_property PACKAGE_PIN CA37 [get_ports refclk_n]
set_property IOSTANDARD LVDS [get_ports {refclk_p refclk_n}]
create_clock -period 3.000 -name refclk [get_ports refclk_p]

set_property PACKAGE_PIN BU21 [get_ports sw3_1]
set_property PACKAGE_PIN BU28 [get_ports sw4_1]
set_property IOSTANDARD LVCMOS12 [get_ports sw3_1]
set_property IOSTANDARD LVCMOS12 [get_ports sw4_1]

# HSPI2-057-UTEH-A20 Ethernet interface.
# The daughter card occupies J20/J21/J22; its DP83867 interface is on J1,
# which mates with VeriTiger J22 (FPGA Bank 20).  DP83867 VDDIO is 1.8 V.
#
# RGMII transmit path: FPGA/TEMAC -> DP83867.
set_property PACKAGE_PIN BJ47 [get_ports {rgmii_txd[0]}] ; # J22-B3 / TXD0
set_property PACKAGE_PIN BE44 [get_ports {rgmii_txd[1]}] ; # J22-A2 / TXD1
set_property PACKAGE_PIN BF41 [get_ports {rgmii_txd[2]}] ; # J22-A0 / TXD2
set_property PACKAGE_PIN BF42 [get_ports {rgmii_txd[3]}] ; # J22-A1 / TXD3
set_property PACKAGE_PIN BN49 [get_ports rgmii_tx_ctl]     ; # J22-D3 / TX_EN
set_property PACKAGE_PIN BN45 [get_ports rgmii_txc]        ; # J22-C4 / GTX_CLK

# RGMII receive path: DP83867 -> FPGA/TEMAC.  Unlike J27, J22-B0 is bonded
# to the clock-capable BJ43 pin, so the RX clock needs no daughter-card flywire.
set_property PACKAGE_PIN BH43 [get_ports {rgmii_rxd[0]}] ; # J22-A7 / RXD0
set_property PACKAGE_PIN BK44 [get_ports {rgmii_rxd[1]}] ; # J22-B8 / RXD1
set_property PACKAGE_PIN BL42 [get_ports {rgmii_rxd[2]}] ; # J22-B7 / RXD2
set_property PACKAGE_PIN BR43 [get_ports {rgmii_rxd[3]}] ; # J22-C9 / RXD3
set_property PACKAGE_PIN BM44 [get_ports rgmii_rx_ctl]     ; # J22-C10 / RX_DV
set_property PACKAGE_PIN BJ43 [get_ports rgmii_rxc]        ; # J22-B0 / RX_CLK, GC

# TEMAC MDIO management and active-low PHY reset (REST_F on the daughter card).
set_property PACKAGE_PIN BJ42 [get_ports mdc]        ; # J22-RSIG0 / MDC_F
set_property PACKAGE_PIN BM42 [get_ports mdio]       ; # J22-RSIG1 / MDIO_F
set_property PACKAGE_PIN BM47 [get_ports phy_resetn] ; # J22-D9 / REST_F

set_property IOSTANDARD LVCMOS18 [get_ports {
  rgmii_txd[*] rgmii_tx_ctl rgmii_txc
  rgmii_rxd[*] rgmii_rx_ctl rgmii_rxc
  mdc mdio phy_resetn
}]
set_property DRIVE 8 [get_ports {
  rgmii_txd[*] rgmii_tx_ctl rgmii_txc mdc mdio phy_resetn
}]
set_property SLEW FAST [get_ports {rgmii_txd[*] rgmii_tx_ctl rgmii_txc}]
set_property SLEW SLOW [get_ports {mdc mdio phy_resetn}]

set_property PACKAGE_PIN BE22 [get_ports {led_t[0]}]
set_property PACKAGE_PIN BG23 [get_ports {led_t[1]}]
set_property PACKAGE_PIN BJ20 [get_ports {led_t[2]}]
set_property PACKAGE_PIN BN19 [get_ports {led_t[3]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led_t[*]}]
set_property DRIVE 8 [get_ports {led_t[*]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
