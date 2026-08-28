"""Persistent WebUI session evidence stored only below webui/runtime."""

from __future__ import annotations

from collections import deque
import csv
from datetime import datetime
import json
from pathlib import Path
import shutil
import threading
from typing import Any

from .info_log import DecodedInfoTextWriter


class SessionRecorder:
    _TIME_FIELDS = {"time", "received_at", "started_at", "completed_at", "updated_at"}

    def __init__(self, runtime_root: Path):
        self.runtime_root = runtime_root.resolve()
        # User-facing execution logs are kept separate from internal runtime
        # state and uploaded program caches.
        self.sessions_root = self.runtime_root.parent / "runlog"
        self.uploads_root = self.runtime_root / "uploads"
        self.sessions_root.mkdir(parents=True, exist_ok=True)
        self.uploads_root.mkdir(parents=True, exist_ok=True)
        self.current_dir: Path | None = None
        self._pcap_writer: Any = None
        self._decoded_info_writer: DecodedInfoTextWriter | None = None
        self._error_code_writer: DecodedInfoTextWriter | None = None
        self._system_messages: deque[dict[str, Any]] = deque(maxlen=100)
        self._lock = threading.RLock()

    @staticmethod
    def timestamp() -> str:
        return datetime.now().astimezone().isoformat(timespec="milliseconds")

    def start(self, interface_id: str) -> Path:
        with self._lock:
            self.close()
            dirname = datetime.now().strftime("session_%Y%m%d_%H%M%S_%f")
            self.current_dir = self.sessions_root / dirname
            self.current_dir.mkdir(parents=True, exist_ok=False)
            metadata = {
                "started_at": self.timestamp(),
                "interface_id": interface_id,
                "note": "PCAP includes accepted RX frames and frames submitted by this WebUI",
            }
            (self.current_dir / "session.json").write_text(
                json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
            self._decoded_info_writer = DecodedInfoTextWriter(
                self.current_dir / "decoded_info_frames.txt"
            )
            self._system_messages.clear()
            return self.current_dir

    def store_upload(self, upload_id: str, filename: str, content: bytes, manifest: dict[str, Any]) -> Path:
        safe_name = Path(filename).name
        target = self.uploads_root / f"{upload_id}_{safe_name}"
        target.write_bytes(content)
        (self.uploads_root / f"{upload_id}_manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        return target

    def record_event(self, event: dict[str, Any]) -> None:
        with self._lock:
            if self.current_dir is None:
                return
            with (self.current_dir / "events.txt").open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps(self._without_time_fields(event), ensure_ascii=False) + "\n")

    def record_packet(self, raw: bytes) -> None:
        with self._lock:
            if self.current_dir is None:
                return
            try:
                from scapy.all import Ether, PcapWriter  # type: ignore

                if self._pcap_writer is None:
                    self._pcap_writer = PcapWriter(
                        str(self.current_dir / "raw_packets.pcap"), sync=False
                    )
                self._pcap_writer.write(Ether(raw))
            except Exception:
                # An event is still retained even if PCAP output is unavailable.
                return

    def save_log_snapshot(self, document: dict[str, Any]) -> Path:
        with self._lock:
            if self.current_dir is None:
                raise RuntimeError("必须先启动监听并建立会话")
            suffix = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
            path = self.current_dir / f"saved_log_{suffix}.txt"
            path.write_text(
                json.dumps(self._without_time_fields(document), ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            return path

    @classmethod
    def _without_time_fields(cls, value: Any) -> Any:
        """Remove timestamps from user-facing TXT evidence, including nested data."""

        if isinstance(value, dict):
            return {
                key: cls._without_time_fields(item)
                for key, item in value.items()
                if key not in cls._TIME_FIELDS
            }
        if isinstance(value, list):
            return [cls._without_time_fields(item) for item in value]
        return value

    def _append_csv(self, filename: str, row: dict[str, Any]) -> None:
        self._append_csv_rows(filename, [row])

    def _append_csv_rows(self, filename: str, rows: list[dict[str, Any]]) -> None:
        """Append a batch with one open/flush so high-rate Info RX stays light."""

        if self.current_dir is None:
            return
        if not rows:
            return
        path = self.current_dir / filename
        exists = path.exists()
        with path.open("a", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            if not exists:
                writer.writeheader()
            writer.writerows(rows)

    def record_system(self, decoded: dict[str, Any]) -> None:
        with self._lock:
            if self.current_dir is None:
                return
            self._system_messages.append(dict(decoded))
            target = self.current_dir / "system_messages.txt"
            temporary = self.current_dir / "system_messages.txt.tmp"
            writer = DecodedInfoTextWriter(temporary)
            try:
                for message in self._system_messages:
                    writer.write_decoded(message)
            finally:
                writer.close()
            temporary.replace(target)

    def record_error_code(self, decoded: dict[str, Any]) -> None:
        """Append every valid FPGA error code to its own no-timestamp TXT."""

        with self._lock:
            if self.current_dir is None:
                return
            if self._error_code_writer is None:
                self._error_code_writer = DecodedInfoTextWriter(
                    self.current_dir / "error_codes.txt"
                )
            self._error_code_writer.write_decoded(decoded)

    def record_info_frame(self, decoded: dict[str, Any]) -> None:
        """Persist the complete decoded frame to one buffered text stream."""

        with self._lock:
            if self._decoded_info_writer is not None:
                self._decoded_info_writer.write_decoded(decoded)

    def record_info_done(self, decoded: dict[str, Any]) -> None:
        with self._lock:
            if self._decoded_info_writer is not None:
                self._decoded_info_writer.write_decoded(decoded)

    def files(self) -> list[dict[str, Any]]:
        with self._lock:
            if self.current_dir is None or not self.current_dir.exists():
                return []
            if self._decoded_info_writer is not None:
                self._decoded_info_writer.flush()
            if self._error_code_writer is not None:
                self._error_code_writer.flush()
            return [
                {"name": item.name, "bytes": item.stat().st_size}
                for item in sorted(self.current_dir.iterdir())
                if item.is_file()
            ]

    def resolve_current_file(self, name: str) -> Path:
        with self._lock:
            if self.current_dir is None:
                raise FileNotFoundError("没有当前会话")
            candidate = (self.current_dir / Path(name).name).resolve()
            if candidate.parent != self.current_dir.resolve() or not candidate.is_file():
                raise FileNotFoundError(name)
            if (self._decoded_info_writer is not None and
                    candidate == self._decoded_info_writer.path):
                self._decoded_info_writer.flush()
            if (self._error_code_writer is not None and
                    candidate == self._error_code_writer.path):
                self._error_code_writer.flush()
            return candidate

    def cleanup_previous_sessions(self, preserve_current: bool) -> int:
        """Remove only session_* children, optionally preserving the live one."""

        with self._lock:
            keep = (
                self.current_dir.resolve()
                if preserve_current and self.current_dir is not None else None
            )
            if not preserve_current:
                self.close()
                self.current_dir = None
                self._system_messages.clear()
            root = self.sessions_root.resolve()
            removed = 0
            for item in list(root.iterdir()):
                if not item.is_dir() or not item.name.startswith("session_"):
                    continue
                target = item.resolve()
                if target.parent != root:
                    raise RuntimeError(
                        f"refusing to clean unexpected session path: {target}"
                    )
                if keep is not None and target == keep:
                    continue
                shutil.rmtree(target)
                removed += 1
            return removed

    def cleanup_upload_cache(self) -> int:
        """Remove only direct files below runtime/uploads."""

        with self._lock:
            root = self.uploads_root.resolve()
            removed = 0
            for item in list(root.iterdir()):
                target = item.resolve()
                if target.parent != root:
                    raise RuntimeError(
                        f"refusing to clean unexpected upload path: {target}"
                    )
                if target.is_file():
                    target.unlink()
                    removed += 1
            return removed

    def close(self) -> None:
        with self._lock:
            if self._pcap_writer is not None:
                try:
                    self._pcap_writer.close()
                finally:
                    self._pcap_writer = None
            if self._decoded_info_writer is not None:
                self._decoded_info_writer.close()
                self._decoded_info_writer = None
            if self._error_code_writer is not None:
                self._error_code_writer.close()
                self._error_code_writer = None
