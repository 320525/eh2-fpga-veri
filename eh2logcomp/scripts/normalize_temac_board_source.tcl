set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set project [file join $root_dir build vivado eh2_veri_system.xpr]
set board_rgmii_if [file join $root_dir rtl eth \
  tri_mode_ethernet_mac_0_rgmii_v2_0_if_board.v]
set generated_rgmii_if [file join $root_dir build vivado \
  eh2_veri_system.gen sources_1 ip tri_mode_ethernet_mac_0 synth physical \
  tri_mode_ethernet_mac_0_rgmii_v2_0_if.v]

open_project $project
file copy -force $board_rgmii_if $generated_rgmii_if
set board_rgmii_file_object [get_files -quiet -all $board_rgmii_if]
if {[llength $board_rgmii_file_object]} {
  remove_files $board_rgmii_file_object
}
update_compile_order -fileset sources_1
close_project
exit
