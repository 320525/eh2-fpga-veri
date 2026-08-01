# Board-level timing for the DP83867 in RGMII_ID mode.
#
# The J22 pinout cannot use the stock TEMAC TXC delay cascade because the TXC
# pin and an RX data pin share the required adjacent BITSLICE resource.  The
# TEMAC wrapper therefore sends TXC edge-aligned and MDIO programs both PHY
# delay fields to TX code 7 (2.00 ns) and RX code 5 (1.50 ns).
#
# DP83867 receiver requirements with internal delay are 1.00 ns setup and
# 1.00 ns hold.  Vivado output delays are referenced to forwarded TXC at the
# FPGA pin, so the external capture-clock skew is subtracted:
#   output_delay(max) = Tsetup - Tphy_delay = 1.00 - 2.00 = -1.00 ns
#   output_delay(min) = -Thold - Tphy_delay = -1.00 - 2.00 = -3.00 ns
set rgmii_tx_phy_clock [get_clocks -quiet -of_objects [get_ports rgmii_txc]]
set rgmii_tx_phy_data [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

set_output_delay -1.000 -max -clock $rgmii_tx_phy_clock \
  $rgmii_tx_phy_data
set_output_delay -3.000 -min -clock $rgmii_tx_phy_clock \
  $rgmii_tx_phy_data
set_output_delay -1.000 -max -clock $rgmii_tx_phy_clock -clock_fall \
  $rgmii_tx_phy_data
set_output_delay -3.000 -min -clock $rgmii_tx_phy_clock -clock_fall \
  $rgmii_tx_phy_data

# The TEMAC core defaults model a 2.00 ns shifted PHY receive clock with
# input delays of -1.00/-2.00 ns.  MDIO programs the independent DP83867 RX
# delay to 1.50 ns, so both limits move 0.50 ns later.  Keep this file LATE so
# these board-specific values replace (rather than hide) the IP defaults.
set rgmii_rx_virtual_clock [get_clocks -quiet -filter \
  {NAME =~ *_rgmii_rx_clk && IS_GENERATED == 0}]
set rgmii_rx_phy_data [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
set_input_delay -0.500 -max -clock $rgmii_rx_virtual_clock \
  $rgmii_rx_phy_data
set_input_delay -1.500 -min -clock $rgmii_rx_virtual_clock \
  $rgmii_rx_phy_data
set_input_delay -0.500 -max -clock $rgmii_rx_virtual_clock -clock_fall \
  $rgmii_rx_phy_data
set_input_delay -1.500 -min -clock $rgmii_rx_virtual_clock -clock_fall \
  $rgmii_rx_phy_data

# PG051 explicitly permits tuning the input IODELAY from a late user PHY
# timing XDC.  Apply it here as an implementation property as well as in the
# project-owned physical wrapper, because flattened top-level synthesis can
# normalize the primitive parameter before this board-level value is applied.
set_property DELAY_VALUE 1100 [get_cells -quiet -hier -filter \
  {NAME =~ *delay_rgmii_rx_ctl || NAME =~ *delay_rgmii_rxd}]

# These are the first metastability-catching stages of the two explicit MIG
# calibration synchronizers.  MAC configuration and PHY initialization are
# already generated in the 100 MHz controller domain in this integrated top.
# Only the first-stage D pins are asynchronous; the second stages remain timed.
set_false_path -to [get_pins -quiet -hier -regexp \
  {(^|.*/)(c0|c1)_calib_complete_sync_reg_reg\[0\]/D$}]

# RX overflow is converted to a source-domain toggle and then sampled by an
# explicit three-stage ASYNC_REG chain in the 100 MHz controller domain.  Cut
# only the metastability-catching first-stage D pin; stages 1 and 2 remain
# timed normally.  The TEMAC RX FIFO contains the same vendor-supplied toggle
# synchronizer structure, so constrain its first stage in the same way.
set_false_path -to [get_pins -quiet -hier -regexp \
  {(^|.*/)rx_fifo_overflow_cdc_i/toggle_sync_reg\[0\]/D$}]
set_false_path -to [get_pins -quiet -hier -regexp \
  {(^|.*/)rx_client_fifo_i/resync_wr_store_frame_tog/data_sync_reg0/D$}]
