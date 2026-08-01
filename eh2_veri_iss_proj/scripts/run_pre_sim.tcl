set root_dir [file normalize [file join [file dirname [info script]] ..]]
set xpr       [file join $root_dir build vivado eh2_dual_ddr.xpr]
set report_dir [file join $root_dir reports]
file mkdir $report_dir

open_project $xpr

# Rebuild the program ATG output products when its COE payload changes.
generate_target all [get_ips atg_program]

# Behavioral pre-sim uses an AXI functional memory in place of the physical
# MIG/DRAM model. All Xilinx ATG, clock-converter and width-converter IPs stay
# in the simulation exactly as instantiated by the hardware top.
foreach ip_name {ddr4_0 ddr4_1} {
  set ip_file [get_files -quiet */${ip_name}.xci]
  if {[llength $ip_file] != 1} {
    error "Cannot uniquely locate ${ip_name}.xci"
  }
  set_property USED_IN_SIMULATION false $ip_file
}

set sim_files [list \
  [file join $root_dir sim axi_ram_model_512.sv] \
  [file join $root_dir sim ddr4_axi_stub.sv] \
  [file join $root_dir sim eh2_dual_ddr_pre_tb.sv]]
foreach f $sim_files {
  if {[llength [get_files -quiet $f]] == 0} {
    add_files -fileset sim_1 -norecurse $f
  }
  set_property FILE_TYPE SystemVerilog [get_files $f]
  set_property USED_IN_SYNTHESIS false [get_files $f]
}

set_property top eh2_dual_ddr_pre_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral
set sim_log [file join $root_dir build vivado eh2_dual_ddr.sim sim_1 behav xsim simulate.log]
close_sim
file copy -force $sim_log [file join $report_dir system_pre_sim.log]
close_project
