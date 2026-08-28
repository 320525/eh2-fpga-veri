# Board implementation and bitstream generation for eh2_veri_system_top.
#
# This script deliberately runs the implementation stages in the current
# Vivado process.  It avoids the Windows Vivado Run Server wrapper while still
# executing the normal opt/place/phys_opt/route/bitstream flow.

set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set synth_dcp  [file join $root_dir build vivado eh2_veri_system.runs synth_1 eh2_veri_system_top.dcp]
set out_dir    [file join $root_dir output board]

file mkdir $out_dir

if {![file exists $synth_dcp]} {
  error "Synthesized checkpoint not found: $synth_dcp"
}

proc stage {message} {
  puts "BOARD_BUILD_STAGE: $message"
  flush stdout
}

stage "open synthesized checkpoint"
open_checkpoint $synth_dcp

# The top checkpoint is synthesized with these IPs out of context.  A normal
# project implementation run loads each scoped IP checkpoint automatically;
# because this script runs the stages in-process, reproduce that linking step
# explicitly for every matching hierarchical instance.
set ooc_refs {
  axi_clock_converter_32
  axi_clock_converter_64
  axi_dwidth_converter_32_512
  axi_dwidth_converter_64_512
  axi_traffic_gen_0
  data_test_atg
}

foreach ref_name $ooc_refs {
  set ip_dcp [file join $root_dir build vivado eh2_veri_system.runs ${ref_name}_synth_1 ${ref_name}.dcp]
  if {![file exists $ip_dcp]} {
    error "OOC checkpoint not found for $ref_name: $ip_dcp"
  }
  set scoped_cells [get_cells -quiet -hierarchical -filter "REF_NAME == $ref_name"]
  if {[llength $scoped_cells] == 0} {
    error "No hierarchical instance found for OOC reference $ref_name"
  }
  foreach scoped_cell $scoped_cells {
    stage "load OOC checkpoint $ref_name into $scoped_cell"
    read_checkpoint -cell $scoped_cell $ip_dcp
  }
}

set unresolved_black_boxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved_black_boxes] != 0} {
  puts "UNRESOLVED_BLACK_BOXES: $unresolved_black_boxes"
  error "Implementation checkpoint still contains unresolved black boxes"
}

stage "post-synthesis design-rule checks"
report_drc -file [file join $out_dir post_synth_drc.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
  -max_paths 20 -file [file join $out_dir post_synth_timing_summary.rpt]

stage "opt_design"
opt_design
write_checkpoint -force [file join $out_dir eh2_veri_system_post_opt.dcp]

stage "place_design Explore"
place_design -directive Explore

stage "post-place phys_opt_design AggressiveExplore"
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $out_dir eh2_veri_system_post_place.dcp]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
  -max_paths 20 -file [file join $out_dir post_place_timing_summary.rpt]

stage "route_design Explore"
route_design -directive Explore

stage "post-route phys_opt_design AggressiveExplore"
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $out_dir eh2_veri_system_post_route.dcp]

stage "final implementation reports"
report_drc -file [file join $out_dir post_route_drc.rpt]
report_methodology -file [file join $out_dir post_route_methodology.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
  -max_paths 100 -file [file join $out_dir post_route_timing_summary.rpt]
report_utilization -hierarchical -file [file join $out_dir post_route_utilization_hierarchical.rpt]
report_clock_utilization -file [file join $out_dir post_route_clock_utilization.rpt]
report_clock_interaction -delay_type min_max -file [file join $out_dir post_route_clock_interaction.rpt]
report_cdc -details -file [file join $out_dir post_route_cdc.rpt]
report_io -file [file join $out_dir post_route_io.rpt]
report_exceptions -coverage -file [file join $out_dir post_route_exception_coverage.rpt]
report_power -file [file join $out_dir post_route_power.rpt]

stage "write bitstream"
write_bitstream -force [file join $out_dir eh2_veri_system.bit]

stage "complete"
close_design
exit
