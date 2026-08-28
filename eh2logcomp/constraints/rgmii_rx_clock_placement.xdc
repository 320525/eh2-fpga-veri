# Constrain the recovered RGMII receive-clock tree to the root selected by the
# implemented-design timing sweep.  The RGMII data delay, input-delay
# constraints and PHY RX skew remain unchanged.
#
# The generated TEMAC wrapper contains two equivalent BUFGs driven by RGMII
# RXC.  The reference design merges them.  X3Y2 left a -0.074 ns routed input
# hold violation in this larger four-SLR system.  A legal post-route sweep of
# X3Y1, X2Y2, X2Y1, X1Y2 and X1Y1 selected X2Y2: with 1100 ps (the legal
# maximum) in every RX IDELAY, the final RGMII setup/hold margins are balanced
# at +0.254/+0.306 ns.  Apply the root to both pre-merge candidate nets so
# opt_design remains free to merge them deterministically.

set rgmii_rx_bufg_cells [get_cells -quiet -hier -filter \
  {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk*}]
set rgmii_rx_bufg_nets [get_nets -quiet -of_objects \
  [get_pins -of_objects $rgmii_rx_bufg_cells -filter {REF_PIN_NAME == O}]]
set_property USER_CLOCK_ROOT X2Y2 $rgmii_rx_bufg_nets
