#!/usr/bin/env python3
"""Build Spike-compatible copies of the ten Struct Info stress programs.

The EH2 program writes a private performance CSR (0x7c0) and terminates through
the FPGA CRC mailbox.  Stock Spike implements neither interface.  This helper
keeps the stress body unchanged, replaces only the private CSR access with a
NOP, and replaces the FPGA-only tail with a standard ``tohost`` exit.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


LINKER = """OUTPUT_ARCH( \"riscv\" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text*) }
  _end = .;
  . = 0x80010000;
  .data : ALIGN(0x800) { *(.*data) *(.rodata*) STACK = ALIGN(16) + 0x8000; }
  . = ALIGN(64);
  .tohost : { *(.tohost) }
}
"""


SPIKE_TAIL = """    la x5, tohost
    li x6, 1
    sw x6, 0(x5)
1:
    wfi
    j 1b

"""


TOHOST = """
    .section .tohost,\"aw\",@progbits
    .balign 64
    .global tohost
tohost:
    .dword 0
    .global fromhost
fromhost:
    .dword 0
"""


def spike_source(source: str) -> str:
    source = source.replace("    csrw 0x7c0, x5", "    nop    # Spike compatibility: EH2 private CSR 0x7c0")
    tail_start = source.index("    li x5, 0xd0580000")
    data_start = source.index("    .section .data", tail_start)
    return source[:tail_start] + SPIKE_TAIL + source[data_start:] + TOHOST


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    args = parser.parse_args()

    gcc = args.toolchain / "riscv64-unknown-elf-gcc.exe"
    objdump = args.toolchain / "riscv64-unknown-elf-objdump.exe"
    objcopy = args.toolchain / "riscv64-unknown-elf-objcopy.exe"
    if not gcc.is_file() or not objdump.is_file() or not objcopy.is_file():
        raise SystemExit(f"RISC-V toolchain not found under {args.toolchain}")

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "link.ld").write_text(LINKER, encoding="ascii")

    for case_number in range(10):
        case_id = f"case_{case_number:02d}"
        source_path = args.cases / case_id / "program.s"
        case_output = args.output / case_id
        case_output.mkdir(exist_ok=True)
        eh2_elf = case_output / "eh2_program_pc80000000.elf"
        eh2_hex = case_output / "eh2_program_pc80000000.hex"
        spike_s = case_output / "spike_program.S"
        spike_elf = case_output / "spike_program.elf"
        spike_dis = case_output / "spike_program.dis"
        spike_s.write_text(spike_source(source_path.read_text(encoding="utf-8")), encoding="utf-8")
        common_gcc_args = [
            str(gcc),
            "-march=rv32im_zicsr",
            "-mabi=ilp32",
            "-nostdlib",
            "-nostartfiles",
            "-Wl,--build-id=none",
            f"-T{args.output / 'link.ld'}",
        ]
        subprocess.run(
            common_gcc_args + ["-o", str(eh2_elf), str(source_path)],
            check=True,
        )
        subprocess.run(
            [str(objcopy), "-O", "verilog", "--verilog-data-width=1", str(eh2_elf), str(eh2_hex)],
            check=True,
        )
        subprocess.run(
            common_gcc_args + ["-o", str(spike_elf), str(spike_s)],
            check=True,
        )
        with spike_dis.open("wb") as output:
            subprocess.run(
                [str(objdump), "-d", "-M", "no-aliases,numeric", str(spike_elf)],
                stdout=output,
                check=True,
            )
        print(
            f"PC80000000_CASE_BUILD_PASS case={case_id} "
            f"eh2_elf={eh2_elf} spike_elf={spike_elf}"
        )


if __name__ == "__main__":
    main()
