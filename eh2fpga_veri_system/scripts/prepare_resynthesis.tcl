# Update board-validated constraint ordering and generate top synthesis scripts
# without launching the Windows Vivado Run Server.

set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set project    [file join $root_dir build vivado eh2_veri_system.xpr]
set phy_xdc    [file join $root_dir constraints rgmii_phy_timing.xdc]
set rx_xdc     [file join $root_dir constraints rgmii_rx_clock_placement.xdc]
set event_cdc  [file join $root_dir rtl common event_toggle_cdc.sv]

open_project $project
if {[llength [get_files -quiet [file normalize $event_cdc]]] == 0} {
  add_files -norecurse [file normalize $event_cdc]
}
update_compile_order -fileset sources_1
set_property PROCESSING_ORDER LATE [get_files [file normalize $phy_xdc]]
set_property PROCESSING_ORDER LATE [get_files [file normalize $rx_xdc]]
puts "PHY_XDC_ORDER: [get_property PROCESSING_ORDER [get_files [file normalize $phy_xdc]]]"
puts "RX_XDC_ORDER: [get_property PROCESSING_ORDER [get_files [file normalize $rx_xdc]]]"

reset_run synth_1
launch_runs synth_1 -scripts_only
puts "SYNTHESIS_SCRIPTS_READY: [get_property DIRECTORY [get_runs synth_1]]"

close_project
exit
