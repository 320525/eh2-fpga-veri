set_param general.maxThreads 4

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set synth_dcp  [file join $root_dir build vivado eh2_veri_system.runs synth_1 eh2logcomp_system_top.dcp]
set out_dir    [file join $root_dir output board]

file mkdir $out_dir
open_checkpoint $synth_dcp

proc require_cells {label pattern} {
  set found [get_cells -quiet -hierarchical -filter "NAME =~ $pattern"]
  puts "AUDIT_REQUIRED $label count=[llength $found]"
  if {[llength $found] == 0} {
    error "Required synthesized block is absent: $label ($pattern)"
  }
}

require_cells EH2_CORE             *eh2_i*
require_cells DDR0_MIG             *mig_i/ddr0_i*
require_cells DDR1_MIG             *mig_i/ddr1_i*
require_cells DDR0_EH2_ARBITER      *eh2_ddr0_arbiter_i*
require_cells DDR0_AXI_W_SLICE       *ddr0_w_slice_i*
require_cells DDR1_AXI_W_SLICE       *ddr1_w_slice_i*
require_cells INFO_CAPTURE         *info_capture_i*
require_cells INFO_CAPTURE_HART0_BANK *info_capture_i/hart0_bank_i*
require_cells INFO_CAPTURE_HART1_BANK *info_capture_i/hart1_bank_i*
require_cells INFO_FIFO_DUAL_HART   *g_info_fifo*
require_cells INFO_ELASTIC_DUAL_HART *g_info_elastic*
require_cells INFO_DDR_WRITE_DMA    *info_write_dma_i*
require_cells INFO_DDR_DUMP         *dump_i*
require_cells INFO_DDR_READ_DMA     *dump_i/read_dma_i*
require_cells INFO_TX_FRAME_SLOTS   *dump_i/frame_fifo_i*
require_cells INFO_DONE_FORMATTER   *dump_i/done_formatter_i*
require_cells ETHERNET_SUBSYSTEM    *eth_i*

set forbidden_patterns {
  *instr_info_capture_dual_reference*
  *instr_crc*
  *crc_mix*
  *log_frame_packetizer*
  *waw_sequence_store*
  *waw_event_cdc*
}
foreach pattern $forbidden_patterns {
  set found [get_cells -quiet -hierarchical -filter "NAME =~ $pattern"]
  puts "AUDIT_FORBIDDEN pattern=$pattern count=[llength $found]"
  if {[llength $found] != 0} {
    error "Removed CRC/package-WAW block is still active: $found"
  }
}

set black_boxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
puts "AUDIT_BLACKBOX_COUNT [llength $black_boxes]"
foreach cell $black_boxes {
  puts "AUDIT_BLACKBOX $cell ref=[get_property REF_NAME $cell]"
}

report_utilization -hierarchical -file [file join $out_dir post_synth_utilization_hierarchical.rpt]
report_drc -file [file join $out_dir post_synth_drc.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
  -max_paths 50 -file [file join $out_dir post_synth_timing_summary.rpt]

puts "AUDIT_SYNTH_COMPLETE"
close_design
exit
