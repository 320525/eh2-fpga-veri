set root_dir  [file normalize [file join [file dirname [info script]] ..]]
set xpr       [file join $root_dir build vivado eh2_dual_ddr.xpr]
set report_dir [file join $root_dir reports]
file mkdir $report_dir

open_project $xpr
source [file join [file dirname [info script]] synplify_netlist_common.tcl]
synplify_netlist::validate $root_dir
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
  error "Synthesis is not complete: $synth_status"
}

reset_run impl_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*Complete*" $impl_status]} {
  error "Implementation failed: $impl_status"
}

open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
  -check_timing_verbose -max_paths 50 -warn_on_violation \
  -file [file join $report_dir timing_summary_impl.rpt]
report_utilization -hierarchical -file [file join $report_dir utilization_impl.rpt]
report_clock_interaction -delay_type min_max \
  -file [file join $report_dir clock_interaction_impl.rpt]
report_cdc -details -file [file join $report_dir cdc_impl.rpt]
report_drc -file [file join $report_dir drc_impl.rpt]
report_methodology -file [file join $report_dir methodology_impl.rpt]
report_route_status -file [file join $report_dir route_status_impl.rpt]
report_io -file [file join $report_dir io_impl.rpt]
report_power -file [file join $report_dir power_impl.rpt]
write_checkpoint -force [file join $report_dir eh2_dual_ddr_impl.dcp]

set bit_file [file normalize [file join $root_dir build vivado \
  eh2_dual_ddr.runs impl_1 eh2_dual_ddr_top.bit]]
if {![file exists $bit_file]} {
  error "Bitstream was not generated: $bit_file"
}
puts "IMPLEMENTATION_COMPLETE"
puts "BITSTREAM=$bit_file"
close_project
