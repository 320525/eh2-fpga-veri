set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set proj_file  [file join $root_dir project eth_tx.xpr]

open_project $proj_file
set_property top eth_tx_core_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project

set sim_log [file join $root_dir project eth_tx.sim sim_1 behav xsim simulate.log]
if {![file exists $sim_log]} {
  puts "ERROR: Simulation log was not created: $sim_log"
  exit 1
}

set fh [open $sim_log r]
set log_text [read $fh]
close $fh
if {[string first "ETH_TX_FRONT_SIM_PASS" $log_text] < 0} {
  puts "ERROR: Front simulation did not report PASS."
  exit 1
}
puts "ETH_TX_FRONT_SIM_VERIFIED $sim_log"
