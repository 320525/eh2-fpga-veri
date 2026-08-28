"""Compact single-file storage for every received FPGA Info Ethernet frame."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
import struct
import threading
import time
from typing import Any

from .protocol import (
    INFO_DATA_ETHERTYPE,
    INFO_DATA_FRAME_BYTES,
    INFO_RECORD_BYTES,
    INFO_RECORDS_PER_FRAME,
)


MAGIC = b"EH2LGF1\0"
HEADER = struct.Struct("<8sI")
FRAME_HEADER = struct.Struct("<QH")
VERSION = 1
MAX_FRAME_BYTES = 2048


class InfoFrameLogWriter:
    """Write timestamped raw Info frames with an 8 MiB userspace buffer."""

    def __init__(self, path: Path, flush_bytes: int = 8 * 1024 * 1024):
        self.path = path.resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._handle = self.path.open("wb", buffering=8 * 1024 * 1024)
        self._handle.write(HEADER.pack(MAGIC, VERSION))
        self._buffer = bytearray()
        self._flush_bytes = int(flush_bytes)
        self._lock = threading.Lock()
        self.frames = 0
        self.records = 0
        self.bytes = HEADER.size
        self.closed = False

    def write(self, raw: bytes, timestamp_ns: int | None = None) -> None:
        frame = bytes(raw)
        if not 14 <= len(frame) <= MAX_FRAME_BYTES:
            raise ValueError(f"Info frame length {len(frame)} is outside 14..{MAX_FRAME_BYTES}")
        no_fcs = frame[:-4] if len(frame) == INFO_DATA_FRAME_BYTES + 4 else frame
        record_count = 0
        if (
            len(no_fcs) == INFO_DATA_FRAME_BYTES
            and int.from_bytes(no_fcs[12:14], "big") == INFO_DATA_ETHERTYPE
        ):
            payload = no_fcs[14:]
            zero_record = bytes(INFO_RECORD_BYTES)
            record_count = sum(
                payload[
                    4 + slot * INFO_RECORD_BYTES:
                    4 + (slot + 1) * INFO_RECORD_BYTES
                ] != zero_record
                for slot in range(INFO_RECORDS_PER_FRAME)
            )
        stamp = time.time_ns() if timestamp_ns is None else int(timestamp_ns)
        record = FRAME_HEADER.pack(stamp, len(frame)) + frame
        with self._lock:
            if self.closed:
                raise RuntimeError("Info frame log is closed")
            self._buffer.extend(record)
            self.frames += 1
            self.records += record_count
            self.bytes += len(record)
            if len(self._buffer) >= self._flush_bytes:
                self._handle.write(self._buffer)
                self._buffer.clear()

    def flush(self) -> None:
        with self._lock:
            if self.closed:
                return
            if self._buffer:
                self._handle.write(self._buffer)
                self._buffer.clear()
            self._handle.flush()

    def close(self) -> None:
        with self._lock:
            if self.closed:
                return
            if self._buffer:
                self._handle.write(self._buffer)
                self._buffer.clear()
            self._handle.flush()
            self._handle.close()
            self.closed = True


class DecodedInfoTextWriter:
    """Stream decoded Info frames to a directly readable UTF-8 text file."""

    HEADER_TEXT = (
        "# EH2 decoded FPGA frame log v2\n"
        "# No timestamps are stored; one tab-separated event per line.\n"
        "# Fields after kind use key=value.\n"
    )

    def __init__(self, path: Path):
        self.path = path.resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._handle = self.path.open(
            "w", encoding="utf-8", buffering=8 * 1024 * 1024, newline="\n"
        )
        self._handle.write(self.HEADER_TEXT)
        self._lock = threading.Lock()
        self.frames = 0
        self.records = 0
        self.bytes = len(self.HEADER_TEXT.encode("utf-8"))
        self.closed = False

    def write_decoded(self, decoded: dict[str, Any]) -> None:
        kind = str(decoded.get("kind", "unknown"))
        lines: list[str] = []
        record_count = 0
        if kind == "info_data":
            hart = int(decoded["hart_id"])
            frame_number = int(decoded["frame_number"])
            for record in decoded.get("records", []):
                padding = bool(record.get("padding"))
                lines.append(
                    f"INFO_DATA\thart={hart}\tframe={frame_number}\t"
                    f"slot={int(record['record_index'])}\tpadding={int(padding)}\t"
                    f"sequence={int(record['sequence'])}\tpc={record['pc']}\t"
                    f"instruction={record['instruction']}\tmetadata={record['metadata']}\t"
                    f"waw_cancel_kind={int(record['waw_cancel_kind'])}\t"
                    f"privilege={int(record['privilege'])}\t"
                    f"event_type={int(record['event_type'])}\t"
                    f"register_number={int(record['register_number'])}\t"
                    f"data={record['data']}\t"
                    f"waw_cancel_number={int(record['waw_cancel_number'])}\t"
                    f"valid={int(bool(decoded.get('valid', False)))}\n"
                )
                if not padding:
                    record_count += 1
        elif kind == "info_done":
            lines.append(
                f"INFO_DONE\thart={int(decoded['hart_id'])}\t"
                f"total_records={int(decoded['total_records'])}\t"
                f"total_frames={int(decoded['total_frames'])}\t"
                f"last_sequence={int(decoded['last_sequence'])}\t"
                f"host_compare={decoded.get('host_compare', '-')}\t"
                f"valid={int(bool(decoded.get('valid', False)))}\n"
            )
        elif kind == "system":
            description = str(decoded.get("description", "")).replace("\t", " ")
            lines.append(
                f"SYSTEM\tcode=0x{decoded['code']}\t"
                f"name={decoded['name']}\tstate={decoded['state']}\t"
                f"description={description}\t"
                f"valid={int(bool(decoded.get('valid', False)))}\n"
            )
        else:
            return
        text = "".join(lines)
        with self._lock:
            if self.closed:
                return
            self._handle.write(text)
            self.frames += 1
            self.records += record_count
            self.bytes += len(text.encode("utf-8"))

    def write_raw(self, raw: bytes, timestamp_ns: int | None = None) -> None:
        # Import lazily so the binary log iterator remains usable on its own.
        from .protocol import decode_frame

        decoded = decode_frame(raw)
        self.write_decoded(decoded)

    def flush(self) -> None:
        with self._lock:
            if not self.closed:
                self._handle.flush()

    def close(self) -> None:
        with self._lock:
            if self.closed:
                return
            self._handle.flush()
            self._handle.close()
            self.closed = True


def iter_info_frames(path: Path) -> Iterator[tuple[int, bytes]]:
    with path.open("rb", buffering=8 * 1024 * 1024) as handle:
        header = handle.read(HEADER.size)
        if len(header) != HEADER.size:
            raise ValueError("FPGA Info log header is truncated")
        magic, version = HEADER.unpack(header)
        if magic != MAGIC or version != VERSION:
            raise ValueError("FPGA Info log magic/version is invalid")
        while True:
            item = handle.read(FRAME_HEADER.size)
            if not item:
                return
            if len(item) != FRAME_HEADER.size:
                raise ValueError("FPGA Info log frame header is truncated")
            timestamp_ns, length = FRAME_HEADER.unpack(item)
            if not 14 <= length <= MAX_FRAME_BYTES:
                raise ValueError(f"FPGA Info log contains invalid frame length {length}")
            raw = handle.read(length)
            if len(raw) != length:
                raise ValueError("FPGA Info log frame payload is truncated")
            yield timestamp_ns, raw
