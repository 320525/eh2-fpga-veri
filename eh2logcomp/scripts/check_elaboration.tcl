set script_dir [file normalize [file dirname [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set_param general.maxThreads 6
open_project [file join $root_dir build vivado eh2_veri_system.xpr]
set_property top eh2logcomp_system_top [get_filesets sources_1]
update_compile_order -fileset sources_1
synth_design -rtl -name rtl_1 -top eh2logcomp_system_top \
  -part xcvu19p_CIV-fsva3824-1-e
puts "RTL_ELAB_TOP=[get_property TOP [current_fileset]]"
puts "RTL_ELAB_CELLS=[llength [get_cells -hierarchical]]"
close_design
exit
