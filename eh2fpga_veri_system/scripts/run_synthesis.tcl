set script_dir [file normalize [file dirname [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set_param general.maxThreads 8
open_project [file join $root_dir build vivado eh2_veri_system.xpr]

# Clear every out-of-context IP run as well as the top run.  A stale OOC
# .vivado.begin marker otherwise leaves the top-level synthesis queued forever.
foreach ip_run [get_runs -quiet *_synth_1] {
  reset_run $ip_run
}
reset_run synth_1
launch_runs synth_1 -jobs 16
wait_on_run synth_1
set run_status [get_property STATUS [get_runs synth_1]]
puts "SYNTHESIS_STATUS=$run_status"
if {![string match "*Complete*" $run_status]} {
  error "Synthesis did not complete: $run_status"
}
exit
