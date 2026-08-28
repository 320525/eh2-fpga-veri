set root_dir D:/eh2_fpga/eh2logcomp
set dcp [file join $root_dir output board eh2logcomp_2slot_routed.dcp]
set report_dir [file join $root_dir output board reports_latest]
file mkdir $report_dir

set_param general.maxThreads 1
open_checkpoint $dcp

set clock_file [open [file join $report_dir routed_clock_periods_compact.rpt] w]
foreach clk [lsort [get_clocks -quiet]] {
  puts $clock_file [format "%s PERIOD=%s" $clk [get_property PERIOD $clk]]
}
close $clock_file

# Keep this intentionally compact.  A full 100-path min/max timing summary
# exceeded the host memory limit after the router had already succeeded.
report_timing -delay_type max -max_paths 24 -nworst 2 -sort_by group \
  -path_type full -input_pins \
  -file [file join $report_dir routed_setup_compact.rpt]
report_timing -delay_type min -max_paths 8 -nworst 1 -sort_by group \
  -path_type full -input_pins \
  -file [file join $report_dir routed_hold_compact.rpt]

set summary_file [open [file join $report_dir routed_path_groups_compact.rpt] w]
foreach group [lsort [get_path_groups -quiet]] {
  set setup_paths [get_timing_paths -quiet -group $group -delay_type max -max_paths 1]
  set hold_paths [get_timing_paths -quiet -group $group -delay_type min -max_paths 1]
  set setup_slack NA
  set hold_slack NA
  if {[llength $setup_paths] != 0} {
    set setup_slack [get_property SLACK [lindex $setup_paths 0]]
  }
  if {[llength $hold_paths] != 0} {
    set hold_slack [get_property SLACK [lindex $hold_paths 0]]
  }
  puts $summary_file [format "%s SETUP=%s HOLD=%s" $group $setup_slack $hold_slack]
}
close $summary_file

puts "COMPACT_TIMING_REPORT_PASS"
close_design
exit 0
