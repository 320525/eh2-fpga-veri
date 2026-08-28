set root_dir D:/eh2_fpga/eh2logcomp
set in_dcp [file join $root_dir output board eh2logcomp_2slot_routed.dcp]
set_param general.maxThreads 1

# Scan roots between the current X3Y2 tree (late clock: setup good/hold bad)
# and X0Y1 (early clock: setup bad/hold good).  Every candidate starts from
# the untouched routed checkpoint.  No candidate is saved or used for a bit.
set candidates {X3Y1 X2Y2 X2Y1 X1Y2 X1Y1}
foreach candidate $candidates {
  puts "RXCLK_SWEEP_BEGIN root=$candidate"
  flush stdout
  open_checkpoint $in_dcp
  set delay_cells [get_cells -quiet -hier -filter \
    {NAME =~ *delay_rgmii_rx_ctl || NAME =~ *delay_rgmii_rxd}]
  set_property DELAY_VALUE 1100 $delay_cells
  set bufg_cells [get_cells -quiet -hier -filter \
    {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk*}]
  set rxclk_net [lindex [get_nets -quiet -of_objects \
    [get_pins -quiet -of_objects $bufg_cells -filter {REF_PIN_NAME == O}]] 0]

  set candidate_error ""
  if {[catch {
    set_property USER_CLOCK_ROOT $candidate $rxclk_net
    route_design -unroute -nets $rxclk_net
    update_clock_routing -net $rxclk_net
    route_design -nets $rxclk_net
    update_timing
  } candidate_error]} {
    puts "RXCLK_SWEEP_FAIL root=$candidate error=$candidate_error"
    close_design
    continue
  }

  set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
  set hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
  set input_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
  set ext_setup_path [get_timing_paths -quiet -from $input_ports \
    -delay_type max -max_paths 1]
  set ext_hold_path [get_timing_paths -quiet -from $input_ports \
    -delay_type min -max_paths 1]
  set setup_slack [get_property SLACK [lindex $setup_path 0]]
  set hold_slack [get_property SLACK [lindex $hold_path 0]]
  set ext_setup_slack [get_property SLACK [lindex $ext_setup_path 0]]
  set ext_hold_slack [get_property SLACK [lindex $ext_hold_path 0]]
  set route_status [report_route_status -return_string]
  set route_ok [regexp {# of nets with routing errors[^:]*:\s+0\s+:} $route_status]
  puts "RXCLK_SWEEP_RESULT root=$candidate actual_root=[get_property CLOCK_ROOT $rxclk_net] setup=$setup_slack hold=$hold_slack ext_setup=$ext_setup_slack ext_hold=$ext_hold_slack route_ok=$route_ok"
  flush stdout
  close_design
}
puts "RXCLK_SWEEP_DONE"
exit 0
