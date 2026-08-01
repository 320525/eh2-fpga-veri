# Preserve the routed receive-clock topology of mac_fifo_dma_proj.  The RGMII
# data delay, input-delay constraints and PHY RX skew remain unchanged.
#
# The generated TEMAC wrapper contains two equivalent BUFGs driven by RGMII
# RXC.  The reference design merges them and routes the resulting clock from
# X3Y2.  Apply the same user clock root to both candidate nets so opt_design is
# free to perform the same merge while the smaller eth_tx floorplan cannot
# choose the lower-latency X0Y1 root.

set rgmii_rx_bufg_cells [get_cells -quiet -hier -filter \
  {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk*}]
set rgmii_rx_bufg_nets [get_nets -quiet -of_objects \
  [get_pins -of_objects $rgmii_rx_bufg_cells -filter {REF_PIN_NAME == O}]]
set_property USER_CLOCK_ROOT X3Y2 $rgmii_rx_bufg_nets

