set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
open_project [file join $root_dir build vivado eh2_dual_ddr.xpr]
set eh2_root D:/eh2_fpga/source/eh2_design
set_property file_type SystemVerilog [get_files [list \
  $eh2_root/dmi/dmi_wrapper.v \
  $eh2_root/dmi/dmi_jtag_to_core_sync.v \
  $eh2_root/dmi/rvjtag_tap.v]]
set_property top eh2_dual_ddr_top [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "PROJECT_FIXED"
exit
