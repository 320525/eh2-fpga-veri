#!/usr/bin/env python3
"""Generate ten straight-line EH2 nonblocking/WAW stress programs."""

from __future__ import annotations

import argparse
from pathlib import Path


LINKER = """OUTPUT_ARCH( \"riscv\" )
ENTRY(_start)

SECTIONS
{
  . = 0;
  .text : { *(.text*) }
  _end = .;
  . = 0x10000;
  .data : ALIGN(0x800) { *(.*data) *(.rodata*) STACK = ALIGN(16) + 0x8000; }
}
"""


def program(seed: int) -> str:
    lines = [
        "    .section .text",
        "    .global _start",
        "    .option norvc",
        "_start:",
        "    csrw mstatus, zero",
        "    li x5, 0x5f555555",
        "    csrw 0x7c0, x5",
        "    la sp, STACK",
        "    la x8, test_data",
        "    li x6, 0x7fffffff",
        "    li x7, 3",
        "    li x27, 0",
        "",
        "    # Exactly 100 consecutive loads: no ALU instruction or NOP is",
        "    # inserted in this region. Adjacent pairs deliberately reuse rd.",
        "continuous_100_nonblocking_loads:",
    ]

    # Fifty adjacent same-rd pairs. Register and address rotation differ for
    # every seed, while x8/x6/x7/x27 and the ABI control registers stay intact.
    load_rds = list(range(10, 26))
    for pair in range(50):
        rd = load_rds[(pair + seed * 3) % len(load_rds)]
        word0 = (pair * 2 + seed * 7) % 128
        word1 = (word0 + 1 + (seed % 3)) % 128
        lines.append(f"    lw x{rd}, {word0 * 4}(x8)")
        lines.append(f"    lw x{rd}, {word1 * 4}(x8)")

    lines += [
        "continuous_100_nonblocking_loads_end:",
        "",
        "    # One hundred further WAW groups. Most are load->load atomic",
        "    # handoffs; every tenth group adds a long DIV victim followed by",
        "    # a younger nonblocking load to the same destination.",
        "waw_stress_groups:",
    ]
    for group in range(100):
        rd = load_rds[(group * 5 + seed) % len(load_rds)]
        word0 = (group * 3 + seed * 11) % 128
        word1 = (word0 + 5 + seed) % 128
        if group % 10 == seed % 10:
            lines.append(f"    div x{rd}, x6, x7")
            lines.append(f"    lw x{rd}, {word1 * 4}(x8)")
        else:
            lines.append(f"    lw x{rd}, {word0 * 4}(x8)")
            lines.append(f"    lw x{rd}, {word1 * 4}(x8)")
        lines.append("    addi x27, x27, 1")

    lines += [
        "",
        "    # Drain all outstanding nonblocking returns before the mailbox.",
        "    .rept 64",
        "    nop",
        "    .endr",
        "",
        "    li x5, 0xd0580000",
        # The Vivado CRC path recognizes the verified 32-bit stop marker with
        # all byte strobes.  The following byte write is retained solely for
        # the unmodified server testbench, whose historical PASS mailbox value
        # is 0xff.  CRC collection is already stopped before that write.
        "    li x6, 0x00320525",
        "    sw x6, 0(x5)",
        # Keep the unmodified EH2 server testbench protocol: 0xff is PASS and
        # 0x01 is FAIL.  Per-case variation belongs in the stress body/data,
        # not in the mailbox completion byte.
        "    li x6, 0xff",
        "    sb x6, 0(x5)",
        "halt:",
        "    wfi",
        "    j halt",
        "",
        "    .section .data",
        "    .balign 8",
        "test_data:",
    ]
    for word in range(128):
        value = (0x13579BDF + seed * 0x01010101 + word * 0x10203) & 0xFFFFFFFF
        lines.append(f"    .word 0x{value:08x}")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for seed in range(10):
        case = args.output / f"case_{seed:02d}"
        case.mkdir(parents=True, exist_ok=True)
        (case / "program.s").write_text(program(seed), encoding="utf-8")
        (case / "link.ld").write_text(LINKER, encoding="utf-8")
        (case / "case.txt").write_text(
            f"case={seed:02d}\n"
            "lmem_delay=0\n"
            "continuous_load_instructions=100\n"
            "waw_groups=100\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
