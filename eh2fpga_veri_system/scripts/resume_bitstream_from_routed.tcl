# Resume only the final bitstream stage from the signed-off routed checkpoint.
# Compression is deliberately disabled to reduce peak memory usage. This does
# not change the implemented logic, placement, routing, timing, or pinout.

if {$argc != 2} {
  puts "Usage: vivado -mode batch -source resume_bitstream_from_routed.tcl -tclargs <routed.dcp> <output.bit>"
  exit 2
}

set routed_dcp [file normalize [lindex $argv 0]]
set bitstream  [file normalize [lindex $argv 1]]

if {![file exists $routed_dcp]} {
  error "Routed checkpoint does not exist: $routed_dcp"
}

file mkdir [file dirname $bitstream]
set_param general.maxThreads 1

puts "RESUME_BITSTREAM_OPEN_DCP=$routed_dcp"
open_checkpoint $routed_dcp

set route_errors [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
puts "RESUME_BITSTREAM_PREEXISTING_SEVERE_DRC=[llength $route_errors]"

# The prior run reached compression and was terminated by system resource
# pressure. An uncompressed .bit configures the FPGA identically; it is only
# larger and takes longer to transfer from the host/configuration memory.
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
puts "RESUME_BITSTREAM_COMPRESS=[get_property BITSTREAM.GENERAL.COMPRESS [current_design]]"

write_bitstream -force $bitstream

if {![file exists $bitstream] || [file size $bitstream] == 0} {
  error "write_bitstream returned without a non-empty output file: $bitstream"
}

puts "RESUME_BITSTREAM_PASS output=$bitstream bytes=[file size $bitstream]"
close_design
exit 0
