set script_dir [file normalize [file dirname [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set proj_dir   [file normalize [file join $root_dir build vivado]]
set part_name  xcvu19p_CIV-fsva3824-1-e
set_param general.maxThreads 8
file mkdir $proj_dir

create_project -force eh2_veri_system $proj_dir -part $part_name
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property xsim.elaborate.mt_level 8 [get_filesets sim_1]

set package_file [file join $root_dir rtl common eh2_system_pkg.sv]
set interface_file [file join $root_dir rtl common axi4_if.sv]
add_files -norecurse [list $package_file $interface_file]
set rtl_files [glob -nocomplain \
  [file join $root_dir rtl common *.sv] \
  [file join $root_dir rtl control *.sv] \
  [file join $root_dir rtl crc *.sv] \
  [file join $root_dir rtl ddr *.sv] \
  [file join $root_dir rtl eh2 *.sv] \
  [file join $root_dir rtl eth *.sv] \
  [file join $root_dir rtl log *.sv] \
  [file join $root_dir rtl *.sv] \
  [file join $root_dir rtl eh2 *.v] \
  [file join $root_dir rtl eth *.v]]
set filtered_rtl {}
foreach f $rtl_files {
  if {$f ne $package_file && $f ne $interface_file} {
    lappend filtered_rtl $f
  }
}
add_files -norecurse $filtered_rtl

# The processor implementation is the board-verified dual-hart Synplify EDIF.
# The matching black-box stub supplies exact port widths to Vivado synthesis.
add_files -norecurse [file join $root_dir netlist eh2_veer_wrapper.edf]

set board_xdc    [file join $root_dir constraints eh2_dual_ddr_v19p.xdc]
set ethernet_xdc [file join $root_dir constraints ethernet_addon.xdc]
set phy_xdc      [file join $root_dir constraints rgmii_phy_timing.xdc]
set rx_place_xdc [file join $root_dir constraints rgmii_rx_clock_placement.xdc]
set tx_cdc_xdc   [file join $root_dir constraints tx_fifo_cdc.xdc]
add_files -fileset constrs_1 -norecurse [list \
  $board_xdc $ethernet_xdc $phy_xdc $rx_place_xdc $tx_cdc_xdc]

# Match the board-validated eth_tx project.  Both files query objects that are
# created by the TEMAC XCI constraints and therefore must run after the IP XDC.
set_property PROCESSING_ORDER LATE [get_files $phy_xdc]
set_property PROCESSING_ORDER LATE [get_files $rx_place_xdc]

# Import the exact board-validated MIG, TEMAC, MAC configuration ATG and
# program DataMover configurations from the four source projects.
import_ip -files D:/eh2_fpga/mac_fifo_dma_proj/mac_fifo_dma_proj.srcs/sources_1/ip/ddr4_0/ddr4_0.xci
copy_ip -name ddr4_1 [get_ips ddr4_0]
import_ip -files D:/eh2_fpga/eth_tx/eth_tx.srcs/sources_1/ip/tri_mode_ethernet_mac_0/tri_mode_ethernet_mac_0.xci
import_ip -files D:/eh2_fpga/mac_fifo_dma_proj/mac_fifo_dma_proj.srcs/sources_1/ip/axi_datamover_0/axi_datamover_0.xci

create_ip -name axi_traffic_gen -vendor xilinx.com -library ip -version 3.0 \
  -module_name axi_traffic_gen_0
set_property -dict [list \
  CONFIG.C_ATG_MODE {AXI4-Lite} \
  CONFIG.C_ATG_SYSINIT_MODES {System_Init} \
  CONFIG.C_M_AXI_DATA_WIDTH {32} \
  CONFIG.C_ATG_MIF_DATA_DEPTH {16} \
  CONFIG.C_ATG_SYSTEM_MAX_CHANNELS {1} \
  CONFIG.C_ATG_SYSTEM_CH1_LOW {0x00000000} \
  CONFIG.C_ATG_SYSTEM_CH1_HIGH {0x00000FFF} \
  CONFIG.C_ATG_SYSTEM_CMD_MAX_RETRY {256} \
  CONFIG.C_ATG_SYSTEM_TEST_MAX_CLKS {100000} \
  CONFIG.C_ATG_SYSTEM_INIT_ADDR_MIF [file join $root_dir init temac_init_addr.coe] \
  CONFIG.C_ATG_SYSTEM_INIT_DATA_MIF [file join $root_dir init temac_init_data.coe] \
  CONFIG.C_ATG_SYSTEM_INIT_MASK_MIF [file join $root_dir init temac_init_mask.coe] \
  CONFIG.C_ATG_SYSTEM_INIT_CTRL_MIF [file join $root_dir init temac_init_ctrl.coe] \
] [get_ips axi_traffic_gen_0]

proc configure_clock_converter {name width} {
  create_ip -name axi_clock_converter -vendor xilinx.com -library ip \
    -version 2.1 -module_name $name
  set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.ADDR_WIDTH {33} CONFIG.DATA_WIDTH $width CONFIG.ID_WIDTH {4} \
    CONFIG.ACLK_ASYNC {1} CONFIG.SYNCHRONIZATION_STAGES {3}] [get_ips $name]
}
configure_clock_converter axi_clock_converter_32 32
configure_clock_converter axi_clock_converter_64 64

proc configure_width_converter {name si_width} {
  create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
    -version 2.1 -module_name $name
  set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.ADDR_WIDTH {33} CONFIG.SI_DATA_WIDTH $si_width \
    CONFIG.MI_DATA_WIDTH {512} CONFIG.SI_ID_WIDTH {4} \
    CONFIG.ACLK_ASYNC {0} CONFIG.SYNCHRONIZATION_STAGES {3}] [get_ips $name]
}
configure_width_converter axi_dwidth_converter_32_512 32
configure_width_converter axi_dwidth_converter_64_512 64

# 256 consecutive 32-bit writes give the PRECONFIG data-DDR ATG exactly
# 1024 bytes of 0xFF at byte address zero, on the 50 MHz processor clock.
create_ip -name axi_traffic_gen -vendor xilinx.com -library ip -version 3.0 \
  -module_name data_test_atg
set_property -dict [list \
  CONFIG.C_ATG_MODE {AXI4-Lite} \
  CONFIG.C_ATG_SYSINIT_MODES {System_Init} \
  CONFIG.C_M_AXI_DATA_WIDTH {32} \
  CONFIG.C_ATG_MIF_DATA_DEPTH {256} \
  CONFIG.C_ATG_SYSTEM_MAX_CHANNELS {1} \
  CONFIG.C_ATG_SYSTEM_CH1_LOW {0x00000000} \
  CONFIG.C_ATG_SYSTEM_CH1_HIGH {0x000003FF} \
  CONFIG.C_ATG_SYSTEM_CMD_MAX_RETRY {256} \
  CONFIG.C_ATG_SYSTEM_TEST_MAX_CLKS {1000000} \
  CONFIG.C_ATG_SYSTEM_INIT_ADDR_MIF [file join $root_dir init data_test_atg_addr.coe] \
  CONFIG.C_ATG_SYSTEM_INIT_DATA_MIF [file join $root_dir init data_test_atg_data.coe] \
  CONFIG.C_ATG_SYSTEM_INIT_MASK_MIF [file join $root_dir init data_test_atg_mask.coe] \
  CONFIG.C_ATG_SYSTEM_INIT_CTRL_MIF [file join $root_dir init data_test_atg_ctrl.coe] \
] [get_ips data_test_atg]

generate_target all [get_ips]
export_ip_user_files -of_objects [get_ips] -no_script -sync -force -quiet

set_property top eh2_veri_system_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]

puts "PROJECT_CREATED=[file join $proj_dir eh2_veri_system.xpr]"
exit
