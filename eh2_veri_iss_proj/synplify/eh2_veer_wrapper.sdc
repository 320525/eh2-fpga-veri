# EH2 out-of-context timing target. The integrated design applies the same
# 20 ns core clock in constraints/eh2_dual_ddr_v19p.xdc.
create_clock -name core_clk -period 20.000 [get_ports {clk}]
set_false_path -from [get_ports {rst_l dbg_rst_l}]
