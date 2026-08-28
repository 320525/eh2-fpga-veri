#!/usr/bin/env python3
"""Restore EH2's private hart-start CSR in a Spike compatibility trace.

The hardware ELF executes ``csrw 0x7fc, x31`` on hart 0.  Stock Spike does
not implement that private EH2 CSR, so the Spike-only ELF executes a NOP at
the same PC while ``-p2`` supplies both harts.  This script replaces exactly
that one hart-0 trace/commit pair with the real instruction and CSR effect.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


TRACE_RE = re.compile(
    r"^(core\s+0:\s+0x(?:0*)8000000c\s+)\(0x00000013\)(?:\s.*)?$"
)
COMMIT_RE = re.compile(
    r"^(core\s+0:\s+\d+\s+0x(?:0*)8000000c\s+)"
    r"\(0x00000013\)(?:\s.*)?$"
)
HART1_PC_RE = re.compile(r"^core\s+1:.*0x(?:0*)8000000c\b")

REAL_INSN = "0x7fcf9073"
REAL_EFFECT = "c2044_mhartstart 0x00000002"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    trace_count = 0
    commit_count = 0
    hart1_count = 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.input.open("r", encoding="utf-8", errors="replace") as source:
        with args.output.open("w", encoding="utf-8", newline="\n") as target:
            for line in source:
                text = line.rstrip("\r\n")
                trace = TRACE_RE.match(text)
                commit = COMMIT_RE.match(text)
                if trace:
                    text = f"{trace.group(1)}({REAL_INSN}) csrw 0x7fc, t6"
                    trace_count += 1
                elif commit:
                    text = (
                        f"{commit.group(1)}({REAL_INSN}) "
                        f"{REAL_EFFECT}"
                    )
                    commit_count += 1
                if HART1_PC_RE.match(text):
                    hart1_count += 1
                target.write(text + "\n")

    if (trace_count, commit_count, hart1_count) != (1, 1, 0):
        raise SystemExit(
            "unexpected private-CSR execution counts: "
            f"hart0 trace={trace_count}, hart0 commit={commit_count}, "
            f"hart1 pc={hart1_count}"
        )
    print(
        "SPIKE_HARTSTART_RESTORE_PASS "
        f"trace={trace_count} commit={commit_count} hart1_pc={hart1_count}"
    )


if __name__ == "__main__":
    main()
