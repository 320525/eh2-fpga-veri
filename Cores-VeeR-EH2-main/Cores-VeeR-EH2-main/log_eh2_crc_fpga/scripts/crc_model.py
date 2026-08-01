#!/usr/bin/env python3
"""Reference model for the dual-CRC instruction package hash."""

from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path

MASK64 = (1 << 64) - 1
POLY = 0x42F0E1EBA9EA3693
K0 = 0x9E3779B97F4A7C15
K1 = 0xD1B54A32D192ED03

EVENT = {"NONE": 0, "GPR": 1, "CSR": 2}


def crc64_ecma_160(value: int, init: int) -> int:
    crc = init & MASK64
    for bit_index in range(159, -1, -1):
        feedback = ((crc >> 63) & 1) ^ ((value >> bit_index) & 1)
        crc = (crc << 1) & MASK64
        if feedback:
            crc ^= POLY
    return crc


def rotl(value: int, amount: int) -> int:
    return ((value << amount) | (value >> (64 - amount))) & MASK64


def mix(c0: int, c1: int) -> tuple[int, int, int, int]:
    g0 = (c0 + rotl(c1, 17) + K0) & MASK64
    g1 = (c1 + rotl(c0, 31) + K1) & MASK64
    g2 = ((c0 ^ rotl(c1, 43)) + rotl(c0, 11)) & MASK64
    g3 = ((c1 ^ rotl(c0, 29)) + rotl(c1, 7)) & MASK64
    return g0, g1, g2, g3


def parse_trace(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open("r", encoding="utf-8") as handle:
        header = handle.readline().split()
        for line in handle:
            fields = line.split()
            if not fields:
                continue
            if len(fields) != len(header):
                raise ValueError(f"bad trace row: {line.rstrip()}")
            rows.append(dict(zip(header, fields, strict=True)))
    return rows


def build_struct(row: dict[str, str], package: int, sequence: int) -> int:
    hart = int(row["hart"], 0)
    priv = int(row.get("priv", "3"), 0)
    target = row["target"].upper()
    event_type = EVENT[target]
    target_num = int(row["target_num"], 0) if event_type else 0
    data = int(row["data"], 16)
    if int(row.get("waw", "0"), 0):
        data = 0
    metadata = ((hart & 1) << 16) | ((priv & 3) << 14) | (
        (event_type & 3) << 12
    ) | (target_num & 0xFFF)
    return (
        ((package & 0xFFFF) << 144)
        | ((sequence & 0xFFFF) << 128)
        | (int(row["pc"], 16) << 96)
        | (int(row["instruction"], 16) << 64)
        | (metadata << 32)
        | (data & 0xFFFFFFFF)
    )


def calculate(rows: list[dict[str, str]], limit: int | None) -> tuple[list[dict], list[dict]]:
    counters = defaultdict(int)
    accumulators: dict[tuple[int, int], dict[str, int]] = {}
    detail: list[dict] = []

    selected = rows if limit is None else rows[:limit]
    for ordinal, row in enumerate(selected, start=1):
        hart = int(row["hart"], 0)
        absolute = counters[hart]
        package = (absolute >> 16) & 0xFFFF
        sequence = absolute & 0xFFFF
        counters[hart] += 1

        instruction_struct = build_struct(row, package, sequence)
        c0 = crc64_ecma_160(instruction_struct, 0)
        c1 = crc64_ecma_160(instruction_struct, MASK64)
        g0, g1, g2, g3 = mix(c0, c1)
        key = (hart, package)
        acc = accumulators.setdefault(
            key,
            {"xor0": 0, "xor1": 0, "sum0": 0, "sum1": 0,
             "sum2": 0, "sum3": 0, "count": 0},
        )
        acc["xor0"] ^= g0
        acc["xor1"] ^= g1
        acc["sum0"] = (acc["sum0"] + g0) & MASK64
        acc["sum1"] = (acc["sum1"] + g1) & MASK64
        acc["sum2"] = (acc["sum2"] + g2) & MASK64
        acc["sum3"] = (acc["sum3"] + g3) & MASK64
        acc["count"] += 1

        detail.append(
            {
                "ordinal": ordinal,
                "hart": hart,
                "package": package,
                "sequence": sequence,
                "struct": f"{instruction_struct:040x}",
                "c0": f"{c0:016x}",
                "c1": f"{c1:016x}",
                "g0": f"{g0:016x}",
                "g1": f"{g1:016x}",
                "g2": f"{g2:016x}",
                "g3": f"{g3:016x}",
            }
        )

    packages: list[dict] = []
    for (hart, package), acc in sorted(accumulators.items()):
        packages.append(
            {
                "hart": hart,
                "package": package,
                "count": acc["count"],
                **{name: f"{acc[name]:016x}" for name in
                   ("xor0", "xor1", "sum0", "sum1", "sum2", "sum3")},
            }
        )
    return packages, detail


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--detail", type=Path)
    args = parser.parse_args()

    rows = parse_trace(args.trace)
    packages, detail = calculate(rows, args.limit)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(
        json.dumps(
            {
                "algorithm": "CRC-64/ECMA-182 pair plus G/XOR/SUM",
                "polynomial": f"{POLY:016x}",
                "c0_init": "0000000000000000",
                "c1_init": "ffffffffffffffff",
                "k0": f"{K0:016x}",
                "k1": f"{K1:016x}",
                "input_rows": len(rows),
                "hashed_rows": len(detail),
                "packages": packages,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    if args.detail:
        args.detail.parent.mkdir(parents=True, exist_ok=True)
        with args.detail.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=detail[0].keys())
            writer.writeheader()
            writer.writerows(detail)


if __name__ == "__main__":
    main()
