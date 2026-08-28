set root_dir D:/eh2_fpga/eh2logcomp
set dcp [file join $root_dir output board eh2logcomp_2slot_routed.dcp]
set out_dir [file join $root_dir output board reports_latest]
open_checkpoint $dcp
set_param general.maxThreads 2

report_timing -delay_type max -max_paths 100 -nworst 20 -path_type full \
  -file [file join $out_dir worst_setup_paths_full.rpt]
report_timing -delay_type min -max_paths 30 -nworst 20 -path_type full \
  -file [file join $out_dir worst_hold_paths_full.rpt]
report_timing -delay_type max -max_paths 30 -nworst 10 -path_type full \
  -group mmcm_clkout0_1 -file [file join $out_dir ddr1_setup_paths_full.rpt]
report_timing -delay_type max -max_paths 30 -nworst 10 -path_type full \
  -group atg_clk -file [file join $out_dir atg_setup_paths_full.rpt]

puts "ANALYZE_SETUP_GROUPS"
foreach group [get_property NAME [get_timing_path_groups -quiet]] {
  set p [get_timing_paths -quiet -delay_type max -max_paths 1 -group $group]
  if {[llength $p]} {
    set slack [get_property SLACK [lindex $p 0]]
    if {$slack < 0.0} { puts "SETUP_GROUP $group SLACK $slack" }
  }
}
puts "ANALYZE_HOLD_GROUPS"
foreach group [get_property NAME [get_timing_path_groups -quiet]] {
  set p [get_timing_paths -quiet -delay_type min -max_paths 1 -group $group]
  if {[llength $p]} {
    set slack [get_property SLACK [lindex $p 0]]
    if {$slack < 0.0} { puts "HOLD_GROUP $group SLACK $slack" }
  }
}
puts "ANALYZE_DONE"
close_design
exit 0
