# Stable full-chip implementation of the latest self-contained synthesis DCP.
# The flow deliberately avoids post-route leaf-clock optimization, which was
# the only stage observed to exhaust host memory.  Every long stage saves a
# recoverable checkpoint before the next stage begins.

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set synth_dcp [file join $root_dir build vivado eh2_veri_system.runs synth_1 \
  eh2logcomp_system_top.dcp]
set out_dir [file join $root_dir output board]
set checkpoint_dir [file join $out_dir checkpoints]
set report_dir [file join $out_dir reports_latest]
set routed_dcp [file join $out_dir eh2logcomp_2slot_routed.dcp]
set bitstream [file join $out_dir eh2logcomp_2slot.bit]
set stop_after_place [expr {[lsearch -exact $argv "stop_after_place"] >= 0}]

file mkdir $out_dir
file mkdir $checkpoint_dir
file mkdir $report_dir

if {![file exists $synth_dcp]} {
  error "synthesis checkpoint does not exist: $synth_dcp"
}

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

stage "create project-mode implementation context"
# The validated MIG PHY cache was produced with the standard eight-thread
# implementation initialization. Keep that setting only through MIG/debug
# core stitching; physical implementation is deliberately memory-limited.
set_param general.maxThreads 8
set_param chipscope.maxJobs 1
set_param runs.launchOptions { -jobs 1 }
create_project -in_memory -part xcvu19p_CIV-fsva3824-1-e
set_property design_mode GateLvl [current_fileset]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
set_property top eh2logcomp_system_top [current_fileset]
set_property parent.project_path \
  [file join $root_dir build vivado eh2_veri_system.xpr] [current_project]

# Reuse the project-managed MIG PHY and debug-core cache.  The original XCI
# metadata is required for Vivado to derive and match each cache ID.
set ip_cache_dir [file join $root_dir output ip_cache]
set_property ip_output_repo $ip_cache_dir [current_project]
set_property ip_cache_permissions {read write} [current_project]
puts "LATEST_IMPL_IP_CACHE=$ip_cache_dir"

add_files -quiet $synth_dcp
foreach ip_name {
  ddr4_1
  ddr4_0
  axi_datamover_0
  tri_mode_ethernet_mac_0
  axi_dwidth_converter_64_512
  axi_clock_converter_64
  axi_dwidth_converter_32_512
  axi_clock_converter_32
  axi_traffic_gen_0
  data_test_atg
} {
  set xci_path [file join $root_dir build vivado eh2_veri_system.srcs \
    sources_1 ip $ip_name ${ip_name}.xci]
  if {![file exists $xci_path]} {
    error "implementation IP metadata does not exist: $xci_path"
  }
  read_ip -quiet $xci_path
}

# Add the unchanged project-owned board XDCs in their validated order before
# link_design, matching the successful Vivado-generated implementation flow.
foreach board_xdc {
  constraints/eh2_dual_ddr_v19p.xdc
  constraints/ethernet_addon.xdc
  constraints/tx_fifo_cdc.xdc
  constraints/rgmii_phy_timing.xdc
  constraints/rgmii_rx_clock_placement.xdc
} {
  set board_xdc_path [file join $root_dir $board_xdc]
  stage "read board constraint $board_xdc"
  read_xdc $board_xdc_path
}
set_property PROCESSING_ORDER LATE \
  [get_files [file join $root_dir constraints rgmii_phy_timing.xdc]]
set_property PROCESSING_ORDER LATE \
  [get_files [file join $root_dir constraints rgmii_rx_clock_placement.xdc]]

stage "link full implementation design"
link_design -top eh2logcomp_system_top -part xcvu19p_CIV-fsva3824-1-e

# The two complete log-frame slots use a bundled-data toggle handshake.  The
# slot contents are held unchanged from publication until the TX domain
# returns the per-slot release toggle.  Cut only those intentionally stable
# bundled-data paths after link; publish/release synchronizers remain timed.
set bundled_src_cells [get_cells -quiet -hier -regexp \
  {.*dump_i/frame_fifo_i/(slot_payload_reg.*|slot_header_reg.*|slot_frame_number_reg.*)}]
set bundled_dst_cells [get_cells -quiet -hier -regexp \
  {.*dump_i/frame_fifo_i/(payload_word_hold_reg.*|active_header_reg.*|active_frame_number_reg.*)}]
