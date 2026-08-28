# Generate the Vivado-managed implementation run scripts without using the
# Windows Run Server.  The generated run preserves project/XCI/IP constraints.

set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set project    [file join $root_dir build vivado eh2_veri_system.xpr]

open_project $project

set synth_run [get_runs synth_1]
set impl_run  [get_runs impl_1]
puts "SYNTH_RUN_STATUS: [get_property STATUS $synth_run]"
puts "SYNTH_RUN_PROGRESS: [get_property PROGRESS $synth_run]"

set preferred_strategy Performance_ExplorePostRoutePhysOpt
if {![catch {set_property strategy $preferred_strategy $impl_run} strategy_error]} {
  set_property strategy $preferred_strategy $impl_run
  puts "IMPLEMENTATION_STRATEGY: $preferred_strategy"
} else {
  puts "IMPLEMENTATION_STRATEGY_FALLBACK: $strategy_error"
  puts "IMPLEMENTATION_STRATEGY: [get_property strategy $impl_run]"
}

reset_run $impl_run
launch_runs $impl_run -to_step write_bitstream -scripts_only
puts "IMPLEMENTATION_SCRIPTS_READY: [get_property DIRECTORY $impl_run]"

close_project
exit
