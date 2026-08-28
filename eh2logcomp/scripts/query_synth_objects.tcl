set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set dcp_file   [file join $root_dir build vivado eh2_veri_system.runs synth_1 eh2_veri_system_top.dcp]
set report_file [file join $root_dir output board synth_object_query.txt]

open_checkpoint $dcp_file
set output [open $report_file w]

puts $output "CALIB_CELLS"
foreach object [get_cells -quiet -hierarchical -filter {NAME =~ *calib*complete*sync*}] {
  puts $output $object
}

puts $output "CALIB_PINS"
foreach object [get_pins -quiet -hierarchical -filter {NAME =~ *calib*complete*sync*}] {
  puts $output $object
}

puts $output "ASYNC_REG_CELLS"
foreach object [get_cells -quiet -hierarchical -filter {ASYNC_REG == TRUE}] {
  if {[string match "*calib*" $object]} {
    puts $output $object
  }
}

close $output
close_design
exit
