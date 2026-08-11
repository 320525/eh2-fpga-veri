"""Persistent WebUI session evidence stored only below webui/runtime."""

from __future__ import annotations

import csv
from datetime import datetime
import json
from pathlib import Path
import threading
from typing import Any


class SessionRecorder:
    def __init__(self, runtime_root: Path):
        self.runtime_root = runtime_root.resolve()
        self.sessions_root = self.runtime_root / "sessions"
        self.uploads_root = self.runtime_root / "uploads"
        self.sessions_root.mkdir(parents=True, exist_ok=True)
        self.uploads_root.mkdir(parents=True, exist_ok=True)
        self.current_dir: Path | None = None
        self._pcap_writer: Any = None
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
            with (self.current_dir / "events.jsonl").open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps(event, ensure_ascii=False) + "\n")

    def record_packet(self, raw: bytes) -> None:
        with self._lock:
            if self.current_dir is None:
                return
            try:
                from scapy.all import Ether, PcapWriter  # type: ignore

                if self._pcap_writer is None:
                    self._pcap_writer = PcapWriter(str(self.current_dir / "raw_packets.pcap"), sync=True)
                self._pcap_writer.write(Ether(raw))
            except Exception:
                # An event is still retained even if PCAP output is unavailable.
                return

    def save_log_snapshot(self, document: dict[str, Any]) -> Path:
        with self._lock:
            if self.current_dir is None:
                raise RuntimeError("必须先启动监听并建立会话")
            suffix = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
            path = self.current_dir / f"saved_log_{suffix}.json"
            path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            return path

    def _append_csv(self, filename: str, row: dict[str, Any]) -> None:
        if self.current_dir is None:
            return
        path = self.current_dir / filename
        exists = path.exists()
        with path.open("a", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(row.keys()))
            if not exists:
                writer.writeheader()
            writer.writerow(row)

    def record_system(self, decoded: dict[str, Any]) -> None:
        with self._lock:
            self._append_csv(
                "system_events.csv",
                {
                    "time": self.timestamp(),
                    "code": decoded["code"],
                    "name": decoded["name"],
                    "state": decoded["state"],
                    "description": decoded["description"],
                    "valid": decoded["valid"],
                },
            )

    def record_reduction(self, decoded: dict[str, Any]) -> None:
        with self._lock:
            self._append_csv(
                "reduction_results.csv",
                {
                    "time": self.timestamp(),
                    "hart": decoded["hart_id"],
                    "package": decoded["package_number"],
                    "count": decoded["count"],
                    "xor0": decoded["xor0"],
                    "xor1": decoded["xor1"],
                    "sum0": decoded["sum0"],
                    "sum1": decoded["sum1"],
                    "sum2": decoded["sum2"],
                    "sum3": decoded["sum3"],
                    "waw_count": decoded["waw_count"],
                    "waw_sequences": " ".join(str(item) for item in decoded["waw_sequences"]),
                    "frame_valid": decoded["valid"],
                    "golden_status": decoded.get("golden", {}).get("status", ""),
                    "golden_mismatches": " | ".join(decoded.get("golden", {}).get("mismatches", [])),
                },
            )

    def files(self) -> list[dict[str, Any]]:
        with self._lock:
            if self.current_dir is None or not self.current_dir.exists():
                return []
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
            return candidate

    def close(self) -> None:
        with self._lock:
            if self._pcap_writer is not None:
                try:
                    self._pcap_writer.close()
                finally:
                    self._pcap_writer = None
