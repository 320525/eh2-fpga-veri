set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set project_file [file join $root_dir build vivado eh2_dual_ddr.xpr]

if {![file exists $project_file]} {
  error "Vivado project not found: $project_file"
}

source [file join $script_dir synplify_netlist_common.tcl]
open_project $project_file
synplify_netlist::configure $root_dir
synplify_netlist::validate $root_dir
set_property top eh2_dual_ddr_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
reset_run synth_1
close_project
puts "SYNPLIFY_NETLIST_INTEGRATION_COMPLETE"
