#!/usr/bin/env python3
"""Compare captured hardware instruction structs with reference detail CSV."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


FIELDS = (
    ("package", 144, 16), ("sequence", 128, 16),
    ("pc", 96, 32), ("instruction", 64, 32),
    ("metadata", 32, 32), ("data", 0, 32),
)


def split(value: int) -> dict[str, int]:
    return {name: (value >> shift) & ((1 << width) - 1)
            for name, shift, width in FIELDS}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("actual", type=Path)
    parser.add_argument("expected_csv", type=Path)
    args = parser.parse_args()

    actual_values = [int(line.strip(), 16) for line in
                     args.actual.read_text(encoding="ascii").splitlines()
                     if line.strip()]
    actual = {(value >> 128) & 0xFFFFFFFF: value for value in actual_values}
    with args.expected_csv.open(newline="", encoding="ascii") as handle:
        expected_rows = list(csv.DictReader(handle))
    expected = {((int(row["package"]) << 16) | int(row["sequence"])):
                int(row["struct"], 16) for row in expected_rows}

    print(f"actual={len(actual_values)} unique={len(actual)} expected={len(expected)}")
    mismatches = 0
    for key in sorted(set(actual) | set(expected)):
        if key not in actual or key not in expected:
            print(f"missing key=0x{key:08x} actual={key in actual} expected={key in expected}")
            mismatches += 1
            continue
        if actual[key] != expected[key]:
            a = split(actual[key])
            e = split(expected[key])
            changed = [f"{name}:actual={a[name]:x},expected={e[name]:x}"
                       for name, _, _ in FIELDS if a[name] != e[name]]
            print(f"mismatch key=0x{key:08x} " + " ".join(changed))
            mismatches += 1
            if mismatches >= 30:
                break
    print(f"mismatches_shown={mismatches}")


if __name__ == "__main__":
    main()
