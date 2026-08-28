set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set_param general.maxThreads 4
open_project [file join $root_dir build vivado eh2_veri_system.xpr]

set ooc_runs [list \
  axi_dwidth_converter_64_512_synth_1 \
  axi_clock_converter_64_synth_1 \
  axi_dwidth_converter_32_512_synth_1 \
  axi_clock_converter_32_synth_1 \
  data_test_atg_synth_1 \
  axi_traffic_gen_0_synth_1]

foreach run_name $ooc_runs {
  set run_obj [get_runs -quiet $run_name]
  if {![llength $run_obj]} {
    error "missing required OOC synthesis run: $run_name"
  }
  reset_run $run_obj
  launch_runs $run_obj -scripts_only
  puts "OOC_SCRIPT_READY=$run_name:[get_property DIRECTORY $run_obj]"
}
close_project
exit
