set_param general.maxThreads 8

set project_dir [file normalize [file dirname [info script]]]
set root_dir    [file normalize [file join $project_dir ..]]
set src_dir     [file join $root_dir source eth]
set ip_dir      [file join $project_dir mac_fifo_dma_proj.srcs sources_1 ip]
set build_dir   [file join $project_dir board_build]
set report_dir  [file join $build_dir reports]
set temp_dir    [file join $build_dir vivado_tmp]

file mkdir $build_dir
file mkdir $report_dir
file mkdir $temp_dir
set ::env(TEMP) $temp_dir
set ::env(TMP)  $temp_dir

create_project -in_memory -part xcvu19p_CIV-fsva3824-1-e
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
set_property ip_output_repo [file join $project_dir mac_fifo_dma_proj.cache ip] \
  [current_project]
set_property ip_cache_permissions {read write} [current_project]

set top_xcis [list \
  [file join $ip_dir tri_mode_ethernet_mac_0 tri_mode_ethernet_mac_0.xci] \
  [file join $ip_dir axi_traffic_gen_0 axi_traffic_gen_0.xci] \
  [file join $ip_dir axi_datamover_0 axi_datamover_0.xci] \
  [file join $ip_dir axi_clock_converter_0 axi_clock_converter_0.xci] \
  [file join $ip_dir axi_dwidth_converter_0 axi_dwidth_converter_0.xci] \
  [file join $ip_dir ddr4_0 ddr4_0.xci]]
foreach xci $top_xcis {
  if {![file exists $xci]} {
    error "Missing IP definition: $xci"
  }
  read_ip -quiet $xci
}
foreach xci $top_xcis {
  set ip_file [get_files -quiet [file normalize $xci]]
  if {[catch {set_property GENERATE_SYNTH_CHECKPOINT false $ip_file} msg]} {
    puts "IP_CHECKPOINT_PROPERTY_SKIPPED=$xci: $msg"
  }
}

foreach rtl [list \
  dma_ddr_led_checker.v \
  dp83867_phy_init.v \
  mac_fifo_dma_ddr4_top.v \
  mac_fifo_dma_top.v \
  rx_fifo_frame_ctrl.v \
  tri_mode_ethernet_mac_0_bram_tdp.v \
  tri_mode_ethernet_mac_0_reset_sync.v \
  tri_mode_ethernet_mac_0_rx_client_fifo_8to16.v \
  tri_mode_ethernet_mac_0_rx_fifo_block.v \
  tri_mode_ethernet_mac_0_sync_block.v \
  mac_fifo_dma_ddr4_board_top.v] {
  read_verilog -library xil_defaultlib [file join $src_dir $rtl]
}
read_xdc [file join $root_dir source constraints ddr4_sodimm1.xdc]

puts "BUILD_STAGE=SYNTHESIS"
synth_design -top mac_fifo_dma_ddr4_board_top \
  -part xcvu19p_CIV-fsva3824-1-e -flatten_hierarchy rebuilt
# Apply board/PHY external-interface timing only after the synthesized netlist
# and the TEMAC generated clock exist.  This is the in-memory equivalent of
# the project's LATE constraint-file processing order.
read_xdc [file join $root_dir source constraints rgmii_phy_timing.xdc]
set rgmii_rx_virtual_clocks [get_clocks -quiet -filter {
  NAME =~ *_rgmii_rx_clk && IS_GENERATED == 0
}]
puts "RGMII_RX_VIRTUAL_CLOCK_COUNT=[llength $rgmii_rx_virtual_clocks]"
if {[llength $rgmii_rx_virtual_clocks] != 1} {
  error "Expected one TEMAC RGMII RX virtual clock: $rgmii_rx_virtual_clocks"
}
set expected_sync_first_d [get_pins -quiet -hier -regexp \
  {^.*/(calib_complete_sync_reg|mac_config_done_sync_reg|mac_config_error_sync_reg|phy_init_success_sync_reg)\[0\]/D$}]
