# Apply the reviewed control-clock/RGMII-RX asynchronous relationship to the
# routed design, save a constraint-complete DCP, and regenerate affected
# sign-off reports. No netlist, placement, or routing operation is performed.

if {$argc != 3} {
  error "usage: apply_final_async_constraint.tcl <input.dcp> <output.dcp> <report_dir>"
}

set input_dcp  [file normalize [lindex $argv 0]]
set output_dcp [file normalize [lindex $argv 1]]
set report_dir [file normalize [lindex $argv 2]]
file mkdir $report_dir
set_param general.maxThreads 4

open_checkpoint $input_dcp

set ctrl_clock_domain [get_clocks -quiet -include_generated_clocks atg_clk]
set rgmii_rx_clock_domain [get_clocks -quiet -include_generated_clocks rgmii_rxc]
if {[llength $ctrl_clock_domain] == 0 || [llength $rgmii_rx_clock_domain] == 0} {
  error "required atg_clk or rgmii_rxc clock domain is missing"
}

puts "FINAL_ASYNC_CTRL_CLOCKS=[llength $ctrl_clock_domain]"
puts "FINAL_ASYNC_RGMII_RX_CLOCKS=[llength $rgmii_rx_clock_domain]"
set_clock_groups -asynchronous \
  -group $ctrl_clock_domain \
  -group $rgmii_rx_clock_domain

report_timing_summary -delay_type min_max -max_paths 100 \
  -report_unconstrained -file [file join $report_dir timing_summary.rpt]
report_clock_interaction -delay_type min_max \
  -file [file join $report_dir clock_interaction.rpt]
report_cdc -details -file [file join $report_dir cdc.rpt]
report_methodology -file [file join $report_dir methodology.rpt]

write_checkpoint -force $output_dcp
puts "FINAL_ASYNC_CONSTRAINT_PASS output=$output_dcp"
close_design
exit 0
