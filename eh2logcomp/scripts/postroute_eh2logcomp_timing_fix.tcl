# Compatibility entry point retained for older build notes.
#
# Do not restore the historical 1250 ps IDELAY experiment: IDELAYE3 at the
# design's 333.333 MHz reference clock accepts at most 1100 ps, and Vivado DRC
# correctly rejects 1250 ps with AVAL-174.  The supported timing closure flow
# uses the legal 1100 ps delay and the swept X2Y2 RGMII RX clock root.
source [file join [file dirname [info script]] postroute_eh2logcomp_rx_clockroot_fix.tcl]
