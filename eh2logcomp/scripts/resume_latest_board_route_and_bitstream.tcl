# Resume the latest board build from the validated post-phys-opt checkpoint.
# This entry point exists so an external command-duration limit cannot force
# synthesis, placement, and physical optimization to be repeated.

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set out_dir [file join $root_dir output board]
set checkpoint_dir [file join $out_dir checkpoints]
set report_dir [file join $out_dir reports_latest]
set input_dcp [file join $checkpoint_dir latest_post_physopt.dcp]
set routed_dcp [file join $out_dir eh2_veri_system_routed_latest.dcp]
set bitstream [file join $out_dir eh2_veri_system_latest.bit]

file mkdir $out_dir
file mkdir $checkpoint_dir
file mkdir $report_dir

if {![file exists $input_dcp]} {
  error "post-phys-opt checkpoint does not exist: $input_dcp"
}

proc stage {message} {
  puts "LATEST_ROUTE_RESUME_STAGE: $message"
  flush stdout
}

proc blackboxes {} {
  return [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
}

proc assert_no_blackboxes {stage_name} {
  set cells [blackboxes]
  puts "LATEST_ROUTE_RESUME_BLACKBOX_COUNT($stage_name)=[llength $cells]"
  if {[llength $cells] != 0} {
    foreach cell $cells {
      puts "LATEST_ROUTE_RESUME_BLACKBOX($stage_name)=$cell REF_NAME=[get_property REF_NAME $cell]"
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

stage "open validated post-phys-opt checkpoint"
# Eight router workers completed the interrupted attempt with a measured peak
# of about 23.6 GB, so this is the fastest already-proven safe setting.
set_param general.maxThreads 8
set_param chipscope.maxJobs 1
open_checkpoint $input_dcp
assert_no_blackboxes post_physopt_reopen

stage "route_design Default (up to eight router workers)"
route_design -directive Default

# Save the expensive routed state before any report or bitstream pass.
stage "save routed checkpoint"
write_checkpoint -force $routed_dcp
assert_no_blackboxes post_route

stage "route, timing, bus-skew, and DRC sign-off"
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
report_drc -file [file join $report_dir drc.rpt]

set worst_setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set worst_hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $worst_setup_paths] == 0 || [llength $worst_hold_paths] == 0} {
  error "could not obtain setup and hold timing paths"
}
set worst_setup_slack [get_property SLACK [lindex $worst_setup_paths 0]]
set worst_hold_slack [get_property SLACK [lindex $worst_hold_paths 0]]
puts "LATEST_ROUTE_RESUME_TIMING setup_slack=$worst_setup_slack hold_slack=$worst_hold_slack"
if {$worst_setup_slack < 0.0 || $worst_hold_slack < 0.0} {
  error "implemented design does not meet setup/hold timing"
}

set severe_drc [severe_drc_violations]
puts "LATEST_ROUTE_RESUME_SEVERE_DRC_COUNT=[llength $severe_drc]"
if {[llength $severe_drc] != 0} {
  error "implemented design has Error/Critical Warning DRC violations: $severe_drc"
}

stage "write uncompressed bitstream"
# Compression changes only configuration-file size and previously caused the
# avoidable high-memory pass, so keep the validated uncompressed setting.
set_param general.maxThreads 2
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force $bitstream

stage "complete"
puts "LATEST_ROUTE_RESUME_PASS routed_dcp=$routed_dcp bitstream=$bitstream"
close_design
exit 0
