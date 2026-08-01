set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set report_dir [file join $root_dir reports]
file mkdir $report_dir
open_project [file join $root_dir build vivado eh2_dual_ddr.xpr]
source [file join $script_dir synplify_netlist_common.tcl]
synplify_netlist::validate $root_dir
set_property top eh2_dual_ddr_top [get_filesets sources_1]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
set status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$status"
if {![string match "*Complete*" $status]} {
  error "Synthesis did not complete successfully: $status"
}
open_run synth_1
report_utilization -hierarchical -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
  -file [file join $report_dir post_synth_timing_summary.rpt]
report_clock_interaction -file [file join $report_dir post_synth_clock_interaction.rpt]
report_cdc -details -file [file join $report_dir post_synth_cdc.rpt]
exit
