# Finalize the already routed eh2logcomp design without repeating synthesis,
# placement, routing, or the completed full-chip CDC analysis.

set root_dir D:/eh2_fpga/eh2logcomp
set out_dir [file join $root_dir output board]
set report_dir [file join $out_dir reports_latest]
set routed_dcp [file join $out_dir eh2logcomp_2slot_routed.dcp]
set cdc_report_path [file join $report_dir cdc.rpt]
set bitstream [file join $out_dir eh2logcomp_2slot.bit]

proc stage {message} {
  puts "FINALIZE_STAGE: $message"
  flush stdout
}

proc blackboxes {} {
  return [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
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

if {![file exists $routed_dcp]} {
  error "routed checkpoint does not exist: $routed_dcp"
}
if {![file exists $cdc_report_path]} {
  error "completed CDC report does not exist: $cdc_report_path"
}
if {[file mtime $cdc_report_path] < [file mtime $routed_dcp]} {
  error "CDC report predates the routed checkpoint"
}

stage "open saved routed checkpoint"
set_param general.maxThreads 1
open_checkpoint $routed_dcp
set unresolved [blackboxes]
puts "FINALIZE_BLACKBOX_COUNT=[llength $unresolved]"
if {[llength $unresolved] != 0} {
  error "routed checkpoint contains unresolved black boxes: $unresolved"
}

stage "route completeness gate"
set route_report [report_route_status -return_string]
if {![regexp {# of nets with routing errors[^:]*:\s+0\s+:} $route_report]} {
  error "route status reports one or more routing errors"
}

stage "reuse and classify completed CDC report"
set cdc_file [open $cdc_report_path r]
set cdc_text [read $cdc_file]
close $cdc_file
set targeted_cdc_violations {}
set known_xpm_reset_count 0
set known_async_assert_count 0
set known_sticky_flush_count 0
set known_xpm_sync_rst_count 0
foreach cdc_line [split $cdc_text "\n"] {
  # First use cheap literal tests so the ~60,000 vendor CDC-15 memory rows do
  # not execute the more expensive path-specific regular expressions.
  set candidate_fifo_class [expr {
    [string first "CDC-1 "  $cdc_line] >= 0 ||
    [string first "CDC-6 "  $cdc_line] >= 0 ||
    [string first "CDC-10 " $cdc_line] >= 0 ||
    [string first "CDC-11 " $cdc_line] >= 0}]
  set candidate_named_path [expr {
    [string first "tx_submit_count_sync_i" $cdc_line] >= 0 ||
    [string first "tx_complete_count_sync_i" $cdc_line] >= 0 ||
    [string first "rx_statistics_cdc_i/count_sync_i" $cdc_line] >= 0 ||
    [string first "count_to_ui_i" $cdc_line] >= 0}]
  set candidate_fifo_path [expr {
    [string first "g_info_fifo" $cdc_line] >= 0}]
  if {!($candidate_fifo_class && $candidate_fifo_path) &&
      !$candidate_named_path} {
    continue
  }

  set known_xpm_reset [regexp {CDC-1[[:space:]]+Critical.*g_info_fifo.*gnuram_async_fifo\.xpm_fifo_base_inst/xpm_fifo_rst_inst/} $cdc_line]
  set known_async_assert [regexp {CDC-11[[:space:]]+Critical.*g_info_fifo.*(wr_reset_pipe_reg\[0\]|rd_reset_pipe_reg\[0\]|src_reset_pipe_reg\[0\]|dst_reset_pipe_reg\[0\])/CLR} $cdc_line]
  # XPM_FIFO_ASYNC rst is made synchronous to wr_clk independently in each
  # lane.  The producer waits for all wr_rst_busy flags before accepting any
  # bundle, making the possible lane-to-lane release skew unobservable.
  set known_xpm_sync_rst [regexp {CDC-11[[:space:]]+Critical.*reset_supervisor_i/system_resetn_reg/C.*g_info_fifo\[[01]\].*g_bank\[[0-3]\].*g_lane\[[0-3]\].xpm_wr_reset_sync_i/syncstages_ff_reg\[0\]/D} $cdc_line]
  # The completion source is a registered level held until global reset.
  # A bank cannot be claimed until its XPM count has remained stable for 32
  # DDR1 UI clocks; these flush synchronizers are only three stages deep.
  # Therefore the possible one-cycle resolution difference cannot reach a
  # FIFO read.  Accept only the exact two-hart/four-bank destinations.
  set known_sticky_flush_fanout [regexp {CDC-11[[:space:]]+Critical.*info_pipeline_done_core_reg/C.*g_info_fifo\[[01]\]\.info_fifo_i/g_bank\[[0-3]\]\.bank_fifo_i/flush_sync_i/pipe_reg\[0\]\[0\]/D} $cdc_line]
  if {$known_xpm_reset} { incr known_xpm_reset_count }
  if {$known_async_assert} { incr known_async_assert_count }
  if {$known_sticky_flush_fanout} { incr known_sticky_flush_count }
  if {$known_xpm_sync_rst} { incr known_xpm_sync_rst_count }

  if {([regexp {CDC-(1|6|10|11)[[:space:]]+(Critical|Warning).*g_info_fifo} \
         $cdc_line] && !$known_xpm_reset && !$known_async_assert &&
         !$known_xpm_sync_rst &&
         !$known_sticky_flush_fanout) ||
      [regexp {CDC-10[[:space:]]+Critical.*(tx_submit_count_sync_i|tx_complete_count_sync_i|rx_statistics_cdc_i/count_sync_i)} \
        $cdc_line] ||
      [string match {*count_to_ui_i*} $cdc_line]} {
    lappend targeted_cdc_violations $cdc_line
  }
}
puts "FINALIZE_CDC_KNOWN_XPM_RESET_COUNT=$known_xpm_reset_count"
puts "FINALIZE_CDC_KNOWN_ASYNC_ASSERT_COUNT=$known_async_assert_count"
puts "FINALIZE_CDC_KNOWN_STICKY_FLUSH_COUNT=$known_sticky_flush_count"
puts "FINALIZE_CDC_KNOWN_XPM_SYNC_RST_COUNT=$known_xpm_sync_rst_count"
puts "FINALIZE_TARGETED_CDC_COUNT=[llength $targeted_cdc_violations]"
if {$known_xpm_sync_rst_count != 32} {
  error "expected exactly 32 reviewed XPM write-reset synchronizer inputs"
}
if {$known_sticky_flush_count != 8} {
  error "expected exactly eight reviewed sticky flush fan-out paths"
}
if {[llength $targeted_cdc_violations] != 0} {
  foreach cdc_line $targeted_cdc_violations {
    puts "FINALIZE_TARGETED_CDC=$cdc_line"
  }
  error "targeted CDC sign-off failed"
}

stage "exact timing and DRC gates"
set worst_setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set worst_hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $worst_setup_paths] == 0 || [llength $worst_hold_paths] == 0} {
  error "could not obtain setup and hold timing paths"
}
set worst_setup_slack [get_property SLACK [lindex $worst_setup_paths 0]]
set worst_hold_slack [get_property SLACK [lindex $worst_hold_paths 0]]
puts "FINALIZE_TIMING setup_slack=$worst_setup_slack hold_slack=$worst_hold_slack"
if {$worst_setup_slack < 0.0 || $worst_hold_slack < 0.0} {
  error "routed design does not meet setup/hold timing"
}
report_drc -file [file join $report_dir drc_finalize.rpt]
set severe_drc [severe_drc_violations]
puts "FINALIZE_SEVERE_DRC_COUNT=[llength $severe_drc]"
if {[llength $severe_drc] != 0} {
  error "routed design has Error/Critical Warning DRC violations: $severe_drc"
}

stage "write uncompressed bitstream"
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force $bitstream

stage "complete"
puts "FINALIZE_PASS bitstream=$bitstream routed_dcp=$routed_dcp"
close_design
exit 0
