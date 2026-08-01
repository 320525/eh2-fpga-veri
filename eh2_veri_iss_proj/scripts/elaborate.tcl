set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
open_project [file join $root_dir build vivado eh2_dual_ddr.xpr]
set_property top eh2_dual_ddr_top [get_filesets sources_1]
update_compile_order -fileset sources_1
synth_design -rtl -name rtl_check -top eh2_dual_ddr_top -part xcvu19p_CIV-fsva3824-1-e
file mkdir [file join $root_dir reports]
report_utilization -file [file join $root_dir reports rtl_elaboration_utilization.rpt]
close_design
exit