puts "EXPLICIT_CDC_FIRST_STAGE_COUNT=[llength $expected_sync_first_d]"
if {[llength $expected_sync_first_d] != 4} {
  error "Expected four explicit CDC first-stage D pins: $expected_sync_first_d"
}
set rgmii_txc_delay_cells [get_cells -quiet -hier -filter {
  NAME =~ *delay_rgmii_tx_clk*
}]
puts "RGMII_TXC_DELAY_CELL_COUNT=[llength $rgmii_txc_delay_cells]"
if {[llength $rgmii_txc_delay_cells] != 0} {
  error "Stock TEMAC TXC delay cascade is present: $rgmii_txc_delay_cells"
}
set rgmii_rx_delay_cells [get_cells -quiet -hier -filter {
  NAME =~ *delay_rgmii_rx_ctl || NAME =~ *delay_rgmii_rxd
}]
puts "RGMII_RX_DELAY_CELL_COUNT=[llength $rgmii_rx_delay_cells]"
if {[llength $rgmii_rx_delay_cells] != 5} {
  error "Expected five RGMII RX input-delay cells: $rgmii_rx_delay_cells"
}
foreach rgmii_rx_delay_cell $rgmii_rx_delay_cells {
  if {[get_property DELAY_VALUE $rgmii_rx_delay_cell] != 1100} {
    error "RGMII RX IDELAY is not 1100 ps on $rgmii_rx_delay_cell"
  }
}
set synth_black_boxes \
  [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
puts "SYNTH_BLACK_BOX_COUNT=[llength $synth_black_boxes]"
puts "SYNTH_BLACK_BOXES=$synth_black_boxes"
set unexpected_synth_black_boxes {}
foreach bb $synth_black_boxes {
  if {[get_property NAME $bb] ne "dbg_hub"} {
    lappend unexpected_synth_black_boxes $bb
  }
}
if {[llength $unexpected_synth_black_boxes] != 0} {
  error "Synthesized design contains unresolved functional black boxes: $unexpected_synth_black_boxes"
}
# The MIG calibration debug connection contributes dbg_hub as a synthesis
# black box.  Reuse the same-device, same-MIG debug partition from led_test;
# this avoids Vivado's non-terminating XSDBM generation path while preserving
# the exact debug functionality and leaving no unresolved cell in the image.
if {[llength $synth_black_boxes] == 1 &&
    [get_property NAME [lindex $synth_black_boxes 0]] eq "dbg_hub"} {
  set reference_debug_dcp [file join $build_dir reference_dbg_hub.dcp]
  if {![file exists $reference_debug_dcp]} {
    error "Missing compatible debug-hub checkpoint: $reference_debug_dcp"
  }
  read_checkpoint -cell dbg_hub $reference_debug_dcp
}
set filled_black_boxes \
  [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
puts "FILLED_BLACK_BOX_COUNT=[llength $filled_black_boxes]"
if {[llength $filled_black_boxes] != 0} {
  error "Black boxes remain after debug-hub partition reuse: $filled_black_boxes"
}
write_checkpoint -force [file join $build_dir board_top_synth.dcp]
report_utilization -hierarchical \
  -file [file join $report_dir utilization_synth.rpt]

puts "BUILD_STAGE=OPT_DESIGN"
opt_design
set opt_black_boxes \
  [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
puts "OPT_BLACK_BOX_COUNT=[llength $opt_black_boxes]"
if {[llength $opt_black_boxes] != 0} {
  error "Optimized design contains unresolved black boxes"
}
write_checkpoint -force [file join $build_dir board_top_opt.dcp]

puts "BUILD_STAGE=PLACE_DESIGN"
# Reuse only placement/routing guidance from the preceding routed image.  The
# logical netlist is the freshly synthesized RTL above (including PHY 0x0075);
# incompatible cells are automatically rejected by incremental implementation.
set incremental_reference [file join $build_dir board_top_routed.dcp]
if {[file exists $incremental_reference]} {
  read_checkpoint -incremental $incremental_reference
  puts "INCREMENTAL_REFERENCE=$incremental_reference"
}
place_design
write_checkpoint -force [file join $build_dir board_top_placed.dcp]
report_utilization -hierarchical \
  -file [file join $report_dir utilization_placed.rpt]

puts "BUILD_STAGE=PHYS_OPT_DESIGN"
phys_opt_design
write_checkpoint -force [file join $build_dir board_top_physopt.dcp]

puts "BUILD_STAGE=ROUTE_DESIGN"
route_design
write_checkpoint -force [file join $build_dir board_top_routed.dcp]

puts "BUILD_STAGE=SIGNOFF_REPORTS"
report_timing_summary -delay_type min_max -max_paths 20 \
  -report_unconstrained -check_timing_verbose \
  -file [file join $report_dir timing_summary_routed.rpt]
report_utilization -hierarchical \
  -file [file join $report_dir utilization_routed.rpt]
report_drc -file [file join $report_dir drc_routed.rpt]
report_clock_utilization \
  -file [file join $report_dir clock_utilization_routed.rpt]
report_methodology \
  -file [file join $report_dir methodology_routed.rpt]
check_timing -verbose -file [file join $report_dir check_timing_routed.rpt]
report_io -file [file join $report_dir io_routed.rpt]
report_bus_skew -file [file join $report_dir bus_skew_routed.rpt]
report_route_status -file [file join $report_dir route_status_routed.rpt]
report_cdc -details -file [file join $report_dir cdc_routed.rpt]

set setup_paths \
  [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
set hold_paths \
  [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
  error "Unable to obtain routed setup/hold timing paths"
}
set routed_wns [get_property SLACK [lindex $setup_paths 0]]
set routed_whs [get_property SLACK [lindex $hold_paths 0]]
set drc_errors \
  [get_drc_violations -quiet -filter {SEVERITY == Error}]
set drc_critical \
  [get_drc_violations -quiet -filter {SEVERITY == {Critical Warning}}]

set skew_fd [open [file join $report_dir bus_skew_routed.rpt] r]
set skew_report [read $skew_fd]
close $skew_fd
set bus_skew_violations [regexp -all {Slack \(VIOLATED\)} $skew_report]

puts "ROUTED_WNS=$routed_wns"
puts "ROUTED_WHS=$routed_whs"
puts "DRC_ERROR_COUNT=[llength $drc_errors]"
puts "DRC_CRITICAL_WARNING_COUNT=[llength $drc_critical]"
puts "BUS_SKEW_VIOLATION_COUNT=$bus_skew_violations"
puts "ROUTED_DCP=[file join $build_dir board_top_routed.dcp]"

if {$routed_wns < 0.0 || $routed_whs < 0.0 ||
    [llength $drc_errors] != 0 || [llength $drc_critical] != 0 ||
    $bus_skew_violations != 0} {
  error "Timing, DRC, or bus-skew signoff failed; bitstream was not generated"
}

puts "BUILD_STAGE=WRITE_BITSTREAM"
set bit_file [file join $build_dir mac_fifo_dma_ddr4_board_top.bit]
write_bitstream -force $bit_file
puts "BITSTREAM=$bit_file"
exit 0
