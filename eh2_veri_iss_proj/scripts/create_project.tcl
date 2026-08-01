set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file dirname $script_dir]
set proj_dir   [file join $root_dir build vivado]
set part_name  xcvu19p_CIV-fsva3824-1-e
file mkdir $proj_dir

create_project -force eh2_dual_ddr $proj_dir -part $part_name
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

set eh2_root D:/eh2_fpga/source/eh2_design
set eh2_files [list \
  $eh2_root/include/eh2_def.sv \
  $eh2_root/eh2_veer_wrapper.sv \
  $eh2_root/eh2_mem.sv \
  $eh2_root/eh2_pic_ctrl.sv \
  $eh2_root/eh2_veer.sv \
  $eh2_root/eh2_dma_ctrl.sv \
  $eh2_root/ifu/eh2_ifu_aln_ctl.sv \
  $eh2_root/ifu/eh2_ifu_compress_ctl.sv \
  $eh2_root/ifu/eh2_ifu_ifc_ctl.sv \
  $eh2_root/ifu/eh2_ifu_bp_ctl.sv \
  $eh2_root/ifu/eh2_ifu_ic_mem.sv \
  $eh2_root/ifu/eh2_ifu_mem_ctl.sv \
  $eh2_root/ifu/eh2_ifu_iccm_mem.sv \
  $eh2_root/ifu/eh2_ifu_btb_mem.sv \
  $eh2_root/ifu/eh2_ifu.sv \
  $eh2_root/dec/eh2_dec_decode_ctl.sv \
  $eh2_root/dec/eh2_dec_gpr_ctl.sv \
  $eh2_root/dec/eh2_dec_ib_ctl.sv \
  $eh2_root/dec/eh2_dec_tlu_ctl.sv \
  $eh2_root/dec/eh2_dec_tlu_top.sv \
  $eh2_root/dec/eh2_dec_csr.sv \
  $eh2_root/dec/eh2_dec_trigger.sv \
  $eh2_root/dec/eh2_dec.sv \
  $eh2_root/exu/eh2_exu_alu_ctl.sv \
  $eh2_root/exu/eh2_exu_mul_ctl.sv \
  $eh2_root/exu/eh2_exu_div_ctl.sv \
  $eh2_root/exu/eh2_exu.sv \
  $eh2_root/lsu/eh2_lsu.sv \
  $eh2_root/lsu/eh2_lsu_clkdomain.sv \
  $eh2_root/lsu/eh2_lsu_addrcheck.sv \
  $eh2_root/lsu/eh2_lsu_lsc_ctl.sv \
  $eh2_root/lsu/eh2_lsu_stbuf.sv \
  $eh2_root/lsu/eh2_lsu_bus_buffer.sv \
  $eh2_root/lsu/eh2_lsu_bus_intf.sv \
  $eh2_root/lsu/eh2_lsu_ecc.sv \
  $eh2_root/lsu/eh2_lsu_dccm_mem.sv \
  $eh2_root/lsu/eh2_lsu_dccm_ctl.sv \
  $eh2_root/lsu/eh2_lsu_trigger.sv \
  $eh2_root/lsu/eh2_lsu_amo.sv \
  $eh2_root/dbg/eh2_dbg.sv \
  $eh2_root/dmi/dmi_wrapper.v \
  $eh2_root/dmi/dmi_jtag_to_core_sync.v \
  $eh2_root/dmi/rvjtag_tap.v \
  $eh2_root/lib/eh2_lib.sv \
  $eh2_root/lib/beh_lib.sv \
  $eh2_root/lib/mem_lib.sv \
  $eh2_root/lib/ahb_to_axi4.sv \
  $eh2_root/lib/axi4_to_ahb.sv \
  $eh2_root/eh2_pdef.vh \
  $eh2_root/eh2_param.vh \
  $eh2_root/common_defines.vh \
  $eh2_root/pd_defines.vh \
  $eh2_root/pic_map_auto.h]
add_files -norecurse $eh2_files
set_property file_type SystemVerilog [get_files [list \
  $eh2_root/dmi/dmi_wrapper.v \
  $eh2_root/dmi/dmi_jtag_to_core_sync.v \
  $eh2_root/dmi/rvjtag_tap.v]]

set local_rtl [list \
  [file join $root_dir rtl axi4_if.sv] \
  [file join $root_dir rtl axi_owner_mux2.sv] \
  [file join $root_dir rtl ddr_result_checker.sv] \
  [file join $root_dir rtl eh2_hw_init.sv] \
  [file join $root_dir rtl axi32_to_512_cdc.sv] \
  [file join $root_dir rtl axi64_to_512_cdc.sv] \
  [file join $root_dir rtl eh2_core_wrapper_hw.sv] \
  [file join $root_dir rtl eh2_dual_ddr_top.sv]]
