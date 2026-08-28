# Restore generated IP products removed by an interrupted/reset OOC synthesis
# launch, then regenerate only the top-level synthesis script.  The RTL changes
# in this sign-off pass do not modify any XCI configuration.

set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set project    [file join $root_dir build vivado eh2_veri_system.xpr]

open_project $project
set ips [get_ips -quiet]
puts "IP_COUNT: [llength $ips]"
reset_target all $ips
generate_target all $ips
export_ip_user_files -of_objects $ips -no_script -sync -force -quiet

# IP regeneration restores TEMAC's stock TXC delay cascade, which conflicts
# with the validated J20/J22 RXD3 pin.  Overwrite only that generated physical
# module with the exact board-validated source preserved under rtl/eth.
set board_rgmii_if [file join $root_dir rtl eth \
  tri_mode_ethernet_mac_0_rgmii_v2_0_if_board.v]
set generated_rgmii_if [file join $root_dir build vivado \
  eh2_veri_system.gen sources_1 ip tri_mode_ethernet_mac_0 synth physical \
  tri_mode_ethernet_mac_0_rgmii_v2_0_if.v]
file copy -force $board_rgmii_if $generated_rgmii_if
set board_rgmii_file_object [get_files -quiet -all $board_rgmii_if]
if {[llength $board_rgmii_file_object]} {
  remove_files $board_rgmii_file_object
}

update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -scripts_only
puts "TOP_SYNTH_SCRIPT_READY: [get_property DIRECTORY [get_runs synth_1]]"

close_project
exit
