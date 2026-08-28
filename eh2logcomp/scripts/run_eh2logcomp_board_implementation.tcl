# Memory-priority full-chip implementation for eh2logcomp_system_top.
# Each expensive stage writes a recoverable checkpoint.  The physical flow
# deliberately avoids post-route phys_opt, which exhausted memory in the
# predecessor project without being needed for sign-off.

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set synth_dcp [file join $root_dir build vivado eh2_veri_system.runs synth_1 \
  eh2logcomp_system_top.dcp]
set out_dir [file join $root_dir output board]
set checkpoint_dir [file join $out_dir checkpoints]
set report_dir [file join $out_dir reports]
set routed_dcp [file join $out_dir eh2logcomp_system_routed.dcp]
set bitstream [file join $out_dir eh2logcomp_system.bit]

file mkdir $out_dir
file mkdir $checkpoint_dir
file mkdir $report_dir
if {![file exists $synth_dcp]} {
  error "synthesis checkpoint does not exist: $synth_dcp"
}

proc stage {message} {
  puts "EH2LOGCOMP_IMPL_STAGE: $message"
  flush stdout
}

proc assert_no_blackboxes {stage_name} {
  set cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
  puts "EH2LOGCOMP_BLACKBOX_COUNT($stage_name)=[llength $cells]"
  if {[llength $cells] != 0} {
    foreach cell $cells {
      puts "EH2LOGCOMP_BLACKBOX($stage_name)=$cell REF_NAME=[get_property REF_NAME $cell]"
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

stage "create project-mode gate-level context"
set_param general.maxThreads 4
set_param chipscope.maxJobs 1
set_param runs.launchOptions { -jobs 1 }
create_project -in_memory -part xcvu19p_CIV-fsva3824-1-e
set_property design_mode GateLvl [current_fileset]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
set_property parent.project_path \
  [file join $root_dir build vivado eh2_veri_system.xpr] [current_project]

set ip_cache_dir [file join $root_dir output ip_cache]
set_property ip_output_repo $ip_cache_dir [current_project]
set_property ip_cache_permissions {read write} [current_project]
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

foreach board_xdc {
  constraints/eh2_dual_ddr_v19p.xdc
  constraints/ethernet_addon.xdc
  constraints/tx_fifo_cdc.xdc
  constraints/rgmii_phy_timing.xdc
  constraints/rgmii_rx_clock_placement.xdc
} {
  stage "read board constraint $board_xdc"
  read_xdc [file join $root_dir $board_xdc]
}
set_property PROCESSING_ORDER LATE \
  [get_files [file join $root_dir constraints rgmii_phy_timing.xdc]]
set_property PROCESSING_ORDER LATE \
  [get_files [file join $root_dir constraints rgmii_rx_clock_placement.xdc]]

stage "link full implementation design"
link_design -top eh2logcomp_system_top -part xcvu19p_CIV-fsva3824-1-e

set c0_sys_clk_pin [get_property PACKAGE_PIN [get_ports c0_sys_clk_p]]
set c1_sys_clk_pin [get_property PACKAGE_PIN [get_ports c1_sys_clk_p]]
puts "EH2LOGCOMP_MIG_CLOCK_PINS c0=$c0_sys_clk_pin c1=$c1_sys_clk_pin"
if {$c0_sys_clk_pin ne "BN26" || $c1_sys_clk_pin ne "F32"} {
  error "board XDC did not place both MIG reference-clock ports"
}

# At link handoff the only legal placeholder is Vivado's generated debug hub.
set unexpected_blackboxes {}
foreach cell [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}] {
  set ref_name [get_property REF_NAME $cell]
  if {![string match "dbg_hub*" $ref_name]} {
    lappend unexpected_blackboxes $cell
  }
}
puts "EH2LOGCOMP_LINK_UNEXPECTED_BLACKBOX_COUNT=[llength $unexpected_blackboxes]"
if {[llength $unexpected_blackboxes] != 0} {
  error "link handoff contains unexpected black boxes: $unexpected_blackboxes"
}

stage "opt_design (single thread for MIG/debug cache stability)"
set_param general.maxThreads 1
opt_design
write_checkpoint -force [file join $checkpoint_dir post_opt.dcp]
assert_no_blackboxes post_opt
report_drc -file [file join $report_dir post_opt_drc.rpt]

stage "place_design Explore (two threads)"
set_param general.maxThreads 2
place_design -directive Explore
write_checkpoint -force [file join $checkpoint_dir post_place.dcp]
report_timing_summary -delay_type min_max -max_paths 50 \
  -report_unconstrained -file [file join $report_dir post_place_timing_summary.rpt]

stage "phys_opt_design AggressiveExplore (single thread)"
set_param general.maxThreads 1
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $checkpoint_dir post_physopt.dcp]
report_timing_summary -delay_type min_max -max_paths 50 \
  -report_unconstrained -file [file join $report_dir post_physopt_timing_summary.rpt]

stage "route_design Default (two threads)"
set_param general.maxThreads 2
route_design -directive Default
write_checkpoint -force $routed_dcp
assert_no_blackboxes post_route

stage "route and timing sign-off"
set route_report [report_route_status -return_string]
set route_file [open [file join $report_dir route_status.rpt] w]
puts -nonewline $route_file $route_report
close $route_file
if {![regexp {# of nets with routing errors[^:]*:\s+0\s+:} $route_report]} {
  error "route status reports one or more routing errors"
}

report_timing_summary -delay_type min_max -max_paths 100 \
  -report_unconstrained -check_timing_verbose \
  -file [file join $report_dir timing_summary.rpt]
report_bus_skew -warn_on_violation -file [file join $report_dir bus_skew.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
report_clock_interaction -delay_type min_max \
  -file [file join $report_dir clock_interaction.rpt]
report_cdc -details -file [file join $report_dir cdc.rpt]
report_utilization -hierarchical -file [file join $report_dir utilization_hierarchical.rpt]
report_io -file [file join $report_dir io.rpt]

set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
  error "could not obtain setup and hold timing paths"
}
set setup_slack [get_property SLACK [lindex $setup_path 0]]
set hold_slack [get_property SLACK [lindex $hold_path 0]]
puts "EH2LOGCOMP_TIMING setup_slack=$setup_slack hold_slack=$hold_slack"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
  error "implemented design does not meet setup/hold timing"
}

set severe_drc [severe_drc_violations]
puts "EH2LOGCOMP_SEVERE_DRC_COUNT=[llength $severe_drc]"
if {[llength $severe_drc] != 0} {
  error "implemented design has severe DRC violations: $severe_drc"
}

stage "write uncompressed bitstream"
set_param general.maxThreads 1
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force $bitstream

stage "complete"
puts "EH2LOGCOMP_IMPL_PASS routed_dcp=$routed_dcp bitstream=$bitstream"
close_design
exit 0
