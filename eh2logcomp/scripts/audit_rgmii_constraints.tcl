# Read-only audit of the routed checkpoint's RGMII timing objects.

if {$argc != 2} {
  error "usage: audit_rgmii_constraints.tcl <routed_dcp> <output_dir>"
}

set dcp_path [file normalize [lindex $argv 0]]
set out_dir  [file normalize [lindex $argv 1]]
file mkdir $out_dir
set_param general.maxThreads 2
open_checkpoint $dcp_path

set tx_ports [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
set txc_port [get_ports rgmii_txc]

set audit [open [file join $out_dir rgmii_constraint_objects.txt] w]
puts $audit "CLOCKS_ON_RGMII_TXC"
foreach clk [get_clocks -quiet -of_objects $txc_port] {
  puts $audit "CLOCK=[get_property NAME $clk] PERIOD=[get_property PERIOD $clk] IS_GENERATED=[get_property IS_GENERATED $clk]"
}

puts $audit "\nOUTPUT_DELAYS"
if {[catch {set delays [get_output_delays -quiet -of_objects $tx_ports]} delay_error]} {
  puts $audit "GET_OUTPUT_DELAYS_ERROR=$delay_error"
} else {
  puts $audit "OUTPUT_DELAY_COUNT=[llength $delays]"
  foreach delay $delays {
    puts $audit "--- [get_property NAME $delay] ---"
    puts $audit [report_property -return_string $delay]
  }
}
close $audit

report_timing -to $tx_ports -delay_type max -max_paths 20 -nworst 4 \
  -file [file join $out_dir rgmii_tx_setup.rpt]
report_timing -to $tx_ports -delay_type min -max_paths 20 -nworst 4 \
  -file [file join $out_dir rgmii_tx_hold.rpt]
check_timing -override_defaults {no_output_delay partial_output_delay} \
  -verbose -file [file join $out_dir rgmii_tx_check_timing.rpt]

close_design
puts "RGMII_CONSTRAINT_AUDIT_PASS output=$out_dir"
exit 0
