set root_dir D:/eh2_fpga/eh2logcomp
set in_dcp [file join $root_dir output board eh2logcomp_2slot_routed.dcp]
set_param general.maxThreads 1
open_checkpoint $in_dcp
set cells [get_cells -quiet -hier -filter \
  {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk*}]
puts "RXCLK_QUERY_CELL_COUNT=[llength $cells]"
foreach cell $cells {
  set nets [get_nets -quiet -of_objects \
    [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == O}]]
  puts "RXCLK_CELL name=$cell loc=[get_property LOC $cell] nets=[llength $nets]"
  foreach net $nets {
    set loads [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == IN}]
    puts "RXCLK_NET name=$net loads=[llength $loads] clock_root=[get_property CLOCK_ROOT $net] user_clock_root=[get_property USER_CLOCK_ROOT $net] route_fixed=[get_property IS_ROUTE_FIXED $net]"
  }
}
close_design
exit 0
