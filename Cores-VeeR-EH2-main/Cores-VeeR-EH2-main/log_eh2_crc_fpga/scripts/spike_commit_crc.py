#!/usr/bin/env python3
"""Convert Spike --log-commits output to EH2 instruction structs and hashes."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

from crc_model import MASK64, crc64_ecma_160, mix

TRACE_RE = re.compile(
    r"^core\s+(?P<hart>\d+): 0x(?P<pc>[0-9a-fA-F]+) "
    r"\(0x(?P<insn>[0-9a-fA-F]+)\)"
)
COMMIT_RE = re.compile(
    r"^core\s+(?P<hart>\d+): (?P<priv>\d+) 0x(?P<pc>[0-9a-fA-F]+) "
    r"\(0x(?P<insn>[0-9a-fA-F]+)\)(?P<effects>.*)$"
)
GPR_RE = re.compile(r"(?:^|\s)x(?P<num>\d+)\s+0x(?P<data>[0-9a-fA-F]+)")
CSR_RE = re.compile(r"(?:^|\s)c(?P<num>\d+)_\S+\s+0x(?P<data>[0-9a-fA-F]+)")
STOP_RE = re.compile(r"\bmem\s+0xd0580000\s+0x(?:00)?320525\b", re.IGNORECASE)

FIELDS = ("xor0", "xor1", "sum0", "sum1", "sum2", "sum3")


def make_struct(
    package: int,
    sequence: int,
    pc: int,
    insn: int,
    hart: int,
    priv: int,
    event: int,
    target: int,
    data: int,
) -> int:
    metadata = ((hart & 1) << 16) | ((priv & 3) << 14) | ((event & 3) << 12) | (target & 0xFFF)
    return (
        ((package & 0xFFFF) << 144)
        | ((sequence & 0xFFFF) << 128)
        | ((pc & 0xFFFFFFFF) << 96)
        | ((insn & 0xFFFFFFFF) << 64)
        | (metadata << 32)
        | (data & 0xFFFFFFFF)
    )


def update(acc: dict[str, int], value: int) -> None:
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
    parser.add_argument("log", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--structs", type=Path)
    parser.add_argument("--start", type=lambda text: int(text, 0), default=0x80000000)
    args = parser.parse_args()

    pending: dict[int, tuple[int, int]] = {}
    stopped: set[int] = set()
    counters: dict[int, int] = defaultdict(int)
    accumulators: dict[tuple[int, int], dict[str, int]] = defaultdict(
        lambda: {"count": 0, **{name: 0 for name in FIELDS}}
    )
    struct_handle = args.structs.open("w", encoding="ascii") if args.structs else None
    try:
        with args.log.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                trace = TRACE_RE.match(line)
                if trace:
                    hart = int(trace["hart"])
                    pending[hart] = (int(trace["pc"], 16), int(trace["insn"], 16))
                    continue
                commit = COMMIT_RE.match(line)
                if not commit:
                    continue
                hart = int(commit["hart"])
                if hart in stopped:
                    continue
                pc = int(commit["pc"], 16)
                insn = int(commit["insn"], 16)
                if pending.get(hart) != (pc, insn):
                    raise SystemExit(f"unpaired Spike commit hart={hart} pc={pc:08x}")
                pending.pop(hart, None)
                if pc < args.start:
                    continue

                effects = commit["effects"]
                event = 0
                target = 0
                data = 0
                csr = CSR_RE.search(effects)
                gpr = GPR_RE.search(effects)
                if csr:
                    event = 2
                    target = int(csr["num"])
                    data = int(csr["data"], 16)
                elif gpr:
                    event = 1
                    target = int(gpr["num"])
                    data = int(gpr["data"], 16)

                absolute = counters[hart]
                package = (absolute >> 16) & 0xFFFF
                sequence = absolute & 0xFFFF
                value = make_struct(
                    package, sequence, pc, insn, hart, int(commit["priv"]),
                    event, target, data,
                )
                update(accumulators[(hart, package)], value)
                counters[hart] += 1
                if struct_handle:
                    struct_handle.write(f"{value:040x}\n")
                if STOP_RE.search(effects):
                    stopped.add(hart)
    finally:
        if struct_handle:
            struct_handle.close()

    packages = []
    for (hart, package), acc in sorted(accumulators.items()):
        packages.append(
            {
                "hart": hart,
                "package": package,
                "count": acc["count"],
                **{name: f"{acc[name]:016x}" for name in FIELDS},
            }
        )
    report = {
        "algorithm": "CRC-64/ECMA-182 pair plus G/XOR/SUM",
        "source": str(args.log),
        "stopped_harts": sorted(stopped),
        "commit_count": {str(hart): count for hart, count in sorted(counters.items())},
        "packages": packages,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if set(counters) != stopped:
        raise SystemExit("not every executing hart reached the 0xD0580000/0x00320525 marker")


if __name__ == "__main__":
    main()
