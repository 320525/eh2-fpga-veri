set root_dir D:/eh2_fpga/eh2logcomp
set dcp [file join $root_dir output board checkpoints latest_post_place.dcp]
set report_dir [file join $root_dir output board reports_latest]
file mkdir $report_dir

set_param general.maxThreads 1
open_checkpoint $dcp

report_timing -delay_type max -max_paths 100 -path_type full \
  -file [file join $report_dir latest_post_place_setup_full.rpt]
report_timing -delay_type min -max_paths 50 -path_type full \
  -file [file join $report_dir latest_post_place_hold_full.rpt]

set paths [get_timing_paths -quiet -delay_type max -max_paths 20]
set f [open [file join $report_dir latest_post_place_path_index.txt] w]
set index 0
foreach p $paths {
  incr index
  puts $f [format {PATH=%d SLACK=%s GROUP=%s START=%s END=%s} \
    $index [get_property SLACK $p] [get_property PATH_GROUP $p] \
    [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
close $f

puts "POST_PLACE_PATH_REPORT_COMPLETE count=[llength $paths]"
close_design
exit 0
