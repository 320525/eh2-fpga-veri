set part_name xcvu19p_CIV-fsva3824-1-e
create_project -in_memory -part $part_name

create_ip -name axi_traffic_gen -vendor xilinx.com -library ip \
  -version 3.0 -module_name tx_axi_traffic_gen_query
puts "ATG_PROPERTIES_BEGIN"
report_property -all [get_ips tx_axi_traffic_gen_query]
puts "ATG_PROPERTIES_END"

if {[catch {
  set_property -dict [list \
    CONFIG.C_ATG_MODE {AXI4-Stream} \
    CONFIG.C_AXIS_MODE {Master Only} \
    CONFIG.C_AXIS_TDATA_WIDTH {8}] \
    [get_ips tx_axi_traffic_gen_query]
} atg_error]} {
  puts "ATG_8BIT_RESULT=FAILED"
  puts "ATG_8BIT_ERROR=$atg_error"
} else {
  puts "ATG_8BIT_RESULT=PASSED"
  puts "ATG_MODE=[get_property CONFIG.C_ATG_MODE [get_ips tx_axi_traffic_gen_query]]"
  puts "ATG_AXIS_MODE=[get_property CONFIG.C_AXIS_MODE [get_ips tx_axi_traffic_gen_query]]"
  puts "ATG_AXIS_WIDTH=[get_property CONFIG.C_AXIS_TDATA_WIDTH [get_ips tx_axi_traffic_gen_query]]"
}

create_ip -name axi_datamover -vendor xilinx.com -library ip \
  -module_name tx_axi_datamover_query
puts "DATAMOVER_PROPERTIES_BEGIN"
report_property -all [get_ips tx_axi_datamover_query]
puts "DATAMOVER_PROPERTIES_END"

if {[catch {
  set_property -dict [list \
    CONFIG.c_include_mm2s {Full} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {8}] \
    [get_ips tx_axi_datamover_query]
} dm_error]} {
  puts "DATAMOVER_8BIT_RESULT=FAILED"
  puts "DATAMOVER_8BIT_ERROR=$dm_error"
} else {
  puts "DATAMOVER_8BIT_RESULT=PASSED"
  puts "DATAMOVER_MM2S=[get_property CONFIG.c_include_mm2s [get_ips tx_axi_datamover_query]]"
  puts "DATAMOVER_AXIS_WIDTH=[get_property CONFIG.c_m_axis_mm2s_tdata_width [get_ips tx_axi_datamover_query]]"
}

exit 0
