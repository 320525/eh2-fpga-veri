
#1001 : create_clock -name core_clk -period 20.000 [get_ports clk]
# line 2 in d:/eh2_fpga/cores-veer-eh2-main/cores-veer-eh2-main/fpga_eh2_synplify/eh2_veer_wrapper.sdc

create_clock -name {core_clk} -period {20.000} [get_ports {clk}]

#1003 : automatically generated

create_clock -name {eh2_veer_wrapper|jtag_tck} -period {20.000} [get_ports {jtag_tck}]


#1002 : set_false_path -from [get_ports {rst_l dbg_rst_l}]
# line 3 in d:/eh2_fpga/cores-veer-eh2-main/cores-veer-eh2-main/fpga_eh2_synplify/eh2_veer_wrapper.sdc

set_false_path -from [get_ports {rst_l dbg_rst_l}]


#1004 : automatically generated

set_clock_groups -name {Inferred_clkgroup_0} -asynchronous -group [get_clocks {eh2_veer_wrapper|jtag_tck}]

set_property ASYNC_REG TRUE [get_cells {dmi_wrapper/i_dmi_jtag_to_core_sync/wren[1]}]
set_property ASYNC_REG TRUE [get_cells {dmi_wrapper/i_dmi_jtag_to_core_sync/wren[0]}]
set_property ASYNC_REG TRUE [get_cells {dmi_wrapper/i_dmi_jtag_to_core_sync/rden[1]}]
set_property ASYNC_REG TRUE [get_cells {dmi_wrapper/i_dmi_jtag_to_core_sync/rden[0]}]


#Constraints which are not forward annotated in XDC and intentionally commented out (unused and unsupported constraints)

#User specified region constraints
