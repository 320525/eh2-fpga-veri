set root_dir [file normalize [file join [file dirname [info script]] ..]]
set ip_dir [file join $root_dir eth_tx.srcs sources_1 ip]

create_project -in_memory -part xcvu19p_CIV-fsva3824-1-e
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

if {![file exists [file join $ip_dir tx_axi_traffic_gen tx_axi_traffic_gen.xci]]} {
  create_ip -name axi_traffic_gen -vendor xilinx.com -library ip \
    -version 3.0 -module_name tx_axi_traffic_gen -dir $ip_dir
  set_property -dict [list \
    CONFIG.C_ATG_MODE {AXI4-Stream} \
    CONFIG.C_AXIS_MODE {Master Only} \
    CONFIG.C_AXIS_TDATA_WIDTH {8} \
    CONFIG.C_AXIS_TUSER_WIDTH {1} \
    CONFIG.C_AXIS_TID_WIDTH {1} \
    CONFIG.C_AXIS_TDEST_WIDTH {1} \
    CONFIG.C_AXIS_SPARSE_EN {false} \
    CONFIG.C_AXIS1_HAS_TKEEP {false} \
    CONFIG.C_AXIS1_HAS_TSTRB {false} \
    CONFIG.STRM_DATA_SEED {0x0001} \
    CONFIG.CLOCK.FREQ_HZ {100000000}] \
    [get_ips tx_axi_traffic_gen]
  generate_target all [get_ips tx_axi_traffic_gen]
}

if {![file exists [file join $ip_dir tx_control_atg tx_control_atg.xci]]} {
  create_ip -name axi_traffic_gen -vendor xilinx.com -library ip \
    -version 3.0 -module_name tx_control_atg -dir $ip_dir
  set_property -dict [list \
    CONFIG.C_ATG_MODE {AXI4-Lite} \
    CONFIG.C_ATG_SYSINIT_MODES {System_Init} \
    CONFIG.C_ATG_MIF_DATA_DEPTH {16} \
    CONFIG.C_ATG_SYSTEM_MAX_CHANNELS {1} \
    CONFIG.C_ATG_SYSTEM_CH1_LOW {0x00000000} \
    CONFIG.C_ATG_SYSTEM_CH1_HIGH {0x00000FFF} \
    CONFIG.C_ATG_SYSTEM_TEST_MAX_CLKS {100000} \
    CONFIG.C_ATG_SYSTEM_CMD_MAX_RETRY {256} \
    CONFIG.C_ATG_SYSTEM_INIT_DATA_MIF \
      [file join $root_dir tx_config tx_atg_init_data.coe] \
    CONFIG.C_ATG_SYSTEM_INIT_ADDR_MIF \
      [file join $root_dir tx_config tx_atg_init_addr.coe] \
    CONFIG.C_ATG_SYSTEM_INIT_MASK_MIF \
      [file join $root_dir tx_config tx_atg_init_mask.coe] \
    CONFIG.C_ATG_SYSTEM_INIT_CTRL_MIF \
      [file join $root_dir tx_config tx_atg_init_ctrl.coe] \
    CONFIG.CLOCK.FREQ_HZ {100000000}] \
    [get_ips tx_control_atg]
  generate_target all [get_ips tx_control_atg]
}

puts "AUX_IP_GENERATION_COMPLETE"
exit 0
