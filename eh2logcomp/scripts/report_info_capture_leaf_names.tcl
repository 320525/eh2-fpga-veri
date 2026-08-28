set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set dcp [file join $root_dir output board eh2logcomp_2slot_routed.dcp]
set out_file [file join $root_dir output board reports_latest info_capture_leaf_names.txt]

open_checkpoint $dcp
set cells [lsort [get_cells -quiet -hier -filter {
  NAME =~ eh2_i/info_capture_i/* && IS_PRIMITIVE == 1
}]]
set fd [open $out_file w]
puts $fd "TOTAL=[llength $cells]"
foreach cell $cells {
  puts $fd $cell
}
close $fd
puts "INFO_CAPTURE_LEAF_REPORT total=[llength $cells] file=$out_file"
close_design
exit 0
