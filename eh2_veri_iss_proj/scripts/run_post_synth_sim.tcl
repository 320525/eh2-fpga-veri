set root_dir [file normalize [file join [file dirname [info script]] ..]]
set proj_dir [file join $root_dir build post_synth_sim]
set report_dir [file join $root_dir reports]
file mkdir $proj_dir
file mkdir $report_dir

create_project -force eh2_post_synth $proj_dir -part xcvu19p_CIV-fsva3824-1-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

set eh2_root D:/eh2_fpga/source/eh2_design
set eh2_files [list \
  $eh2_root/include/eh2_def.sv \
  $eh2_root/eh2_veer_wrapper.sv $eh2_root/eh2_mem.sv \
  $eh2_root/eh2_pic_ctrl.sv $eh2_root/eh2_veer.sv $eh2_root/eh2_dma_ctrl.sv \
  $eh2_root/ifu/eh2_ifu_aln_ctl.sv $eh2_root/ifu/eh2_ifu_compress_ctl.sv \
  $eh2_root/ifu/eh2_ifu_ifc_ctl.sv $eh2_root/ifu/eh2_ifu_bp_ctl.sv \
  $eh2_root/ifu/eh2_ifu_ic_mem.sv $eh2_root/ifu/eh2_ifu_mem_ctl.sv \
  $eh2_root/ifu/eh2_ifu_iccm_mem.sv $eh2_root/ifu/eh2_ifu_btb_mem.sv \
  $eh2_root/ifu/eh2_ifu.sv \
  $eh2_root/dec/eh2_dec_decode_ctl.sv $eh2_root/dec/eh2_dec_gpr_ctl.sv \
  $eh2_root/dec/eh2_dec_ib_ctl.sv $eh2_root/dec/eh2_dec_tlu_ctl.sv \
  $eh2_root/dec/eh2_dec_tlu_top.sv $eh2_root/dec/eh2_dec_csr.sv \
  $eh2_root/dec/eh2_dec_trigger.sv $eh2_root/dec/eh2_dec.sv \
  $eh2_root/exu/eh2_exu_alu_ctl.sv $eh2_root/exu/eh2_exu_mul_ctl.sv \
  $eh2_root/exu/eh2_exu_div_ctl.sv $eh2_root/exu/eh2_exu.sv \
  $eh2_root/lsu/eh2_lsu.sv $eh2_root/lsu/eh2_lsu_clkdomain.sv \
  $eh2_root/lsu/eh2_lsu_addrcheck.sv $eh2_root/lsu/eh2_lsu_lsc_ctl.sv \
  $eh2_root/lsu/eh2_lsu_stbuf.sv $eh2_root/lsu/eh2_lsu_bus_buffer.sv \
  $eh2_root/lsu/eh2_lsu_bus_intf.sv $eh2_root/lsu/eh2_lsu_ecc.sv \
  $eh2_root/lsu/eh2_lsu_dccm_mem.sv $eh2_root/lsu/eh2_lsu_dccm_ctl.sv \
  $eh2_root/lsu/eh2_lsu_trigger.sv $eh2_root/lsu/eh2_lsu_amo.sv \
  $eh2_root/dbg/eh2_dbg.sv $eh2_root/dmi/dmi_wrapper.v \
  $eh2_root/dmi/dmi_jtag_to_core_sync.v $eh2_root/dmi/rvjtag_tap.v \
  $eh2_root/lib/eh2_lib.sv $eh2_root/lib/beh_lib.sv \
  $eh2_root/lib/mem_lib.sv $eh2_root/lib/ahb_to_axi4.sv \
  $eh2_root/lib/axi4_to_ahb.sv $eh2_root/eh2_pdef.vh \
  $eh2_root/eh2_param.vh $eh2_root/common_defines.vh \
  $eh2_root/pd_defines.vh $eh2_root/pic_map_auto.h]
add_files -norecurse $eh2_files
set_property file_type SystemVerilog [get_files [list \
  $eh2_root/dmi/dmi_wrapper.v $eh2_root/dmi/dmi_jtag_to_core_sync.v \
  $eh2_root/dmi/rvjtag_tap.v]]

set synth_sources [list \
  [file join $root_dir rtl axi4_if.sv] \
  [file join $root_dir rtl axi_owner_mux2.sv] \
  [file join $root_dir rtl ddr_result_checker.sv] \
  [file join $root_dir rtl eh2_hw_init.sv] \
  [file join $root_dir rtl axi32_to_512_cdc.sv] \
  [file join $root_dir rtl axi64_to_512_cdc.sv] \
  [file join $root_dir rtl eh2_core_wrapper_hw.sv] \
  [file join $root_dir rtl eh2_dual_ddr_top.sv] \
  [file join $root_dir sim axi_ram_model_512.sv] \
  [file join $root_dir sim ddr4_axi_stub.sv]]
add_files -norecurse $synth_sources
set_property file_type SystemVerilog [get_files $synth_sources]
set_property include_dirs [list \
  $eh2_root $eh2_root/include $eh2_root/ifu $eh2_root/dec $eh2_root/exu \
  $eh2_root/lsu $eh2_root/dbg $eh2_root/dmi $eh2_root/lib] \
  [get_filesets sources_1]

# Replace the EH2 RTL implementation with the Synplify EDIF for synthesis.
# The RTL remains in the project only as a behavioral-simulation source.
source [file join [file dirname [info script]] synplify_netlist_common.tcl]
synplify_netlist::configure $root_dir
synplify_netlist::validate $root_dir

set ip_root [file join $root_dir build vivado eh2_dual_ddr.srcs sources_1 ip]
foreach ip_name {atg_program atg_data axi_clock_converter_32 \
                 axi_clock_converter_64 axi_dwidth_converter_32_512 \
                 axi_dwidth_converter_64_512} {
  add_files -norecurse [file join $ip_root $ip_name ${ip_name}.xci]
}

set_property top eh2_dual_ddr_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
# Gate-level functional simulation of the complete 128 KiB scrub takes many
# tens of hours. The production RTL defaults remain unchanged; this dedicated
# netlist uses 32 writes per TCM to verify synthesis preservation of the DMA,
# debug-resume and first-fetch sequence in a practical runtime.
set_property generic {HW_INIT_DCCM_LAST=32'hf00400f8 HW_INIT_ICCM_LAST=32'hee0000f8} \
  [get_filesets sources_1]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "POST_SYNTH_STATUS=$synth_status"
if {![string match "*Complete*" $synth_status]} {
  error "Post-synthesis simulation netlist synthesis failed: $synth_status"
}

set tb [file join $root_dir sim eh2_dual_ddr_post_synth_tb.sv]
add_files -fileset sim_1 -norecurse $tb
set_property file_type SystemVerilog [get_files $tb]
set_property top eh2_dual_ddr_post_synth_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode post-synthesis -type functional
set sim_log [file join $proj_dir eh2_post_synth.sim sim_1 synth func xsim simulate.log]
close_sim
file copy -force $sim_log [file join $report_dir system_post_synth_sim.log]
puts "POST_SYNTH_SIM_COMPLETE"
close_project
