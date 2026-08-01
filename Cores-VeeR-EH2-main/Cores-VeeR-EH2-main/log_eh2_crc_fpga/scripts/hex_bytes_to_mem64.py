#!/usr/bin/env python3
"""Convert EH2 byte-addressed hex into a fixed-size little-endian mem64 file."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--base", type=lambda value: int(value, 0),
                        default=0x80000000)
    parser.add_argument("--bytes", type=lambda value: int(value, 0),
                        default=128 * 1024)
    args = parser.parse_args()

    image = bytearray(args.bytes)
    address = args.base
    loaded = 0
    for token in args.input.read_text(encoding="ascii").split():
        if token.startswith("@"):
            address = int(token[1:], 16)
            continue
        value = int(token, 16)
        offset = address - args.base
        if not 0 <= offset < args.bytes:
            raise ValueError(f"address 0x{address:08x} outside memory window")
        image[offset] = value
        address += 1
        loaded += 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as handle:
        for offset in range(0, args.bytes, 8):
            word = int.from_bytes(image[offset:offset + 8], "little")
            handle.write(f"{word:016x}\n")
    print(f"loaded_bytes={loaded} words={args.bytes // 8} output={args.output}")


if __name__ == "__main__":
    main()