# Use legal timing start/end pins rather than whole cell collections.  The
# broad cell regex also sees synthesis-created LUT helpers, which are not
# valid -from/-to cell endpoints and previously produced Constraints 18-401.
set bundled_src_regs [filter $bundled_src_cells {IS_SEQUENTIAL == 1}]
set bundled_dst_regs [filter $bundled_dst_cells {IS_SEQUENTIAL == 1}]
puts "LATEST_IMPL_BUNDLED_CDC_REGS source=[llength $bundled_src_regs] destination=[llength $bundled_dst_regs]"
if {[llength $bundled_src_regs] == 0 || [llength $bundled_dst_regs] == 0} {
  error "could not resolve complete-frame bundled-data CDC registers"
}
set_false_path -from $bundled_src_regs -to $bundled_dst_regs

set c0_sys_clk_pin [get_property PACKAGE_PIN [get_ports c0_sys_clk_p]]
set c1_sys_clk_pin [get_property PACKAGE_PIN [get_ports c1_sys_clk_p]]
puts "LATEST_IMPL_MIG_CLOCK_PINS c0=$c0_sys_clk_pin c1=$c1_sys_clk_pin"
if {$c0_sys_clk_pin ne "BN26" || $c1_sys_clk_pin ne "F32"} {
  error "board XDC did not place both MIG reference-clock ports"
}

# At synthesis handoff the only legal placeholder is Vivado's generated debug
# hub.  All system RTL/IP modules were required to be resolved by synthesis.
set synth_blackboxes [blackboxes]
set unexpected_synth_blackboxes {}
foreach cell $synth_blackboxes {
  if {!($cell eq "dbg_hub" && \
      [string match "dbg_hub*" [get_property REF_NAME $cell]])} {
    lappend unexpected_synth_blackboxes $cell
  }
}
puts "LATEST_IMPL_SYNTH_BLACKBOX_COUNT=[llength $synth_blackboxes]"
puts "LATEST_IMPL_SYNTH_UNEXPECTED_BLACKBOX_COUNT=[llength $unexpected_synth_blackboxes]"
if {[llength $unexpected_synth_blackboxes] != 0} {
  error "synthesis handoff contains unexpected black boxes: $unexpected_synth_blackboxes"
}

stage "opt_design (MIG cache-compatible initialization)"
# If the project cache is empty, opt_design launches a nested synthesis for
# each MIG PHY.  On Windows, multi-process child synthesis can race while
# deleting its shared realtime/tmp directory and falsely report a completed
# PHY synthesis as failed.  Run only this cache-population/opt stage with one
# thread; placement and routing restore their independently validated limits.
set_param general.maxThreads 1
opt_design
write_checkpoint -force [file join $checkpoint_dir latest_post_opt.dcp]
assert_no_blackboxes post_opt
report_drc -file [file join $report_dir post_opt_drc.rpt]

# Keep each Hart's complete state/selection hierarchy locally optimizable.
# This replaces the hard leaf Pblock that concentrated SLL traffic at one
# boundary while leaving wide combinational paths crossing SLR1 and SLR2.
set capture_bank_assignments {
  eh2_i/info_capture_i/hart0_bank_i SLR1
  eh2_i/info_capture_i/hart1_bank_i SLR2
}
foreach {hierarchy slr} $capture_bank_assignments {
  set hierarchy_cell [get_cells -quiet $hierarchy]
  if {[llength $hierarchy_cell] != 1} {
    error "could not resolve unique capture bank $hierarchy"
  }
  set_property USER_SLR_ASSIGNMENT $slr $hierarchy_cell
  puts "LATEST_IMPL_CAPTURE_ASSIGNMENT $hierarchy=$slr"
}

# Localize the fast DDR0 UI-clock logic.  Without this guidance the SSI
# spreading directive may put the m_clk half of program_cdc_i in SLR1, making
# a 266.5 MHz address/control path cross SLR1->SLR0 twice before the MIG.
set ddr0_local_hierarchies {
  program_cdc_i
  ifu_cdc_i
  lsu_cdc_i
  eh2_ddr0_arbiter_i
  instr_checker_i
}
foreach hierarchy $ddr0_local_hierarchies {
  set hierarchy_cell [get_cells -quiet $hierarchy]
  if {[llength $hierarchy_cell] != 1} {
    error "could not resolve unique DDR0-local hierarchy $hierarchy"
  }
  set_property USER_SLR_ASSIGNMENT SLR0 $hierarchy_cell
  puts "LATEST_IMPL_SLR_ASSIGNMENT $hierarchy=[get_property USER_SLR_ASSIGNMENT $hierarchy_cell]"
}

