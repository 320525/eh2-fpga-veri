"""Thread-safe orchestration of capture, program sending and board state."""

from __future__ import annotations

from collections import deque
from datetime import datetime
import json
from pathlib import Path
import queue
import threading
import time
from typing import Any, Callable
from uuid import uuid4

from .golden import ProgramReference
from .automation import AutomationController
from .network import NetworkBackend
from .program_image import (
    DEFAULT_MAX_PROGRAM_BYTES,
    ProgramImage,
    inspect_program_path,
    parse_program_file,
)
from .protocol import (
    BROADCAST_MAC,
    HART0_INFO_SOURCE_MAC,
    HART1_INFO_SOURCE_MAC,
    INFO_DATA_ETHERTYPE,
    INFO_DATA_FRAME_BYTES,
    INFO_RECORD_BYTES,
    INFO_RECORDS_PER_FRAME,
    build_end_frame,
    build_host_global_reset_frame,
    build_host_info_retransmit_all_frame,
    build_host_send_stopped_frame,
    build_preconfig_program_frame,
    decode_frame,
    iter_program_file_frames,
    iter_program_frames,
)
from .session import SessionRecorder


EventSink = Callable[[dict[str, Any]], None]
MAX_INFO_RECORDS_PER_HART = 4 * 1024 * 1024 * 1024 // INFO_RECORD_BYTES
RESET_RECOVERY_TIMEOUT_SECONDS = 8.0
RESET_RECOVERY_MAX_RETRIES = 2


class _SequenceCoverage:
    """Compact one-bit-per-sequence coverage for an out-of-order Info stream."""

    def __init__(self) -> None:
        self.bits = bytearray()
        self.count = 0
        self.max_sequence = -1

    def clear(self) -> None:
        self.bits.clear()
        self.count = 0
        self.max_sequence = -1

    def add(self, sequence: int) -> bool:
        if not 0 <= sequence < MAX_INFO_RECORDS_PER_HART:
            return False
        byte_index = sequence >> 3
        mask = 1 << (sequence & 7)
        if byte_index >= len(self.bits):
            self.bits.extend(bytes(byte_index + 1 - len(self.bits)))
        if self.bits[byte_index] & mask:
            return False
        self.bits[byte_index] |= mask
        self.count += 1
        self.max_sequence = max(self.max_sequence, sequence)
        return True

    def complete(self, total: int) -> bool:
        expected_max = -1 if total == 0 else total - 1
        return self.count == total and self.max_sequence == expected_max


