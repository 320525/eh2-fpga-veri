set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
open_project [file join $root_dir project eth_tx.xpr]
set ip_obj [get_ips tx_control_atg]
reset_target all $ip_obj
generate_target all $ip_obj
export_ip_user_files -of_objects $ip_obj -no_script -sync -force -quiet
close_project
puts "TX_CONTROL_IP_REFRESHED"

