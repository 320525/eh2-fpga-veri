# Persist the memory-safe bitstream packaging default in an existing routed
# checkpoint. This changes no cells, nets, placement, routing, or timing.

if {$argc != 2} {
  error "usage: finalize_dcp_bitstream_property.tcl <input.dcp> <output.dcp>"
}

set input_dcp  [file normalize [lindex $argv 0]]
set output_dcp [file normalize [lindex $argv 1]]
set_param general.maxThreads 1
open_checkpoint $input_dcp
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
puts "FINAL_DCP_COMPRESS=[get_property BITSTREAM.GENERAL.COMPRESS [current_design]]"
write_checkpoint -force $output_dcp
puts "FINAL_DCP_PROPERTY_PASS output=$output_dcp"
close_design
exit 0
