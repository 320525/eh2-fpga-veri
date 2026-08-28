set script_dir [file normalize [file dirname [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set_param general.maxThreads 6
open_project [file join $root_dir build vivado eh2_veri_system.xpr]

# OOC IP DCPs are configuration-independent of the modified top RTL and are
# intentionally reused after their successful first build.  This reduces both
# peak memory and retry time.
reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1
set run_status [get_property STATUS [get_runs synth_1]]
puts "SYNTHESIS_STATUS=$run_status"
if {![string match "*Complete*" $run_status]} {
  error "Synthesis did not complete: $run_status"
}
exit
