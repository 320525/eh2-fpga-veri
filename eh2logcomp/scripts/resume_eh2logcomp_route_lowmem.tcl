# Resume the eh2logcomp full-chip implementation from the last completed
# placement checkpoint.  AggressiveExplore phys_opt_design is intentionally
# skipped because its Phase 10 exceeded the 16.9 GiB host's practical memory
# capacity.  This does not alter RTL or constraints; all route/timing/DRC
# sign-off gates remain mandatory before bitstream generation.  This resume
# also uses one router worker: the previous two-worker attempt reached about
# 27.75 GiB while updating timing and exited without a Tcl/Vivado error.

set root_dir D:/eh2_fpga/eh2logcomp
set out_dir [file join $root_dir output board]
set checkpoint_dir [file join $out_dir checkpoints]
set report_dir [file join $out_dir reports_latest]
set place_dcp [file join $checkpoint_dir latest_post_place.dcp]
set routed_dcp [file join $out_dir eh2logcomp_2slot_routed.dcp]
set bitstream [file join $out_dir eh2logcomp_2slot.bit]

file mkdir $out_dir
file mkdir $report_dir

proc stage {message} {
  puts "LATEST_IMPL_STAGE: $message"
  flush stdout
}

proc blackboxes {} {
  return [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
}

proc assert_no_blackboxes {stage_name} {
  set cells [blackboxes]
  puts "LATEST_IMPL_BLACKBOX_COUNT($stage_name)=[llength $cells]"
  if {[llength $cells] != 0} {
    foreach cell $cells {
      puts "LATEST_IMPL_BLACKBOX($stage_name)=$cell REF_NAME=[get_property REF_NAME $cell]"
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

if {![file exists $place_dcp]} {
  error "placement checkpoint does not exist: $place_dcp"
}

stage "open completed placement checkpoint"
set_param general.maxThreads 1
open_checkpoint $place_dcp
assert_no_blackboxes post_place_resume

stage "route_design Default (one thread, memory-safe resume)"
route_design -directive Default

stage "save routed checkpoint"
write_checkpoint -force $routed_dcp
assert_no_blackboxes post_route

stage "route sign-off reports"
set route_report [report_route_status -return_string]
set route_file [open [file join $report_dir route_status.rpt] w]
puts -nonewline $route_file $route_report
close $route_file
if {![regexp {# of nets with routing errors[^:]*:\s+0\s+:} $route_report]} {
  error "route status reports one or more routing errors"
}

# Avoid materializing the very large combined timing-summary database on this
# host.  Compact setup/hold reports plus the all-clock slack gate below retain
# the same pass/fail criterion with substantially lower peak memory.
report_timing -delay_type max -max_paths 100 \
  -file [file join $report_dir routed_setup_compact.rpt]
report_timing -delay_type min -max_paths 100 \
  -file [file join $report_dir routed_hold_compact.rpt]
report_bus_skew -warn_on_violation -file [file join $report_dir bus_skew.rpt]
report_drc -file [file join $report_dir drc.rpt]

# Preserve the same hard CDC gate as the complete implementation flow.  The
# XPM FIFO memory internals may be reported as vendor CDC-15 structures; the
# surrounding ownership/count/control paths and registered Gray counters may
# not contain unknown, multi-bit, combinational-source, or fan-out crossings.
set cdc_report_path [file join $report_dir cdc.rpt]
report_cdc -details -file $cdc_report_path
set cdc_file [open $cdc_report_path r]
set cdc_text [read $cdc_file]
close $cdc_file
set targeted_cdc_violations {}
set known_xpm_sync_rst_count 0
foreach cdc_line [split $cdc_text "\n"] {
  # Avoid running several unbounded regular expressions across the tens of
  # thousands of vendor CDC-15 memory rows.  Only the classes and named paths
  # below can participate in this focused sign-off gate.
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
  # XPM's asynchronous FIFO deliberately synchronizes its reset separately
  # into the write and read clock domains.  Vivado reports the primitive's
  # private xpm_fifo_rst_inst state as CDC-1 when the reset is driven by our
  # local replicated reset flop; this is the vendor reset circuit itself,
  # not an unprotected payload/control crossing.
  set known_xpm_reset [regexp {CDC-1[[:space:]]+Critical.*g_info_fifo.*gnuram_async_fifo\.xpm_fifo_base_inst/xpm_fifo_rst_inst/} $cdc_line]
  # The reset pipes intentionally assert from hard_resetn asynchronously and
  # release on the respective local clock.  CDC-11 reports ending at the
  # first pipe register CLR pin therefore describe the reset synchronizer,
  # not a functional signal fanning into another clock domain.
  set known_async_assert [regexp {CDC-11[[:space:]]+Critical.*g_info_fifo.*(wr_reset_pipe_reg\[0\]|rd_reset_pipe_reg\[0\]|src_reset_pipe_reg\[0\]|dst_reset_pipe_reg\[0\])/CLR} $cdc_line]
  # Exactly 2 harts x 4 banks x 4 lanes use XPM's synchronous reset CDC.
  # Writes stay blocked until all lane wr_rst_busy flags are low, so reset
  # release skew between these synchronizers cannot expose partial startup.
  set known_xpm_sync_rst [regexp {CDC-11[[:space:]]+Critical.*reset_supervisor_i/system_resetn_reg/C.*g_info_fifo\[[01]\].*g_bank\[[0-3]\].*g_lane\[[0-3]\].xpm_wr_reset_sync_i/syncstages_ff_reg\[0\]/D} $cdc_line]
  if {$known_xpm_sync_rst} { incr known_xpm_sync_rst_count }
  # info_pipeline_done_core is a registered level that remains asserted until
  # the next global reset.  Each bank waits 32 stable DDR1 UI clocks after its
  # READY crossing before DMA may claim it, whereas these bank-local flush
  # synchronizers are only three stages deep.  A one-cycle metastability
  # resolution difference therefore cannot reach a FIFO read or change the
  # final odd-record beat.  Match only the exact two-hart/four-bank paths.
  set known_sticky_flush_fanout [regexp {CDC-11[[:space:]]+Critical.*info_pipeline_done_core_reg/C.*g_info_fifo\[[01]\]\.info_fifo_i/g_bank\[[0-3]\]\.bank_fifo_i/flush_sync_i/pipe_reg\[0\]\[0\]/D} $cdc_line]
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
puts "LATEST_IMPL_CDC_KNOWN_XPM_SYNC_RST_COUNT=$known_xpm_sync_rst_count"
if {$known_xpm_sync_rst_count != 32} {
  error "expected exactly 32 reviewed XPM write-reset synchronizer inputs"
}
puts "LATEST_IMPL_TARGETED_CDC_COUNT=[llength $targeted_cdc_violations]"
foreach cdc_line $targeted_cdc_violations {
  puts "LATEST_IMPL_TARGETED_CDC=$cdc_line"
}
if {[llength $targeted_cdc_violations] != 0} {
  error "log FIFO/MAC counter CDC sign-off failed"
}

set worst_setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set worst_hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $worst_setup_paths] == 0 || [llength $worst_hold_paths] == 0} {
  error "could not obtain setup and hold timing paths"
}
set worst_setup_slack [get_property SLACK [lindex $worst_setup_paths 0]]
set worst_hold_slack [get_property SLACK [lindex $worst_hold_paths 0]]
puts "LATEST_IMPL_TIMING setup_slack=$worst_setup_slack hold_slack=$worst_hold_slack"
if {$worst_setup_slack < 0.0 || $worst_hold_slack < 0.0} {
  error "implemented design does not meet setup/hold timing"
}

set severe_drc [severe_drc_violations]
puts "LATEST_IMPL_SEVERE_DRC_COUNT=[llength $severe_drc]"
if {[llength $severe_drc] != 0} {
  error "implemented design has Error/Critical Warning DRC violations: $severe_drc"
}

stage "write uncompressed bitstream"
set_param general.maxThreads 1
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force $bitstream

stage "complete"
puts "LATEST_IMPL_PASS routed_dcp=$routed_dcp bitstream=$bitstream"
close_design
exit 0
