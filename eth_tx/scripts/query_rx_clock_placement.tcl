set root_dir [file normalize [file join [file dirname [file normalize [info script]]] ..]]

proc show_rx_clock {label dcp_file} {
  open_checkpoint $dcp_file
  set rx_bufg [get_cells -quiet -hier -filter \
    {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk}]
  puts "$label RX_BUFG_COUNT [llength $rx_bufg]"
  foreach cell $rx_bufg {
    puts "$label RX_BUFG_NAME $cell"
    puts "$label RX_BUFG_LOC [get_property LOC $cell]"
    puts "$label RX_BUFG_BEL [get_property BEL $cell]"
    set out_net [get_nets -quiet -of_objects [get_pins $cell/O]]
    puts "$label RX_CLOCK_NET $out_net"
    foreach prop {CLOCK_ROOT USER_CLOCK_ROOT IS_ROUTE_FIXED} {
      catch {puts "$label RX_NET_$prop [get_property $prop $out_net]"}
    }
  }
  close_design
}

show_rx_clock REFERENCE \
  D:/eh2_fpga/mac_fifo_dma_proj/board_build/board_top_routed.dcp
show_rx_clock ETH_TX [file join $root_dir checkpoints post_route.dcp]

