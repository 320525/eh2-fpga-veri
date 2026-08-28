"""Streaming Spike versus FPGA Info comparison for very large dual-hart runs."""

from __future__ import annotations

from dataclasses import dataclass
import json
import mmap
from pathlib import Path
import re
import struct
import shutil
import tempfile
from typing import Any, BinaryIO, Callable

from .info_log import MAGIC, iter_info_frames
from .protocol import (
    BROADCAST_MAC,
    HART0_INFO_SOURCE_MAC,
    HART1_INFO_SOURCE_MAC,
    INFO_DATA_ETHERTYPE,
    INFO_DONE_ETHERTYPE,
    INFO_RECORD_BYTES,
    INFO_RECORDS_PER_FRAME,
)


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
EXPECTED = struct.Struct(">IIII")
INFO_DATA_PAYLOAD = 4 + INFO_RECORD_BYTES * INFO_RECORDS_PER_FRAME


def _parse_text_fields(parts: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for item in parts:
        if "=" not in item:
            continue
        key, value = item.split("=", 1)
        fields[key] = value
    return fields


def _iter_text_info_frames(path: Path):
    """Rebuild verified Info Ethernet frames from the readable TXT log."""

    pending_hart: int | None = None
    pending_frame: int | None = None
    pending_records: list[bytes] = []

    def finish_data_frame() -> bytes | None:
        nonlocal pending_hart, pending_frame, pending_records
        if pending_hart is None:
            return None
        if len(pending_records) != INFO_RECORDS_PER_FRAME:
            _fail(
                "decoded TXT contains an incomplete Info data frame",
                hart=pending_hart,
                frame=pending_frame,
                slots=len(pending_records),
            )
        source = HART1_INFO_SOURCE_MAC if pending_hart else HART0_INFO_SOURCE_MAC
        payload = int(pending_frame).to_bytes(4, "big") + b"".join(pending_records)
        raw = BROADCAST_MAC + source + INFO_DATA_ETHERTYPE.to_bytes(2, "big") + payload
        pending_hart = None
        pending_frame = None
        pending_records = []
        return raw

    with path.open("r", encoding="utf-8", errors="strict", buffering=8 * 1024 * 1024) as handle:
        for line_number, line in enumerate(handle, 1):
            if not line or line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if not parts:
                _fail("decoded TXT line has no event kind", line=line_number)
            # v2 starts directly with the event kind and stores no timestamp.
            # Keep accepting v1 timestamped logs so retained FAIL evidence can
            # still be compared after a WebUI update.
            if parts[0] in {"SYSTEM", "INFO_DATA", "INFO_DONE"}:
                kind = parts[0]
                fields = _parse_text_fields(parts[1:])
            elif len(parts) >= 2:
                kind = parts[1]
                fields = _parse_text_fields(parts[2:])
            else:
                _fail("decoded TXT line has no event kind", line=line_number)
            if kind == "SYSTEM":
                continue
            if fields.get("valid") != "1":
                _fail("decoded TXT contains an invalid Info event", line=line_number)
            if kind == "INFO_DATA":
                hart = int(fields["hart"], 0)
                frame = int(fields["frame"], 0)
                slot = int(fields["slot"], 0)
                if pending_hart is not None and (hart, frame) != (pending_hart, pending_frame):
                    raw = finish_data_frame()
                    if raw is not None:
                        yield 0, raw
                if pending_hart is None:
                    pending_hart, pending_frame = hart, frame
                if slot != len(pending_records):
                    _fail(
                        "decoded TXT record slot discontinuity",
                        hart=hart,
                        frame=frame,
                        expected=len(pending_records),
                        actual=slot,
                    )
                if int(fields["padding"], 0):
                    record = bytes(INFO_RECORD_BYTES)
                else:
                    record = struct.pack(
                        ">IIIIII",
                        int(fields["sequence"], 0),
                        int(fields["pc"], 0),
                        int(fields["instruction"], 0),
                        int(fields["metadata"], 0),
                        int(fields["data"], 0),
                        int(fields["waw_cancel_number"], 0),
                    )
                pending_records.append(record)
                if len(pending_records) == INFO_RECORDS_PER_FRAME:
                    raw = finish_data_frame()
                    if raw is not None:
                        yield 0, raw
                continue
            if kind == "INFO_DONE":
                raw = finish_data_frame()
                if raw is not None:
                    yield 0, raw
                hart = int(fields["hart"], 0)
                total_records = int(fields["total_records"], 0)
                total_frames = int(fields["total_frames"], 0)
                last_sequence = int(fields["last_sequence"], 0)
                source = HART1_INFO_SOURCE_MAC if hart else HART0_INFO_SOURCE_MAC
                payload = (
                    (b"H1DN" if hart else b"H0DN")
                    + bytes((hart, 1))
                    + INFO_RECORD_BYTES.to_bytes(2, "big")
                    + total_records.to_bytes(4, "big")
                    + total_frames.to_bytes(4, "big")
                    + last_sequence.to_bytes(4, "big")
                    + bytes(3)
                    + bytes((hart ^ 1,))
                    + bytes(22)
                )
                yield 0, BROADCAST_MAC + source + INFO_DONE_ETHERTYPE.to_bytes(2, "big") + payload
                continue
            _fail("decoded TXT contains an unknown event kind", line=line_number, kind=kind)
    raw = finish_data_frame()
    if raw is not None:
        yield 0, raw


def _iter_fpga_frames(path: Path):
    with path.open("rb") as handle:
        legacy_binary = handle.read(len(MAGIC)) == MAGIC
    if legacy_binary:
        yield from iter_info_frames(path)
    else:
        yield from _iter_text_info_frames(path)


class ComparisonFailure(RuntimeError):
    def __init__(self, reason: str, *, hart: int | None = None,
                 sequence: int | None = None, details: dict[str, Any] | None = None):
        super().__init__(reason)
        self.reason = reason
        self.hart = hart
        self.sequence = sequence
        self.details = details or {}
        self.compared_instructions = 0


def _strip_fcs(raw: bytes) -> bytes:
    if len(raw) in (64, 1462):
        return raw[:-4]
    return raw


def _patches(manifest: dict[str, Any]) -> tuple[dict[int, int], dict[int, int], int]:
    by_name = {item["name"]: item for item in manifest.get("patches", [])}
    required = {"eh2_hart_start_patch", "eh2_h0_stop_patch", "eh2_h1_stop_patch"}
    missing = required - set(by_name)
    if missing:
        raise ValueError(f"manifest is missing comparison patches: {sorted(missing)}")
    instructions = {
        int(item["pc"]): int(item["hardware_instruction"])
        for item in by_name.values()
    }
    stops = {
        0: int(by_name["eh2_h0_stop_patch"]["pc"]),
        1: int(by_name["eh2_h1_stop_patch"]["pc"]),
    }
    return instructions, stops, int(by_name["eh2_hart_start_patch"]["pc"])


def normalize_spike(
    spike_log: Path,
    manifest: dict[str, Any],
    output_dir: Path,
) -> tuple[list[Path], list[int]]:
    """Convert an interleaved Spike trace into two fixed-size expected streams."""

    instructions, stop_pcs, hart_start_pc = _patches(manifest)
    reset = int(manifest.get("reset_vector", 0x80000000))
    outputs = [
        output_dir / "spike_hart0.normalized.bin",
        output_dir / "spike_hart1.normalized.bin",
    ]
    handles: list[BinaryIO] = [item.open("wb", buffering=8 * 1024 * 1024) for item in outputs]
    counts = [0, 0]
    stopped = [False, False]
    pending: dict[int, tuple[int, int]] = {}
    try:
        with spike_log.open("r", encoding="utf-8", errors="replace", buffering=8 * 1024 * 1024) as source:
            for line in source:
                trace = TRACE_RE.match(line)
                if trace:
                    pending[int(trace["hart"])] = (int(trace["pc"], 16), int(trace["insn"], 16))
                    continue
                commit = COMMIT_RE.match(line)
                if not commit:
                    continue
                hart = int(commit["hart"])
                if hart not in (0, 1) or stopped[hart]:
                    continue
                pc = int(commit["pc"], 16)
                insn = int(commit["insn"], 16)
                if pc < reset:
                    continue
                paired = pending.pop(hart, None)
                if paired is not None and paired != (pc, insn):
                    raise ComparisonFailure(
                        "Spike trace/commit pair mismatch", hart=hart, sequence=counts[hart],
                        details={"trace": paired, "commit": (pc, insn)},
                    )

                effects = commit["effects"]
                event = 0
                target = 0
                data = 0
                csr = CSR_RE.search(effects)
                gpr = GPR_RE.search(effects)
                if csr:
                    event = 2
                    target = int(csr["num"])
                    data = int(csr["data"], 16) & 0xFFFF_FFFF
                elif gpr:
                    event = 1
                    target = int(gpr["num"])
                    data = int(gpr["data"], 16) & 0xFFFF_FFFF

                if pc in instructions:
                    insn = instructions[pc]
                if hart == 0 and pc == hart_start_pc:
                    event, target, data = 2, 0x7FC, 2
                if pc == stop_pcs[hart]:
                    event, target, data = 0, 0, 0

                metadata = ((hart & 1) << 16) | ((int(commit["priv"]) & 3) << 14)
                metadata |= (event & 3) << 12 | (target & 0xFFF)
                handles[hart].write(EXPECTED.pack(pc & 0xFFFF_FFFF, insn & 0xFFFF_FFFF, metadata, data))
                counts[hart] += 1
                if pc == stop_pcs[hart]:
                    stopped[hart] = True
    finally:
        for handle in handles:
            handle.close()
    if stopped != [True, True]:
        raise ComparisonFailure("Spike did not reach both patched stop instructions",
                                details={"stopped": stopped, "counts": counts})
    return outputs, counts


@dataclass
class ExpectedMap:
    path: Path

    def __post_init__(self) -> None:
        self.handle = self.path.open("rb")
        size = self.path.stat().st_size
        if size % EXPECTED.size:
            self.handle.close()
            raise ValueError(f"normalized Spike stream has invalid length: {self.path}")
        self.count = size // EXPECTED.size
        self.mapping = mmap.mmap(self.handle.fileno(), 0, access=mmap.ACCESS_READ) if size else None

    def get(self, sequence: int) -> tuple[int, int, int, int]:
        if not 0 <= sequence < self.count or self.mapping is None:
            raise IndexError(sequence)
        return EXPECTED.unpack_from(self.mapping, sequence * EXPECTED.size)

    def close(self) -> None:
        if self.mapping is not None:
            self.mapping.close()
        self.handle.close()


def _fail(reason: str, hart: int | None = None, sequence: int | None = None, **details: Any) -> None:
    raise ComparisonFailure(reason, hart=hart, sequence=sequence, details=details)


def compare_fpga(
    fpga_log: Path,
    expected_paths: list[Path],
    expected_counts: list[int],
    progress: Callable[[int], None] | None = None,
) -> dict[str, Any]:
    maps = [ExpectedMap(item) for item in expected_paths]
    expected_frame = [0, 0]
    # EH2 can retire a younger direct instruction while an older nonblocking
    # load/div record is waiting for its result or WAW cancellation.  DDR/TX
    # order is therefore allowed to differ from sequence order.  The sequence
    # ID is the key: every ID must occur exactly once and the final coverage
    # must be the dense range 0..count-1.
    seen_sequence = [bytearray(item.count) for item in maps]
    received_records = [0, 0]
    data_frames = [0, 0]
    done: dict[int, dict[str, int]] = {}
    last_hart = 0
    raw_frame_count = 0
    compared_instructions = 0
    try:
        for _, captured in _iter_fpga_frames(fpga_log):
            raw_frame_count += 1
            raw = _strip_fcs(captured)
            if len(raw) < 14:
                _fail("captured Info frame is shorter than Ethernet header")
            destination, source = raw[0:6], raw[6:12]
            ethertype = int.from_bytes(raw[12:14], "big")
            payload = raw[14:]
            if destination != BROADCAST_MAC:
                _fail("Info frame destination is not broadcast")
            if source == HART0_INFO_SOURCE_MAC:
                hart = 0
            elif source == HART1_INFO_SOURCE_MAC:
                hart = 1
            else:
                _fail("Info frame source MAC is unknown", source=source.hex(":"))
            if hart < last_hart:
                _fail("hart0 frame appeared after hart1 stream started", hart=hart)
            last_hart = hart

            if ethertype == INFO_DATA_ETHERTYPE:
                if len(payload) != INFO_DATA_PAYLOAD:
                    _fail("Info data payload length mismatch", hart=hart, length=len(payload))
                frame_number = int.from_bytes(payload[0:4], "big")
                if frame_number != expected_frame[hart]:
                    _fail("Info frame number discontinuity", hart=hart,
                          sequence=received_records[hart], expected=expected_frame[hart], actual=frame_number)
                expected_frame[hart] += 1
                data_frames[hart] += 1
                padding_seen = False
                for slot in range(INFO_RECORDS_PER_FRAME):
                    start = 4 + slot * INFO_RECORD_BYTES
                    record = payload[start:start + INFO_RECORD_BYTES]
                    if record == bytes(INFO_RECORD_BYTES):
                        padding_seen = True
                        continue
                    if padding_seen:
                        _fail("non-padding record follows padding", hart=hart,
                              sequence=received_records[hart], frame=frame_number, slot=slot)
                    sequence, pc, insn, metadata, data, cancel = struct.unpack(">IIIIII", record)
                    if sequence >= maps[hart].count:
                        _fail("FPGA produced more records than Spike", hart=hart, sequence=sequence,
                              spike_count=maps[hart].count)
                    if seen_sequence[hart][sequence]:
                        _fail("duplicate FPGA Info sequence", hart=hart, sequence=sequence,
                              frame=frame_number, slot=slot)
                    seen_sequence[hart][sequence] = 1
                    received_records[hart] += 1
                    exp_pc, exp_insn, exp_metadata, exp_data = maps[hart].get(sequence)
                    compared_instructions += 1
                    kind = (metadata >> 30) & 3
                    base_metadata = metadata & 0x3FFF_FFFF
                    if (pc, insn, base_metadata) != (exp_pc, exp_insn, exp_metadata):
                        _fail("PC/instruction/metadata mismatch", hart=hart, sequence=sequence,
                              fpga={"pc": f"{pc:08x}", "insn": f"{insn:08x}", "metadata": f"{metadata:08x}"},
                              spike={"pc": f"{exp_pc:08x}", "insn": f"{exp_insn:08x}", "metadata": f"{exp_metadata:08x}"})
                    if kind == 0:
                        if cancel != 0:
                            _fail("non-WAW record has nonzero cancel number", hart=hart,
                                  sequence=sequence, cancel=cancel)
                        if data != exp_data:
                            _fail("architectural data mismatch", hart=hart, sequence=sequence,
                                  fpga=f"{data:08x}", spike=f"{exp_data:08x}")
                    else:
                        if data != 0:
                            _fail("WAW-cancelled victim data is not zero", hart=hart,
                                  sequence=sequence, data=f"{data:08x}", kind=kind)
                        if not sequence < cancel < maps[hart].count:
                            _fail("WAW cancel number is outside later same-hart stream", hart=hart,
                                  sequence=sequence, cancel=cancel, count=maps[hart].count)
                        _, _, cancel_meta, _ = maps[hart].get(cancel)
                        victim_event = (exp_metadata >> 12) & 3
                        cancel_event = (cancel_meta >> 12) & 3
                        victim_target = exp_metadata & 0xFFF
                        cancel_target = cancel_meta & 0xFFF
                        if victim_event != 1 or cancel_event != 1 or victim_target != cancel_target:
                            _fail("WAW cancel sequence does not target the victim GPR", hart=hart,
                                  sequence=sequence, cancel=cancel,
                                  victim_event=victim_event, cancel_event=cancel_event,
                                  victim_target=victim_target, cancel_target=cancel_target)
                    if progress is not None and (
                        compared_instructions == 1 or compared_instructions % 1024 == 0
                    ):
                        progress(compared_instructions)
                continue

            if ethertype == INFO_DONE_ETHERTYPE:
                if len(payload) != 46:
                    _fail("Info done payload length mismatch", hart=hart, length=len(payload))
                magic = b"H0DN" if hart == 0 else b"H1DN"
                total_records = int.from_bytes(payload[8:12], "big")
                total_frames = int.from_bytes(payload[12:16], "big")
                last_sequence = int.from_bytes(payload[16:20], "big")
                if payload[0:4] != magic or payload[4] != hart or payload[5] != 1:
                    _fail("Info done identity/version mismatch", hart=hart)
                if int.from_bytes(payload[6:8], "big") != INFO_RECORD_BYTES:
                    _fail("Info done record size mismatch", hart=hart)
                if hart in done:
                    _fail("duplicate Info done frame", hart=hart)
                done[hart] = {
                    "records": total_records,
                    "frames": total_frames,
                    "last_sequence": last_sequence,
                }
                if total_records != received_records[hart] or total_frames != data_frames[hart]:
                    _fail("Info done count does not match captured stream", hart=hart,
                          captured_records=received_records[hart], declared_records=total_records,
                          captured_frames=data_frames[hart], declared_frames=total_frames)
                expected_last = 0xFFFF_FFFF if total_records == 0 else total_records - 1
                if last_sequence != expected_last:
                    _fail("Info done last sequence mismatch", hart=hart,
                          expected=expected_last, actual=last_sequence)
                try:
                    missing = seen_sequence[hart].index(0)
                except ValueError:
                    missing = None
                if missing is not None:
                    _fail("FPGA Info stream is missing a sequence", hart=hart,
                          sequence=missing, declared_records=total_records)
                continue
            _fail("unexpected EtherType inside FPGA Info log", hart=hart, ethertype=f"{ethertype:04x}")

        if set(done) != {0, 1}:
            _fail("FPGA Info log does not contain both completion frames", done=sorted(done))
        for hart in (0, 1):
            if received_records[hart] != expected_counts[hart] or maps[hart].count != expected_counts[hart]:
                _fail("FPGA/Spike final record count mismatch", hart=hart,
                      fpga=received_records[hart], normalized=maps[hart].count,
                      spike=expected_counts[hart])
        if progress is not None:
            progress(compared_instructions)
        return {
            "status": "PASS",
            "raw_info_frames": raw_frame_count,
            "hart0_records": received_records[0],
            "hart1_records": received_records[1],
            "hart0_data_frames": data_frames[0],
            "hart1_data_frames": data_frames[1],
            "compared_instructions": compared_instructions,
            "done": {str(key): value for key, value in done.items()},
        }
    except ComparisonFailure as exc:
        exc.compared_instructions = compared_instructions
        if progress is not None:
            progress(compared_instructions)
        raise
    finally:
        for item in maps:
            item.close()


def compare_run(
    fpga_log: Path,
    spike_log: Path,
    manifest_path: Path,
    report_path: Path,
    progress: Callable[[int], None] | None = None,
) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    report_path.parent.mkdir(parents=True, exist_ok=True)
    # Preserve exactly the text produced by Spike in the user-facing runlog.
    # Fixed-size normalized streams are comparison scratch files only.
    local_spike_log = report_path.parent / "spike.log.txt"
    local_manifest = report_path.parent / "manifest.json"
    if spike_log.resolve() != local_spike_log.resolve():
        shutil.copyfile(spike_log, local_spike_log)
    if manifest_path.resolve() != local_manifest.resolve():
        shutil.copyfile(manifest_path, local_manifest)
    report: dict[str, Any]
    try:
        with tempfile.TemporaryDirectory(
            prefix=".compare_", dir=report_path.parent
        ) as temporary:
            expected_paths, expected_counts = normalize_spike(
                local_spike_log, manifest, Path(temporary)
            )
            report = compare_fpga(
                fpga_log, expected_paths, expected_counts, progress=progress
            )
            report["spike_counts"] = expected_counts
    except ComparisonFailure as exc:
        report = {
            "status": "FAIL",
            "reason": exc.reason,
            "first_failure_hart": exc.hart,
            "first_failure_sequence": exc.sequence,
            "compared_instructions": exc.compared_instructions,
            "details": exc.details,
        }
    except Exception as exc:
        report = {
            "status": "FAIL",
            "reason": f"comparison exception: {exc}",
            "first_failure_hart": None,
            "first_failure_sequence": None,
            "compared_instructions": 0,
            "details": {"exception_type": type(exc).__name__},
        }
    report["fpga_log"] = str(fpga_log)
    report["spike_log"] = str(local_spike_log)
    report["manifest"] = str(local_manifest)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    text_report = (
        f"status={report.get('status')}\n"
        f"compared_instructions={int(report.get('compared_instructions', 0))}\n"
        f"first_failure_hart={report.get('first_failure_hart', '-')}\n"
        f"first_failure_sequence={report.get('first_failure_sequence', '-')}\n"
        f"reason={report.get('reason', '-')}\n"
    )
    report_path.with_name("comparison_result.txt").write_text(
        text_report, encoding="utf-8"
    )
    return report
