#!/bin/bash
set -eu

project_root=${RV_ROOT:-/proj/project2/workarea/user12/eh2/Cores-VeeR-EH2-main}
export RV_ROOT="$project_root"
work_root="$project_root/agent/eh2_interface_verification"
snapshot_root="$work_root/snapshot_current"
run_root="$work_root/runs"
verification_root="$project_root/agent/verification"

mkdir -p "$snapshot_root" "$run_root" "$work_root/build"
cp "$project_root/agent/snapshots/default/defines.h" \
   "$project_root/agent/snapshots/default/common_defines.vh" \
   "$project_root/agent/snapshots/default/eh2_pdef.vh" \
   "$project_root/agent/snapshots/default/eh2_param.vh" \
   "$project_root/agent/snapshots/default/pd_defines.vh" \
   "$project_root/agent/snapshots/default/pic_map_auto.h" \
   "$snapshot_root/"

# Build a fresh snapshot from the current server EH2 source tree.  This avoids
# relying on the date or contents of a historical precompiled snapshot.
if [ ! -d "$snapshot_root/veer.build" ]; then
    cd "$work_root/build"
    make -B -f "$project_root/tools/makefile" irun-build \
      BUILD_DIR="$snapshot_root" snapshot=eh2_interface_verify \
      TBFILES="$verification_root/tb_top_waw.sv $verification_root/ahb_sif_waw.sv $verification_root/eh2_waw_monitor.sv"
fi

sha256sum "$project_root/design/eh2_veer_wrapper.sv" \
          "$project_root/design/eh2_veer.sv" \
          "$project_root/design/dec/eh2_dec.sv" \
          "$project_root/design/lsu/eh2_lsu.sv" \
          > "$work_root/eh2_source_sha256.txt"

: > "$work_root/directed_summary.log"
for read_delay in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
    case_root="$run_root/lmem_delay_$read_delay"
    mkdir -p "$case_root"
    cp "$verification_root/program.hex" "$case_root/program.hex"
    cd "$case_root"
    irun -64bit +lic_queue -licqueue -status \
      -nclibdirpath "$snapshot_root" -nclibdirname veer.build \
      -snapshot eh2_interface_verify -r eh2_interface_verify \
      "+lmem_delay=$read_delay" > sim.log 2>&1
    grep -q TEST_PASSED sim.log
    summary=$(grep '^SUMMARY ' waw_monitor.log)
    printf 'lmem_delay=%s %s\n' "$read_delay" "$summary" | \
      tee -a "$work_root/directed_summary.log"
done

awk '
function value(name,   i, pair) {
    for (i=1; i<=NF; i++) {
        split($i, pair, "=")
        if (pair[1] == name) return pair[2] + 0
    }
    return -1
}
{
    runs++
    if (value("errors") != 0) bad_errors++
    if (value("commits_i0") > 0 && value("commits_i1") > 0) dual_commit++
    if (value("same_waw") >= 2) same_cycle++
    if (value("nb_div_waw") > value("div_return_waw")) div_before++
    if (value("div_return_waw") > 0) div_return++
    if (value("nb_load_waw") > 0 && value("load_return_waw") == 0) load_before++
    if (value("load_return_waw") > 0) load_return++
    if (value("nb_load_gpr_write") > 0) load_write++
    if (value("nb_div_gpr_write") > 0) div_write++
    if (value("nb_parallel_normal_write") > 0) parallel_write++
}
END {
    if (runs != 13 || bad_errors || dual_commit == 0 || same_cycle == 0 ||
        div_before == 0 || div_return == 0 || load_before == 0 ||
        load_return == 0 || load_write == 0 || div_write == 0 ||
        parallel_write == 0) {
        print "EH2_INTERFACE_COVERAGE_FAIL runs=" runs " errors=" bad_errors
        exit 1
    }
    print "EH2_INTERFACE_COVERAGE_PASS runs=" runs \
          " same_cycle=1 div_before=1 div_return=1" \
          " load_before=1 load_return=1" \
          " load_write=1 div_write=1 parallel_write=1 errors=0"
}' "$work_root/directed_summary.log" | tee "$work_root/coverage_result.log"

grep -h '^NB_WAW .*writer_lane=0' "$run_root"/*/waw_monitor.log >/dev/null
grep -h '^NB_WAW .*writer_lane=1' "$run_root"/*/waw_monitor.log >/dev/null
grep -h '^NB_GPR_WRITE .*type=load .*rd=23 data=13579bdf' \
  "$run_root"/*/waw_monitor.log >/dev/null
grep -h '^NB_GPR_WRITE .*type=div .*rd=21 data=7fffffff' \
  "$run_root"/*/waw_monitor.log >/dev/null
printf 'EH2_INTERFACE_VALUE_PASS load_rd23=13579bdf div_rd21=7fffffff\n' | \
  tee -a "$work_root/coverage_result.log"
printf 'EH2_INTERFACE_LANE_PASS writer_i0=1 writer_i1=1\n' | \
  tee -a "$work_root/coverage_result.log"
