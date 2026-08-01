# Batch Vivado build for the dual-thread Synplify EH2 netlist plus CRC logic.
set script_dir [file normalize [file dirname [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set build_dir  [file normalize [file join $root_dir vivado_build]]
set report_dir [file normalize [file join $build_dir reports]]
set out_dir    [file normalize [file join $build_dir output]]
file mkdir $build_dir
file mkdir $report_dir
file mkdir $out_dir

# Use the available host cores in Vivado phases that support multithreading.
# Eight is the supported/stable upper setting for this Vivado implementation
# flow on the 16-logical-CPU Windows host.
set_param general.maxThreads 8

# Match the reference eh2_veri_iss_proj implementation target.  Synplify maps
# the EH2 netlist against XCVU19P-FSVA3824-1-e, while Vivado implements that
# equivalent netlist on the restricted CIV part installed for the V19P board.
set part_name xcvu19p_CIV-fsva3824-1-e
create_project -in_memory -part $part_name

# The processor itself is the dual-hart Synplify EDIF.  Only the surrounding
# memory, commit hash, FIFO, reducer, clock/reset and LED logic are synthesized
# by Vivado.
read_edif [file join $root_dir synplify_mt rev_mt eh2_veer_wrapper.edf]
read_verilog -sv [list \
    [file join $root_dir rtl eh2_veer_wrapper_mt_stub.v] \
    [file join $root_dir rtl crc64_ecma_pair_160.sv] \
    [file join $root_dir rtl instr_crc_hash_dual.sv] \
    [file join $root_dir rtl crc_pair_fifo_async_4w1r.sv] \
    [file join $root_dir rtl crc_mix_accumulator.sv] \
    [file join $root_dir rtl instr_crc_system_dual.sv] \
    [file join $root_dir rtl eh2_unified_axi_bram.sv] \
    [file join $root_dir rtl eh2_crc_soc.sv] \
    [file join $script_dir eh2_crc_fpga_top.sv]]

set mem_file [file join $root_dir programs trace_1000_jump trace_1000_jump.mem64]
add_files -norecurse $mem_file
set_property FILE_TYPE "Memory Initialization Files" [get_files $mem_file]
read_xdc [file join $script_dir eh2_crc_fpga_v19p.xdc]

set_msg_config -id {Synth 8-3331} -limit 200
synth_design -top eh2_crc_fpga_top -part $part_name \
    -directive PerformanceOptimized -flatten_hierarchy rebuilt
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -hierarchical -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir post_synth_timing_summary.rpt]

opt_design -directive Explore
place_design -directive ExtraNetDelay_high
write_checkpoint -force [file join $out_dir pre_physopt_place.dcp]
report_timing_summary -delay_type max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir pre_physopt_place_timing_summary.rpt]
phys_opt_design -directive Explore
write_checkpoint -force [file join $out_dir post_place.dcp]
report_timing_summary -delay_type max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir post_place_timing_summary.rpt]

route_design -directive AggressiveExplore
write_checkpoint -force [file join $out_dir pre_physopt_route.dcp]
phys_opt_design -directive Explore
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -hierarchical -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 50 \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]
report_cdc -details -file [file join $report_dir cdc.rpt]
report_drc -file [file join $report_dir drc.rpt]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force [file join $out_dir eh2_crc_fpga_top.bit]
write_debug_probes -force [file join $out_dir eh2_crc_fpga_top.ltx]
puts "BITSTREAM_BUILD_COMPLETE [file join $out_dir eh2_crc_fpga_top.bit]"
