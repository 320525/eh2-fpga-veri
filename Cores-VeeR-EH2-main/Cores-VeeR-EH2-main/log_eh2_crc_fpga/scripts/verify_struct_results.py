#!/usr/bin/env python3
"""Recompute package results from RTL-emitted 160-bit structures."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

from crc_model import MASK64, crc64_ecma_160, mix


RESULT_RE = re.compile(
    r"hart=(?P<hart>\d+) bank=(?P<bank>\d+) package=(?P<package>\d+) "
    r"count=(?P<count>\d+) xor0=(?P<xor0>[0-9a-fA-F]+) "
    r"xor1=(?P<xor1>[0-9a-fA-F]+) sum0=(?P<sum0>[0-9a-fA-F]+) "
    r"sum1=(?P<sum1>[0-9a-fA-F]+) sum2=(?P<sum2>[0-9a-fA-F]+) "
    r"sum3=(?P<sum3>[0-9a-fA-F]+)"
)

FIELDS = ("xor0", "xor1", "sum0", "sum1", "sum2", "sum3")


def add_struct(acc: dict[str, int], value: int) -> None:
    c0 = crc64_ecma_160(value, 0)
    c1 = crc64_ecma_160(value, MASK64)
    g0, g1, g2, g3 = mix(c0, c1)
    acc["xor0"] ^= g0
    acc["xor1"] ^= g1
    acc["sum0"] = (acc["sum0"] + g0) & MASK64
    acc["sum1"] = (acc["sum1"] + g1) & MASK64
    acc["sum2"] = (acc["sum2"] + g2) & MASK64
    acc["sum3"] = (acc["sum3"] + g3) & MASK64
    acc["count"] += 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("structs", type=Path)
    parser.add_argument("results", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()

    accumulator: dict[tuple[int, int], dict[str, int]] = defaultdict(
        lambda: {"count": 0, **{name: 0 for name in FIELDS}}
    )
    sequences: dict[tuple[int, int], set[int]] = defaultdict(set)
    line_count = 0
    with args.structs.open("r", encoding="ascii") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            if len(text) != 40:
                raise SystemExit(f"bad struct width at line {line_number}: {text}")
            value = int(text, 16)
            package = (value >> 144) & 0xFFFF
            sequence = (value >> 128) & 0xFFFF
            hart = (value >> 48) & 1
            key = (hart, package)
            if sequence in sequences[key]:
                raise SystemExit(
                    f"duplicate sequence hart={hart} package={package} sequence={sequence}"
                )
            sequences[key].add(sequence)
            add_struct(accumulator[key], value)
            line_count += 1

    hardware: dict[tuple[int, int], dict[str, int]] = {}
    with args.results.open("r", encoding="ascii") as handle:
        for line_number, line in enumerate(handle, start=1):
            match = RESULT_RE.fullmatch(line.strip())
            if not match:
                raise SystemExit(f"bad result row at line {line_number}: {line.rstrip()}")
            parsed = {name: int(value, 10 if name in {"hart", "bank", "package", "count"} else 16)
                      for name, value in match.groupdict().items()}
            key = (parsed["hart"], parsed["package"])
            if key in hardware:
                raise SystemExit(f"duplicate hardware result {key}")
            hardware[key] = parsed

    errors: list[str] = []
    packages: list[dict[str, object]] = []
    all_keys = sorted(set(accumulator) | set(hardware))
    for key in all_keys:
        sw = accumulator.get(key)
        hw = hardware.get(key)
        if sw is None or hw is None:
            errors.append(f"missing {'software' if sw is None else 'hardware'} package {key}")
            continue
        expected_sequences = set(range(sw["count"]))
        if sequences[key] != expected_sequences:
            missing = sorted(expected_sequences - sequences[key])[:8]
            extra = sorted(sequences[key] - expected_sequences)[:8]
            errors.append(f"sequence coverage {key}: missing={missing} extra={extra}")
        mismatches = []
        for field in ("count", *FIELDS):
            if sw[field] != hw[field]:
                mismatches.append(
                    f"{field}:sw={sw[field]:x},hw={hw[field]:x}"
                )
        if mismatches:
            errors.append(f"package {key}: " + ", ".join(mismatches))
        packages.append(
            {
                "hart": key[0],
                "package": key[1],
                "count": sw["count"],
                **{name: f"{sw[name]:016x}" for name in FIELDS},
                "hardware_match": not mismatches,
            }
        )

    report = {
        "status": "PASS" if not errors else "FAIL",
        "structure_count": line_count,
        "package_count": len(packages),
        "packages": packages,
        "errors": errors,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"STRUCT_RESULT_{report['status']} structures={line_count} "
        f"packages={len(packages)}"
    )
    for error in errors:
        print(f"ERROR {error}")
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
