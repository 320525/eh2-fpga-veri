# VeriTiger V19P-A14, matching eh2_veri_iss_proj LED and 50 MHz clock pins.
set_property PACKAGE_PIN BY44 [get_ports core_clk_p]
set_property PACKAGE_PIN CA44 [get_ports core_clk_n]
set_property IOSTANDARD LVDS [get_ports {core_clk_p core_clk_n}]
create_clock -period 20.000 -name core_clk [get_ports core_clk_p]

set_property PACKAGE_PIN BU21 [get_ports sw3_1]
set_property PACKAGE_PIN BU28 [get_ports sw4_1]
set_property IOSTANDARD LVCMOS12 [get_ports {sw3_1 sw4_1}]
set_property PULLDOWN true [get_ports {sw3_1 sw4_1}]

set_property PACKAGE_PIN BE22 [get_ports {led[0]}]
set_property PACKAGE_PIN BG23 [get_ports {led[1]}]
set_property PACKAGE_PIN BJ20 [get_ports {led[2]}]
set_property PACKAGE_PIN BN19 [get_ports {led[3]}]
set_property PACKAGE_PIN U34  [get_ports {led[4]}]
set_property PACKAGE_PIN T37  [get_ports {led[5]}]
set_property PACKAGE_PIN K37  [get_ports {led[6]}]
set_property PACKAGE_PIN M39  [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[*]}]
set_property DRIVE 8 [get_ports {led[*]}]

# Core/CRC clocks are related through the MMCM. Asynchronous FIFO constraints
# are supplied by XPM; the explicit false path covers only external reset pins.
set_false_path -from [get_ports {sw3_1 sw4_1}]
