# Ethernet-only additions to eh2_dual_ddr_v19p.xdc.  The combined design
# reuses core_clk_p/n (50 MHz) and generates TEMAC GTX/CRC 125 MHz internally;
# atg_clk_p/n is the 100 MHz MAC/control clock.

set_property PACKAGE_PIN CA36 [get_ports refclk_p]
set_property PACKAGE_PIN CA37 [get_ports refclk_n]
set_property IOSTANDARD LVDS [get_ports {refclk_p refclk_n}]
create_clock -period 3.000 -name refclk [get_ports refclk_p]

set_property PACKAGE_PIN BJ47 [get_ports {rgmii_txd[0]}]
set_property PACKAGE_PIN BE44 [get_ports {rgmii_txd[1]}]
set_property PACKAGE_PIN BF41 [get_ports {rgmii_txd[2]}]
set_property PACKAGE_PIN BF42 [get_ports {rgmii_txd[3]}]
set_property PACKAGE_PIN BN49 [get_ports rgmii_tx_ctl]
set_property PACKAGE_PIN BN45 [get_ports rgmii_txc]

set_property PACKAGE_PIN BH43 [get_ports {rgmii_rxd[0]}]
set_property PACKAGE_PIN BK44 [get_ports {rgmii_rxd[1]}]
set_property PACKAGE_PIN BL42 [get_ports {rgmii_rxd[2]}]
set_property PACKAGE_PIN BR43 [get_ports {rgmii_rxd[3]}]
set_property PACKAGE_PIN BM44 [get_ports rgmii_rx_ctl]
set_property PACKAGE_PIN BJ43 [get_ports rgmii_rxc]

set_property PACKAGE_PIN BJ42 [get_ports mdc]
set_property PACKAGE_PIN BM42 [get_ports mdio]
set_property PACKAGE_PIN BM47 [get_ports phy_resetn]

set_property IOSTANDARD LVCMOS18 [get_ports {
  rgmii_txd[*] rgmii_tx_ctl rgmii_txc
  rgmii_rxd[*] rgmii_rx_ctl rgmii_rxc
  mdc mdio phy_resetn
}]
set_property DRIVE 8 [get_ports {
  rgmii_txd[*] rgmii_tx_ctl rgmii_txc mdc mdio phy_resetn
}]
set_property SLEW FAST [get_ports {
  rgmii_txd[*] rgmii_tx_ctl rgmii_txc
}]
set_property SLEW SLOW [get_ports {mdc mdio phy_resetn}]

