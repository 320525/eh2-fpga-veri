namespace eval synplify_netlist {
  variable vivado_part xcvu19p_CIV-fsva3824-1-e
  variable eh2_ref_name eh2_veer_wrapper

  proc require_target_part {} {
    variable vivado_part
    set actual_part [get_property PART [current_project]]
    if {$actual_part ne $vivado_part} {
      error "Part mismatch: project=$actual_part, required=$vivado_part"
    }
  }

  proc configure {root_dir} {
    variable eh2_ref_name
    require_target_part

    set netlist [file normalize [file join $root_dir build synplify rev_1 \
      eh2_veer_wrapper.edf]]
    if {![file exists $netlist]} {
      error "Synplify netlist not found: $netlist"
    }

    set netlist_obj [get_files -quiet $netlist]
    if {[llength $netlist_obj] == 0} {
      add_files -norecurse $netlist
      set netlist_obj [get_files $netlist]
    }
    set_property USED_IN_SYNTHESIS true $netlist_obj
    set_property USED_IN_IMPLEMENTATION true $netlist_obj
    # EDIF file objects in Vivado 2023.2 do not expose USED_IN_SIMULATION.
    # They are naturally ignored by behavioral simulation and consumed by
    # synthesis/implementation through the two properties above.

    # Vivado needs an HDL black-box declaration during RTL elaboration before
    # it can bind the instantiated cell to the EDIF implementation.
    set stub [file normalize [file join $root_dir rtl \
      eh2_veer_wrapper_synplify_stub.v]]
    set stub_obj [get_files -quiet $stub]
    if {[llength $stub_obj] == 0} {
      add_files -norecurse $stub
      set stub_obj [get_files $stub]
    }
    set_property USED_IN_SYNTHESIS true $stub_obj
    set_property USED_IN_IMPLEMENTATION true $stub_obj
    set_property USED_IN_SIMULATION false $stub_obj

    # Keep the EH2 RTL in the project for behavioral simulation, but make the
    # Synplify EDIF the only synthesis implementation of eh2_veer_wrapper.
    set eh2_root [file normalize D:/eh2_fpga/source/eh2_design]
    set disabled_count 0
    foreach file_obj [get_files -quiet -of_objects [get_filesets sources_1]] {
      set file_name [file normalize [get_property NAME $file_obj]]
      if {[string first "${eh2_root}/" $file_name] == 0} {
        set_property USED_IN_SYNTHESIS false $file_obj
        incr disabled_count
      }
    }
    if {$disabled_count == 0} {
      error "No EH2 RTL files were found under $eh2_root"
    }

    puts "SYNPLIFY_NETLIST_CONFIGURED=$netlist"
    puts "SYNPLIFY_NETLIST_STUB=$stub"
    puts "SYNPLIFY_NETLIST_REF=$eh2_ref_name"
    puts "SYNPLIFY_DISABLED_EH2_RTL_FILES=$disabled_count"
    return $netlist
  }

  proc validate {root_dir} {
    variable vivado_part
    require_target_part

    set netlist [file normalize [file join $root_dir build synplify rev_1 \
      eh2_veer_wrapper.edf]]
    set netlist_obj [get_files -quiet $netlist]
    if {[llength $netlist_obj] != 1} {
      error "Expected one integrated Synplify EDIF, found [llength $netlist_obj]: $netlist"
    }
    if {![get_property USED_IN_SYNTHESIS $netlist_obj]} {
      error "Synplify EDIF is not enabled for synthesis: $netlist"
    }

    set stub [file normalize [file join $root_dir rtl \
      eh2_veer_wrapper_synplify_stub.v]]
    set stub_obj [get_files -quiet $stub]
    if {[llength $stub_obj] != 1 ||
        ![get_property USED_IN_SYNTHESIS $stub_obj] ||
        [get_property USED_IN_SIMULATION $stub_obj]} {
      error "Synplify black-box stub is not configured correctly: $stub"
    }

    set eh2_root [file normalize D:/eh2_fpga/source/eh2_design]
    set enabled_rtl {}
    foreach file_obj [get_files -quiet -of_objects [get_filesets sources_1]] {
      set file_name [file normalize [get_property NAME $file_obj]]
      if {[string first "${eh2_root}/" $file_name] == 0 &&
          [get_property USED_IN_SYNTHESIS $file_obj]} {
        lappend enabled_rtl $file_name
      }
    }
    if {[llength $enabled_rtl] != 0} {
      error "EH2 RTL is still enabled for synthesis: $enabled_rtl"
    }

    puts "SYNPLIFY_NETLIST_VALID=1"
    puts "VIVADO_PART=$vivado_part"
    puts "SYNPLIFY_EQUIVALENT_PART=XCVU19P/FSVA3824/-1-e"
  }
}
