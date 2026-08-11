#!/usr/bin/env python3
"""Compare EH2 and Spike instruction structures, including WAW victims.

EH2 deliberately replaces the result field of a cancelled nonblocking
instruction with zero before hashing it.  Spike executes architecturally and
therefore retains the original result.  Apart from this one documented
difference, all 160-bit fields must match exactly by hart/package/sequence.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


Key = tuple[int, int, int]


def load(path: Path) -> dict[Key, int]:
    values: dict[Key, int] = {}
    for line_number, text in enumerate(
        path.read_text(encoding="ascii").split(), 1
    ):
        if len(text) != 40:
            raise SystemExit(f"{path}:{line_number}: expected 40 hex digits")
        value = int(text, 16)
        key = (
            (value >> 48) & 1,
            (value >> 144) & 0xFFFF,
            (value >> 128) & 0xFFFF,
        )
        if key in values:
            raise SystemExit(f"{path}:{line_number}: duplicate key {key}")
        values[key] = value
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("eh2", type=Path)
    parser.add_argument("spike", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument(
        "--allow-waw-zero",
        action="store_true",
        help="accept EH2 data=0 when every upper field matches Spike",
    )
    args = parser.parse_args()

    eh2 = load(args.eh2)
    spike = load(args.spike)
    missing_eh2 = sorted(set(spike) - set(eh2))
    missing_spike = sorted(set(eh2) - set(spike))
    exact = 0
    waw_keys: list[Key] = []
    mismatches: list[dict[str, object]] = []
    for key in sorted(set(eh2) & set(spike)):
        actual = eh2[key]
        expected = spike[key]
        if actual == expected:
            exact += 1
        elif (
            args.allow_waw_zero
            and (actual >> 32) == (expected >> 32)
            and (actual & 0xFFFF_FFFF) == 0
        ):
            waw_keys.append(key)
        elif len(mismatches) < 32:
            mismatches.append(
                {
                    "key": {
                        "hart": key[0],
                        "package": key[1],
                        "sequence": key[2],
                    },
                    "eh2": f"{actual:040x}",
                    "spike": f"{expected:040x}",
                    "xor": f"{actual ^ expected:040x}",
                }
            )

    grouped: dict[tuple[int, int], list[int]] = defaultdict(list)
    for hart, package, sequence in waw_keys:
        grouped[(hart, package)].append(sequence)
    waw_packages = [
        {
            "hart": hart,
            "package": package,
            "count": len(sequences),
            "sequences": sequences,
        }
        for (hart, package), sequences in sorted(grouped.items())
    ]

    status = "PASS" if not (missing_eh2 or missing_spike or mismatches) else "FAIL"
    report = {
        "status": status,
        "eh2_count": len(eh2),
        "spike_count": len(spike),
        "exact_matches": exact,
        "accepted_waw_zero": len(waw_keys),
        "accepted_waw_packages": waw_packages,
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
        f"exact={exact} waw_zero={len(waw_keys)} "
        f"missing={len(missing_eh2)}/{len(missing_spike)} "
        f"mismatches={len(mismatches)}"
    )
    if status != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
