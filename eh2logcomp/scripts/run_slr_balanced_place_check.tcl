# Placement-only qualification run from the already verified post-opt DCP.
# It avoids spending several hours routing a candidate until SLR balance,
# congestion, and placement timing have first been measured.
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set in_dcp [file join $root_dir output board checkpoints latest_post_opt.dcp]
set out_dcp [file join $root_dir output board checkpoints latest_post_place_slr_balanced.dcp]
set report_dir [file join $root_dir output board reports_slr_balanced_place]
file mkdir $report_dir

proc stage {message} {
  puts "SLR_PLACE_STAGE: $message"
  flush stdout
}

stage "open verified post-opt checkpoint"
open_checkpoint $in_dcp

# The production RTL now preserves one explicit hierarchy per Hart.  Constrain
# complete banks instead of synthesized leaves so each bank remains locally
# optimizable without recreating wide cross-Hart combinational cones.
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
  puts "SLR_PLACE_CAPTURE_ASSIGNMENT $hierarchy=$slr"
}

# Keep every 266.5 MHz DDR0-side bridge/arbiter/checker in the same SLR as
# the DDR0 MIG.  SSI_SpreadLogic_high otherwise moved program_cdc_i into SLR1;
# the resulting address/control path crossed SLR1->SLR0 twice and became the
# placement WNS (-0.649 ns).  The source sides of these bridges run at only
# 50/100 MHz, so their intentional boundary crossing remains on the relaxed
# side of each CDC rather than inside the DDR0 UI-clock path.
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
  puts "SLR_PLACE_ASSIGNMENT $hierarchy=[get_property USER_SLR_ASSIGNMENT $hierarchy_cell]"
}

stage "place SSI_SpreadLogic_high with two threads"
set_param general.maxThreads 2
place_design -directive SSI_SpreadLogic_high

stage "save and report candidate"
write_checkpoint -force $out_dcp
report_timing_summary -delay_type min_max -max_paths 50 -report_unconstrained \
  -file [file join $report_dir timing_summary.rpt]
report_utilization -slr -file [file join $report_dir utilization_slr.rpt]
report_design_analysis -congestion -file [file join $report_dir congestion.rpt]

set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
puts "SLR_PLACE_TIMING setup=[get_property SLACK [lindex $setup_path 0]] hold=[get_property SLACK [lindex $hold_path 0]]"
puts "SLR_PLACE_PASS checkpoint=$out_dcp"
close_design
exit 0
