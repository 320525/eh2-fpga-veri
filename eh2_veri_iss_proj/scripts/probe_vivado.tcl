set part_name xcvu19p_CIV-fsva3824-1-e
puts "PART_COUNT=[llength [get_parts -quiet $part_name]]"
create_project -in_memory -part $part_name
foreach ip_pat {xilinx.com:ip:ddr4:* xilinx.com:ip:axi_traffic_gen:* xilinx.com:ip:axi_protocol_converter:* xilinx.com:ip:axi_clock_converter:* xilinx.com:ip:axi_dwidth_converter:*} {
  puts "IPDEF $ip_pat -> [get_ipdefs -all -quiet $ip_pat]"
}
set probe_dir [file join [pwd] escalated_probe]
file mkdir $probe_dir
create_ip -name axi_traffic_gen -vendor xilinx.com -library ip -version 3.0 -module_name probe_atg -dir $probe_dir
create_ip -name axi_protocol_converter -vendor xilinx.com -library ip -version 2.1 -module_name probe_pc -dir $probe_dir
create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name probe_cc -dir $probe_dir
create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip -version 2.1 -module_name probe_dw -dir $probe_dir
foreach ip {probe_atg probe_pc probe_cc probe_dw} {
  puts "---PROPERTIES $ip---"
  foreach prop [lsort [list_property [get_ips $ip]]] {
    if {[string match "CONFIG.*" $prop] && [regexp -nocase {protocol|data_width|addr_width|id_width|read_write|atg_mode|sysinit|system_init|mif|channels|async} $prop]} {
      puts "$prop=[get_property $prop [get_ips $ip]]"
    }
  }
}
exit