stage "place_design SSI_SpreadLogic_high (two threads, SLR1 congestion repair)"
set_param general.maxThreads 2
place_design -directive SSI_SpreadLogic_high
write_checkpoint -force [file join $checkpoint_dir latest_post_place.dcp]
# A complete timing-summary database has previously pushed this 16.9-GiB host
# into paging immediately before routing.  The critical paths are sufficient
# for the post-place decision; full setup/hold gates are evaluated after route.
report_timing -delay_type max -max_paths 30 \
  -file [file join $report_dir post_place_setup_compact.rpt]
report_timing -delay_type min -max_paths 30 \
  -file [file join $report_dir post_place_hold_compact.rpt]
report_utilization -slr -file [file join $report_dir post_place_utilization_slr.rpt]
report_design_analysis -congestion \
  -file [file join $report_dir post_place_congestion.rpt]

# The VU19P placement pass is the largest resident-memory stage on this host.
# Let the caller deliberately terminate here so all placement memory is
# returned to Windows before a fresh one-thread routing process opens the DCP.
if {$stop_after_place} {
  stage "placement checkpoint complete; exit for low-memory route restart"
  close_project
  exit 0
}

stage "skip pre-route AggressiveExplore (host-memory safety)"
# The earlier routed build proved that AggressiveExplore can commit more than
# 50 GiB on this 16.9 GiB host and crash before routing.  The DDR1 write path
# is now structurally pipelined in RTL, so save the placed checkpoint and let
# the timing-driven router optimize the registered design directly.

stage "route_design Default (one thread, memory-priority)"
set_param general.maxThreads 1
route_design -directive Default

# Save the expensive result before timing, DRC, or bitstream processing.
stage "save routed checkpoint"
write_checkpoint -force $routed_dcp
assert_no_blackboxes post_route

stage "minimum route sign-off reports"
set route_report [report_route_status -return_string]
set route_file [open [file join $report_dir route_status.rpt] w]
puts -nonewline $route_file $route_report
close $route_file
if {![regexp {# of nets with routing errors[^:]*:\s+0\s+:} $route_report]} {
  error "route status reports one or more routing errors"
}

# Keep sign-off reporting compact.  Timing acceptance below queries every
# clock through get_timing_paths and therefore does not depend on a bulky
# summary report being materialized in memory.
report_timing -delay_type max -max_paths 100 \
  -file [file join $report_dir routed_setup_compact.rpt]
report_timing -delay_type min -max_paths 100 \
  -file [file join $report_dir routed_hold_compact.rpt]
report_bus_skew -warn_on_violation -file [file join $report_dir bus_skew.rpt]
report_drc -file [file join $report_dir drc.rpt]

# CDC is a hard bitstream gate for every path changed by the four-bank log
# FIFO and cumulative MAC counters.  XPM FIFO memory crossings are reported
# as CDC-15 clock-enable structures and are intentionally implemented by the
# vendor primitive; unknown, multi-bit, combinational-source or fan-out CDCs
# in the surrounding control logic are not accepted.
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
  # XPM_FIFO_ASYNC requires its rst input synchronous to wr_clk.  Each of the
  # two harts x four banks x four lanes therefore owns an xpm_cdc_sync_rst.
  # The surrounding producer remains blocked until every lane reports
  # wr_rst_busy=0, so a possible one-cycle difference between these reset
  # synchronizers cannot expose a partially initialized striped FIFO.
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

stage "write bitstream"
set_param general.maxThreads 1
# The VU19P compressed-bitstream pass exceeded the 16.9 GB host's practical
# memory limit after routing had already passed. Compression changes only the
# configuration file size, not FPGA logic or behavior, so keep final output
# uncompressed for reproducible generation on this machine.
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force $bitstream

stage "complete"
puts "LATEST_IMPL_PASS routed_dcp=$routed_dcp bitstream=$bitstream"
close_design
exit 0
