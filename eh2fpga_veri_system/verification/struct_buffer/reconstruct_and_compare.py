#!/usr/bin/env python3
"""Reconstruct server EH2 events and compare with Vivado pre-CRC structs."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


PAIR_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]+)")


def fields(line: str) -> dict[str, str]:
    return dict(PAIR_RE.findall(line.strip()))


def integer(row: dict[str, str], name: str, base: int = 10) -> int:
    return int(row[name], base)


def make_struct(
    package: int,
    sequence: int,
    pc: int,
    insn: int,
    hart: int,
    priv: int,
    event: int,
    reg: int,
    data: int,
) -> int:
    metadata = ((hart & 1) << 16) | ((priv & 3) << 14) | ((event & 3) << 12) | (reg & 0xFFF)
    return (
        ((package & 0xFFFF) << 144)
        | ((sequence & 0xFFFF) << 128)
        | ((pc & 0xFFFFFFFF) << 96)
        | ((insn & 0xFFFFFFFF) << 64)
        | ((metadata & 0xFFFFFFFF) << 32)
        | (data & 0xFFFFFFFF)
    )


def key_from_struct(value: int) -> tuple[int, int, int]:
    return ((value >> 48) & 1, (value >> 144) & 0xFFFF, (value >> 128) & 0xFFFF)


def load_actual(
    path: Path,
) -> tuple[
    dict[tuple[int, int, int], int],
    dict[tuple[int, int, int], str],
]:
    result: dict[tuple[int, int, int], int] = {}
    sources: dict[tuple[int, int, int], str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        row = fields(line)
        if line.startswith("STRUCT "):
            value = int(row["value"], 16)
            key = key_from_struct(value)
            if key in result:
                raise ValueError(f"duplicate Vivado key {key}")
            result[key] = value
            sources[key] = row["source"]
    return result, sources


def load_summary(path: Path) -> dict[str, int | str]:
    summary: dict[str, int | str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("SUMMARY "):
            for name, value in fields(line).items():
                summary[name] = int(value) if value.isdigit() else value
    return summary


def load_server_monitor_summary(path: Path) -> dict[str, int]:
    summary: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("SUMMARY "):
            continue
        for name, value in fields(line).items():
            if "/" in value:
                hart0, hart1 = value.split("/", 1)
                summary[f"{name}_hart0"] = int(hart0)
                summary[f"{name}_hart1"] = int(hart1)
            else:
                summary[name] = int(value)
    return summary


def reconstruct(
    path: Path, pc_offset: int
) -> tuple[dict[tuple[int, int, int], int], dict[str, int]]:
    sequence = [0, 0]
    package = [0, 0]
    pending: dict[tuple[int, int], int] = {}
    expected: dict[tuple[int, int, int], int] = {}
    stats = {"raw_cycles": 0, "commits": 0, "nonblock_commits": 0,
             "waw_events": 0, "atomic_handoffs": 0, "reference_conflicts": 0}

    def emit(value: int) -> None:
        key = key_from_struct(value)
        if key in expected:
            raise ValueError(f"duplicate reference key {key}")
        expected[key] = value

    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("IF "):
            continue
        row = fields(line)
        stats["raw_cycles"] += 1
        cv = int(row["cv"], 16)
        nw = int(row["nw"], 16)

        cancel_keys: set[tuple[int, int]] = set()
        for lane in range(2):
            if (nw >> lane) & 1:
                cancel_keys.add((integer(row, f"nw{lane}_h"), integer(row, f"nw{lane}_rd")))
                stats["waw_events"] += 1

        allocs: list[tuple[tuple[int, int], int]] = []
        for lane in range(2):
            if not ((cv >> lane) & 1):
                continue
            stats["commits"] += 1
            p = package[integer(row, f"c{lane}_h")]
            s = sequence[integer(row, f"c{lane}_h")]
            hart = integer(row, f"c{lane}_h")
            rd = integer(row, f"c{lane}_rd")
            is_nb = integer(row, f"c{lane}_nb")
            is_load = integer(row, f"c{lane}_nbl")
            is_div = integer(row, f"c{lane}_nbd")
            lr_match = bool(is_load and integer(row, "lr") and
                            integer(row, "lr_h") == hart and integer(row, "lr_rd") == rd)
            dr_match = bool(is_div and integer(row, "dr") and
                            integer(row, "dr_h") == hart and integer(row, "dr_rd") == rd)
            same_return = lr_match or dr_match

            event = 0
            reg = 0
            data = 0
            if integer(row, f"c{lane}_wawv") and rd != 0:
                event, reg, data = 1, rd, 0
            elif integer(row, f"c{lane}_csrwen"):
                event = 2
                reg = integer(row, f"c{lane}_csr", 16)
                data = integer(row, f"c{lane}_csrdata", 16)
            elif integer(row, f"c{lane}_gwen") and rd != 0:
                event, reg = 1, rd
                data = integer(row, f"c{lane}_wdata", 16)
            elif is_nb and integer(row, f"c{lane}_gint") and rd != 0:
                event, reg = 1, rd
                if same_return:
                    data = integer(row, "lr_data" if is_load else "dr_data", 16)

            # The server testbench resets at 0 while the Vivado project resets
            # at 0x8000_0000.  PC-relative setup instructions therefore create
            # the same offset but an address-valued GPR result separated by the
            # reset-base offset.  Normalize only the linked RAM/stack window;
            # ordinary program data remains bit-exact and untouched.
            if pc_offset and 0x00010000 <= data < 0x00020000:
                data = (data + pc_offset) & 0xFFFFFFFF

            value = make_struct(
                p, s, (integer(row, f"c{lane}_pc", 16) + pc_offset) & 0xFFFFFFFF,
                integer(row, f"c{lane}_insn", 16), hart,
                integer(row, f"c{lane}_priv"), event, reg, data,
            )
            alloc_request = bool(is_nb and integer(row, f"c{lane}_gint") and
                                 rd != 0 and not integer(row, f"c{lane}_wawv") and
                                 not same_return)
            if alloc_request:
                allocs.append(((hart, rd), value))
                stats["nonblock_commits"] += 1
            else:
                emit(value)

            if sequence[hart] == 0xFFFF:
                sequence[hart] = 0
                package[hart] = (package[hart] + 1) & 0xFFFF
            else:
                sequence[hart] += 1

        # Allocation acceptance uses the state visible before this clock edge.
        # A return in this cycle does not make the slot allocatable; only an
        # EH2-confirmed WAW cancellation permits the atomic same-edge handoff.
        accepted_allocs: list[tuple[tuple[int, int], int]] = []
        accepted_owners: set[tuple[int, int]] = set()
        occupied_before = set(pending)
        for owner, value in allocs:
            atomic = owner in occupied_before and owner in cancel_keys
            if owner in accepted_owners or (owner in occupied_before and not atomic):
                stats["reference_conflicts"] += 1
            else:
                accepted_allocs.append((owner, value))
                accepted_owners.add(owner)
                if atomic:
                    stats["atomic_handoffs"] += 1

        # Resolve/cancel old owners using the state visible before allocations.
        for owner in list(pending):
            if owner in cancel_keys:
                emit(pending.pop(owner) & ~0xFFFFFFFF)
            elif integer(row, "lr") and owner == (integer(row, "lr_h"), integer(row, "lr_rd")):
                emit((pending.pop(owner) & ~0xFFFFFFFF) | integer(row, "lr_data", 16))
            elif integer(row, "dr") and owner == (integer(row, "dr_h"), integer(row, "dr_rd")):
                emit((pending.pop(owner) & ~0xFFFFFFFF) | integer(row, "dr_data", 16))

        for owner, value in accepted_allocs:
            pending[owner] = value

    stats["pending_at_end"] = len(pending)
    return expected, stats


def write_sorted(path: Path, records: dict[tuple[int, int, int], int]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        for (hart, package, sequence), value in sorted(records.items()):
            stream.write(
                f"hart={hart} package={package} sequence={sequence} struct={value:040x}\n"
            )


ABI_NAMES = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0/fp", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
]


def load_direct_waw_keys(path: Path) -> set[tuple[int, int, int]]:
    sequence = [0, 0]
    package = [0, 0]
    result: set[tuple[int, int, int]] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("COMMIT "):
            continue
        row = fields(line)
        hart = int(row["hart"])
        key = (hart, package[hart], sequence[hart])
        if int(row["direct_waw"]):
            result.add(key)
        if sequence[hart] == 0xFFFF:
            sequence[hart] = 0
            package[hart] = (package[hart] + 1) & 0xFFFF
        else:
            sequence[hart] += 1
    return result


def load_disassembly(path: Path, pc_offset: int) -> dict[int, str]:
    result: dict[int, str] = {}
    pattern = re.compile(r"^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F]{8}\s+(.+)$")
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = pattern.match(line)
        if match:
            pc = (int(match.group(1), 16) + pc_offset) & 0xFFFFFFFF
            result[pc] = " ".join(match.group(2).strip().split())
    return result


def write_readable(
    path: Path,
    records: dict[tuple[int, int, int], int],
    sources: dict[tuple[int, int, int], str],
    direct_waw_keys: set[tuple[int, int, int]],
    disassembly: dict[int, str],
) -> None:
    privilege_names = {0: "U", 1: "S", 2: "reserved", 3: "M"}
    event_names = {0: "NONE", 1: "GPR", 2: "CSR", 3: "reserved"}
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(
            "# 160-bit layout: [159:144]=package [143:128]=sequence "
            "[127:96]=pc [95:64]=instruction [63:32]=metadata "
            "[31:0]=data\n"
        )
        stream.write(
            "# metadata: [16]=hart [15:14]=privilege [13:12]=event "
            "[11:0]=GPR rd or CSR address; [31:17] must be zero\n"
        )
        stream.write(
            "# WAW cancellation is decoded from the capture source for an "
            "older pending nonblock victim and from direct_waw for an "
            "i0/i1 same-cycle victim.\n"
        )
        for index, (key, value) in enumerate(sorted(records.items())):
            hart, package, sequence = key
            pc = (value >> 96) & 0xFFFFFFFF
            insn = (value >> 64) & 0xFFFFFFFF
            metadata = (value >> 32) & 0xFFFFFFFF
            data = value & 0xFFFFFFFF
            metadata_hart = (metadata >> 16) & 1
            privilege = (metadata >> 14) & 3
            event = (metadata >> 12) & 3
            reg = metadata & 0xFFF
            reserved = (metadata >> 17) & 0x7FFF
            source = sources.get(key, "unknown")
            if source == "atomic_waw_victim":
                waw = "yes"
                waw_reason = "pending_nonblock_victim"
            elif key in direct_waw_keys:
                waw = "yes"
                waw_reason = "same_cycle_commit_victim"
            else:
                waw = "no"
                waw_reason = "-"
            if event == 1 and reg < 32:
                target = f"x{reg}({ABI_NAMES[reg]})"
                data_text = f"0x{data:08x}"
            elif event == 2:
                target = f"csr_0x{reg:03x}"
                data_text = f"0x{data:08x}"
            else:
                target = "-"
                data_text = "-" if event == 0 else f"0x{data:08x}"
            asm = disassembly.get(pc, "-").replace("\t", " ")
            stream.write(
                f"index={index:04d} hart={hart} metadata_hart={metadata_hart} "
                f"package={package} sequence={sequence} "
                f"pc=0x{pc:08x} instruction=0x{insn:08x} "
                f"asm=\"{asm}\" privilege={privilege_names[privilege]} "
                f"event={event_names[event]} target={target} data={data_text} "
                f"waw_cancelled={waw} waw_reason={waw_reason} source={source} "
                f"metadata=0x{metadata:08x} reserved=0x{reserved:04x} "
                f"struct=0x{value:040x}\n"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("case_dir", type=Path)
    parser.add_argument(
        "--server-pc-offset", type=lambda value: int(value, 0),
        default=0x80000000,
        help="translate the server reset base to the Vivado reset base",
    )
    args = parser.parse_args()
    raw = args.case_dir / "server_eh2_interface_raw.log"
    unsorted = args.case_dir / "vivado_structs_unsorted.log"
    reconstructed_all, reference_stats = reconstruct(raw, args.server_pc_offset)
    server_monitor_summary = load_server_monitor_summary(
        args.case_dir / "server_crc_monitor_unsorted.log"
    )
    # The historical server testbench performs a second 0xff mailbox write a
    # few commits after the current CRC stop word.  Keep the original log
    # untouched, but compare only the per-hart prefix that the CRC monitor says
    # belongs to the active session.
    expected: dict[tuple[int, int, int], int] = {}
    taken = [0, 0]
    limits = [
        server_monitor_summary.get("generated_hart0", 0),
        server_monitor_summary.get("generated_hart1", 0),
    ]
    for key, value in sorted(reconstructed_all.items()):
        hart = key[0]
        if taken[hart] < limits[hart]:
            expected[key] = value
            taken[hart] += 1
    reference_stats["ignored_after_crc_stop"] = (
        len(reconstructed_all) - len(expected)
    )
    actual, actual_sources = load_actual(unsorted)
    vivado_summary = load_summary(args.case_dir / "vivado_interface.log")
    write_sorted(
        args.case_dir / "server_reconstructed_all_sorted.log",
        reconstructed_all,
    )
    write_sorted(
        args.case_dir / "server_reconstructed_structs_sorted.log", expected
    )
    write_sorted(args.case_dir / "vivado_structs_sorted.log", actual)
    write_readable(
        args.case_dir / "fpga_structs_sorted_readable.log",
        actual,
        actual_sources,
        load_direct_waw_keys(args.case_dir / "vivado_interface.log"),
        load_disassembly(
            args.case_dir / "server_program.dis", args.server_pc_offset
        ),
    )

    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    mismatches = [key for key in sorted(set(expected) & set(actual))
                  if expected[key] != actual[key]]
    status = "PASS" if not missing and not extra and not mismatches else "FAIL"
    report = {
        "status": status,
        "reference_count": len(expected),
        "vivado_count": len(actual),
        "missing_count": len(missing),
        "extra_count": len(extra),
        "mismatch_count": len(mismatches),
        "missing_sample": missing[:16],
        "extra_sample": extra[:16],
        "mismatch_sample": [
            {"key": key, "reference": f"{expected[key]:040x}", "rtl": f"{actual[key]:040x}"}
            for key in mismatches[:16]
        ],
        "reference_stats": reference_stats,
        "server_crc_monitor_summary": server_monitor_summary,
        "vivado_summary": vivado_summary,
        "server_log_note": (
            "server_eh2_original.log is the untouched EH2 exec.log; "
            "server_eh2_interface_raw.log is the untouched interface trace "
            "used only as reconstruction input"
        ),
    }
    (args.case_dir / "comparison.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(
        f"STRUCT_COMPARE_{status} reference={len(expected)} rtl={len(actual)} "
        f"missing={len(missing)} extra={len(extra)} mismatch={len(mismatches)} "
        f"handoff={vivado_summary.get('atomic_handoff', -1)} "
        f"conflicts={vivado_summary.get('conflict', -1)}"
    )
    if status != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
