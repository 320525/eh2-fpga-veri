# VeriTiger-V19P-A14 DDR4-1 SODIMM pinout.
# Source: the board's SODIMM_1 DDR4 example design.

# Non-MIG system clocks are sourced from the board's SI5338 programmable
# differential global-clock outputs.  The pairs are AC-coupled and externally
# terminated, so internal DIFF_TERM must remain disabled in the RTL IBUFDS.
#
# GCLK0_FPGA_TOP: TEMAC transmit clock, 125 MHz.
set_property PACKAGE_PIN BY44 [get_ports gtx_clk_p]
set_property PACKAGE_PIN CA44 [get_ports gtx_clk_n]
set_property IOSTANDARD LVDS [get_ports {gtx_clk_p gtx_clk_n}]
create_clock -period 8.000 -name gtx_clk [get_ports gtx_clk_p]

# GCLK1_FPGA_TOP: AXI4-Lite/ATG/MDIO initialization clock, 100 MHz.
set_property PACKAGE_PIN BN55 [get_ports s_axi_aclk_p]
set_property PACKAGE_PIN BP55 [get_ports s_axi_aclk_n]
set_property IOSTANDARD LVDS [get_ports {s_axi_aclk_p s_axi_aclk_n}]
create_clock -period 10.000 -name s_axi_aclk [get_ports s_axi_aclk_p]

# GCLK4_FPGA_BOT: TEMAC IDELAY/ODELAY calibration reference, 333.333 MHz.
set_property PACKAGE_PIN CA36 [get_ports refclk_p]
set_property PACKAGE_PIN CA37 [get_ports refclk_n]
set_property IOSTANDARD LVDS [get_ports {refclk_p refclk_n}]
create_clock -period 3.000 -name refclk [get_ports refclk_p]

# The FIFO read side, frame controller, DataMover and AXI clock-converter
# source side use TEMAC rx_mac_aclk.  TEMAC derives it from rgmii_rxc through
# the dedicated input buffer and BUFG, so no separate board clock is needed.
# The TEMAC-generated scoped XDC supplies the 8.000 ns rgmii_rxc constraint.

# Board-wide reset release, identical to led_test: both switches high releases
# the design; either switch low resets MAC, FIFO, DMA, AXI and MIG together.
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

# Active-high board LEDs.  T1/T3 indicate DMA/DDR readback data matches;
# T2/T4 remain on whenever the FPGA image is running.
set_property PACKAGE_PIN BE22 [get_ports {led_t[0]}]
set_property PACKAGE_PIN BG23 [get_ports {led_t[1]}]
set_property PACKAGE_PIN BJ20 [get_ports {led_t[2]}]
set_property PACKAGE_PIN BN19 [get_ports {led_t[3]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led_t[*]}]
set_property DRIVE 8 [get_ports {led_t[*]}]

set_property PACKAGE_PIN BN26 [get_ports c0_sys_clk_p]
set_property PACKAGE_PIN BP26 [get_ports c0_sys_clk_n]
# The led_test/reference MIG-generated XDC supplies DIFF_SSTL12 and the
# 13.132 ns (76.150 MHz) differential input-clock constraint.

