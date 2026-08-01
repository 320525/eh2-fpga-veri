# Resume board routing from the saved post-place physical-optimization DCP.
#
# The normal project run reached a fully routed design but exhausted host
# memory in Explore/TNS-cleanup leaf-clock optimization before it could save
# the routed checkpoint.  This recovery run uses the normal router directive
# and saves the routed DCP immediately, before any post-route optimization.

set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set impl_dir   [file join $root_dir build vivado eh2_veri_system.runs impl_1]
set input_dcp  [file join $impl_dir eh2_veri_system_top_physopt.dcp]
set out_dir    [file join $root_dir output board]
set routed_dcp [file join $out_dir eh2_veri_system_routed.dcp]

file mkdir $out_dir
if {![file exists $input_dcp]} {
  error "post-place physopt checkpoint not found: $input_dcp"
}

proc stage {message} {
  puts "ROUTE_RECOVERY_STAGE: $message"
  flush stdout
}

stage "open post-place physopt checkpoint"
open_checkpoint $input_dcp

# The DCP predates the final board-XDC edit, so apply the two targeted
# asynchronous first-stage exceptions explicitly to this in-memory design.
set overflow_sync_d [get_pins -quiet -hier -regexp \
  {(^|.*/)rx_fifo_overflow_cdc_i/toggle_sync_reg\[0\]/D$}]
set temac_sync_d [get_pins -quiet -hier -regexp \
  {(^|.*/)rx_client_fifo_i/resync_wr_store_frame_tog/data_sync_reg0/D$}]
if {[llength $overflow_sync_d] != 1} {
  error "expected one RX-overflow synchronizer first-stage D pin, found [llength $overflow_sync_d]: $overflow_sync_d"
}
if {[llength $temac_sync_d] != 1} {
  error "expected one TEMAC RX toggle synchronizer first-stage D pin, found [llength $temac_sync_d]: $temac_sync_d"
}
set_false_path -to $overflow_sync_d
set_false_path -to $temac_sync_d
puts "ROUTE_RECOVERY_CDC: overflow=$overflow_sync_d temac=$temac_sync_d"

stage "route_design Default"
route_design -directive Default

# Save first.  If a later report consumes excessive memory, the complete
# route remains recoverable by a separate Vivado process.
stage "save routed checkpoint"
write_checkpoint -force $routed_dcp

stage "write minimum route and timing reports"
report_route_status -file [file join $out_dir route_status_pre_physopt.rpt]
report_timing_summary -delay_type min_max -max_paths 100 \
  -report_unconstrained -check_timing_verbose \
  -file [file join $out_dir timing_summary_pre_physopt.rpt]

set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths  [get_timing_paths -quiet -delay_type min -max_paths 1]
set setup_slack "N/A"
set hold_slack  "N/A"
if {[llength $setup_paths] != 0} {
  set setup_slack [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] != 0} {
  set hold_slack [get_property SLACK [lindex $hold_paths 0]]
}
puts "ROUTE_RECOVERY_RESULT: setup_slack=$setup_slack hold_slack=$hold_slack dcp=$routed_dcp"

close_design
exit 0
