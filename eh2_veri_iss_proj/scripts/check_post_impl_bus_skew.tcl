set root_dir [file normalize [file join [file dirname [info script]] ..]]
set xpr [file join $root_dir build vivado eh2_dual_ddr.xpr]
set report_dir [file join $root_dir reports]

open_project $xpr
open_run impl_1
report_bus_skew -file [file join $report_dir bus_skew_impl.rpt]
close_project
exit