set_property PACKAGE_PIN BW33 [get_ports {c0_ddr4_dq[0]}]
set_property PACKAGE_PIN BW31 [get_ports {c0_ddr4_dq[1]}]
set_property PACKAGE_PIN BV31 [get_ports {c0_ddr4_dq[2]}]
set_property PACKAGE_PIN BV30 [get_ports {c0_ddr4_dq[3]}]
set_property PACKAGE_PIN BV34 [get_ports {c0_ddr4_dq[4]}]
set_property PACKAGE_PIN BV33 [get_ports {c0_ddr4_dq[5]}]
set_property PACKAGE_PIN BW32 [get_ports {c0_ddr4_dq[6]}]
set_property PACKAGE_PIN BW30 [get_ports {c0_ddr4_dq[7]}]
set_property PACKAGE_PIN BF21 [get_ports {c0_ddr4_dq[8]}]
set_property PACKAGE_PIN BG22 [get_ports {c0_ddr4_dq[9]}]
set_property PACKAGE_PIN BG21 [get_ports {c0_ddr4_dq[10]}]
set_property PACKAGE_PIN BF24 [get_ports {c0_ddr4_dq[11]}]
set_property PACKAGE_PIN BE24 [get_ports {c0_ddr4_dq[12]}]
set_property PACKAGE_PIN BH24 [get_ports {c0_ddr4_dq[13]}]
set_property PACKAGE_PIN BG24 [get_ports {c0_ddr4_dq[14]}]
set_property PACKAGE_PIN BF22 [get_ports {c0_ddr4_dq[15]}]
set_property PACKAGE_PIN BV28 [get_ports {c0_ddr4_dq[16]}]
set_property PACKAGE_PIN BV29 [get_ports {c0_ddr4_dq[17]}]
set_property PACKAGE_PIN BW27 [get_ports {c0_ddr4_dq[18]}]
set_property PACKAGE_PIN BY27 [get_ports {c0_ddr4_dq[19]}]
set_property PACKAGE_PIN BV26 [get_ports {c0_ddr4_dq[20]}]
set_property PACKAGE_PIN BV25 [get_ports {c0_ddr4_dq[21]}]
set_property PACKAGE_PIN BW28 [get_ports {c0_ddr4_dq[22]}]
set_property PACKAGE_PIN BY28 [get_ports {c0_ddr4_dq[23]}]
set_property PACKAGE_PIN CA27 [get_ports {c0_ddr4_dq[24]}]
set_property PACKAGE_PIN CC26 [get_ports {c0_ddr4_dq[25]}]
set_property PACKAGE_PIN CC25 [get_ports {c0_ddr4_dq[26]}]
set_property PACKAGE_PIN CA24 [get_ports {c0_ddr4_dq[27]}]
set_property PACKAGE_PIN CB27 [get_ports {c0_ddr4_dq[28]}]
set_property PACKAGE_PIN CA26 [get_ports {c0_ddr4_dq[29]}]
set_property PACKAGE_PIN CB26 [get_ports {c0_ddr4_dq[30]}]
set_property PACKAGE_PIN CA25 [get_ports {c0_ddr4_dq[31]}]
set_property PACKAGE_PIN BP22 [get_ports {c0_ddr4_dq[32]}]
set_property PACKAGE_PIN BR19 [get_ports {c0_ddr4_dq[33]}]
set_property PACKAGE_PIN BR20 [get_ports {c0_ddr4_dq[34]}]
set_property PACKAGE_PIN BP21 [get_ports {c0_ddr4_dq[35]}]
set_property PACKAGE_PIN BR22 [get_ports {c0_ddr4_dq[36]}]
set_property PACKAGE_PIN BR23 [get_ports {c0_ddr4_dq[37]}]
set_property PACKAGE_PIN BT20 [get_ports {c0_ddr4_dq[38]}]
set_property PACKAGE_PIN BT21 [get_ports {c0_ddr4_dq[39]}]
set_property PACKAGE_PIN BK22 [get_ports {c0_ddr4_dq[40]}]
set_property PACKAGE_PIN BH23 [get_ports {c0_ddr4_dq[41]}]
set_property PACKAGE_PIN BH19 [get_ports {c0_ddr4_dq[42]}]
set_property PACKAGE_PIN BK19 [get_ports {c0_ddr4_dq[43]}]
set_property PACKAGE_PIN BJ22 [get_ports {c0_ddr4_dq[44]}]
set_property PACKAGE_PIN BJ23 [get_ports {c0_ddr4_dq[45]}]
set_property PACKAGE_PIN BH20 [get_ports {c0_ddr4_dq[46]}]
set_property PACKAGE_PIN BK20 [get_ports {c0_ddr4_dq[47]}]
set_property PACKAGE_PIN CA30 [get_ports {c0_ddr4_dq[48]}]
set_property PACKAGE_PIN CB33 [get_ports {c0_ddr4_dq[49]}]
set_property PACKAGE_PIN CC28 [get_ports {c0_ddr4_dq[50]}]
set_property PACKAGE_PIN CA31 [get_ports {c0_ddr4_dq[51]}]
set_property PACKAGE_PIN CC33 [get_ports {c0_ddr4_dq[52]}]
set_property PACKAGE_PIN CC30 [get_ports {c0_ddr4_dq[53]}]
set_property PACKAGE_PIN CC29 [get_ports {c0_ddr4_dq[54]}]
set_property PACKAGE_PIN CC31 [get_ports {c0_ddr4_dq[55]}]
set_property PACKAGE_PIN BL22 [get_ports {c0_ddr4_dq[56]}]
set_property PACKAGE_PIN BM21 [get_ports {c0_ddr4_dq[57]}]
set_property PACKAGE_PIN BL20 [get_ports {c0_ddr4_dq[58]}]
set_property PACKAGE_PIN BL21 [get_ports {c0_ddr4_dq[59]}]
set_property PACKAGE_PIN BP23 [get_ports {c0_ddr4_dq[60]}]
set_property PACKAGE_PIN BN23 [get_ports {c0_ddr4_dq[61]}]
set_property PACKAGE_PIN BM22 [get_ports {c0_ddr4_dq[62]}]
set_property PACKAGE_PIN BL19 [get_ports {c0_ddr4_dq[63]}]
set_property PACKAGE_PIN BT29 [get_ports {c0_ddr4_dq[64]}]
set_property PACKAGE_PIN BR29 [get_ports {c0_ddr4_dq[65]}]
set_property PACKAGE_PIN BT25 [get_ports {c0_ddr4_dq[66]}]
set_property PACKAGE_PIN BR25 [get_ports {c0_ddr4_dq[67]}]
set_property PACKAGE_PIN BR28 [get_ports {c0_ddr4_dq[68]}]
set_property PACKAGE_PIN BR24 [get_ports {c0_ddr4_dq[69]}]
set_property PACKAGE_PIN BR27 [get_ports {c0_ddr4_dq[70]}]
set_property PACKAGE_PIN BT26 [get_ports {c0_ddr4_dq[71]}]

