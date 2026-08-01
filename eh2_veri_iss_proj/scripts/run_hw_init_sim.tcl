set root_dir [file normalize [file join [file dirname [info script]] ..]]
set xpr [file join $root_dir build vivado eh2_dual_ddr.xpr]
open_project $xpr
set tb [file join $root_dir sim eh2_hw_init_tb.sv]
if {[llength [get_files -quiet $tb]] == 0} {
  add_files -fileset sim_1 -norecurse $tb
}
set_property FILE_TYPE SystemVerilog [get_files $tb]
set_property USED_IN_SYNTHESIS false [get_files $tb]
set_property top eh2_hw_init_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
set sim_log [file join $root_dir build vivado eh2_dual_ddr.sim sim_1 behav xsim simulate.log]
close_sim
file copy -force $sim_log [file join $root_dir reports hw_init_pre_sim.log]
close_project
