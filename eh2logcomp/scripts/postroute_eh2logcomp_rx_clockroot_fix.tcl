set root_dir D:/eh2_fpga/eh2logcomp
set in_dcp [file join $root_dir output board eh2logcomp_2slot_routed.dcp]
set out_dir [file join $root_dir output board]
set report_dir [file join $out_dir reports_final]
set out_dcp [file join $out_dir eh2logcomp_2slot_postroute_timing_fixed.dcp]
set bitstream [file join $out_dir eh2logcomp_2slot.bit]
file mkdir $report_dir

proc stage {message} { puts "RXCLK_FIX_STAGE: $message"; flush stdout }
proc severe_drc_violations {} {
  set result {}
  foreach violation [get_drc_violations -quiet] {
    set severity [get_property SEVERITY $violation]
    if {$severity eq "Error" || $severity eq "Critical Warning"} {
      lappend result $violation
    }
  }
  return $result
}

stage "open routed checkpoint"
set_param general.maxThreads 1
open_checkpoint $in_dcp

# Keep every data input IDELAY at the xcvu19p/333.333 MHz legal maximum.
set delay_cells [get_cells -quiet -hier -filter \
  {NAME =~ *delay_rgmii_rx_ctl || NAME =~ *delay_rgmii_rxd}]
if {[llength $delay_cells] != 5} {
  error "expected exactly five RGMII RX IDELAY cells"
}
set_property DELAY_VALUE 1100 $delay_cells

# Only the recovered RGMII RXC global clock net is changed.  The original X3Y2
# root gives -0.074 ns input hold.  A legal implemented-design sweep selected
# X2Y2 as the most balanced root (+0.254 ns external setup and +0.306 ns
# external hold).  Unroute, rebuild the clock gap tree, and route this one
# non-fixed clock net while preserving all placement and every other route.
set bufg_cells [get_cells -quiet -hier -filter \
  {NAME =~ *rgmii_interface/bufg_rgmii_rx_clk*}]
set rxclk_nets [get_nets -quiet -of_objects \
  [get_pins -quiet -of_objects $bufg_cells -filter {REF_PIN_NAME == O}]]
puts "RXCLK_FIX_BUFG_COUNT=[llength $bufg_cells] NET_COUNT=[llength $rxclk_nets]"
if {[llength $bufg_cells] != 1 || [llength $rxclk_nets] != 1} {
  error "expected one merged RGMII RXC BUFG/net"
}
set rxclk_net [lindex $rxclk_nets 0]
puts "RXCLK_FIX_BEFORE clock_root=[get_property CLOCK_ROOT $rxclk_net] user_clock_root=[get_property USER_CLOCK_ROOT $rxclk_net]"
set_property USER_CLOCK_ROOT X2Y2 $rxclk_net
route_design -unroute -nets $rxclk_net
update_clock_routing -net $rxclk_net
route_design -nets $rxclk_net
update_timing
puts "RXCLK_FIX_AFTER clock_root=[get_property CLOCK_ROOT $rxclk_net] user_clock_root=[get_property USER_CLOCK_ROOT $rxclk_net]"

stage "save timing-fixed checkpoint"
write_checkpoint -force $out_dcp

stage "sign-off reports"
report_route_status -file [file join $report_dir route_status.rpt]
report_timing_summary -delay_type min_max -max_paths 100 \
  -report_unconstrained -file [file join $report_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 100 -nworst 20 -path_type full \
  -file [file join $report_dir worst_setup_paths_full.rpt]
report_timing -delay_type min -max_paths 30 -nworst 20 -path_type full \
  -file [file join $report_dir worst_hold_paths_full.rpt]
set bus_skew_file [file join $report_dir bus_skew.rpt]
report_bus_skew -warn_on_violation -file $bus_skew_file
report_drc -file [file join $report_dir drc.rpt]

set route_status [report_route_status -return_string]
if {![regexp {# of nets with routing errors[^:]*:\s+0\s+:} $route_status]} {
  error "RX clock-root fixed design has routing errors"
}
set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
set setup_slack [get_property SLACK [lindex $setup_path 0]]
set hold_slack [get_property SLACK [lindex $hold_path 0]]
puts "RXCLK_FIX_TIMING setup_slack=$setup_slack hold_slack=$hold_slack"

set bus_skew_fp [open $bus_skew_file r]
set bus_skew_text [read $bus_skew_fp]
close $bus_skew_fp
if {[regexp {Slack \(VIOLATED\)} $bus_skew_text]} {
  error "RX clock-root fixed design has a bus-skew violation"
}
puts "RXCLK_FIX_BUS_SKEW_VIOLATIONS=0"

set severe_drc [severe_drc_violations]
puts "RXCLK_FIX_SEVERE_DRC_COUNT=[llength $severe_drc]"
if {[llength $severe_drc] != 0} {
  error "RX clock-root fixed design has Error/Critical Warning DRC violations: $severe_drc"
}
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
  error "RX clock-root fixed design still does not meet setup/hold timing"
}

stage "write uncompressed bitstream"
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
write_bitstream -force $bitstream
puts "RXCLK_FIX_PASS dcp=$out_dcp bitstream=$bitstream"
close_design
exit 0