set_property PACKAGE_PIN BF29 [get_ports {c0_ddr4_adr[0]}]
set_property PACKAGE_PIN BN29 [get_ports {c0_ddr4_adr[1]}]
set_property PACKAGE_PIN BP25 [get_ports {c0_ddr4_adr[2]}]
set_property PACKAGE_PIN BM28 [get_ports {c0_ddr4_adr[3]}]
set_property PACKAGE_PIN BL26 [get_ports {c0_ddr4_adr[4]}]
set_property PACKAGE_PIN BM26 [get_ports {c0_ddr4_adr[5]}]
set_property PACKAGE_PIN BM29 [get_ports {c0_ddr4_adr[6]}]
set_property PACKAGE_PIN BM27 [get_ports {c0_ddr4_adr[7]}]
set_property PACKAGE_PIN BL27 [get_ports {c0_ddr4_adr[8]}]
set_property PACKAGE_PIN BH29 [get_ports {c0_ddr4_adr[9]}]
set_property PACKAGE_PIN BJ25 [get_ports {c0_ddr4_adr[10]}]
set_property PACKAGE_PIN BN28 [get_ports {c0_ddr4_adr[11]}]
set_property PACKAGE_PIN BG29 [get_ports {c0_ddr4_adr[12]}]
set_property PACKAGE_PIN BE25 [get_ports {c0_ddr4_adr[13]}]
set_property PACKAGE_PIN BH25 [get_ports {c0_ddr4_adr[14]}]
set_property PACKAGE_PIN BG26 [get_ports {c0_ddr4_adr[15]}]
set_property PACKAGE_PIN BF25 [get_ports {c0_ddr4_adr[16]}]

