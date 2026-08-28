# Stable full-chip implementation of the latest self-contained synthesis DCP.
# The flow deliberately avoids post-route leaf-clock optimization, which was
# the only stage observed to exhaust host memory.  Every long stage saves a
# recoverable checkpoint before the next stage begins.

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set synth_dcp [file join $root_dir build vivado eh2_veri_system.runs synth_1 \
  eh2_veri_system_top.dcp]
set out_dir [file join $root_dir output board]
set checkpoint_dir [file join $out_dir checkpoints]
set report_dir [file join $out_dir reports_latest]
set routed_dcp [file join $out_dir eh2_veri_system_routed_latest.dcp]
set bitstream [file join $out_dir eh2_veri_system_latest.bit]

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
link_design -top eh2_veri_system_top -part xcvu19p_CIV-fsva3824-1-e

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

stage "place_design Explore (two threads, memory-priority)"
set_param general.maxThreads 2
place_design -directive Explore
write_checkpoint -force [file join $checkpoint_dir latest_post_place.dcp]
report_timing_summary -delay_type min_max -max_paths 50 \
  -report_unconstrained -file [file join $report_dir post_place_timing_summary.rpt]

stage "phys_opt_design AggressiveExplore (one thread, memory-priority)"
set_param general.maxThreads 1
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $checkpoint_dir latest_post_physopt.dcp]
report_timing_summary -delay_type min_max -max_paths 50 \
  -report_unconstrained -file [file join $report_dir post_physopt_timing_summary.rpt]

stage "route_design Default (two threads, memory-priority)"
set_param general.maxThreads 2
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
