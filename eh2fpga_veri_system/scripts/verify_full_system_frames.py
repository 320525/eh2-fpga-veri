#!/usr/bin/env python3
"""Verify full-system TX frames against state codes and Spike hash goldens."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


INFO_CODES = [
    0x11111111,  # preinit done
    0x22222222,  # system function check pass
    0x33333333,  # ready
    0x44444444,  # program write done
    0x55555555,  # EH2 execution done
    0x77777777,  # execution end
    0x33333333,  # END returns to READY; DDR clear completes and READY repeats
]
SYSTEM_SOURCE = bytes.fromhex("0232052500ff")
LOG_SOURCE = bytes.fromhex("0212345678ff")
BROADCAST = b"\xff" * 6
ETHERTYPE = bytes.fromhex("88b5")


def load_frames(path: Path) -> list[bytes]:
    frames: list[bytes] = []
    for line_number, line in enumerate(
        path.read_text(encoding="ascii").splitlines(), 1
    ):
        fields = line.split()
        if len(fields) != 4 or fields[0] != "FRAME":
            raise SystemExit(f"{path}:{line_number}: malformed frame record")
        index = int(fields[1])
        declared_length = int(fields[2])
        data = bytes.fromhex(fields[3])
        if index != len(frames):
            raise SystemExit(f"{path}:{line_number}: non-consecutive index")
        if len(data) != declared_length:
            raise SystemExit(f"{path}:{line_number}: length mismatch")
        frames.append(data)
    return frames


def be_u16(data: bytes) -> int:
    return int.from_bytes(data, "big")


def be_u32(data: bytes) -> int:
    return int.from_bytes(data, "big")


def be_u64(data: bytes) -> int:
    return int.from_bytes(data, "big")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("frames", type=Path)
    parser.add_argument("spike_json", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()

    frames = load_frames(args.frames)
    golden = json.loads(args.spike_json.read_text(encoding="utf-8"))
    golden_packages = {
        (item["hart"], item["package"]): item
        for item in golden["packages"]
    }

    seen_info: list[int] = []
    seen_log: set[tuple[int, int]] = set()
    log_summaries: list[dict[str, object]] = []
    errors: list[str] = []
    for frame_index, frame in enumerate(frames):
        if len(frame) == 60:
            if frame[:6] != BROADCAST:
                errors.append(f"frame {frame_index}: info destination")
            if frame[6:12] != SYSTEM_SOURCE:
                errors.append(f"frame {frame_index}: info source")
            if frame[12:14] != ETHERTYPE:
                errors.append(f"frame {frame_index}: info EtherType")
            code = be_u32(frame[14:18])
            seen_info.append(code)
            if frame[18:20] != bytes.fromhex("0320"):
                errors.append(f"frame {frame_index}: info bytes 5/6")
            if any(frame[20:]):
                errors.append(f"frame {frame_index}: nonzero info padding")
        elif len(frame) == 1038:
            if frame[:6] != BROADCAST:
                errors.append(f"frame {frame_index}: log destination")
            if frame[6:12] != LOG_SOURCE:
                errors.append(f"frame {frame_index}: log source")
            if frame[12:14] != ETHERTYPE:
                errors.append(f"frame {frame_index}: log EtherType")
            package = be_u16(frame[14:16])
            hart = frame[16] & 1
            key = (hart, package)
            count = be_u32(frame[18:22])
            hash_names = ("xor0", "xor1", "sum0", "sum1", "sum2", "sum3")
            hashes = {
                name: f"{be_u64(frame[22 + i*8:30 + i*8]):016x}"
                for i, name in enumerate(hash_names)
            }
            waw_count = be_u16(frame[70:72]) & 0x1FF
            if waw_count > 483:
                errors.append(f"frame {frame_index}: WAW count {waw_count}")
            if any(frame[72 + 2*waw_count:]):
                errors.append(f"frame {frame_index}: nonzero log padding")
            if key not in golden_packages:
                errors.append(f"frame {frame_index}: unexpected key {key}")
            else:
                expected = golden_packages[key]
                if count != expected["count"]:
                    errors.append(
                        f"frame {frame_index}: count {count} != "
                        f"{expected['count']}"
                    )
                for name in hash_names:
                    if hashes[name] != expected[name]:
                        errors.append(
                            f"frame {frame_index}: {name} {hashes[name]} "
                            f"!= {expected[name]}"
                        )
            if key in seen_log:
                errors.append(f"frame {frame_index}: duplicate log key {key}")
            seen_log.add(key)
            log_summaries.append(
                {
                    "frame": frame_index,
                    "hart": hart,
                    "package": package,
                    "count": count,
                    "waw_count": waw_count,
                    **hashes,
                }
            )
        else:
            errors.append(
                f"frame {frame_index}: unexpected length {len(frame)}"
            )

    if seen_info != INFO_CODES:
        errors.append(
            "system code sequence "
            f"{[f'{value:08x}' for value in seen_info]} != "
            f"{[f'{value:08x}' for value in INFO_CODES]}"
        )
    if seen_log != set(golden_packages):
        errors.append(
            f"log keys {sorted(seen_log)} != {sorted(golden_packages)}"
        )

    report = {
        "status": "PASS" if not errors else "FAIL",
        "frame_count": len(frames),
        "system_codes": [f"{value:08x}" for value in seen_info],
        "log_frames": log_summaries,
        "errors": errors,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"FULL_SYSTEM_FRAME_{report['status']} frames={len(frames)} "
        f"info={len(seen_info)} log={len(seen_log)} errors={len(errors)}"
    )
    if errors:
        for error in errors[:32]:
            print(f"ERROR: {error}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