class BoardService:
    def __init__(
        self,
        webui_root: Path,
        event_sink: EventSink,
        max_program_bytes: int = DEFAULT_MAX_PROGRAM_BYTES,
        windows_shared_root: Path = Path("D:/share/comp_log_dvspike"),
    ):
        self.webui_root = webui_root.resolve()
        self.event_sink = event_sink
        self.max_program_bytes = int(max_program_bytes)
        self.network = NetworkBackend()
        self.recorder = SessionRecorder(self.webui_root / "runtime")
        self.program_reference = ProgramReference(
            self.webui_root / "golden" / "stress_200k_system_golden.json"
        )
        self._lock = threading.RLock()
        self._tx_lock = threading.Lock()
        self._tx_cancel_event = threading.Event()
        # Npcap callback only copies/enqueues raw frames.  Decoding 60 records,
        # CSV/PCAP persistence and WebSocket events run here so a line-rate
        # burst is absorbed in memory instead of blocking the capture thread.
        self._rx_queue: queue.SimpleQueue[bytes | None] = queue.SimpleQueue()
        self._rx_worker: threading.Thread | None = None
        self._stop_ack_pending = False
        self._stop_ack_sent = False
        self._info_retransmit_pending = False
        self._info_retransmit_count = 0
        self._info_loss_discard_pending = False
        self._reset_watchdog_generation = 0
        self._events: deque[dict[str, Any]] = deque(maxlen=500)
        # The browser and status snapshots need only the most recent status
        # history.  Error codes are persisted independently by SessionRecorder.
        self._system_messages: deque[dict[str, Any]] = deque(maxlen=100)
        self._info_frames: deque[dict[str, Any]] = deque(maxlen=5000)
        self._info_done: dict[int, dict[str, Any]] = {}
        self._info_expected_frame = [0, 0]
        self._info_sequence_coverage = [_SequenceCoverage(), _SequenceCoverage()]
        self._info_received_frames = [0, 0]
        self._info_received_records = [0, 0]
        self._info_stream_error = [False, False]
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
            "rx_info_data": 0,
            "rx_info_done": 0,
            "rx_invalid": 0,
            "rx_ignored": 0,
            "tx_total": 0,
        }
        self.automation = AutomationController(
            self.webui_root,
            self._emit,
            send_preconfig=lambda: self.send_preconfig(force=False, inter_frame_us=0),
            send_program_path=lambda path: self.send_program_path(path),
            windows_shared_root=windows_shared_root,
            reset_board=lambda: self._send_board_reset(
                preserve_automation=True, recovery_attempt=0
            ),
            request_info_retransmit=lambda reason: self._request_info_retransmit(
                reason, automation=True
            ),
        )

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

    def _reset_info_round_locked(self) -> None:
        self._info_done.clear()
        self._info_expected_frame[:] = [0, 0]
        for coverage in self._info_sequence_coverage:
            coverage.clear()
        self._info_received_frames[:] = [0, 0]
        self._info_received_records[:] = [0, 0]
        self._info_stream_error[:] = [False, False]

    def _request_info_retransmit(self, reason: str, *, automation: bool = False) -> None:
        """Ask FPGA to replay retained DDR1 logs; cache switches only on ACK."""

        with self._lock:
            if self._info_retransmit_pending:
                return
            if not self.capture_running or not self.interface_id:
                self._emit(
                    "info_retransmit_error",
                    "无法请求Info重传：监听接口未启动",
                    level="error", reason=reason,
                )
                return
            self._info_retransmit_pending = True
            interface_id = self.interface_id
            self.board_state = "END_WAIT_RETRANSMIT_ACK"

        def on_packet_sent(raw: bytes) -> None:
            with self._lock:
                self.stats["tx_total"] += 1
            self.recorder.record_packet(raw)

        def worker() -> None:
            try:
                acquired = self._tx_lock.acquire(timeout=30.0)
                if not acquired:
                    raise RuntimeError("等待当前发送任务停止超时")
                try:
                    self.network.send_frame(
                        interface_id, build_host_info_retransmit_all_frame(),
                        on_packet_sent,
                    )
                finally:
                    self._tx_lock.release()
                self._emit(
                    "info_retransmit_requested",
                    "检测到Info帧缺失，已发送HOST_INFO_RETRANSMIT_ALL；等待重传开始确认",
                    level="warning", code="44144445", reason=reason,
                    automation=automation,
                )
            except Exception as exc:  # pragma: no cover - requires Npcap/NIC
                with self._lock:
                    self._info_retransmit_pending = False
                self._emit(
                    "info_retransmit_error", f"Info重传请求发送失败: {exc}",
                    level="error", reason=reason,
                )

        threading.Thread(
            target=worker, name="eh2-info-retransmit", daemon=True,
        ).start()

    def _discard_info_stream(
        self,
        reason: str,
        *,
        comparison_reason: str = "Info frame number discontinuity",
        hart: int | None = None,
        frame_number: int | None = None,
        expected_frame: int | None = None,
        first_failure_sequence: int | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        """Discard a transport-damaged round; never request replay here."""

        handled = self.automation.on_info_stream_loss(
            reason,
            comparison_reason=comparison_reason,
            hart=hart,
            frame_number=frame_number,
            expected_frame=expected_frame,
            first_failure_sequence=first_failure_sequence,
            details=details,
        )
        if handled:
            with self._lock:
                self._info_loss_discard_pending = True
            self._emit(
                "info_loss_round_discarded",
                "Info回传缺失：已丢弃本轮并发送全局复位，不请求重传",
                level="error",
                reason=reason,
                hart=hart,
                frame_number=frame_number,
                expected_frame=expected_frame,
            )
            return

        with self._lock:
            if (
                not self.capture_running
                or self._info_loss_discard_pending
                or self.board_state == "RESETTING"
            ):
                return
            self._info_loss_discard_pending = True
        self._emit(
            "info_loss_manual_reset",
            "Info回传缺失：当前非自动化轮次，已直接请求全局复位",
            level="error",
            reason=reason,
            hart=hart,
            frame_number=frame_number,
            expected_frame=expected_frame,
        )
        self._send_board_reset(preserve_automation=False, recovery_attempt=0)

    def start_capture(self, interface_id: str) -> dict[str, Any]:
        if not interface_id:
            raise ValueError("必须选择有线网卡")
        with self._lock:
            if self.capture_running:
                raise RuntimeError("监听已经启动")
            session_dir = self.recorder.start(interface_id)
            self._rx_queue = queue.SimpleQueue()
            self._rx_worker = threading.Thread(
                target=self._rx_worker_loop,
                name="eh2-rx-decode",
                daemon=True,
            )
            self._rx_worker.start()
            try:
                self.network.start_capture(interface_id, self._enqueue_packet)
            except Exception:
                self._rx_queue.put(None)
                self._rx_worker.join(timeout=2.0)
                self._rx_worker = None
                self.recorder.close()
                raise
            self.capture_running = True
            self.interface_id = interface_id
            self.board_state = "LISTENING"
            self.program_send_allowed = False
            self._info_loss_discard_pending = False
            self._reset_info_round_locked()
        self._emit("capture_started", "已开始持续监听板卡返回帧", interface_id=interface_id)
        return {"session": session_dir.name, "interface_id": interface_id}

    def stop_capture(self) -> None:
        if self.automation.enabled:
            self.automation.stop("监听被停止，自动化流程同时停止")
        self.network.stop_capture()
        worker = self._rx_worker
        self._rx_worker = None
        if worker is not None:
            self._rx_queue.put(None)
            worker.join(timeout=30.0)
        with self._lock:
            self.capture_running = False
            self.interface_id = None
            self._reset_watchdog_generation += 1
            self._info_loss_discard_pending = False
            if self.board_state != "ERROR":
                self.board_state = "DISCONNECTED"
            self.program_send_allowed = False
        self._emit("capture_stopped", "监听已停止", level="warning")
        self.recorder.close()

    def _enqueue_packet(self, raw: bytes) -> None:
        self._rx_queue.put(bytes(raw))

    def _rx_worker_loop(self) -> None:
        while True:
            raw = self._rx_queue.get()
            if raw is None:
                return
            try:
                self._on_packet(raw)
            except Exception as exc:
                self._emit(
                    "rx_decode_error",
                    f"接收帧后台解码异常: {exc}",
                    level="error",
                )

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

    def send_program_path(self, path: Path, force: bool = False, inter_frame_us: int = 0) -> None:
        """Stream an automatically generated shared-folder image to the board."""

        manifest = inspect_program_path(path, max_bytes=self.max_program_bytes)
        if not force and not self.program_send_allowed:
            raise RuntimeError("尚未收到允许本轮发送的33333333")
        total_frames = int(manifest["frame_count"])
        nominal_seconds = total_frames * max(0, inter_frame_us) / 1_000_000
        if nominal_seconds >= 18 and not force:
            raise RuntimeError("配置的帧间隔使名义发送时间接近20秒超时")
        self._begin_send(
            operation="PROGRAM_WRITE",
            frames=iter_program_file_frames(path),
            total_frames=total_frames,
            inter_frame_us=inter_frame_us,
            program_manifest=manifest,
        )

    def send_end_only(self) -> None:
        self._begin_send(
            operation="END_FRAME_ONLY",
            frames=[],
            total_frames=0,
            inter_frame_us=0,
            trailer_only=True,
        )

    def reset_board(self) -> None:
        """Operator reset: stop automation, serialize reset, keep RX listening."""

        self._send_board_reset(preserve_automation=False, recovery_attempt=0)

    def _send_board_reset(
        self, *, preserve_automation: bool, recovery_attempt: int,
    ) -> None:
        """Send a reset command; watchdog recovery keeps comparison alive."""

        if self.automation.enabled and not preserve_automation:
            self.automation.stop("用户请求板级全局复位；当前自动化轮次已停止并保留")
        with self._lock:
            if not self.capture_running or not self.interface_id:
                raise RuntimeError("必须先启动监听，才能确认复位后的11111111")
            self._tx_cancel_event.set()
            interface_id = self.interface_id
            self.board_state = "RESETTING"

        def on_packet_sent(raw: bytes) -> None:
            with self._lock:
                self.stats["tx_total"] += 1
            self.recorder.record_packet(raw)

        def worker() -> None:
            acquired = self._tx_lock.acquire(timeout=30.0)
            if not acquired:
                self._emit(
                    "board_reset_error",
                    "等待当前发送任务停止超时，板级复位命令尚未发出",
                    level="error",
                )
                return
            try:
                self.network.send_frame(
                    interface_id,
                    build_host_global_reset_frame(),
                    on_packet_sent,
                )
                self._emit(
                    "board_reset_sent",
                    "已发送 HOST_GLOBAL_RESET 0x44134445，等待板卡重新返回11111111",
                    code="44134445",
                    automatic_recovery=preserve_automation,
                    recovery_attempt=recovery_attempt,
                )
                self._arm_reset_recovery_watchdog(
                    reason="HOST_GLOBAL_RESET后未收到PREINIT_DONE",
                    attempt=recovery_attempt,
                )
            except Exception as exc:  # pragma: no cover - requires Npcap/NIC
                self._emit(
                    "board_reset_error",
                    f"板级复位命令发送失败: {exc}",
                    level="error",
                )
            finally:
                self._tx_lock.release()

        threading.Thread(target=worker, name="eh2-board-reset", daemon=True).start()

    def _arm_reset_recovery_watchdog(self, *, reason: str, attempt: int = 0) -> None:
        """Require PREINIT after RESETTING, retrying without cancelling compare."""

        with self._lock:
            self._reset_watchdog_generation += 1
            generation = self._reset_watchdog_generation

        def worker() -> None:
            time.sleep(RESET_RECOVERY_TIMEOUT_SECONDS)
            with self._lock:
                if generation != self._reset_watchdog_generation:
                    return
                still_waiting = bool(
                    self.capture_running and self.board_state == "RESETTING"
                )
                if not still_waiting:
                    return
                if attempt >= RESET_RECOVERY_MAX_RETRIES:
                    self.board_state = "RESET_TIMEOUT"
                    timed_out = True
                else:
                    timed_out = False
            if timed_out:
                self._emit(
                    "reset_recovery_timeout",
                    "全局复位恢复超时：已重试仍未收到0x11111111，请检查PHY/MIG初始化或执行板级硬复位",
                    level="error",
                    attempts=attempt,
                    reason=reason,
                )
                return
            self._emit(
                "reset_recovery_retry",
                f"RESETTING持续{RESET_RECOVERY_TIMEOUT_SECONDS:g}秒未收到0x11111111，自动补发全局复位命令",
                level="warning",
                attempt=attempt + 1,
                reason=reason,
            )
            try:
                self._send_board_reset(
                    preserve_automation=True,
                    recovery_attempt=attempt + 1,
                )
            except Exception as exc:
                self._emit(
                    "reset_recovery_error",
                    f"自动补发全局复位命令失败: {exc}",
                    level="error",
                )

        threading.Thread(
            target=worker,
            name=f"eh2-reset-watchdog-{generation}",
            daemon=True,
        ).start()

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
            # Automated images can contain tens of thousands of program frames.
            # Their SHA-256/manifest is authoritative; duplicating every TX frame
            # into a synchronous PCAP can exceed the 20 s FPGA watchdog.
            if not self.automation.enabled:
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
                    self.board_state = "ERROR_WAIT_HOST_RESET"
                self._emit(
                    "host_send_stopped",
                    "已向板卡发送 HOST_SEND_STOPPED 0x44124445；板卡保持ERROR，等待上位机显式复位",
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
        frame = bytes(raw)
        no_fcs = frame[:-4] if len(frame) == INFO_DATA_FRAME_BYTES + 4 else frame
        ethertype = int.from_bytes(no_fcs[12:14], "big") if len(no_fcs) >= 14 else -1
        source = no_fcs[6:12] if len(no_fcs) >= 12 else b""
        auto_info_data = bool(
            self.automation.accepting_info_frames()
            and ethertype == INFO_DATA_ETHERTYPE
            and source in {HART0_INFO_SOURCE_MAC, HART1_INFO_SOURCE_MAC}
        )
        auto_info_done = bool(
            self.automation.accepting_info_frames()
            and ethertype == 0x88B8
            and source in {HART0_INFO_SOURCE_MAC, HART1_INFO_SOURCE_MAC}
        )
        if auto_info_data or auto_info_done:
            self.automation.on_info_frame(frame)
        else:
            self.recorder.record_packet(frame)
        if auto_info_data:
            self._on_automation_info_data(no_fcs)
            return
        decoded = decode_frame(frame)
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
                    if decoded["code"] == "11111111":
                        # PREINIT proves the new reset epoch is alive and
                        # cancels every older watchdog thread by generation.
                        self._reset_watchdog_generation += 1
                        self._info_loss_discard_pending = False
                    if decoded["state"] != "KEEP":
                        self.board_state = decoded["state"]
                    self.program_send_allowed = decoded["code"] == "33333333"
                    # READY grants a fresh program session.  Preserve history
                    # in the visible/log deques, but reset the authoritative
                    # frame/record counters used for this round's END checks.
                    if decoded["code"] == "33333333":
                        self._reset_info_round_locked()
                    if (decoded["code"] == "77770001" and
                            self._info_retransmit_pending):
                        # The confirmation frame is the session boundary.  Do
                        # not erase partial logs until it arrives, otherwise
                        # late old-generation frames could be misclassified.
                        self._reset_info_round_locked()
                        self._info_retransmit_pending = False
                        self._info_retransmit_count += 1
                        self.board_state = "END"
                self._system_messages.append(dict(decoded))
            self.recorder.record_system(decoded)
            # Use the protocol table's decoded state as the single source of
            # truth so newly added valid error codes are recorded automatically.
            is_error = decoded["state"] == "ERROR"
            if is_error and decoded["valid"]:
                self.recorder.record_error_code(decoded)
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
            self.automation.on_system(decoded)
            return
        if decoded["kind"] == "info_data":
            decoded["received_at"] = self._now()
            hart = int(decoded["hart_id"])
            with self._lock:
                expected_frame = self._info_expected_frame[hart]
                frame_continuous = decoded["frame_number"] == expected_frame
                records = decoded["records"]
                non_padding = [item for item in records if not item["padding"]]
                first_padding = next(
                    (index for index, item in enumerate(records) if item["padding"]),
                    len(records),
                )
                padding_order_ok = all(
                    item["padding"] for item in records[first_padding:]
                )
                sequence_unique = True
                for item in non_padding:
                    if not self._info_sequence_coverage[hart].add(
                        int(item["sequence"])
                    ):
                        sequence_unique = False
                decoded["frame_number_continuous"] = frame_continuous
                # Preserve the old JSON key for saved-log compatibility.  It
                # now means sequence coverage is valid (unique/in range), not
                # that physical DDR/TX order is monotonically increasing.
                decoded["sequence_continuous"] = sequence_unique
                decoded["sequence_unique"] = sequence_unique
                decoded["padding_order_ok"] = padding_order_ok
                decoded["valid_records"] = len(non_padding)
                decoded["padding_records"] = len(records) - len(non_padding)
                decoded["valid"] = bool(
                    decoded["valid"] and frame_continuous
                    and sequence_unique and padding_order_ok
                )

                self._info_received_frames[hart] += 1
                self._info_received_records[hart] = \
                    self._info_sequence_coverage[hart].count
                self._info_expected_frame[hart] = decoded["frame_number"] + 1
                if not decoded["valid"]:
                    self._info_stream_error[hart] = True
                summary = {
                    key: value for key, value in decoded.items()
                    if key != "records"
                }
                self._info_frames.append(summary)
                self.stats["rx_info_data"] += 1

            self.recorder.record_info_frame(decoded)
            level = "info" if decoded["valid"] else "error"
            if (not decoded["valid"] or self.stats["rx_info_data"] == 1 or
                    self.stats["rx_info_data"] % 1024 == 0):
                self._emit(
                    "info_data_progress",
                    f"Info数据已写入TXT：hart{hart} frame={decoded['frame_number']}，"
                    f"累计{self._info_received_records[hart]}条",
                    level=level,
                    frame=summary,
                )
            if not decoded["valid"]:
                self._discard_info_stream(
                    f"hart{hart} frame={decoded['frame_number']}编号/记录连续性错误",
                    hart=hart,
                    frame_number=int(decoded["frame_number"]),
                    expected_frame=int(expected_frame),
                    details={
                        "frame_number_continuous": frame_continuous,
                        "sequence_unique": sequence_unique,
                        "padding_order_ok": padding_order_ok,
                    },
                )
            return

        if decoded["kind"] == "info_done":
            decoded["received_at"] = self._now()
            hart = int(decoded["hart_id"])
            with self._lock:
                received_frames = self._info_received_frames[hart]
                received_records = self._info_received_records[hart]
                count_ok = (
                    decoded["total_frames"] == received_frames
                    and decoded["total_records"] == received_records
                )
                last_sequence_ok = (
                    decoded["last_sequence"] ==
                    (0xFFFF_FFFF if received_records == 0
                     else decoded["total_records"] - 1)
                )
                coverage_ok = self._info_sequence_coverage[hart].complete(
                    decoded["total_records"]
                )
                host_ok = bool(
                    decoded["valid"] and count_ok and last_sequence_ok
                    and coverage_ok and not self._info_stream_error[hart]
                )
                decoded["host_received_frames"] = received_frames
                decoded["host_received_records"] = received_records
                decoded["frame_count_match"] = decoded["total_frames"] == received_frames
                decoded["record_count_match"] = decoded["total_records"] == received_records
                decoded["last_sequence_match"] = last_sequence_ok
                decoded["sequence_coverage_match"] = coverage_ok
                decoded["host_compare"] = "PASS" if host_ok else "FAIL"
                self._info_done[hart] = dict(decoded)
                self.stats["rx_info_done"] += 1
            self.recorder.record_info_done(decoded)
            self._emit(
                "info_done_frame",
                f"hart{hart} 回传结束：记录{decoded['total_records']}，"
                f"帧{decoded['total_frames']}，上位机核对={decoded['host_compare']}",
                level="info" if host_ok else "error",
                frame=decoded,
            )
            if host_ok:
                self.automation.on_info_done(hart)
            else:
                self._discard_info_stream(
                    f"hart{hart}完成帧与已收Info数据不一致",
                    comparison_reason="Info done count does not match captured stream",
                    hart=hart,
                    details={
                        "host_received_frames": received_frames,
                        "declared_frames": int(decoded["total_frames"]),
                        "host_received_records": received_records,
                        "declared_records": int(decoded["total_records"]),
                    },
                )
            return

    def _on_automation_info_data(self, raw: bytes) -> None:
        """Validate a 60-record frame without allocating 60 Python dictionaries."""

        with self._lock:
            self.stats["rx_total"] += 1
        if len(raw) != INFO_DATA_FRAME_BYTES:
            with self._lock:
                self.stats["rx_invalid"] += 1
            self._emit("invalid_frame", "自动化Info数据帧长度错误", level="error", length=len(raw))
            return
        if raw[0:6] != BROADCAST_MAC:
            with self._lock:
                self.stats["rx_invalid"] += 1
            self._emit("invalid_frame", "自动化Info数据帧目的MAC错误", level="error")
            return
        hart = 0 if raw[6:12] == HART0_INFO_SOURCE_MAC else 1
        payload = memoryview(raw)[14:]
        frame_number = int.from_bytes(payload[0:4], "big")
        valid_records = 0
        padding_seen = False
        padding_order_ok = True
        metadata_hart_ok = True
        sequence_unique = True
        last_record: dict[str, Any] | None = None
        with self._lock:
            expected_frame = self._info_expected_frame[hart]
            for slot in range(INFO_RECORDS_PER_FRAME):
                start = 4 + slot * INFO_RECORD_BYTES
                record = bytes(payload[start:start + INFO_RECORD_BYTES])
                if record == bytes(INFO_RECORD_BYTES):
                    padding_seen = True
                    continue
                if padding_seen:
                    padding_order_ok = False
                sequence = int.from_bytes(record[0:4], "big")
                metadata = int.from_bytes(record[12:16], "big")
                if not self._info_sequence_coverage[hart].add(sequence):
                    sequence_unique = False
                if ((metadata >> 16) & 1) != hart:
                    metadata_hart_ok = False
                valid_records += 1
                if slot == INFO_RECORDS_PER_FRAME - 1 or valid_records == 1:
                    last_record = {
                        "record_index": slot,
                        "sequence": sequence,
                        "pc": f"0x{int.from_bytes(record[4:8], 'big'):08x}",
                        "instruction": f"0x{int.from_bytes(record[8:12], 'big'):08x}",
                        "metadata": f"0x{metadata:08x}",
                        "waw_cancel_kind": (metadata >> 30) & 3,
                        "hart_metadata": (metadata >> 16) & 1,
                        "privilege": (metadata >> 14) & 3,
                        "event_type": (metadata >> 12) & 3,
                        "register_number": metadata & 0xFFF,
                        "data": f"0x{int.from_bytes(record[16:20], 'big'):08x}",
                        "waw_cancel_number": int.from_bytes(record[20:24], "big"),
                        "hart_id": hart,
                        "frame_number": frame_number,
                        "received_at": self._now(),
                    }
            valid = bool(
                frame_number == expected_frame
                and sequence_unique
                and padding_order_ok
                and metadata_hart_ok
            )
            self._info_received_frames[hart] += 1
            self._info_received_records[hart] = \
                self._info_sequence_coverage[hart].count
            self._info_expected_frame[hart] = frame_number + 1
            if not valid:
                self._info_stream_error[hart] = True
            summary = {
                "received_at": self._now(),
                "hart_id": hart,
                "frame_number": frame_number,
                "valid_records": valid_records,
                "padding_records": INFO_RECORDS_PER_FRAME - valid_records,
                "frame_number_continuous": frame_number == expected_frame,
                "sequence_continuous": sequence_unique,
                "sequence_unique": sequence_unique,
                "padding_order_ok": padding_order_ok,
                "metadata_hart_ok": metadata_hart_ok,
                "valid": valid,
            }
            self._info_frames.append(summary)
            self.stats["rx_info_data"] += 1
            total_frames = self.stats["rx_info_data"]
        if not valid or total_frames == 1 or total_frames % 1024 == 0:
            self._emit(
                "info_data_progress",
                f"自动化Info接收：hart{hart} frame={frame_number}，累计{self._info_received_records[hart]}条",
                level="info" if valid else "error",
                frame=summary,
            )
        if not valid:
            self._discard_info_stream(
                f"自动化hart{hart} frame={frame_number}编号/记录连续性错误",
                hart=hart,
                frame_number=frame_number,
                expected_frame=int(expected_frame),
                details={
                    "frame_number_continuous": frame_number == expected_frame,
                    "sequence_unique": sequence_unique,
                    "padding_order_ok": padding_order_ok,
                    "metadata_hart_ok": metadata_hart_ok,
                },
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
                "info_done": {str(key): value for key, value in self._info_done.items()},
                "comparison_summary": self._comparison_summary_locked(),
                "info_retransmit_pending": self._info_retransmit_pending,
                "info_retransmit_count": self._info_retransmit_count,
                "info_loss_discard_pending": self._info_loss_discard_pending,
                "session_files": self.recorder.files(),
                "diagnostics": self.network.diagnostics(),
                "limits": {"max_program_bytes": self.max_program_bytes},
                "automation": self.automation.status(),
            }

    def _comparison_summary_locked(self) -> dict[str, Any]:
        done_values = list(self._info_done.values())
        if any(item.get("host_compare") == "FAIL" for item in done_values):
            overall = "FAIL"
        elif len(done_values) == 2 and all(
            item.get("host_compare") == "PASS" for item in done_values
        ):
            overall = "PASS"
        else:
            overall = "WAITING"
        return {
            "status": overall,
            "hart0_frames": self._info_received_frames[0],
            "hart1_frames": self._info_received_frames[1],
            "hart0_records": self._info_received_records[0],
            "hart1_records": self._info_received_records[1],
            "hart0_done": self._info_done.get(0),
            "hart1_done": self._info_done.get(1),
            "stream_error": list(self._info_stream_error),
        }

    def clear_logs(self) -> None:
        with self._lock:
            self._events.clear()
            self._system_messages.clear()
            self._info_frames.clear()
            self._reset_info_round_locked()
            for key in self.stats:
                self.stats[key] = 0

    def clear_run_cache(self) -> dict[str, Any]:
        """Clear stale run artifacts while preserving every active operation."""

        with self._lock:
            capture_running = self.capture_running
            tx_busy = self.tx_busy

        automation_result = self.automation.clear_run_cache()
        sessions_removed = self.recorder.cleanup_previous_sessions(
            preserve_current=capture_running
        )

        # An in-flight manual sender may still rely on the uploaded ProgramImage.
        # Keep the complete upload cache in that case.  The next cleanup after TX
        # finishes can remove it safely.
        uploads_removed = 0
        uploads_preserved = 0
        if tx_busy:
            with self._lock:
                uploads_preserved = len(self._uploads)
        else:
            with self._lock:
                self._uploads.clear()
            uploads_removed = self.recorder.cleanup_upload_cache()

        result: dict[str, Any] = {
            **automation_result,
            "sessions": sessions_removed,
            "upload_files": uploads_removed,
            "uploads_preserved": uploads_preserved,
            "current_session_preserved": capture_running,
            "active_tx_preserved": tx_busy,
        }
        self._emit(
            "run_cache_cleared",
            "历史运行缓存已清理；正在运行的任务和当前监听会话保持不变",
            **result,
        )
        return result

    def save_logs(self) -> dict[str, Any]:
        with self._lock:
            document = {
                "saved_at": self._now(),
                "board_state": self.board_state,
                "last_system_code": self.last_system_code,
                "stats": dict(self.stats),
                "system_messages": list(self._system_messages),
                "info_frames": list(self._info_frames),
                "info_done": {str(key): value for key, value in self._info_done.items()},
                "comparison_summary": self._comparison_summary_locked(),
                "events": list(self._events),
            }
        path = self.recorder.save_log_snapshot(document)
        return {"name": path.name, "bytes": path.stat().st_size}

    def golden_document(self) -> dict[str, Any]:
        return json.loads(json.dumps(self.program_reference.document))
