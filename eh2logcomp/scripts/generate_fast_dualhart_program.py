#!/usr/bin/env python3
"""Generate a deterministic, fast, self-contained dual-hart RV32IM program."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import random
import struct


RESET_VECTOR = 0x8000_0000
STOP_ADDR = 0xD058_0000
STOP_DATA = 0x0032_0525


def signed(value: int, bits: int) -> int:
    limit = 1 << (bits - 1)
    if not -limit <= value < limit:
        raise ValueError(f"{value} does not fit signed {bits} bits")
    return value & ((1 << bits) - 1)


def i_type(opcode: int, rd: int, funct3: int, rs1: int, immediate: int) -> int:
    return (signed(immediate, 12) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def r_type(rd: int, funct3: int, rs1: int, rs2: int, funct7: int = 0) -> int:
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33


def s_type(funct3: int, rs1: int, rs2: int, immediate: int) -> int:
    imm = signed(immediate, 12)
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((imm & 0x1F) << 7) | 0x23


def u_type(opcode: int, rd: int, upper20: int) -> int:
    return ((upper20 & 0xFFFFF) << 12) | (rd << 7) | opcode


def csr_type(rd: int, funct3: int, rs1: int, csr: int) -> int:
    return ((csr & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x73


def branch_type(funct3: int, rs1: int, rs2: int, offset: int) -> int:
    if offset & 1:
        raise ValueError("branch offset is not aligned")
    imm = signed(offset, 13)
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def jal_type(rd: int, offset: int) -> int:
    if offset & 1:
        raise ValueError("JAL offset is not aligned")
    imm = signed(offset, 21)
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


class Program:
    def __init__(self) -> None:
        self.words: list[int] = []
        self.labels: dict[str, int] = {}
        self.patches: list[tuple[int, str, str, tuple[int, ...]]] = []

    @property
    def pc(self) -> int:
        return RESET_VECTOR + 4 * len(self.words)

    def label(self, name: str) -> None:
        if name in self.labels:
            raise ValueError(f"duplicate label {name}")
        self.labels[name] = self.pc

    def emit(self, instruction: int) -> None:
        self.words.append(instruction & 0xFFFF_FFFF)

    def branch(self, label: str, funct3: int, rs1: int, rs2: int) -> None:
        index = len(self.words)
        self.emit(0)
        self.patches.append((index, label, "branch", (funct3, rs1, rs2)))

    def jal(self, label: str, rd: int = 0) -> None:
        index = len(self.words)
        self.emit(0)
        self.patches.append((index, label, "jal", (rd,)))

    def resolve(self) -> None:
        for index, label, kind, fields in self.patches:
            if label not in self.labels:
                raise ValueError(f"unknown label {label}")
            pc = RESET_VECTOR + 4 * index
            offset = self.labels[label] - pc
            if kind == "branch":
                self.words[index] = branch_type(fields[0], fields[1], fields[2], offset)
            else:
                self.words[index] = jal_type(fields[0], offset)


def random_body(program: Program, seed: int, hart: int, count: int) -> None:
    rng = random.Random(seed ^ (0x9E37_79B9 * (hart + 1)))
    # The first instruction establishes a private 4-KiB test page in DDR0.
    # All later loads/stores remain within 0xA0000000..0xA0001FFF.
    program.emit(u_type(0x37, 20, 0xA0000 + hart))
    emitted = 1
    previous_rd = 1
    while emitted < count:
        slot = emitted % 257
        rs1 = rng.choice([register for register in range(1, 29) if register != 20])
        rs2 = rng.choice([register for register in range(1, 29) if register != 20])
        rd = rng.choice([register for register in range(1, 29) if register != 20])

        # A resolved divide immediately followed by a younger write to the
        # same architectural destination exercises the real WAW-cancel path.
        if slot == 0 and emitted + 1 < count:
            program.emit(r_type(rd, 0b100, rs1, rs2, 0b0000001))  # div
            previous_rd = rd
            emitted += 1
            continue
        if slot == 1:
            rd = previous_rd
            program.emit(i_type(0x13, rd, 0b000, rs1, rng.randint(-2048, 2047)))
            emitted += 1
            continue

        choice = rng.randrange(100)
        if choice < 36:
            funct3 = rng.choice([0b000, 0b100, 0b110, 0b111])
            program.emit(i_type(0x13, rd, funct3, rs1, rng.randint(-2048, 2047)))
        elif choice < 48:
            shift = rng.randrange(32)
            funct3 = rng.choice([0b001, 0b101])
            if funct3 == 0b001:
                immediate = shift
            else:
                immediate = shift | (rng.choice([0, 0x20]) << 5)
            program.emit(i_type(0x13, rd, funct3, rs1, immediate))
        elif choice < 76:
            funct3 = rng.choice([0b000, 0b001, 0b100, 0b101, 0b110, 0b111])
            funct7 = 0b0100000 if funct3 in (0b000, 0b101) and rng.randrange(2) else 0
            program.emit(r_type(rd, funct3, rs1, rs2, funct7))
        elif choice < 88:
            funct3 = rng.choice([0b000, 0b001, 0b010, 0b011])  # mul/mulh family
            program.emit(r_type(rd, funct3, rs1, rs2, 0b0000001))
        elif choice < 94:
            funct3 = rng.choice([0b100, 0b101, 0b110, 0b111])  # div/rem family
            program.emit(r_type(rd, funct3, rs1, rs2, 0b0000001))
        elif choice < 97:
            offset = rng.randrange(0, 2048, 4)
            program.emit(i_type(0x03, rd, 0b010, 20, offset))
        else:
            offset = rng.randrange(0, 2048, 4)
            program.emit(s_type(0b010, 20, rs2, offset))
        previous_rd = rd
        emitted += 1


def stop_tail(program: Program, hart: int) -> None:
    program.emit(u_type(0x37, 29, STOP_ADDR >> 12))
    program.emit(u_type(0x37, 30, STOP_DATA >> 12))
    program.emit(i_type(0x13, 30, 0b000, 30, STOP_DATA & 0xFFF))
    program.emit(s_type(0b010, 29, 30, 0))
    program.emit(0x1050_0073)  # wfi
    program.jal(f"hart{hart}_park")
    program.label(f"hart{hart}_park")
    program.emit(0x1050_0073)
    program.jal(f"hart{hart}_park")


def build(seed: int, target_records: int) -> tuple[bytes, dict]:
    if target_records < 64:
        raise ValueError("target record count is too small")
    program = Program()
    # Both harts enter at the same reset vector. Only hart0 executes CSR 0x7FC.
    program.emit(csr_type(8, 0b010, 0, 0xF14))  # csrr s0,mhartid
    program.branch("hart0_boot", 0b000, 8, 0)  # beq s0,zero,hart0_boot
    program.jal("hart1_main")
    program.label("hart0_boot")
    program.emit(i_type(0x13, 31, 0b000, 0, 2))
    program.emit(csr_type(0, 0b001, 31, 0x7FC))  # csrw 0x7fc,t6
    program.jal("hart0_main")

    # Capture counts include the reset-vector dispatch, the three setup
    # instructions immediately before each stop marker, and the marker store.
    # The store retires before its AXI AW/W handshakes set stopped; only younger
    # WFI/park instructions are suppressed by the capture RTL.
    hart0_prefix_records = 5
    hart1_prefix_records = 3
    tail_records = 4
    hart0_body = target_records - hart0_prefix_records - tail_records
    hart1_body = target_records - hart1_prefix_records - tail_records

    program.label("hart0_main")
    random_body(program, seed, 0, hart0_body)
    stop_tail(program, 0)
    program.label("hart1_main")
    random_body(program, seed, 1, hart1_body)
    stop_tail(program, 1)
    program.resolve()
    binary = b"".join(struct.pack("<I", word) for word in program.words)
    manifest = {
        "generator": "generate_fast_dualhart_program.py",
        "isa": "RV32IMAC (32-bit I/M instructions used; C/A remain enabled)",
        "seed": seed,
        "reset_vector": RESET_VECTOR,
        "program_bytes": len(binary),
        "program_sha256": hashlib.sha256(binary).hexdigest(),
        "target_records": {"hart0": target_records, "hart1": target_records},
        "random_body_instructions": {"hart0": hart0_body, "hart1": hart1_body},
        "hart0_start_csr": "0x7fc written only by hart0",
        "lsu_ranges": {
            "hart0": [0xA000_0000, 0xA000_0800],
            "hart1": [0xA000_1000, 0xA000_1800],
        },
        "stop_address": STOP_ADDR,
        "stop_data": STOP_DATA,
    }
    return binary, manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--records-per-hart", type=int, default=10_000)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--expected-svh", type=Path)
    args = parser.parse_args()
    binary, manifest = build(args.seed, args.records_per_hart)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(binary)
    manifest_path = args.manifest or args.output.with_suffix(".json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    if args.expected_svh:
        args.expected_svh.write_text(
            "`define RISCV_DV_MIN_HART_RECORDS %d\n"
            "`define RISCV_DV_MAX_HART_RECORDS %d\n"
            "`define RISCV_DV_FAST_PROGRAM_SEED %d\n"
            % (args.records_per_hart, args.records_per_hart + 16, args.seed),
            encoding="ascii",
        )
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
