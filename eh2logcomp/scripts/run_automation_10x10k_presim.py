#!/usr/bin/env python3
"""Run two strictly sequential local-program full-top XSim regressions by default."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
WEBUI_ROOT = ROOT / "webui"
sys.path.insert(0, str(WEBUI_ROOT))

from eh2web.info_log import DecodedInfoTextWriter  # noqa: E402
from eh2web.comparator import _iter_fpga_frames  # noqa: E402


VIVADO = Path(r"D:\vivado23\Vivado\2023.2\bin\vivado.bat")
PROGRAM_BUILD = ROOT / "programs" / "riscvdv_10k_top" / "build"
TX_CAPTURE = ROOT / "artifacts" / "sim" / "full_system_tx_frames.log"
FRAME_PATTERN = re.compile(r"^FRAME\s+(\d+)\s+(\d+)\s+([0-9a-fA-F]+)$")
INFO_ETHERTYPES = {b"\x88\xb7", b"\x88\xb8"}
HART_MAC = {bytes.fromhex("023205251000"): 0, bytes.fromhex("023205251001"): 1}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def prepare_program(seed: int, round_dir: Path) -> tuple[dict, dict]:
    PROGRAM_BUILD.mkdir(parents=True, exist_ok=True)
    program = PROGRAM_BUILD / "riscvdv_10k_program.bin"
    generator_manifest = round_dir / "fast_program_manifest.json"
    expected_svh = PROGRAM_BUILD / "riscvdv_10k_expected_params.svh"
    generate = [
        sys.executable,
        str(ROOT / "scripts" / "generate_fast_dualhart_program.py"),
        str(program), "--seed", str(seed), "--records-per-hart", "10000",
        "--manifest", str(generator_manifest), "--expected-svh", str(expected_svh),
    ]
    completed = subprocess.run(generate, cwd=ROOT, check=True, text=True,
                               capture_output=True)
    if completed.stdout.strip():
        print(f"PROGRAM_GENERATED seed={seed} {completed.stdout.strip()}", flush=True)
    shutil.copy2(program, round_dir / "program.bin")

    make_images = [
        sys.executable,
        str(ROOT / "scripts" / "make_program_images.py"),
        str(program), str(PROGRAM_BUILD),
        "--base", "0x80000000", "--memory-bytes", "0x100000",
        "--prefix", "riscvdv_10k", "--macro-prefix", "RISCV_DV",
    ]
    completed = subprocess.run(make_images, cwd=ROOT, check=True, text=True,
                               capture_output=True)
    if completed.stdout.strip():
        print(completed.stdout.strip(), flush=True)
    image_path = PROGRAM_BUILD / "riscvdv_10k_image_manifest.json"
    return (
        json.loads(generator_manifest.read_text(encoding="utf-8")),
        json.loads(image_path.read_text(encoding="utf-8")),
    )


def run_full_top(round_dir: Path) -> Path:
    if TX_CAPTURE.exists():
        TX_CAPTURE.unlink()
    console_path = round_dir / "vivado_full_top_console.log"
    command = [
        str(VIVADO), "-mode", "batch",
        "-source", str(ROOT / "scripts" / "run_full_system_sim.tcl"),
        "-tclargs", "riscvdv_10k",
    ]
    interesting = (
        "LINE_RATE_", "SYSTEM_TX", "EXECUTE_PROGRESS", "INFO_DUMP_EXPECT",
        "INFO_DATA_TX", "INFO_DONE_TX", "FULL_SYSTEM_RGMII_PASS",
        "FATAL", "ERROR:", "TB_PASS", "TB_FAIL",
    )
    with console_path.open("w", encoding="utf-8", errors="replace") as log:
        process = subprocess.Popen(
            command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            if any(marker in line for marker in interesting):
                print(line.rstrip(), flush=True)
        return_code = process.wait()
    if return_code:
        raise RuntimeError(f"Vivado/XSim failed with exit code {return_code}")
    console_text = console_path.read_text(encoding="utf-8", errors="replace")
    if "FULL_SYSTEM_RGMII_PASS" not in console_text:
        raise RuntimeError("full-top simulation did not print FULL_SYSTEM_RGMII_PASS")
    if not TX_CAPTURE.is_file():
        raise FileNotFoundError(TX_CAPTURE)
    archived_capture = round_dir / "full_system_tx_frames.log"
    shutil.copy2(TX_CAPTURE, archived_capture)
    return archived_capture


def convert_capture(capture: Path, output: Path) -> dict[str, int]:
    """Convert top-level TX evidence through the production readable TXT writer."""

    writer = DecodedInfoTextWriter(output)
    data_frames = 0
    done_frames = 0
    source_counts = {0: 0, 1: 0}
    try:
        timestamp = time.time_ns()
        for line_number, line in enumerate(
            capture.read_text(encoding="ascii").splitlines(), start=1
        ):
            match = FRAME_PATTERN.fullmatch(line)
            if not match:
                raise ValueError(f"invalid TX capture line {line_number}: {line[:80]}")
            declared_length = int(match.group(2))
            raw = bytes.fromhex(match.group(3))
            if len(raw) != declared_length:
                raise ValueError(
                    f"TX capture line {line_number} length {len(raw)}/{declared_length}"
                )
            if raw[12:14] not in INFO_ETHERTYPES:
                continue
            if raw[6:12] not in HART_MAC:
                raise ValueError(f"unexpected Info source MAC {raw[6:12].hex()}")
            hart = HART_MAC[raw[6:12]]
            source_counts[hart] += 1
            if raw[12:14] == b"\x88\xb7":
                data_frames += 1
            else:
                done_frames += 1
            writer.write_raw(raw, timestamp_ns=timestamp)
            timestamp += 1
    finally:
        writer.close()
    if data_frames == 0 or done_frames != 2 or any(count == 0 for count in source_counts.values()):
        raise RuntimeError(
            f"incomplete Info archive: data={data_frames} done={done_frames} "
            f"sources={source_counts}"
        )
    return {
        "data_frames": data_frames,
        "done_frames": done_frames,
        "hart0_frames_including_done": source_counts[0],
        "hart1_frames_including_done": source_counts[1],
    }


def verify_webui_info_log(path: Path, minimum_records: int = 10_000,
                          maximum_records: int = 10_016) -> dict:
    data: dict[int, list[bytes]] = {0: [], 1: []}
    done: dict[int, dict[str, int]] = {}
    # Reconstruct Ethernet frames from the same TXT representation consumed
    # by the Windows comparator.  This verifies that no information needed by
    # the comparator is lost when the human-readable log is written.
    for _, raw in _iter_fpga_frames(path):
        if raw[6:12] not in HART_MAC:
            raise ValueError("WebUI log reader saw an unknown source MAC")
        hart = HART_MAC[raw[6:12]]
        if raw[12:14] == b"\x88\xb7":
            if len(raw) != 1458:
                raise ValueError(f"hart{hart} data-frame length {len(raw)}")
            data[hart].append(raw)
        elif raw[12:14] == b"\x88\xb8":
            if len(raw) != 60 or hart in done:
                raise ValueError(f"hart{hart} invalid/duplicate completion frame")
            done[hart] = {
                "records": int.from_bytes(raw[22:26], "big"),
                "frames": int.from_bytes(raw[26:30], "big"),
                "last_sequence": int.from_bytes(raw[30:34], "big"),
            }
        else:
            raise ValueError("unexpected EtherType in WebUI Info log")

    if set(done) != {0, 1}:
        raise ValueError(f"missing completion frame: {done}")
    result: dict[str, object] = {"status": "PASS", "done": done}
    for hart in (0, 1):
        declaration = done[hart]
        declared_records = declaration["records"]
        if not minimum_records <= declared_records <= maximum_records:
            raise ValueError(
                f"hart{hart} records {declared_records} outside "
                f"{minimum_records}..{maximum_records}"
            )
        expected_frames = (declared_records + 59) // 60
        if declaration["frames"] != expected_frames or len(data[hart]) != expected_frames:
            raise ValueError(
                f"hart{hart} frames {len(data[hart])}/{declaration['frames']}/{expected_frames}"
            )
        if declaration["last_sequence"] != declared_records - 1:
            raise ValueError(f"hart{hart} bad last sequence")
        sequences: list[int] = []
        for frame_index, raw in enumerate(data[hart]):
            valid = min(60, declared_records - frame_index * 60)
            for record_index in range(valid):
                start = 18 + record_index * 24
                sequences.append(int.from_bytes(raw[start:start + 4], "big"))
            padding_start = 18 + valid * 24
            if any(raw[padding_start:]):
                raise ValueError(f"hart{hart} final-frame padding is nonzero")
        if len(sequences) != declared_records or len(set(sequences)) != declared_records:
            raise ValueError(f"hart{hart} duplicate/missing sequence")
        if min(sequences) != 0 or max(sequences) != declared_records - 1:
            raise ValueError(f"hart{hart} sequence range is not dense")
        result[f"hart{hart}_records"] = len(sequences)
        result[f"hart{hart}_data_frames"] = len(data[hart])
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--seed-base", type=int, default=32052531)
    args = parser.parse_args()
    if args.rounds <= 0:
        raise SystemExit("round count must be positive")

    campaign_id = time.strftime("campaign_%Y%m%d_%H%M%S")
    campaign_dir = ROOT / "output" / "verification" / "automation_10x10k" / campaign_id
    campaign_dir.mkdir(parents=True, exist_ok=False)
    campaign_summary = {
        "campaign_id": campaign_id,
        "rounds_requested": args.rounds,
        "program_generator": "local direct RV32IM instruction generator",
        "strict_sequential_barrier": True,
        "full_top_rgmii_rx_and_tx": True,
        "rounds": [],
        "status": "RUNNING",
    }
    atomic_json(campaign_dir / "campaign_summary.json", campaign_summary)

    try:
        for round_index in range(1, args.rounds + 1):
            seed = args.seed_base + round_index - 1
            round_dir = campaign_dir / f"round_{round_index:02d}_seed_{seed}"
            round_dir.mkdir()
            started = time.time()
            print(f"ROUND_START index={round_index}/{args.rounds} seed={seed}", flush=True)
            generator, image = prepare_program(seed, round_dir)
            capture = run_full_top(round_dir)
            fpga_log = round_dir / "fpga_info.txt"
            frame_summary = convert_capture(capture, fpga_log)
            webui_check = verify_webui_info_log(fpga_log)
            atomic_json(round_dir / "webui_log_check.json", webui_check)

            round_summary = {
                "round": round_index,
                "seed": seed,
                "status": "PASS",
                "elapsed_seconds": round(time.time() - started, 3),
                "program_sha256": sha256_file(round_dir / "program.bin"),
                "fpga_log_sha256": sha256_file(fpga_log),
                "tx_capture_sha256": sha256_file(capture),
                "generator": generator,
                "image": image,
                "frames": frame_summary,
                "webui_log_check": webui_check,
            }
            atomic_json(round_dir / "round_summary.json", round_summary)
            campaign_summary["rounds"].append(round_summary)
            atomic_json(campaign_dir / "campaign_summary.json", campaign_summary)
            print(
                f"ROUND_PASS index={round_index}/{args.rounds} seed={seed} "
                f"records={webui_check['hart0_records']}/"
                f"{webui_check['hart1_records']} elapsed_s={round_summary['elapsed_seconds']}",
                flush=True,
            )
            # Only a complete full-top PASS plus a parsed WebUI log PASS can
            # release this barrier and permit the next program to be created.
            print(f"ROUND_BARRIER_RELEASE index={round_index}", flush=True)

        campaign_summary["status"] = "PASS"
        campaign_summary["completed_rounds"] = args.rounds
        atomic_json(campaign_dir / "campaign_summary.json", campaign_summary)
        print(f"AUTOMATION_10X10K_PASS evidence={campaign_dir}", flush=True)
    except Exception as exc:
        campaign_summary["status"] = "FAIL"
        campaign_summary["failure"] = str(exc)
        campaign_summary["completed_rounds"] = len(campaign_summary["rounds"])
        atomic_json(campaign_dir / "campaign_summary.json", campaign_summary)
        print(f"AUTOMATION_10X10K_FAIL reason={exc} evidence={campaign_dir}", flush=True)
        raise


if __name__ == "__main__":
    main()
