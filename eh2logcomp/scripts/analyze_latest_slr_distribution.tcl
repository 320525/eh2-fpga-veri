set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set dcp [file join $root_dir output board eh2logcomp_2slot_routed.dcp]
set out_dir [file join $root_dir output board reports_latest]

open_checkpoint $dcp
report_utilization -slr -file [file join $out_dir utilization_slr.rpt]
report_design_analysis -congestion -file [file join $out_dir congestion_post_route.rpt]

proc report_group_slr {label pattern} {
  set group_cells [get_cells -quiet -hier -filter "NAME =~ $pattern && IS_PRIMITIVE == 1"]
  puts "SLR_GROUP $label total=[llength $group_cells]"
  foreach slr [get_slrs] {
    set slr_cells [get_cells -quiet -of_objects [get_sites -quiet -of_objects $slr] \
      -filter "NAME =~ $pattern && IS_PRIMITIVE == 1"]
    set count [llength $slr_cells]
    puts "SLR_GROUP $label $slr=$count"
  }
}

report_group_slr DDR0_PATH "ddr0_*"
report_group_slr IFU_CDC "ifu_cdc_i/*"
report_group_slr LSU_CDC "lsu_cdc_i/*"
report_group_slr DDR1_DMA "info_ddr_dma_i/*"
report_group_slr INFO_ELASTIC "g_info_elastic*"
report_group_slr INFO_CAPTURE "eh2_i/info_capture_i/*"
report_group_slr FRAME_SLOTS "dump_i/frame_fifo_i/*"
report_group_slr EH2_CORE "eh2_i/core_i/*"

close_design
exit 0
