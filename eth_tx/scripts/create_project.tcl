set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set proj_dir   [file join $root_dir project]
set proj_file  [file join $proj_dir eth_tx.xpr]

if {[file exists $proj_file]} {
  puts "ERROR: Project already exists at $proj_file"
  puts "Delete only the project directory before recreating it."
  exit 1
}

file mkdir $proj_dir
create_project eth_tx $proj_dir -part xcvu19p_CIV-fsva3824-1-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property source_mgmt_mode All [current_project]
set_property default_lib xil_defaultlib [current_project]

set rtl_files [list \
  [file join $root_dir rtl dp83867_phy_init.v] \
  [file join $root_dir rtl tri_mode_ethernet_mac_0_bram_tdp.v] \
  [file join $root_dir rtl tri_mode_ethernet_mac_0_reset_sync.v] \
  [file join $root_dir rtl tri_mode_ethernet_mac_0_sync_block.v] \
  [file join $root_dir rtl tri_mode_ethernet_mac_0_rx_client_fifo_8to16.v] \
  [file join $root_dir rtl tri_mode_ethernet_mac_0_tx_client_fifo.v] \
  [file join $root_dir rtl eth_tx_frame_formatter.v] \
  [file join $root_dir rtl eth_tx_mac_fifo_block.v] \
  [file join $root_dir rtl eth_tx_core.v] \
  [file join $root_dir rtl eth_tx_board_top.v]]
add_files -fileset sources_1 -norecurse $rtl_files

# These XCIs are deliberately referenced in place.  In particular, the TEMAC
# generated files include the same board-specific TXC physical-wrapper change
# as mac_fifo_dma_proj and must not be regenerated from the stock IP template.
set ip_files [list \
  [file join $root_dir eth_tx.srcs sources_1 ip tri_mode_ethernet_mac_0 tri_mode_ethernet_mac_0.xci] \
  [file join $root_dir eth_tx.srcs sources_1 ip axi_traffic_gen_0 axi_traffic_gen_0.xci] \
  [file join $root_dir eth_tx.srcs sources_1 ip tx_axi_traffic_gen tx_axi_traffic_gen.xci] \
  [file join $root_dir eth_tx.srcs sources_1 ip tx_control_atg tx_control_atg.xci]]
add_files -fileset sources_1 -norecurse $ip_files

foreach ip_file [get_files -quiet *.xci] {
  catch {set_property GENERATE_SYNTH_CHECKPOINT false $ip_file}
}

set board_xdc [file join $root_dir constraints eth_tx_board.xdc]
set phy_xdc   [file join $root_dir constraints rgmii_phy_timing.xdc]
set tx_cdc_xdc [file join $root_dir constraints tx_fifo_cdc.xdc]
set rx_place_xdc [file join $root_dir constraints rgmii_rx_clock_placement.xdc]
add_files -fileset constrs_1 -norecurse \
  [list $board_xdc $tx_cdc_xdc $phy_xdc $rx_place_xdc]
set_property PROCESSING_ORDER LATE [get_files $phy_xdc]
set_property PROCESSING_ORDER LATE [get_files $rx_place_xdc]

set tb_file [file join $root_dir tb eth_tx_core_tb.sv]
add_files -fileset sim_1 -norecurse $tb_file
set_property file_type SystemVerilog [get_files $tb_file]

set_property top eth_tx_board_top [get_filesets sources_1]
set_property top eth_tx_core_tb [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
set_property xsim.elaborate.debug_level typical [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "ETH_TX_PROJECT_CREATED $proj_file"
close_project
