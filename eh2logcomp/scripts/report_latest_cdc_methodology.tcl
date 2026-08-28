set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set board_dir [file join $root_dir output board]
set report_dir [file join $board_dir reports_latest]
set routed_dcp [file join $board_dir eh2_veri_system_routed_latest.dcp]

file mkdir $report_dir
set_param general.maxThreads 8

if {![file exists $routed_dcp]} {
  error "Latest routed checkpoint does not exist: $routed_dcp"
}

open_checkpoint $routed_dcp

set blackboxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $blackboxes] != 0} {
  error "Latest routed checkpoint contains unresolved black boxes: $blackboxes"
}

report_clock_interaction -delay_type min_max \
  -file [file join $report_dir clock_interaction.rpt]
report_cdc -details -file [file join $report_dir cdc.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
check_timing -verbose -file [file join $report_dir check_timing.rpt]

puts "LATEST_CDC_REPORT_PASS report_dir=$report_dir"
close_design
exit
