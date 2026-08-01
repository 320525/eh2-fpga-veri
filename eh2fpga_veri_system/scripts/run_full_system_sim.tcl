set script_dir [file normalize [file dirname [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set project_file [file join $root_dir build vivado eh2_veri_system.xpr]
set reference_root D:/eh2_fpga/Cores-VeeR-EH2-main/Cores-VeeR-EH2-main
set reference_log [file join $reference_root log_eh2_crc_fpga]

set_param general.maxThreads 8
open_project $project_file

# Synthesis keeps the verified EDIF and its port stub.  Behavioral simulation
# substitutes the corresponding EH2 RTL and a compact MIG AXI-UI model.
set synth_only_files [list \
  [file join $root_dir rtl eh2 eh2_veer_wrapper_mt_stub.v] \
  [file join $root_dir netlist eh2_veer_wrapper.edf] \
  [file join $root_dir rtl ddr dual_ddr_mig_wrapper.sv]]
foreach source $synth_only_files {
  set object [get_files -quiet [file normalize $source]]
  if {[llength $object]} {
    set_property USED_IN {synthesis implementation} $object
  }
}

set eh2_sources [list [file join $reference_root design include eh2_def.sv]]
set list_handle [open [file join $reference_log sim eh2_rtl_flist.f] r]
while {[gets $list_handle line] >= 0} {
  set line [string trim $line]
  if {$line ne ""} {
    lappend eh2_sources [file normalize \
      [file join $reference_log sim $line]]
  }
}
close $list_handle

foreach source $eh2_sources {
  if {![llength [get_files -quiet [file normalize $source]]]} {
    add_files -fileset sim_1 -norecurse [file normalize $source]
  }
  # The EH2 source list is compiled with xvlog --sv in its validated
  # standalone simulation, including files carrying a legacy .v suffix.
  set_property file_type SystemVerilog \
    [get_files [file normalize $source]]
}

set tb_sources [list \
  [file join $root_dir tb axi512_memory_model.sv] \
  [file join $root_dir tb dual_ddr_mig_sim_wrapper.sv] \
  [file join $root_dir tb tb_eh2_veri_system_rgmii.sv]]
foreach source $tb_sources {
  if {![llength [get_files -quiet [file normalize $source]]]} {
    add_files -fileset sim_1 -norecurse [file normalize $source]
  }
  set_property file_type SystemVerilog \
    [get_files [file normalize $source]]
}

set_property include_dirs [list \
  [file join $reference_log config default_mt] \
  [file join $reference_root design] \
  [file join $root_dir programs stress_200k_dualhart_system build]] \
  [get_filesets sim_1]
set_property top tb_eh2_veri_system_rgmii [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
set_property xsim.elaborate.debug_level typical [get_filesets sim_1]
set_property xsim.elaborate.mt_level 8 [get_filesets sim_1]
# launch_simulation obeys this property immediately. Keep it at 0 ns and
# issue exactly one explicit "run all" below so a testbench $fatal cannot be
# followed by a second run that prints a misleading PASS banner.
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]

update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
close_project
exit
