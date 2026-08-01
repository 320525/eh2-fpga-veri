#!/usr/bin/env python3
"""Generate a dual-hart RV32IMAC workload with about 200k dynamic commits."""

from __future__ import annotations

import argparse
from pathlib import Path


ASSEMBLY = r"""
    .option norvc
    .section .text.init
    .globl _start
_start:
    csrr    s0, mhartid
    la      sp, stack_top
    slli    t0, s0, 10
    sub     sp, sp, t0
    la      s1, shared_data
    slli    t0, s0, 8
    add     s1, s1, t0
    li      t1, {iterations}
    li      t0, 0
    li      a0, 0
    li      t2, 0x13579bdf
    li      t3, 0x2468ace1

stress_loop:
    addi    t2, t2, 7
    xor     t3, t3, t2
    add     t4, t2, t3
    mul     t5, t4, t2
    divu    s2, t5, t2
    remu    s3, t5, t3
    sw      t5, 0(s1)
    lw      s4, 0(s1)
    addi    s4, s4, 1
    lw      s5, 0(s1)
    add     s6, s5, s4
    div     s7, s6, t2
    xor     s7, s7, t3
    addi    a0, a0, 3
    xori    a0, a0, 0x55
    and     a1, t2, t3
    or      a2, t2, t3
    sll     a3, a1, s0
    srl     a4, a2, s0
    addi    t0, t0, 1
    bne     t0, t1, stress_loop

    li      t4, 0xD0580000
    li      t5, 0x00320525
    sw      t5, 0(t4)
    fence   rw, rw
done:
    wfi
    j       done

    .section .data
    .align 6
shared_data:
    .space 512

    .section .bss
    .align 12
stack_area:
    .space 8192
stack_top:
"""

LINKER = r"""
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text .text.*) }
  . = ALIGN(64);
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  .bss : { *(.bss .bss.*) *(COMMON) }
  /DISCARD/ : { *(.comment) *(.note*) }
}
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--target-total", type=int, default=200_000)
    args = parser.parse_args()

    # There are 21 dynamic loop instructions per hart. Setup and completion
    # contribute fewer than 100 instructions, so this lands close to 200k.
    iterations = max(1, (args.target_total - 100) // (21 * 2))
    estimated = iterations * 21 * 2 + 100
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "stress_200k_dualhart.S").write_text(
        ASSEMBLY.format(iterations=iterations), encoding="utf-8"
    )
    (args.output / "link.ld").write_text(LINKER, encoding="utf-8")
    (args.output / "generation.txt").write_text(
        f"target_total={args.target_total}\n"
        f"iterations_per_hart={iterations}\n"
        f"estimated_dynamic_commits={estimated}\n",
        encoding="utf-8",
    )
    print(f"iterations_per_hart={iterations}")
    print(f"estimated_dynamic_commits={estimated}")


if __name__ == "__main__":
    main()
