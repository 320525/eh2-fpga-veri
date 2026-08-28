set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
open_project [file join $root_dir build vivado eh2_veri_system.xpr]

foreach pattern {
  *eh2_veri_system.gen/sources_1/ip/axi_traffic_gen_0/axi_traffic_gen_0_stub.v
  *ooc_synth_stubs/axi_traffic_gen_0_stub.v
} {
  foreach file_object [get_files -quiet -all $pattern] {
    puts "STUB_OBJECT: $file_object"
    if {[string match "*ooc_synth_stubs*" $file_object]} {
      if {[catch {set_property IS_AUTO_DISABLED 0 $file_object} set_error]} {
        puts "  SET_IS_AUTO_DISABLED_ERROR = $set_error"
      } else {
        puts "  SET_IS_AUTO_DISABLED_OK"
      }
    }
    foreach property_name [list_property $file_object] {
      if {[string match -nocase "*enable*" $property_name] ||
          [string match -nocase "*disable*" $property_name] ||
          [string match -nocase "*used_in*" $property_name]} {
        puts "  $property_name = [get_property $property_name $file_object]"
      }
    }
  }
}

set generated_stub [get_files -quiet -all *eh2_veri_system.gen/sources_1/ip/axi_traffic_gen_0/axi_traffic_gen_0_stub.v]
if {[catch {remove_files $generated_stub} remove_error]} {
  puts "REMOVE_GENERATED_ERROR = $remove_error"
} else {
  update_compile_order -fileset sources_1
  set manual_stub [get_files -quiet -all *ooc_synth_stubs/axi_traffic_gen_0_stub.v]
  puts "REMOVE_GENERATED_OK; MANUAL_AUTO_DISABLED=[get_property IS_AUTO_DISABLED $manual_stub]"
}

puts "ALL_AXI_TRAFFIC_FILES"
foreach file_object [get_files -quiet -all *axi_traffic_gen_0*] {
  puts "  $file_object | TYPE=[get_property FILE_TYPE $file_object] | AUTO=[get_property IS_AUTO_DISABLED $file_object] | SYNTH=[get_property USED_IN_SYNTHESIS $file_object]"
}

set xci [get_files -quiet -all *axi_traffic_gen_0.xci]
puts "AXI_TRAFFIC_XCI_PROPERTIES"
foreach property_name [list_property $xci] {
  if {[string match -nocase "*synth*" $property_name] ||
      [string match -nocase "*checkpoint*" $property_name]} {
    puts "  $property_name = [get_property $property_name $xci]"
  }
}

close_project
exit
