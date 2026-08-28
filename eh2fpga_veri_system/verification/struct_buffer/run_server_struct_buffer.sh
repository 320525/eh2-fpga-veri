#!/bin/bash
set -eu

project_root=${RV_ROOT:-/proj/project2/workarea/user12/eh2/Cores-VeeR-EH2-main}
export RV_ROOT="$project_root"
work_root="$project_root/agent/struct_buffer_verification"
snapshot_root="$work_root/snapshot_pc80000000_v3"
output_root="$work_root/output"
snapshot_name=struct_buffer_verify_pc80000000_v3
tb_pc80000000="$work_root/tb_top_waw_pc80000000.sv"

mkdir -p "$snapshot_root" "$output_root"
cp "$project_root/agent/snapshots/default/defines.h" \
   "$project_root/agent/snapshots/default/common_defines.vh" \
   "$project_root/agent/snapshots/default/eh2_pdef.vh" \
   "$project_root/agent/snapshots/default/eh2_param.vh" \
   "$project_root/agent/snapshots/default/pd_defines.vh" \
   "$project_root/agent/snapshots/default/pic_map_auto.h" \
   "$snapshot_root/"

# Preserve the original testbench and build a dedicated copy whose reset PC is
# the FPGA system address.  The AHB memory model indexes the loaded HEX through
# the implemented low address bits, so no textual PC offset is applied later.
sed "s/reset_vector = 32'h0;/reset_vector = 32'h80000000;/" \
  "$project_root/agent/verification/tb_top_waw.sv" > "$tb_pc80000000"
grep -q "reset_vector = 32'h80000000;" "$tb_pc80000000"

if [ ! -d "$snapshot_root/veer.build" ]; then
    mkdir -p "$work_root/build"
    cd "$work_root/build"
    make -B -f "$project_root/tools/makefile" irun-build \
      BUILD_DIR="$snapshot_root" snapshot="$snapshot_name" \
      TBFILES="$tb_pc80000000 $project_root/agent/verification/ahb_sif_waw.sv $work_root/struct_buffer_capture_monitor.sv $work_root/crc64_ecma_pair_160.sv $work_root/instr_crc_hash_dual.sv"
fi

for case_id in 00 01 02 03 04 05 06 07 08 09; do
    case_root="$work_root/cases/case_$case_id"
    sw_root="$case_root/sw"
    run_root="$case_root/run"
    mkdir -p "$sw_root" "$run_root" "$output_root/case_$case_id"
    # The server consumes a prebuilt Verilog HEX whose address directives are
    # linked at 0x80000000/0x80010000.  This makes both instruction fetch and
    # data load use real FPGA addresses rather than post-processing PC text.
    test -s "$case_root/program.hex"
    test -s "$case_root/program.dis"
    cp "$case_root/program.hex" "$run_root/program.hex"
    cp "$case_root/program.dis" "$output_root/case_$case_id/program.dis"
    cp "$case_root/program.s" "$output_root/case_$case_id/program.s"
    cp "$case_root/case.txt" "$output_root/case_$case_id/case.txt"
    # Match the Vivado AXI memory model's no-extra-delay response.  The ten
    # simulations remain different through their independently generated
    # instruction/address/register patterns.
    delay=0
    cd "$run_root"
    irun -64bit +lic_queue -licqueue -status \
      -nclibdirpath "$snapshot_root" -nclibdirname veer.build \
      -snapshot "$snapshot_name" -r "$snapshot_name" \
      "+lmem_delay=$delay" > sim.log 2>&1
    grep -q 'TEST_PASSED' sim.log
    grep -q ' 80000000 30001073' exec.log
    cp exec.log "$output_root/case_$case_id/exec.log"
    grep '^SUMMARY ' rtl_structs_unsorted.log
done

echo STRUCT_BUFFER_SERVER_RUN_PASS cases=10