set_property PACKAGE_PIN BY30 [get_ports {c0_ddr4_dm_dbi_n[0]}]
set_property PACKAGE_PIN BE23 [get_ports {c0_ddr4_dm_dbi_n[1]}]
set_property PACKAGE_PIN BU29 [get_ports {c0_ddr4_dm_dbi_n[2]}]
set_property PACKAGE_PIN BY25 [get_ports {c0_ddr4_dm_dbi_n[3]}]
set_property PACKAGE_PIN BT22 [get_ports {c0_ddr4_dm_dbi_n[4]}]
set_property PACKAGE_PIN BH21 [get_ports {c0_ddr4_dm_dbi_n[5]}]
set_property PACKAGE_PIN CA29 [get_ports {c0_ddr4_dm_dbi_n[6]}]
set_property PACKAGE_PIN BM19 [get_ports {c0_ddr4_dm_dbi_n[7]}]
set_property PACKAGE_PIN BT24 [get_ports {c0_ddr4_dm_dbi_n[8]}]

set_property PACKAGE_PIN BK27 [get_ports {c0_ddr4_ba[0]}]
set_property PACKAGE_PIN BP27 [get_ports {c0_ddr4_ba[1]}]
set_property PACKAGE_PIN BE27 [get_ports {c0_ddr4_bg[0]}]
set_property PACKAGE_PIN BF26 [get_ports {c0_ddr4_bg[1]}]
set_property PACKAGE_PIN BL29 [get_ports c0_ddr4_act_n]
set_property PACKAGE_PIN BM23 [get_ports c0_ddr4_reset_n]
set_property PACKAGE_PIN BJ28 [get_ports {c0_ddr4_cs_n[0]}]
set_property PACKAGE_PIN BE28 [get_ports {c0_ddr4_cke[0]}]
set_property PACKAGE_PIN BK29 [get_ports {c0_ddr4_odt[0]}]
set_property PACKAGE_PIN BK25 [get_ports {c0_ddr4_ck_t[0]}]
set_property PACKAGE_PIN BL25 [get_ports {c0_ddr4_ck_c[0]}]

set_property PACKAGE_PIN BY33 [get_ports {c0_ddr4_dqs_c[0]}]
set_property PACKAGE_PIN BY34 [get_ports {c0_ddr4_dqs_t[0]}]
set_property PACKAGE_PIN BF20 [get_ports {c0_ddr4_dqs_c[1]}]
set_property PACKAGE_PIN BE20 [get_ports {c0_ddr4_dqs_t[1]}]
set_property PACKAGE_PIN BW25 [get_ports {c0_ddr4_dqs_c[2]}]
set_property PACKAGE_PIN BW26 [get_ports {c0_ddr4_dqs_t[2]}]
set_property PACKAGE_PIN CC24 [get_ports {c0_ddr4_dqs_c[3]}]
set_property PACKAGE_PIN CB24 [get_ports {c0_ddr4_dqs_t[3]}]
set_property PACKAGE_PIN BU22 [get_ports {c0_ddr4_dqs_c[4]}]
set_property PACKAGE_PIN BU23 [get_ports {c0_ddr4_dqs_t[4]}]
set_property PACKAGE_PIN BK23 [get_ports {c0_ddr4_dqs_c[5]}]
set_property PACKAGE_PIN BK24 [get_ports {c0_ddr4_dqs_t[5]}]
set_property PACKAGE_PIN CB32 [get_ports {c0_ddr4_dqs_c[6]}]
set_property PACKAGE_PIN CA32 [get_ports {c0_ddr4_dqs_t[6]}]
set_property PACKAGE_PIN BN20 [get_ports {c0_ddr4_dqs_c[7]}]
set_property PACKAGE_PIN BN21 [get_ports {c0_ddr4_dqs_t[7]}]
set_property PACKAGE_PIN BU26 [get_ports {c0_ddr4_dqs_c[8]}]
set_property PACKAGE_PIN BT27 [get_ports {c0_ddr4_dqs_t[8]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
