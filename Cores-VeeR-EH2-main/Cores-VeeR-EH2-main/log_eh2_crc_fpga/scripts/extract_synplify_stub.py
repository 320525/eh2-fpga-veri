#!/usr/bin/env python3
"""Extract an exact Vivado black-box declaration from a Synplify .vm netlist."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("netlist", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--module", default="eh2_veer_wrapper")
    args = parser.parse_args()

    header: list[str] = []
    declarations: list[str] = []
    state = "search"
    with args.netlist.open("r", encoding="ascii", errors="ignore") as handle:
        for line in handle:
            if state == "search":
                if line.startswith(f"module {args.module} ("):
                    header.append(line)
                    state = "header"
            elif state == "header":
                header.append(line)
                if line.strip() == ";":
                    state = "metadata"
            elif state == "metadata":
                if line.startswith("input ") or line.startswith("output "):
                    declarations.append(line)
                    state = "declarations"
            elif state == "declarations":
                if line.startswith("input ") or line.startswith("output "):
                    declarations.append(line)
                else:
                    break

    if not header or not declarations:
        raise RuntimeError(f"module {args.module} not found in {args.netlist}")
    header[0] = f'(* black_box = "true" *)\nmodule {args.module} (\n'
    body = [
        "// Auto-extracted from the dual-hart Synplify netlist.\n",
        "// Do not hand-edit port widths; regenerate with extract_synplify_stub.py.\n",
        *header,
        *declarations,
        "endmodule\n",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(body), encoding="ascii")
    print(f"ports={len(declarations)} output={args.output}")


if __name__ == "__main__":
    main()
