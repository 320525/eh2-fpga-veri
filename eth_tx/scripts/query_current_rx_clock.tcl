set root_dir [file normalize [file join [file dirname [file normalize [info script]]] ..]]
open_checkpoint [file join $root_dir checkpoints post_route.dcp]
set rx_bufg [get_cells -quiet -hier -filter \
  {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk}]
set rx_net [get_nets -quiet -of_objects [get_pins $rx_bufg/O]]
puts "CURRENT_RX_BUFG $rx_bufg"
foreach prop {LOC BEL IS_LOC_FIXED IS_BEL_FIXED} {
  catch {puts "CURRENT_RX_BUFG_$prop [get_property $prop $rx_bufg]"}
}
puts "CURRENT_RX_NET $rx_net"
foreach prop {CLOCK_ROOT USER_CLOCK_ROOT IS_ROUTE_FIXED} {
  catch {puts "CURRENT_RX_NET_$prop [get_property $prop $rx_net]"}
}
close_design

