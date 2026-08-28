# Recreate exact Verilog synthesis stubs for OOC IP checkpoints.  Vivado uses
# these declarations while synthesizing the parent design and stitches the DCPs
# during implementation.

set_param general.maxThreads 8

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set run_root   [file join $root_dir build vivado eh2_veri_system.runs]
set gen_root   [file join $root_dir build vivado eh2_veri_system.gen sources_1 ip]

set ip_names {
  axi_clock_converter_32
  axi_clock_converter_64
  axi_dwidth_converter_32_512
  axi_dwidth_converter_64_512
  axi_traffic_gen_0
  data_test_atg
}

foreach ip_name $ip_names {
  set checkpoint [file join $run_root ${ip_name}_synth_1 ${ip_name}.dcp]
  set stub       [file join $gen_root $ip_name ${ip_name}_stub.v]
  puts "RESTORE_STUB: $ip_name"
  open_checkpoint $checkpoint
  write_verilog -force -mode synth_stub $stub
  close_design
}

exit
