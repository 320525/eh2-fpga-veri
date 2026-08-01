set root_dir [file normalize [file join [file dirname [file normalize [info script]]] ..]]
open_project [file join $root_dir project eth_tx.xpr]
set tx_cdc_xdc [file join $root_dir constraints tx_fifo_cdc.xdc]
set rx_place_xdc [file join $root_dir constraints rgmii_rx_clock_placement.xdc]
foreach xdc_file [list $tx_cdc_xdc $rx_place_xdc] {
  if {[llength [get_files -quiet $xdc_file]] == 0} {
    add_files -fileset constrs_1 -norecurse $xdc_file
  }
}
set_property PROCESSING_ORDER LATE [get_files $rx_place_xdc]
close_project
puts "ETH_TX_COMPAT_CONSTRAINTS_ADDED"

