set root_dir [file normalize [file join [file dirname [file normalize [info script]]] ..]]
set report_dir [file join $root_dir reports]
file mkdir $report_dir
open_checkpoint [file join $root_dir checkpoints post_route.dcp]
report_clocks -file [file join $report_dir clocks.rpt]
report_clock_interaction -delay_type min_max \
  -file [file join $report_dir clock_interaction.rpt]
report_cdc -details -file [file join $report_dir clock_domain_cdc.rpt]
close_design
puts "ETH_TX_CLOCK_REPORTS_READY"

