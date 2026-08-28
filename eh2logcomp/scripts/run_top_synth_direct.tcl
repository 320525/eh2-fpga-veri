# Run a Vivado-generated top-level synthesis script without the Windows Run
# Server.  Some generated scripts try to set USED_IN_* on optional nested-IP
# products that are not registered as file objects in a fresh in-memory
# project.  Missing optional objects are harmless; all other property failures
# remain fatal.

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set synth_tcl  [file join $root_dir build vivado eh2_veri_system.runs synth_1 eh2logcomp_system_top.tcl]
cd [file dirname $synth_tcl]

set fp [open $synth_tcl r]
set generated_script [read $fp]
close $fp

set safe_script ""
foreach line [split $generated_script "\n"] {
  if {[regexp {^(close \[open|file delete) __synthesis_} $line]} {
    # Run-state marker files are only needed by the Windows Run Server.  Direct
    # batch execution deliberately omits them.
    continue
  } elseif {[regexp {^create_project -in_memory } $line]} {
    append safe_script "$line\n"
    append safe_script "cd [file dirname $synth_tcl]\n"
  } elseif {[regexp {^set_property (used_in_(implementation|synthesis)) false \[get_files -all (.+)\]\r?$} \
              $line -> property_name property_suffix file_name]} {
    append safe_script "set __optional_ip_objs \[get_files -quiet -all $file_name\]\n"
    append safe_script "if {\[llength \$__optional_ip_objs\]} { set_property $property_name false \$__optional_ip_objs }\n"
  } else {
    append safe_script "$line\n"
  }
}

uplevel #0 $safe_script
