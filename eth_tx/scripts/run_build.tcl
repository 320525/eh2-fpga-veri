set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set proj_file  [file join $root_dir project eth_tx.xpr]
set report_dir [file join $root_dir reports]
set output_dir [file join $root_dir output]
set dcp_dir    [file join $root_dir checkpoints]
file mkdir $report_dir
file mkdir $output_dir
file mkdir $dcp_dir

set_param general.maxThreads 8
open_project $proj_file
set_property top eth_tx_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# Run the complete flow in this Vivado process.  This avoids the Windows
# script-host launcher used by project runs while preserving the same project,
# sources, IP output products and constraint processing order.
synth_design -top eth_tx_board_top -part xcvu19p_CIV-fsva3824-1-e \
  -flatten_hierarchy rebuilt
write_checkpoint -force [file join $dcp_dir post_synth.dcp]
report_utilization -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 20 -file [file join $report_dir post_synth_timing_summary.rpt]
check_timing -verbose -file [file join $report_dir post_synth_check_timing.rpt]
puts "ETH_TX_SYNTH_COMPLETE"

# The copied physical wrapper must remain the board-specific one: no TXC
# ODELAY cascade, with five input delay elements retained for RXD[3:0]/RX_CTL.
set txc_delays [get_cells -quiet -hier -filter \
  {(REF_NAME =~ ODELAY*) && (NAME =~ *rgmii_txc*)}]
set rx_delays [get_cells -quiet -hier -filter \
  {(REF_NAME =~ IDELAY*) && ((NAME =~ *delay_rgmii_rxd*) || (NAME =~ *delay_rgmii_rx_ctl*))}]
puts "ETH_TX_SYNTH_TXC_DELAY_CELL_COUNT [llength $txc_delays]"
puts "ETH_TX_SYNTH_RX_DELAY_CELL_COUNT [llength $rx_delays]"
if {[llength $txc_delays] != 0 || [llength $rx_delays] != 5} {
  puts "ERROR: TEMAC RGMII physical wrapper does not match mac_fifo_dma_proj."
  exit 1
}

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $dcp_dir post_route.dcp]

report_route_status -file [file join $report_dir post_route_status.rpt]
report_utilization -file [file join $report_dir post_route_utilization.rpt]
report_clock_utilization -file [file join $report_dir post_route_clock_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
  -max_paths 50 -file [file join $report_dir post_route_timing_summary.rpt]
check_timing -verbose -file [file join $report_dir post_route_check_timing.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_cdc -details -file [file join $report_dir post_route_cdc.rpt]

set max_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set min_path [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $max_path] == 0 || [llength $min_path] == 0} {
  puts "ERROR: Unable to obtain setup/hold timing paths."
  exit 1
}
set wns [get_property SLACK [lindex $max_path 0]]
set whs [get_property SLACK [lindex $min_path 0]]
puts "ETH_TX_POST_ROUTE_WNS $wns"
puts "ETH_TX_POST_ROUTE_WHS $whs"
if {$wns < 0.0 || $whs < 0.0} {
  puts "ERROR: Post-route timing is not clean."
  exit 1
}

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
puts "ETH_TX_POST_ROUTE_DRC_ERROR_COUNT [llength $drc_errors]"
if {[llength $drc_errors] != 0} {
  puts "ERROR: Post-route DRC has errors."
  exit 1
}

set rx_bufgs [get_cells -quiet -hier -filter \
  {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk*}]
set rx_clock_nets [get_nets -quiet -of_objects \
  [get_pins -of_objects $rx_bufgs -filter {REF_PIN_NAME == O}]]
puts "ETH_TX_IMPL_RX_BUFG_COUNT [llength $rx_bufgs]"
puts "ETH_TX_IMPL_RX_CLOCK_ROOTS [get_property CLOCK_ROOT $rx_clock_nets]"
foreach rx_root [get_property CLOCK_ROOT $rx_clock_nets] {
  if {$rx_root ne "X3Y2"} {
    puts "ERROR: An RGMII RX clock root differs from mac_fifo_dma_proj."
    exit 1
  }
}

set rx_delays_impl [get_cells -quiet -hier -filter \
  {(REF_NAME =~ IDELAY*) && ((NAME =~ *delay_rgmii_rxd*) || (NAME =~ *delay_rgmii_rx_ctl*))}]
set rx_delay_values {}
foreach delay_cell $rx_delays_impl {
  lappend rx_delay_values [get_property DELAY_VALUE $delay_cell]
}
puts "ETH_TX_IMPL_RX_DELAY_VALUES $rx_delay_values"
if {[llength $rx_delays_impl] != 5} {
  puts "ERROR: Post-route RGMII RX delay cell count is not five."
  exit 1
}
foreach delay_value $rx_delay_values {
  if {$delay_value != 1100} {
    puts "ERROR: Post-route RGMII RX delay is not 1100 ps."
    exit 1
  }
}

set bit_file [file join $output_dir eth_tx_board_top.bit]
write_bitstream -force $bit_file
if {![file exists $bit_file]} {
  puts "ERROR: Bitstream was not created: $bit_file"
  exit 1
}
puts "ETH_TX_BITSTREAM_READY $bit_file"
close_design
close_project
