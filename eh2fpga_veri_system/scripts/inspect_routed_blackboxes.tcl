set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
open_checkpoint [file join $root_dir output board eh2_veri_system_routed.dcp]
set blackboxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
puts "ROUTED_BLACKBOX_COUNT=[llength $blackboxes]"
foreach cell $blackboxes {
  puts "ROUTED_BLACKBOX=$cell REF=[get_property REF_NAME $cell]"
}
set dbg_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ *dbg_hub* || NAME =~ *dbg_hub*}]
puts "ROUTED_DBG_HUB_COUNT=[llength $dbg_cells]"
foreach cell $dbg_cells {
  puts "ROUTED_DBG_HUB=$cell REF=[get_property REF_NAME $cell] BLACKBOX=[get_property IS_BLACKBOX $cell]"
}
close_design
exit
