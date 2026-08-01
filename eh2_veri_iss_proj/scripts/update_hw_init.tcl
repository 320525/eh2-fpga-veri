set root_dir [file normalize [file join [file dirname [info script]] ..]]
set xpr [file join $root_dir build vivado eh2_dual_ddr.xpr]
set init_rtl [file join $root_dir rtl eh2_hw_init.sv]
open_project $xpr
if {[llength [get_files -quiet $init_rtl]] == 0} {
  add_files -norecurse $init_rtl
}
set_property FILE_TYPE SystemVerilog [get_files $init_rtl]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project
