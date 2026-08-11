# Direct project-mode synthesis.  This bypasses the Windows Run Server while
# retaining Vivado's project-managed XCI source expansion and constraint order.

set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set project    [file join $root_dir build vivado eh2_veri_system.xpr]
set run_dir    [file join $root_dir build vivado eh2_veri_system.runs synth_1]

# Direct synth_design does not create the project-mode run directory.  Create
# it explicitly before any post-synthesis reports or checkpoints are written.
file mkdir $run_dir

open_project $project
foreach ip_name {
  axi_clock_converter_32
  axi_clock_converter_64
  axi_dwidth_converter_32_512
  axi_dwidth_converter_64_512
  axi_traffic_gen_0
  data_test_atg
} {
  set xci [get_files -quiet -all */${ip_name}.xci]
  set_property GENERATE_SYNTH_CHECKPOINT 0 $xci
  # With checkpoint generation disabled Vivado must compile the generated
  # synthesis RTL.  Do not also compile the generated black-box declaration:
  # its later module definition would overwrite the real implementation.
  set generated_stub [get_files -quiet -all \
    *eh2_veri_system.gen/sources_1/ip/${ip_name}/${ip_name}_stub.v]
  if {[llength $generated_stub]} {
    remove_files $generated_stub
  }
  set manual_stub [get_files -quiet -all *ooc_synth_stubs/${ip_name}_stub.v]
  if {[llength $manual_stub]} {
    remove_files $manual_stub
  }
}

# The validated J20/J22 board cannot use TEMAC's stock TXC ODELAY/IDELAY
# cascade because RXD3 occupies the adjacent BITSLICE.  Restore the exact
# board-validated eth_tx/mac_fifo_dma_proj physical interface after any IP
# regeneration.  The board copy is a template, not a second compiled module.
set board_rgmii_if [file join $root_dir rtl eth \
  tri_mode_ethernet_mac_0_rgmii_v2_0_if_board.v]
set generated_rgmii_if [file join $root_dir build vivado \
  eh2_veri_system.gen sources_1 ip tri_mode_ethernet_mac_0 synth physical \
  tri_mode_ethernet_mac_0_rgmii_v2_0_if.v]
file copy -force $board_rgmii_if $generated_rgmii_if
set board_rgmii_file_object [get_files -quiet -all $board_rgmii_if]
if {[llength $board_rgmii_file_object]} {
  remove_files $board_rgmii_file_object
}
update_compile_order -fileset sources_1

synth_design -top eh2_veri_system_top \
  -part xcvu19p_CIV-fsva3824-1-e \
  -directive PerformanceOptimized \
  -fsm_extraction one_hot \
  -keep_equivalent_registers \
  -resource_sharing off \
  -no_lc \
  -shreg_min_size 5

set blackboxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
set unresolved_system_blackboxes {}
set deferred_vivado_blackboxes {}
foreach blackbox $blackboxes {
  # Vivado inserts dbg_hub as a synthesis-stage placeholder and expands it
  # during implementation.  It is not a user/IP module; every other black box
  # is a hard synthesis failure.  The implementation script checks that even
  # dbg_hub is fully resolved after opt_design.
  if {$blackbox eq "dbg_hub" && [string match "dbg_hub*" [get_property REF_NAME $blackbox]]} {
    lappend deferred_vivado_blackboxes $blackbox
  } else {
    lappend unresolved_system_blackboxes $blackbox
  }
}
set blackbox_report [open [file join $run_dir eh2_veri_system_top_blackboxes.rpt] w]
puts $blackbox_report "BLACKBOX_COUNT=[llength $blackboxes]"
puts $blackbox_report "UNRESOLVED_SYSTEM_BLACKBOX_COUNT=[llength $unresolved_system_blackboxes]"
puts $blackbox_report "DEFERRED_VIVADO_BLACKBOX_COUNT=[llength $deferred_vivado_blackboxes]"
foreach blackbox $blackboxes {
  puts $blackbox_report "$blackbox REF_NAME=[get_property REF_NAME $blackbox]"
}
close $blackbox_report
puts "BLACKBOX_COUNT=[llength $blackboxes]"
puts "UNRESOLVED_SYSTEM_BLACKBOX_COUNT=[llength $unresolved_system_blackboxes]"
puts "DEFERRED_VIVADO_BLACKBOX_COUNT=[llength $deferred_vivado_blackboxes]"
if {[llength $unresolved_system_blackboxes] != 0} {
  error "Synthesis contains unresolved black boxes; see eh2_veri_system_top_blackboxes.rpt"
}

write_checkpoint -force -noxdef [file join $run_dir eh2_veri_system_top.dcp]
report_utilization -file [file join $run_dir eh2_veri_system_top_utilization_synth.rpt]
report_utilization -hierarchical -hierarchical_depth 6 \
  -file [file join $run_dir eh2_veri_system_top_utilization_hierarchical_synth.rpt]
report_timing_summary -file [file join $run_dir eh2_veri_system_top_timing_synth.rpt]

puts "SYNTHESIS_DIRECT_COMPLETE"
close_project
exit
