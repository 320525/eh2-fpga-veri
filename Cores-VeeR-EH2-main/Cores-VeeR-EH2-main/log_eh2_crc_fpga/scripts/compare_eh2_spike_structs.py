#!/usr/bin/env python3
"""Compare EH2 and Spike 160-bit instruction structs by hart/package/sequence."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(path: Path) -> dict[tuple[int, int, int], int]:
    values: dict[tuple[int, int, int], int] = {}
    for line_number, text in enumerate(path.read_text(encoding="ascii").split(), 1):
        if len(text) != 40:
            raise SystemExit(f"{path}:{line_number}: expected 40 hex digits")
        value = int(text, 16)
        key = ((value >> 48) & 1, (value >> 144) & 0xFFFF,
               (value >> 128) & 0xFFFF)
        if key in values:
            raise SystemExit(f"{path}:{line_number}: duplicate key {key}")
        values[key] = value
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("eh2", type=Path)
    parser.add_argument("spike", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--allow-waw-zero", action="store_true",
                        help="accept EH2 data=0 when every upper field matches")
    args = parser.parse_args()

    eh2 = load(args.eh2)
    spike = load(args.spike)
    missing_eh2 = sorted(set(spike) - set(eh2))
    missing_spike = sorted(set(eh2) - set(spike))
    exact = 0
    waw_zero = 0
    mismatches: list[dict[str, object]] = []
    for key in sorted(set(eh2) & set(spike)):
        actual = eh2[key]
        expected = spike[key]
        if actual == expected:
            exact += 1
        elif (args.allow_waw_zero and (actual >> 32) == (expected >> 32)
              and (actual & 0xFFFF_FFFF) == 0):
            waw_zero += 1
        elif len(mismatches) < 32:
            mismatches.append({
                "key": {"hart": key[0], "package": key[1],
                        "sequence": key[2]},
                "eh2": f"{actual:040x}",
                "spike": f"{expected:040x}",
                "xor": f"{actual ^ expected:040x}",
            })

    status = "PASS" if not (missing_eh2 or missing_spike or mismatches) else "FAIL"
    report = {
        "status": status,
        "eh2_count": len(eh2),
        "spike_count": len(spike),
        "exact_matches": exact,
        "accepted_waw_zero": waw_zero,
        "missing_eh2_count": len(missing_eh2),
        "missing_spike_count": len(missing_spike),
        "missing_eh2_sample": missing_eh2[:32],
        "missing_spike_sample": missing_spike[:32],
        "mismatches": mismatches,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"EH2_SPIKE_STRUCT_{status} eh2={len(eh2)} spike={len(spike)} "
        f"exact={exact} waw_zero={waw_zero} missing={len(missing_eh2)}/"
        f"{len(missing_spike)} mismatches={len(mismatches)}"
    )
    if status != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
