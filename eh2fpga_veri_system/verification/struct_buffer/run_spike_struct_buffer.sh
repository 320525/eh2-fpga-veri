#!/bin/sh
set -eu

cd /tmp/eh2_struct_buffer_spike
for case_id in 00 01 02 03 04 05 06 07 08 09; do
    log="case_${case_id}/spike.log"
    spike --pc=0x80000000 --isa=rv32im_zicsr --log-commits -l \
        "case_${case_id}/spike_program.elf" > "$log" 2>&1
    grep -q '0x80000000 (0x30001073)' "$log"
    printf 'SPIKE_RUN_PASS case=case_%s lines=%s first_pc=0x80000000\n' \
        "$case_id" "$(wc -l < "$log")"
done
tar -czf spike_logs.tar.gz case_*/spike.log
