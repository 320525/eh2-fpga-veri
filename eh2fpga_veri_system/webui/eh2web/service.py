"""Thread-safe orchestration of capture, program sending and board state."""

from __future__ import annotations

from collections import deque
from datetime import datetime
import json
from pathlib import Path
import threading
import time
from typing import Any, Callable
from uuid import uuid4

from .golden import GoldenResults
from .network import NetworkBackend
from .program_image import DEFAULT_MAX_PROGRAM_BYTES, ProgramImage, parse_program_file
from .protocol import (
    build_end_frame,
    build_host_send_stopped_frame,
    build_preconfig_program_frame,
    decode_frame,
    iter_program_frames,
)
from .session import SessionRecorder


EventSink = Callable[[dict[str, Any]], None]


class BoardService:
    def __init__(
        self,
        webui_root: Path,
        event_sink: EventSink,
        max_program_bytes: int = DEFAULT_MAX_PROGRAM_BYTES,
    ):
        self.webui_root = webui_root.resolve()
        self.event_sink = event_sink
        self.max_program_bytes = int(max_program_bytes)
        self.network = NetworkBackend()
        self.recorder = SessionRecorder(self.webui_root / "runtime")
        self.golden = GoldenResults(self.webui_root / "golden" / "stress_200k_system_golden.json")
        self._lock = threading.RLock()
        self._tx_lock = threading.Lock()
        self._tx_cancel_event = threading.Event()
        self._stop_ack_pending = False
        self._stop_ack_sent = False
        self._events: deque[dict[str, Any]] = deque(maxlen=500)
        self._system_messages: deque[dict[str, Any]] = deque(maxlen=1000)
        self._reductions: deque[dict[str, Any]] = deque(maxlen=2000)
        self._uploads: dict[str, ProgramImage] = {}
        self.capture_running = False
        self.interface_id: str | None = None
        self.board_state = "DISCONNECTED"
        self.program_send_allowed = False
        self.last_system_code: str | None = None
        self.tx_busy = False
        self.tx_progress = {"sent": 0, "total": 0, "percent": 0.0, "operation": None}
        self.stats = {
            "rx_total": 0,
            "rx_system": 0,
            "rx_log": 0,
            "rx_invalid": 0,
            "rx_ignored": 0,
            "tx_total": 0,
        }

    @staticmethod
    def _now() -> str:
        return datetime.now().astimezone().isoformat(timespec="milliseconds")

    def _emit(self, event_type: str, message: str, level: str = "info", **data: Any) -> None:
        event = {
            "time": self._now(),
            "type": event_type,
            "level": level,
            "message": message,
            "data": data,
        }
        with self._lock:
            self._events.append(event)
        self.recorder.record_event(event)
        self.event_sink(event)

    def list_interfaces(self) -> list[dict[str, Any]]:
        return self.network.list_interfaces()

    def start_capture(self, interface_id: str) -> dict[str, Any]:
        if not interface_id:
            raise ValueError("必须选择有线网卡")
        with self._lock:
            if self.capture_running:
                raise RuntimeError("监听已经启动")
            session_dir = self.recorder.start(interface_id)
            self.network.start_capture(interface_id, self._on_packet)
            self.capture_running = True
            self.interface_id = interface_id
            self.board_state = "LISTENING"
            self.program_send_allowed = False
        self._emit("capture_started", "已开始持续监听板卡返回帧", interface_id=interface_id)
        return {"session": session_dir.name, "interface_id": interface_id}

    def stop_capture(self) -> None:
        self.network.stop_capture()
        with self._lock:
            self.capture_running = False
            self.interface_id = None
            if self.board_state != "ERROR":
                self.board_state = "DISCONNECTED"
            self.program_send_allowed = False
        self._emit("capture_stopped", "监听已停止", level="warning")
        self.recorder.close()

    def inspect_program(self, filename: str, content: bytes) -> dict[str, Any]:
        image = parse_program_file(filename, content, max_bytes=self.max_program_bytes)
        upload_id = uuid4().hex
        manifest = image.manifest()
        manifest["upload_id"] = upload_id
        with self._lock:
            self._uploads = {upload_id: image}
        self.recorder.store_upload(upload_id, filename, content, manifest)
        self._emit(
            "program_loaded",
            f"已载入{image.frame_count}帧原始二进制程序",
            filename=image.filename,
            sha256=image.sha256,
            bytes=len(image.data),
            frames=image.frame_count,
        )
        return manifest

    def send_preconfig(self, force: bool = False, inter_frame_us: int = 0) -> None:
        if not force and self.board_state != "PRECONFIG":
            raise RuntimeError("尚未收到PREINIT_DONE；如确认板卡状态可使用强制发送")
        self._begin_send(
            operation="PRECONFIG_CHECK",
            frames=[build_preconfig_program_frame()],
            total_frames=1,
            inter_frame_us=inter_frame_us,
        )

    def send_program(self, upload_id: str, force: bool = False, inter_frame_us: int = 0) -> None:
        with self._lock:
            image = self._uploads.get(upload_id)
        if image is None:
            raise ValueError("程序缓存不存在，请重新选择.bin文件")
        if not force and not self.program_send_allowed:
            raise RuntimeError("尚未收到允许本轮发送的33333333；如确认板卡状态可使用强制发送")
        nominal_seconds = image.frame_count * max(0, inter_frame_us) / 1_000_000
        if nominal_seconds >= 18 and not force:
            raise RuntimeError("配置的帧间隔使名义发送时间接近20秒超时，请减小间隔")
        self._begin_send(
            operation="PROGRAM_WRITE",
            frames=iter_program_frames(image.data),
            total_frames=image.frame_count,
            inter_frame_us=inter_frame_us,
            program_manifest=image.manifest(),
        )

    def send_end_only(self) -> None:
        self._begin_send(
            operation="END_FRAME_ONLY",
            frames=[],
            total_frames=0,
            inter_frame_us=0,
            trailer_only=True,
        )

    def _begin_send(
        self,
        operation: str,
        frames: Any,
        total_frames: int,
        inter_frame_us: int,
        program_manifest: dict[str, Any] | None = None,
        trailer_only: bool = False,
    ) -> None:
        with self._lock:
            if not self.capture_running or not self.interface_id:
                raise RuntimeError("必须先启动监听，确保不会漏掉板卡立即返回的状态帧")
            if self.tx_busy:
                raise RuntimeError("已有发送任务正在运行")
            if not self._tx_lock.acquire(blocking=False):
                raise RuntimeError("发送器忙")
            self.tx_busy = True
            self._tx_cancel_event.clear()
            self._stop_ack_pending = False
            self._stop_ack_sent = False
            if operation == "PROGRAM_WRITE":
                # 33333333 means hardware has already entered PROGRAM_WRITE.
                # Consume the one-shot permission when this transfer starts so
                # a retry click cannot append a second image to the same DDR.
                self.program_send_allowed = False
            self.tx_progress = {
                "sent": 0,
                "total": total_frames,
                "percent": 0.0 if total_frames else 100.0,
                "operation": operation,
            }
            interface_id = self.interface_id

        worker = threading.Thread(
            target=self._send_worker,
            name=f"eh2-{operation.lower()}",
            daemon=True,
            args=(
                interface_id,
                operation,
                frames,
                total_frames,
                inter_frame_us,
                program_manifest,
                trailer_only,
            ),
        )
        worker.start()

    def _send_worker(
        self,
        interface_id: str,
        operation: str,
        frames: Any,
        total_frames: int,
        inter_frame_us: int,
        program_manifest: dict[str, Any] | None,
        trailer_only: bool,
    ) -> None:
        started = time.perf_counter()
        self._emit(
            "tx_started",
            f"开始发送 {operation}",
            operation=operation,
            frames=total_frames,
            inter_frame_us=inter_frame_us,
            manifest=program_manifest,
        )

        def on_progress(sent: int, total: int) -> None:
            percent = (sent * 100.0 / total) if total else 100.0
            with self._lock:
                self.tx_progress = {
                    "sent": sent,
                    "total": total,
                    "percent": round(percent, 2),
                    "operation": operation,
                }
            if sent == total or sent == 1 or sent % 32 == 0:
                self._emit(
                    "tx_progress",
                    f"{operation}: {sent}/{total} 帧",
                    operation=operation,
                    sent=sent,
                    total=total,
                    percent=percent,
                )

        def on_packet_sent(raw: bytes) -> None:
            with self._lock:
                self.stats["tx_total"] += 1
            self.recorder.record_packet(raw)

        try:
            trailer = build_end_frame(0 if trailer_only else total_frames)
            send_frames = [] if trailer_only else frames
            cancelled = self.network.send_sequence(
                interface_id=interface_id,
                frames=send_frames,
                total_frames=0 if trailer_only else total_frames,
                trailer=trailer,
                inter_frame_seconds=max(0, inter_frame_us) / 1_000_000,
                progress=on_progress,
                packet_sent=on_packet_sent,
                cancel_event=self._tx_cancel_event,
            )
            elapsed = time.perf_counter() - started
            if cancelled:
                self._emit(
                    "tx_cancelled",
                    f"{operation} 因板卡错误帧已立即停止，未发送结束帧",
                    level="warning",
                    operation=operation,
                    sent=self.tx_progress["sent"],
                    total=total_frames,
                    elapsed_seconds=round(elapsed, 6),
                )
            else:
                self._emit(
                    "tx_complete",
                    f"{operation} 已提交全部数据帧并紧接发送结束帧",
                    operation=operation,
                    data_frames=total_frames,
                    elapsed_seconds=round(elapsed, 6),
                )
        except Exception as exc:  # pragma: no cover - requires Npcap/NIC
            self._emit("tx_error", f"{operation} 发送失败: {exc}", level="error", operation=operation)
        finally:
            with self._lock:
                self.tx_busy = False
            self._tx_lock.release()

    def _send_host_stopped_ack(self) -> None:
        with self._lock:
            if self._stop_ack_pending or self._stop_ack_sent:
                return
            if not self.capture_running or not self.interface_id:
                self._emit(
                    "stop_ack_error",
                    "无法发送停止确认：监听接口已经关闭",
                    level="error",
                )
                return
            self._stop_ack_pending = True
            interface_id = self.interface_id

        def on_packet_sent(raw: bytes) -> None:
            with self._lock:
                self.stats["tx_total"] += 1
            self.recorder.record_packet(raw)

        def worker() -> None:
            success = False
            try:
                self.network.send_frame(
                    interface_id,
                    build_host_send_stopped_frame(),
                    on_packet_sent,
                )
                success = True
                with self._lock:
                    self.board_state = "RESETTING"
                self._emit(
                    "host_send_stopped",
                    "已向板卡发送 HOST_SEND_STOPPED 0x44124445，等待全局复位",
                    code="44124445",
                )
            except Exception as exc:  # pragma: no cover - requires Npcap/NIC
                self._emit(
                    "stop_ack_error",
                    f"停止确认帧发送失败: {exc}",
                    level="error",
                )
            finally:
                with self._lock:
                    self._stop_ack_pending = False
                    self._stop_ack_sent = success

        threading.Thread(
            target=worker,
            name="eh2-host-send-stopped",
            daemon=True,
        ).start()

    def _on_packet(self, raw: bytes) -> None:
        self.recorder.record_packet(raw)
        decoded = decode_frame(raw)
        with self._lock:
            self.stats["rx_total"] += 1

        if decoded["kind"] == "ignored":
            with self._lock:
                self.stats["rx_ignored"] += 1
            return
        if decoded["kind"] == "invalid":
            with self._lock:
                self.stats["rx_invalid"] += 1
            self._emit("invalid_frame", decoded["reason"], level="warning", frame=decoded)
            return
        if decoded["kind"] == "system":
            decoded["received_at"] = self._now()
            with self._lock:
                self.stats["rx_system"] += 1
                self.last_system_code = decoded["code"]
                if decoded["valid"]:
                    if decoded["state"] != "KEEP":
                        self.board_state = decoded["state"]
                    self.program_send_allowed = decoded["code"] == "33333333"
                self._system_messages.append(dict(decoded))
            self.recorder.record_system(decoded)
            is_error = (
                decoded["code"] in {"22220011", "22220022"}
                or decoded["code"].startswith("444400")
                or decoded["code"].startswith("666600")
            )
            if is_error and decoded["valid"]:
                # Stop bulk transmission before log/UI work so the sender can
                # observe cancellation at the earliest frame boundary.
                self._tx_cancel_event.set()
            level = "error" if is_error else ("info" if decoded["valid"] else "warning")
            self._emit(
                "system_frame",
                f"{decoded['name']}: {decoded['description']}",
                level=level,
                frame=decoded,
            )
            if is_error and decoded["valid"]:
                # The bulk sender observes cancellation between frames (or during its
                # interruptible gap), closes its L2 socket without a trailer,
                # then the acknowledgement uses the same serialized TX path.
                self._send_host_stopped_ack()
            return
        if decoded["kind"] == "log":
            decoded["received_at"] = self._now()
            decoded["golden"] = self.golden.compare(decoded)
            with self._lock:
                self.stats["rx_log"] += 1
                self._reductions.append(decoded)
            self.recorder.record_reduction(decoded)
            level = "info" if decoded["valid"] and decoded["golden"]["status"] != "FAIL" else "error"
            self._emit(
                "log_frame",
                f"hart{decoded['hart_id']} package{decoded['package_number']} "
                f"count={decoded['count']} golden={decoded['golden']['status']}",
                level=level,
                frame=decoded,
            )

    def status(self) -> dict[str, Any]:
        with self._lock:
            return {
                "capture_running": self.capture_running,
                "interface_id": self.interface_id,
                "board_state": self.board_state,
                "program_send_allowed": self.program_send_allowed,
                "last_system_code": self.last_system_code,
                "tx_busy": self.tx_busy,
                "tx_progress": dict(self.tx_progress),
                "stats": dict(self.stats),
                "events": list(self._events)[-100:],
                "system_messages": list(self._system_messages),
                "reductions": list(self._reductions),
                "comparison_summary": self._comparison_summary_locked(),
                "session_files": self.recorder.files(),
                "diagnostics": self.network.diagnostics(),
                "limits": {"max_program_bytes": self.max_program_bytes},
            }

    def _comparison_summary_locked(self) -> dict[str, Any]:
        expected = len(self.golden.document.get("packages", []))
        latest: dict[tuple[int, int], dict[str, Any]] = {}
        for item in self._reductions:
            latest[(int(item["hart_id"]), int(item["package_number"]))] = item
        values = list(latest.values())
        failed = [item for item in values if item.get("golden", {}).get("status") == "FAIL"]
        passed = [item for item in values if item.get("golden", {}).get("status") == "PASS"]
        if failed:
            overall = "FAIL"
        elif expected and len(passed) == expected:
            overall = "PASS"
        else:
            overall = "WAITING"
        return {
            "status": overall,
            "expected_packages": expected,
            "received_packages": len(values),
            "passed_packages": len(passed),
            "failed_packages": len(failed),
            "last_reduction": dict(self._reductions[-1]) if self._reductions else None,
        }

    def clear_logs(self) -> None:
        with self._lock:
            self._events.clear()
            self._system_messages.clear()
            self._reductions.clear()
            for key in self.stats:
                self.stats[key] = 0

    def save_logs(self) -> dict[str, Any]:
        with self._lock:
            document = {
                "saved_at": self._now(),
                "board_state": self.board_state,
                "last_system_code": self.last_system_code,
                "stats": dict(self.stats),
                "system_messages": list(self._system_messages),
                "reductions": list(self._reductions),
                "comparison_summary": self._comparison_summary_locked(),
                "events": list(self._events),
            }
        path = self.recorder.save_log_snapshot(document)
        return {"name": path.name, "bytes": path.stat().st_size}

    def golden_document(self) -> dict[str, Any]:
        return json.loads(json.dumps(self.golden.document))
