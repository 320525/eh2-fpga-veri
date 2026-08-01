#!/usr/bin/env python3
"""Generate independent golden values for the ten-package RTL wrap test."""

from __future__ import annotations

import json
from pathlib import Path

MASK64 = (1 << 64) - 1
POLY = 0x42F0E1EBA9EA3693
K0 = 0x9E3779B97F4A7C15
K1 = 0xD1B54A32D192ED03
PACKAGES = 10
ITEMS_PER_PACKAGE = 65536


def make_table() -> list[int]:
    table = []
    for value in range(256):
        crc = value << 56
        for _ in range(8):
            crc = ((crc << 1) & MASK64) ^ (POLY if (crc >> 63) else 0)
        table.append(crc)
    return table


TABLE = make_table()


def crc64(value: int, init: int) -> int:
    crc = init
    for byte in value.to_bytes(20, "big"):
        crc = ((crc << 8) & MASK64) ^ TABLE[((crc >> 56) ^ byte) & 0xFF]
    return crc


def rotl(value: int, amount: int) -> int:
    return ((value << amount) | (value >> (64 - amount))) & MASK64


def mix(c0: int, c1: int) -> tuple[int, int, int, int]:
    return (
        (c0 + rotl(c1, 17) + K0) & MASK64,
        (c1 + rotl(c0, 31) + K1) & MASK64,
        ((c0 ^ rotl(c1, 43)) + rotl(c0, 11)) & MASK64,
        ((c1 ^ rotl(c0, 29)) + rotl(c1, 7)) & MASK64,
    )


def instruction_struct(hart: int, absolute: int) -> int:
    package = absolute >> 16
    sequence = absolute & 0xFFFF
    pc = (0x80000000 + hart * 0x10000 + ((absolute & 0x3FF) << 2)) & 0xFFFFFFFF
    insn = (0x00000013 ^ ((absolute * 0x1021) & 0xFFFFFFFF)) & 0xFFFFFFFF
    rd = (absolute % 31) + 1
    data = ((absolute * 0x9E3779B1) ^ (hart * 0xA5A5A5A5)) & 0xFFFFFFFF
    metadata = (hart << 16) | (3 << 14) | (1 << 12) | rd
    return (
        (package << 144)
        | (sequence << 128)
        | (pc << 96)
        | (insn << 64)
        | (metadata << 32)
        | data
    )


def main() -> None:
    output = Path(__file__).resolve().parents[1] / "sim"
    all_results = []
    for hart in range(2):
        hart_results = []
        mem_lines = []
        for package in range(PACKAGES):
            xor0 = xor1 = sum0 = sum1 = sum2 = sum3 = 0
            start = package * ITEMS_PER_PACKAGE
            for absolute in range(start, start + ITEMS_PER_PACKAGE):
                struct = instruction_struct(hart, absolute)
                c0 = crc64(struct, 0)
                c1 = crc64(struct, MASK64)
                g0, g1, g2, g3 = mix(c0, c1)
                xor0 ^= g0
                xor1 ^= g1
                sum0 = (sum0 + g0) & MASK64
                sum1 = (sum1 + g1) & MASK64
                sum2 = (sum2 + g2) & MASK64
                sum3 = (sum3 + g3) & MASK64
            values = (xor0, xor1, sum0, sum1, sum2, sum3)
            hart_results.append({
                "hart": hart,
                "package": package,
                "count": ITEMS_PER_PACKAGE,
                "xor0": f"{xor0:016x}",
                "xor1": f"{xor1:016x}",
                "sum0": f"{sum0:016x}",
                "sum1": f"{sum1:016x}",
                "sum2": f"{sum2:016x}",
                "sum3": f"{sum3:016x}",
            })
            mem_lines.append("".join(f"{value:016x}" for value in values))
        (output / f"wrap_expected_hart{hart}.mem").write_text(
            "\n".join(mem_lines) + "\n", encoding="ascii"
        )
        all_results.extend(hart_results)

    (output / "wrap_expected.json").write_text(
        json.dumps({
            "packages_per_hart": PACKAGES,
            "items_per_package": ITEMS_PER_PACKAGE,
            "algorithm": "CRC-64/ECMA pair plus G/XOR/SUM",
            "results": all_results,
        }, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