add_files -norecurse $local_rtl
set_property file_type SystemVerilog [get_files $local_rtl]
set_property include_dirs [list \
  $eh2_root $eh2_root/include $eh2_root/ifu $eh2_root/dec $eh2_root/exu \
  $eh2_root/lsu $eh2_root/dbg $eh2_root/dmi $eh2_root/lib] [get_filesets sources_1]

add_files -fileset constrs_1 -norecurse [file join $root_dir constraints eh2_dual_ddr_v19p.xdc]

# Import the known-good MAC-project MIG and clone it for the second SODIMM.
import_ip -files D:/eh2_fpga/mac_fifo_dma_proj/mac_fifo_dma_proj.srcs/sources_1/ip/ddr4_0/ddr4_0.xci
copy_ip -name ddr4_1 [get_ips ddr4_0]

proc configure_atg {name addr_file data_file mask_file ctrl_file} {
  create_ip -name axi_traffic_gen -vendor xilinx.com -library ip -version 3.0 -module_name $name
  set_property -dict [list \
    CONFIG.C_ATG_MODE {AXI4-Lite} \
    CONFIG.C_ATG_SYSINIT_MODES {System_Init} \
    CONFIG.C_M_AXI_DATA_WIDTH {32} \
    CONFIG.C_ATG_MIF_DATA_DEPTH {32} \
    CONFIG.C_ATG_SYSTEM_MAX_CHANNELS {1} \
    CONFIG.C_ATG_SYSTEM_CH1_LOW {0x00000000} \
    CONFIG.C_ATG_SYSTEM_CH1_HIGH {0x0001FFFF} \
    CONFIG.C_ATG_SYSTEM_CMD_MAX_RETRY {256} \
    CONFIG.C_ATG_SYSTEM_TEST_MAX_CLKS {100000} \
    CONFIG.C_ATG_SYSTEM_INIT_ADDR_MIF $addr_file \
    CONFIG.C_ATG_SYSTEM_INIT_DATA_MIF $data_file \
    CONFIG.C_ATG_SYSTEM_INIT_MASK_MIF $mask_file \
    CONFIG.C_ATG_SYSTEM_INIT_CTRL_MIF $ctrl_file] [get_ips $name]
}

configure_atg atg_program \
  [file join $root_dir init atg_program_addr.coe] \
  [file join $root_dir init atg_program_data.coe] \
  [file join $root_dir init atg_program_mask.coe] \
  [file join $root_dir init atg_program_ctrl.coe]
configure_atg atg_data \
  [file join $root_dir init atg_data_addr.coe] \
  [file join $root_dir init atg_data_data.coe] \
  [file join $root_dir init atg_data_mask.coe] \
  [file join $root_dir init atg_data_ctrl.coe]

proc configure_clock_converter {name width} {
  create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name $name
  set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.ADDR_WIDTH {33} CONFIG.DATA_WIDTH $width CONFIG.ID_WIDTH {4} \
    CONFIG.ACLK_ASYNC {1} CONFIG.SYNCHRONIZATION_STAGES {3}] [get_ips $name]
}
configure_clock_converter axi_clock_converter_32 32
configure_clock_converter axi_clock_converter_64 64

proc configure_width_converter {name si_width} {
  create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip -version 2.1 -module_name $name
  set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.ADDR_WIDTH {33} CONFIG.SI_DATA_WIDTH $si_width \
    CONFIG.MI_DATA_WIDTH {512} CONFIG.SI_ID_WIDTH {4} \
    CONFIG.ACLK_ASYNC {0} CONFIG.SYNCHRONIZATION_STAGES {3}] [get_ips $name]
}
configure_width_converter axi_dwidth_converter_32_512 32
configure_width_converter axi_dwidth_converter_64_512 64

generate_target all [get_ips]
export_ip_user_files -of_objects [get_ips] -no_script -sync -force -quiet

set_property top eh2_dual_ddr_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]

# If the Synplify block netlist already exists, use it for synthesis while
# retaining the EH2 RTL sources for behavioral simulation.
set synplify_netlist [file join $root_dir build synplify rev_1 eh2_veer_wrapper.edf]
if {[file exists $synplify_netlist]} {
  source [file join $script_dir synplify_netlist_common.tcl]
  synplify_netlist::configure $root_dir
  synplify_netlist::validate $root_dir
  update_compile_order -fileset sources_1
  update_compile_order -fileset sim_1
}
puts "PROJECT_CREATED=[file join $proj_dir eh2_dual_ddr.xpr]"
exit
