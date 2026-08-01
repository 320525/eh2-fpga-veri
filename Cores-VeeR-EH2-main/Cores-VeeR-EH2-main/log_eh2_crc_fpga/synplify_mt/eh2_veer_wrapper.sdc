# EH2 out-of-context 50 MHz core-clock constraint.
create_clock -name core_clk -period 20.000 [get_ports {clk}]
set_false_path -from [get_ports {rst_l dbg_rst_l}]
