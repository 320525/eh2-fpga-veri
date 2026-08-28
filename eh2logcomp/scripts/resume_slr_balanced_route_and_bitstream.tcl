# Resume the final route/bitstream flow from the qualified placed checkpoint.
# This avoids repeating synthesis, IP stitching, opt_design, and the one-hour
# placement qualification.  The checkpoint already contains all board/IP
# constraints and the accepted SLR assignments.
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set in_dcp [file join $root_dir output board checkpoints latest_post_place_slr_balanced.dcp]
set out_dir [file join $root_dir output board]
set report_dir [file join $out_dir reports_latest]
set routed_dcp [file join $out_dir eh2logcomp_2slot_routed.dcp]
set bitstream [file join $out_dir eh2logcomp_2slot.bit]
file mkdir $report_dir

proc stage {message} {
  puts "LATEST_ROUTE_STAGE: $message"
  flush stdout
}

proc blackboxes {} {
  return [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
}

proc assert_no_blackboxes {stage_name} {
  set cells [blackboxes]
  puts "LATEST_ROUTE_BLACKBOX_COUNT($stage_name)=[llength $cells]"
  if {[llength $cells] != 0} {
    foreach cell $cells {
      puts "LATEST_ROUTE_BLACKBOX($stage_name)=$cell REF_NAME=[get_property REF_NAME $cell]"
    }
    error "$stage_name contains unresolved black boxes"
  }
}

proc severe_drc_violations {} {
  set result {}
  foreach violation [get_drc_violations -quiet] {
    set severity [get_property SEVERITY $violation]
    if {$severity eq "Error" || $severity eq "Critical Warning"} {
      lappend result $violation
    }
  }
  return $result
}

if {![file exists $in_dcp]} {
  error "qualified placed checkpoint does not exist: $in_dcp"
}

stage "open qualified SLR-balanced placement"
open_checkpoint $in_dcp
assert_no_blackboxes pre_route

stage "route_design Default (two threads, memory-priority)"
set_param general.maxThreads 2
route_design -directive Default

# Preserve the expensive routed result before running any report.
stage "save routed checkpoint"
write_checkpoint -force $routed_dcp
assert_no_blackboxes post_route

stage "route, timing, skew, CDC, and DRC sign-off reports"
set route_report [report_route_status -return_string]
set route_file [open [file join $report_dir route_status.rpt] w]
puts -nonewline $route_file $route_report
close $route_file
if {![regexp {# of nets with routing errors[^:]*:\s+0\s+:} $route_report]} {
  error "route status reports one or more routing errors"
}

report_timing_summary -delay_type min_max -max_paths 100 \
  -report_unconstrained -file [file join $report_dir timing_summary.rpt]
report_bus_skew -warn_on_violation -file [file join $report_dir bus_skew.rpt]
report_cdc -details -file [file join $report_dir cdc.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_utilization -slr -file [file join $report_dir utilization_slr.rpt]
report_design_analysis -congestion \
  -file [file join $report_dir congestion_post_route.rpt]

set worst_setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set worst_hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $worst_setup_paths] == 0 || [llength $worst_hold_paths] == 0} {
  error "could not obtain setup and hold timing paths"
}
set worst_setup_slack [get_property SLACK [lindex $worst_setup_paths 0]]
set worst_hold_slack [get_property SLACK [lindex $worst_hold_paths 0]]
puts "LATEST_ROUTE_TIMING setup_slack=$worst_setup_slack hold_slack=$worst_hold_slack"
if {$worst_setup_slack < 0.0 || $worst_hold_slack < 0.0} {
  error "implemented design does not meet setup/hold timing"
}

set severe_drc [severe_drc_violations]
puts "LATEST_ROUTE_SEVERE_DRC_COUNT=[llength $severe_drc]"
if {[llength $severe_drc] != 0} {
  error "implemented design has Error/Critical Warning DRC violations: $severe_drc"
}

stage "write uncompressed bitstream"
set_param general.maxThreads 1
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force $bitstream

stage "complete"
puts "LATEST_ROUTE_PASS routed_dcp=$routed_dcp bitstream=$bitstream"
close_design
exit 0
