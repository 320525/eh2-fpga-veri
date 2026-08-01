# Generate a complete, reproducible board-signoff report set from a routed DCP.
# Usage:
#   vivado -mode batch -source scripts/generate_board_reports.tcl \
#          -tclargs <routed_or_postroute_physopt.dcp> <output_dir>

if {$argc != 2} {
  error "usage: generate_board_reports.tcl <routed_dcp> <output_dir>"
}

set dcp_path [file normalize [lindex $argv 0]]
set out_dir  [file normalize [lindex $argv 1]]

if {![file exists $dcp_path]} {
  error "checkpoint does not exist: $dcp_path"
}
file mkdir $out_dir

set_param general.maxThreads 8
open_checkpoint $dcp_path

set report_failures {}
proc emit_report {name command} {
  puts "BOARD_REPORT: starting $name"
  if {[catch {uplevel 1 $command} result]} {
    puts stderr "BOARD_REPORT_ERROR: $name: $result"
    lappend ::report_failures "$name: $result"
  } else {
    puts "BOARD_REPORT: completed $name"
  }
}

emit_report timing_summary [list report_timing_summary \
  -delay_type min_max -max_paths 100 -report_unconstrained \
  -file [file join $out_dir timing_summary.rpt]]
emit_report timing_paths [list report_timing \
  -delay_type min_max -max_paths 100 -nworst 10 \
  -file [file join $out_dir timing_paths.rpt]]
emit_report timing_checks [list check_timing \
  -verbose -file [file join $out_dir timing_checks.rpt]]
emit_report utilization [list report_utilization \
  -hierarchical -hierarchical_depth 3 \
  -file [file join $out_dir utilization_hierarchical.rpt]]
emit_report clocks [list report_clocks \
  -file [file join $out_dir clocks.rpt]]
emit_report clock_utilization [list report_clock_utilization \
  -file [file join $out_dir clock_utilization.rpt]]
emit_report clock_interaction [list report_clock_interaction \
  -delay_type min_max \
  -file [file join $out_dir clock_interaction.rpt]]
emit_report cdc [list report_cdc \
  -details \
  -file [file join $out_dir cdc.rpt]]
emit_report io [list report_io \
  -verbose -file [file join $out_dir io.rpt]]
emit_report route_status [list report_route_status \
  -file [file join $out_dir route_status.rpt]]
emit_report drc [list report_drc \
  -file [file join $out_dir drc.rpt]]
emit_report methodology [list report_methodology \
  -file [file join $out_dir methodology.rpt]]
emit_report bus_skew [list report_bus_skew \
  -warn_on_violation -file [file join $out_dir bus_skew.rpt]]
emit_report power [list report_power \
  -file [file join $out_dir power.rpt]]
emit_report exceptions [list report_exceptions \
  -coverage -file [file join $out_dir exceptions_coverage.rpt]]
emit_report high_fanout [list report_high_fanout_nets \
  -timing -load_types -max_nets 200 \
  -file [file join $out_dir high_fanout_nets.rpt]]

close_design

if {[llength $report_failures] != 0} {
  puts stderr "BOARD_REPORT: [llength $report_failures] report command(s) failed"
  foreach failure $report_failures {
    puts stderr "  $failure"
  }
  exit 2
}

puts "BOARD_REPORT_PASS: all reports generated in $out_dir"
exit 0
