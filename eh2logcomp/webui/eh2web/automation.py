"""Strict one-round-at-a-time automated board validation controller."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
import json
from pathlib import Path
import secrets
import shutil
import threading
import time
from typing import Any, Callable

from .comparator import compare_run
from .info_log import DecodedInfoTextWriter, InfoFrameLogWriter, iter_info_frames
from .remote import RemoteJob, RemoteSettings


Emit = Callable[..., None]


@dataclass
class Round:
    run_id: str
    seed: int
    local_dir: Path
    remote_dir: Path
    fpga_log: Path
    writer: InfoFrameLogWriter
    remote_pid: int | None = None
    remote_status: dict[str, Any] | None = None
    board_program_ready: bool = False
    program_send_started: bool = False
    info_done_harts: set[int] | None = None
    board_exe_end: bool = False
    comparing: bool = False
    compared_instructions: int = 0
    failure_text_log: Path | None = None
    system_events: deque[dict[str, Any]] | None = None
    timing_marks: dict[str, float] = field(default_factory=dict)
    retransmit_count: int = 0

    def __post_init__(self) -> None:
        if self.info_done_harts is None:
            self.info_done_harts = set()
        if self.system_events is None:
            self.system_events = deque(maxlen=100)
        self.timing_marks.setdefault("round_start", time.perf_counter())


class AutomationController:
    ERROR_PREFIXES = ("222200", "444400", "666600")
    RECOVERABLE_INFO_LOSS_REASONS = frozenset({
        "Info frame number discontinuity",
        "Info done count does not match captured stream",
        "FPGA Info stream is missing a sequence",
        "FPGA Info log does not contain both completion frames",
    })

    def __init__(
        self,
        webui_root: Path,
        emit: Emit,
        send_preconfig: Callable[[], None],
        send_program_path: Callable[[Path], None],
        windows_shared_root: Path,
        reset_board: Callable[[], None] | None = None,
        request_info_retransmit: Callable[[str], None] | None = None,
    ):
        self.webui_root = webui_root.resolve()
        self.runtime = self.webui_root / "runtime" / "automation"
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.runs_root = self.webui_root / "runlog" / "automation"
        self.runs_root.mkdir(parents=True, exist_ok=True)
        self.wrong_log = self.runs_root / "_wrong.txt"
        self.history = self.runtime / "pass_history.jsonl"
        self.comparison_stats_path = self.runtime / "comparison_stats.json"
        self.emit = emit
        self._send_preconfig = send_preconfig
        self._send_program_path = send_program_path
        self._reset_board = reset_board
        self._request_info_retransmit = request_info_retransmit
        self.remote = RemoteJob(self.webui_root, windows_shared_root)
        self._lock = threading.RLock()
        self.comparison_stats = self._load_comparison_stats()
        self.session_comparison_stats = {
            "total_comparisons": 0,
            "pass_comparisons": 0,
            "fail_comparisons": 0,
            "compared_instructions": 0,
        }
        self._stop = threading.Event()
        self._poller = threading.Thread(target=self._poll_loop, name="eh2-auto-poll", daemon=True)
        self._poller.start()
        self.enabled = False
        self.state = "DISABLED"
        self.settings: RemoteSettings | None = None
        self.round: Round | None = None
        self.preinit_pending = False
        self.preconfig_inflight = False
        self.program_ready_pending = False
        self.last_result: dict[str, Any] | None = None
        self.last_error: str | None = None
        self.last_timings: dict[str, Any] | None = None
        self.last_vm_wrong_log: Path | None = None
        self.last_wrong_log: Path | None = None
        self.recovering_skipped_round = False
        self.session_id: str | None = None
        self.session_dir: Path | None = None

    @staticmethod
    def _mark_timing(current: Round | None, name: str) -> None:
        if current is not None:
            current.timing_marks.setdefault(name, time.perf_counter())

    @staticmethod
    def _timing_summary(current: Round) -> dict[str, Any]:
        marks = dict(current.timing_marks)

        def interval(start: str, end: str) -> float | None:
            if start not in marks or end not in marks:
                return None
            return round(max(0.0, marks[end] - marks[start]), 6)

        summary: dict[str, Any] = {
            "round_elapsed": round(
                max(0.0, time.perf_counter() - marks["round_start"]), 6
            ),
            "remote_to_program_ready": interval("round_start", "program_ready"),
            "host_wait_to_program_send": interval(
                "round_start", "host_program_send_start"
            ),
            "fpga_program_write": interval("fpga_program_start", "fpga_program_done"),
            "fpga_execute": interval("fpga_program_done", "fpga_info_dump_start"),
            "fpga_info_dump": interval("fpga_info_dump_start", "fpga_exe_end"),
            "spike_total_observed": interval("round_start", "spike_done"),
            "comparison": interval("comparison_start", "comparison_done"),
            "reset_to_preinit": interval("fpga_exe_end", "next_preinit"),
        }
        remote = current.remote_status or {}
        summary["remote_total"] = remote.get("elapsed_seconds")
        summary["remote_current_stage"] = remote.get("stage")
        summary["remote_stage_durations"] = dict(
            remote.get("stage_durations_seconds") or {}
        )
        return summary

    def _write_timing_report(self, current: Round) -> Path:
        summary = self._timing_summary(current)
        lines = [
            "# EH2 automation timing report (seconds; no wall-clock timestamps)",
            f"run_id={current.run_id}",
            f"seed={current.seed}",
        ]
        for key, value in summary.items():
            if key == "remote_stage_durations":
                continue
            lines.append(f"{key}={'-' if value is None else value}")
        for stage, value in summary["remote_stage_durations"].items():
            lines.append(f"remote_stage.{stage}={value}")
        path = current.local_dir / "timing_report.txt"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def _load_comparison_stats(self) -> dict[str, Any]:
        default = {
            "total_comparisons": 0,
            "pass_comparisons": 0,
            "fail_comparisons": 0,
            "last_run_id": None,
            "last_status": None,
            "updated_at": None,
        }
        if not self.comparison_stats_path.is_file():
            return default
        try:
            loaded = json.loads(self.comparison_stats_path.read_text(encoding="utf-8"))
            for key in ("total_comparisons", "pass_comparisons", "fail_comparisons"):
                value = int(loaded.get(key, 0))
                if value < 0:
                    raise ValueError(key)
                default[key] = value
            if default["total_comparisons"] != (
                default["pass_comparisons"] + default["fail_comparisons"]
            ):
                raise ValueError("comparison totals do not add up")
            default["last_run_id"] = loaded.get("last_run_id")
            default["last_status"] = loaded.get("last_status")
            default["updated_at"] = loaded.get("updated_at")
            return default
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            raise RuntimeError(
                f"系统比较计数文件损坏，请保留现场并检查 {self.comparison_stats_path}: {exc}"
            ) from exc

    def _record_comparison(self, current: Round, report: dict[str, Any]) -> None:
        status = str(report.get("status", "")).upper()
        if status not in {"PASS", "FAIL"}:
            raise RuntimeError(f"不能记录未知的系统比较结果: {status}")
        with self._lock:
            updated = dict(self.comparison_stats)
            updated["total_comparisons"] = int(updated["total_comparisons"]) + 1
            key = "pass_comparisons" if status == "PASS" else "fail_comparisons"
            updated[key] = int(updated[key]) + 1
            updated["last_run_id"] = current.run_id
            updated["last_status"] = status
            updated["updated_at"] = datetime.now().astimezone().isoformat(timespec="milliseconds")
            temporary = self.comparison_stats_path.with_suffix(".json.tmp")
            temporary.write_text(
                json.dumps(updated, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            temporary.replace(self.comparison_stats_path)
            self.comparison_stats = updated
            self.session_comparison_stats["total_comparisons"] += 1
            session_key = (
                "pass_comparisons" if status == "PASS" else "fail_comparisons"
            )
            self.session_comparison_stats[session_key] += 1
            self.session_comparison_stats["compared_instructions"] += max(
                0, int(report.get("compared_instructions", 0))
            )

    def start(self, settings: RemoteSettings, last_system_code: str | None) -> dict[str, Any]:
        if not settings.password:
            raise ValueError("请输入虚拟机SSH密码")
        if settings.instructions_per_hart <= 0:
            raise ValueError("每hart指令数必须为正数")
        if settings.instructions_per_hart % settings.chunk_instructions:
            raise ValueError("每hart指令数必须能被分块指令数整除")
        previous_terminal: Round | None = None
        with self._lock:
            if self.enabled:
                raise RuntimeError("自动化流程已经启动，不能创建第二条并发流程")
            if self.round is not None:
                if self.state not in {"FAILED", "STOPPED"}:
                    raise RuntimeError("上一轮尚未释放，不能创建第二条并发流程")
                # A new explicit button click is authorization to detach the
                # preserved failed/stopped run.  Its directories are not deleted.
                self.round.writer.close()
                if self.state == "FAILED":
                    previous_terminal = self.round
                self.round = None
            session_id = datetime.now().strftime("session_%Y%m%d_%H%M%S_%f")
            session_dir = (self.runs_root / session_id).resolve()
            if session_dir.parent != self.runs_root.resolve():
                raise RuntimeError(f"invalid automation session path: {session_dir}")
            session_dir.mkdir(parents=True, exist_ok=False)
            (session_dir / "automation_session.json").write_text(
                json.dumps(
                    {
                        "format_version": 1,
                        "session_id": session_id,
                        "started_at": datetime.now().astimezone().isoformat(
                            timespec="milliseconds"
                        ),
                        "settings": {
                            "host": settings.host,
                            "port": settings.port,
                            "username": settings.username,
                            "instructions_per_hart": settings.instructions_per_hart,
                            "chunk_instructions": settings.chunk_instructions,
                            "workers": settings.workers,
                        },
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            self.enabled = True
            self.settings = settings
            self.session_id = session_id
            self.session_dir = session_dir
            self.state = "WAIT_PREINIT"
            self.last_error = None
            self.last_result = None
            self.last_timings = None
            self.last_vm_wrong_log = None
            self.last_wrong_log = None
            self.recovering_skipped_round = False
            self.session_comparison_stats = {
                "total_comparisons": 0,
                "pass_comparisons": 0,
                "fail_comparisons": 0,
                "compared_instructions": 0,
            }
            self.preinit_pending = last_system_code == "11111111"
            self.program_ready_pending = last_system_code == "33333333"
        if previous_terminal is not None:
            self._materialize_failure_text(previous_terminal)
        self.emit("automation_started", "一键自动化已启动；严格等待本轮比较完成后才允许下一轮", settings={
            "host": settings.host,
            "port": settings.port,
            "username": settings.username,
            "instructions_per_hart": settings.instructions_per_hart,
            "chunk_instructions": settings.chunk_instructions,
            "workers": settings.workers,
        })
        if self.preinit_pending:
            self._schedule_preconfig()
        elif last_system_code in {"22222222", "33333333"}:
            # Permit one-button takeover even when the user starts automation
            # after PRECONFIG has already completed.  PROGRAM_WRITE's watchdog
            # starts on the first data frame, so generating at 33333333 is safe.
            self._schedule_round_start()
        return self.status()

    def stop(self, reason: str = "用户停止自动化") -> None:
        with self._lock:
            current = self.round
            self.enabled = False
            self.state = "STOPPED"
            self.last_error = reason
            self.recovering_skipped_round = False
        if current is not None:
            self.remote.request_cancel(current.run_id)
            current.writer.close()
        self.emit("automation_stopped", reason, level="warning")

    def shutdown(self) -> None:
        self._stop.set()
        self._poller.join(timeout=3)
        with self._lock:
            if self.round is not None:
                self.round.writer.close()

    def on_system(self, frame: dict[str, Any]) -> None:
        if not frame.get("valid"):
            return
        code = str(frame["code"]).lower()
        with self._lock:
            enabled = self.enabled
            current = self.round
            state = self.state
            recovering_skipped_round = self.recovering_skipped_round
        if current is not None and current.system_events is not None:
            current.system_events.append(dict(frame))
        if enabled and recovering_skipped_round:
            if code != "11111111":
                # A VM failure may be detected after READY, after a bulk send
                # has started, or while old status frames are still buffered.
                # Only PREINIT from the new reset epoch may release this gate.
                return
            with self._lock:
                if not self.enabled or not self.recovering_skipped_round:
                    return
                self.recovering_skipped_round = False
                self.preinit_pending = True
                self.program_ready_pending = False
                self.state = "WAIT_PRECONFIG_AFTER_SKIPPED_ROUND"
            self.emit(
                "automation_skipped_round_reset_complete",
                "可恢复失败轮次复位完成；已收到新的PREINIT，开始下一轮PRECONFIG",
            )
            self._schedule_preconfig()
            return
        if not enabled:
            # After an FPGA error, buffered log frames can still be ahead of
            # the system-error frame in the MAC/Npcap path.  Keep the failed
            # run's files open until PREINIT proves that the global reset has
            # ended the stream, then close them without deleting anything.
            if code == "11111111" and current is not None and state == "FAILED":
                current.writer.close()
                self._materialize_failure_text(current)
            return
        if code == "11111111":
            with self._lock:
                self.preinit_pending = True
                busy = self.round is not None
                self._mark_timing(self.round, "next_preinit")
            if not busy:
                self._schedule_preconfig()
            else:
                self.emit(
                    "automation_barrier",
                    "比较屏障尚未释放；已记录PREINIT，但不会提前启动下一轮",
                    level="warning",
                )
            return
        if code == "22222222":
            self._schedule_round_start()
            return
        if code == "33333333":
            start_needed = False
            with self._lock:
                if self.round is not None:
                    self.round.board_program_ready = True
                    self._mark_timing(self.round, "board_program_ready")
                    self.state = "WAIT_PROGRAM_AND_SPIKE"
                else:
                    # 33333333 can follow 22222222 before the SSH worker thread
                    # has installed the Round object, or capture may have missed
                    # 22222222.  Latch it rather than losing the one-shot grant.
                    self.program_ready_pending = True
                    start_needed = True
            if start_needed:
                self._schedule_round_start()
            self._maybe_send_program()
            return
        if code == "44004444":
            with self._lock:
                self._mark_timing(self.round, "fpga_program_start")
            return
        if code == "44114444":
            with self._lock:
                self._mark_timing(self.round, "fpga_receive_done")
            return
        if code == "44444444":
            with self._lock:
                self._mark_timing(self.round, "fpga_program_done")
            return
        if code == "55555555":
            with self._lock:
                if self.round is not None:
                    self._mark_timing(self.round, "fpga_info_dump_start")
                    self.state = "RECEIVING_FPGA_LOG"
            return
        if code == "77770001":
            # The current board image can leave its retransmit request level
            # asserted and consequently emit unsolicited replay delimiters.
            # Automatic replay is disabled until that RTL is rebuilt.  Treat
            # the delimiter as a contaminated transport round rather than
            # rotating the capture underneath a comparison worker.
            self.on_info_stream_loss(
                "收到未请求的Info重传开始确认",
                comparison_reason="FPGA Info log does not contain both completion frames",
                details={"system_code": code, "unexpected_retransmit_begin": True},
            )
            return
        if code == "77777777":
            missing_harts: list[int] = []
            with self._lock:
                if self.round is not None:
                    self._mark_timing(self.round, "fpga_exe_end")
                    self.round.board_exe_end = True
                    self.round.writer.flush()
                    missing_harts = sorted(
                        {0, 1} - set(self.round.info_done_harts or set())
                    )
                    if not missing_harts:
                        self.state = "WAIT_SPIKE_AND_COMPARE"
            if missing_harts:
                self.on_info_stream_loss(
                    "EXE_END到达时缺少hart完成帧",
                    comparison_reason="FPGA Info log does not contain both completion frames",
                    details={"missing_done_harts": missing_harts},
                )
                return
            self._maybe_compare()
            return
        if code.startswith(self.ERROR_PREFIXES):
            self.fail(f"FPGA reported error code 0x{code}")

    def on_info_frame(self, raw: bytes) -> None:
        with self._lock:
            current = self.round
        if current is not None:
            current.writer.write(raw)

    def on_info_done(self, hart: int) -> None:
        with self._lock:
            if self.round is not None and self.round.info_done_harts is not None:
                self.round.info_done_harts.add(int(hart))
                if self.round.info_done_harts == {0, 1}:
                    self._mark_timing(self.round, "both_info_done")
                self.round.writer.flush()
        self._maybe_compare()

    def on_info_stream_loss(
        self,
        reason: str,
        *,
        comparison_reason: str = "Info frame number discontinuity",
        hart: int | None = None,
        frame_number: int | None = None,
        expected_frame: int | None = None,
        first_failure_sequence: int | None = None,
        details: dict[str, Any] | None = None,
    ) -> bool:
        """Discard one transport-damaged round and reset into the next epoch."""

        with self._lock:
            current = self.round
            if (
                not self.enabled or current is None
                or self.recovering_skipped_round
                or self.state in {"SAVING_INFO_LOSS", "RESETTING_AFTER_SKIPPED_ROUND"}
            ):
                return False
            current.comparing = True
            self.state = "SAVING_INFO_LOSS"
            self.last_error = reason

        report = {
            "status": "FAIL",
            "reason": comparison_reason,
            "first_failure_hart": hart,
            "first_failure_sequence": first_failure_sequence,
            "compared_instructions": 0,
            "details": {
                "transport_round_discarded": True,
                "frame_number": frame_number,
                "expected_frame": expected_frame,
                **(details or {}),
            },
        }
        self._skip_info_loss_round(current, report, reason)
        return True

    def fail(self, reason: str) -> None:
        with self._lock:
            current = self.round
            if not self.enabled and self.state == "FAILED":
                return
            self.enabled = False
            self.state = "FAILED"
            self.last_error = reason
            self.recovering_skipped_round = False
        if current is not None:
            self.remote.request_cancel(current.run_id)
            current.writer.flush()
        self.emit("automation_failed", reason, level="error",
                  run_id=current.run_id if current else None)

    def _schedule_preconfig(self) -> None:
        with self._lock:
            if not self.enabled or self.round is not None or not self.preinit_pending or self.preconfig_inflight:
                return
            self.preconfig_inflight = True
            self.state = "SENDING_PRECONFIG"

        def worker() -> None:
            try:
                self._send_preconfig()
                with self._lock:
                    self.preinit_pending = False
                    self.state = "WAIT_222"
                self.emit("automation_preconfig", "已自动发送PRECONFIG检查帧和结束帧")
            except Exception as exc:
                self.fail(f"自动PRECONFIG发送失败: {exc}")
            finally:
                with self._lock:
                    self.preconfig_inflight = False

        threading.Thread(target=worker, name="eh2-auto-preconfig", daemon=True).start()

    def _schedule_round_start(self) -> None:
        with self._lock:
            if not self.enabled or self.recovering_skipped_round:
                return
            if self.round is not None:
                self.emit(
                    "automation_barrier_violation",
                    "本轮尚未完成全部比较，忽略额外的0x22222222，不启动新一轮",
                    level="error",
                    active_run=self.round.run_id,
                )
                return
            if self.settings is None:
                self.fail("automation settings are missing")
                return
            self.state = "STARTING_REMOTE_RUN"
        threading.Thread(target=self._start_round_worker, name="eh2-auto-start-round", daemon=True).start()

    def _start_round_worker(self) -> None:
        with self._lock:
            if (
                not self.enabled or self.recovering_skipped_round
                or self.round is not None or self.settings is None
                or self.session_dir is None
            ):
                return
            settings = self.settings
            session_dir = self.session_dir
            run_id = datetime.now().strftime("run_%Y%m%d_%H%M%S_%f")
            seed = secrets.randbits(31) or 1
            local_dir = (session_dir / run_id).resolve()
            if (
                session_dir.parent != self.runs_root.resolve()
                or not session_dir.name.startswith("session_")
                or local_dir.parent != session_dir
            ):
                self.fail(f"invalid automation round path: {local_dir}")
                return
            local_dir.mkdir(parents=True, exist_ok=False)
            # Capture compact raw frames while the run is active. PASS rounds
            # are deleted without TXT expansion; FAIL rounds are decoded once.
            fpga_log = local_dir / "fpga_info.eh2log"
            current = Round(
                run_id=run_id,
                seed=seed,
                local_dir=local_dir,
                remote_dir=self.remote.run_path(run_id),
                fpga_log=fpga_log,
                writer=InfoFrameLogWriter(fpga_log),
                board_program_ready=self.program_ready_pending,
            )
            if self.program_ready_pending:
                self._mark_timing(current, "board_program_ready")
            self.program_ready_pending = False
            self.round = current
            self.state = "REMOTE_GENERATING"
            self.last_error = None
        try:
            pid = self.remote.deploy_and_launch(settings, run_id, seed)
            with self._lock:
                if self.round is current:
                    current.remote_pid = pid
            self.emit(
                "automation_round_started",
                f"本轮{run_id}已启动：seed={seed}，每hart约{settings.instructions_per_hart}条",
                run_id=run_id,
                seed=seed,
                remote_pid=pid,
            )
        except Exception as exc:
            self.fail(f"启动VM riscv-dv/Spike任务失败: {exc}")

    def _poll_loop(self) -> None:
        while not self._stop.wait(1.0):
            with self._lock:
                current = self.round
                enabled = self.enabled
            if current is None or not enabled:
                continue
            remote_status = self.remote.read_status(current.run_id)
            if remote_status is None:
                continue
            changed_stage = current.remote_status is None or (
                remote_status.get("stage") != current.remote_status.get("stage")
            )
            with self._lock:
                if self.round is not current:
                    continue
                current.remote_status = remote_status
                if remote_status.get("program_ready"):
                    self._mark_timing(current, "program_ready")
                if remote_status.get("spike_done"):
                    self._mark_timing(current, "spike_done")
                if remote_status.get("stage") and not current.comparing:
                    self.state = f"REMOTE_{remote_status['stage']}"
            if changed_stage:
                self.emit(
                    "automation_remote_status",
                    f"VM阶段: {remote_status.get('stage')} - {remote_status.get('message', '')}",
                    stage=remote_status.get("stage"),
                    generated_chunks=remote_status.get("generated_chunks"),
                    compiled_chunks=remote_status.get("compiled_chunks"),
                )
            if remote_status.get("failed"):
                self._skip_vm_failed_round(current, remote_status)
                continue
            self._maybe_send_program()
            self._maybe_compare()

    def _maybe_send_program(self) -> None:
        with self._lock:
            current = self.round
            if (
                not self.enabled or current is None or current.program_send_started
                or not current.board_program_ready
                or not current.remote_status
                or not current.remote_status.get("program_ready")
            ):
                return
            program = current.remote_dir / "program.bin"
            if not program.is_file():
                return
            current.program_send_started = True
            self._mark_timing(current, "host_program_send_start")
            self.state = "SENDING_PROGRAM"

        def worker() -> None:
            try:
                self._send_program_path(program)
                with self._lock:
                    still_current = self.round is current
                if still_current:
                    self.emit("automation_program_send", "已开始从共享目录全速烧写自动生成程序",
                              run_id=current.run_id, program=str(program))
            except Exception as exc:
                with self._lock:
                    still_current = self.round is current
                    recovering = self.recovering_skipped_round
                if still_current:
                    self.fail(f"自动程序烧写启动失败: {exc}")
                elif recovering:
                    self.emit(
                        "automation_program_send_cancelled",
                        "VM失败后已取消本轮程序发送，等待板卡复位",
                        level="warning",
                        run_id=current.run_id,
                    )

        threading.Thread(target=worker, name="eh2-auto-send-program", daemon=True).start()

    def _write_vm_wrong(
        self, current: Round, remote_status: dict[str, Any], reason: str,
    ) -> Path:
        """Persist the complete VM failure diagnosis in this run's folder."""

        current.local_dir.mkdir(parents=True, exist_ok=True)
        sections = [
            "# EH2 automation VM failure",
            f"run_id={current.run_id}",
            f"seed={current.seed}",
            f"stage={remote_status.get('stage', '-')}",
            f"message={remote_status.get('message', reason)}",
            f"board_program_ready={int(current.board_program_ready)}",
            f"program_send_started={int(current.program_send_started)}",
            "",
            "[remote_status]",
            json.dumps(remote_status, ensure_ascii=False, indent=2),
        ]
        for name in ("status.json", "remote_runner_console.log"):
            source = current.remote_dir / name
            if not source.is_file():
                continue
            try:
                content = source.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                content = f"<cannot read {source}: {exc}>"
            sections.extend(("", f"[{name}]", content.rstrip()))
        target = current.local_dir / "vmwrong.txt"
        target.write_text("\n".join(sections).rstrip() + "\n", encoding="utf-8")
        return target

    def _append_wrong(
        self,
        current: Round,
        *,
        kind: str,
        reason: str,
        details: dict[str, Any],
    ) -> Path:
        """Append one recoverable-round diagnosis to automation/_wrong.txt."""

        target = self.wrong_log.resolve()
        if target.parent != self.runs_root.resolve() or target.name != "_wrong.txt":
            raise RuntimeError(f"invalid automation wrong-log path: {target}")
        block = [
            f"[{kind}]",
            f"session_id={self.session_id or '-'}",
            f"run_id={current.run_id}",
            f"seed={current.seed}",
            f"reason={reason}",
            f"run_dir={current.local_dir}",
            "details=" + json.dumps(details, ensure_ascii=False, sort_keys=True),
            "",
        ]
        with self._lock:
            with target.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write("\n".join(block))
                handle.flush()
            self.last_wrong_log = target
        return target

    def _reset_after_skipped_round(
        self,
        current: Round,
        *,
        reason: str,
        event_type: str,
        message: str,
    ) -> None:
        """Release the strict barrier only through a new global-reset epoch."""

        with self._lock:
            if self.round is not current:
                return
            self.round = None
            self.preinit_pending = False
            self.program_ready_pending = False
            self.recovering_skipped_round = True
            self.state = "RESETTING_AFTER_SKIPPED_ROUND"

        self.emit(
            event_type,
            message,
            level="error",
            run_id=current.run_id,
            file=self.wrong_log.name,
            reason=reason,
        )
        if self._reset_board is None:
            with self._lock:
                self.enabled = False
                self.recovering_skipped_round = False
                self.state = "FAILED"
                self.last_error = f"{reason}; 未配置自动板级复位回调"
            self.emit("automation_failed", self.last_error, level="error",
                      run_id=current.run_id)
            return
        try:
            self._reset_board()
        except Exception as exc:
            with self._lock:
                self.enabled = False
                self.recovering_skipped_round = False
                self.state = "FAILED"
                self.last_error = f"{reason}; 自动板级复位失败: {exc}"
            self.emit("automation_failed", self.last_error, level="error",
                      run_id=current.run_id)

    def _skip_vm_failed_round(
        self, current: Round, remote_status: dict[str, Any],
    ) -> None:
        """Skip one failed VM reference run and reset into the next epoch."""

        reason = f"VM任务失败: {remote_status.get('message', 'unknown error')}"
        with self._lock:
            if (
                not self.enabled or self.round is not current
                or self.recovering_skipped_round
            ):
                return
            self.state = "SAVING_VM_FAILURE"
            self.last_error = reason
            current.remote_status = dict(remote_status)

        self.remote.request_cancel(current.run_id)
        current.writer.close()
        # A VM failure normally happens before FPGA execution.  Do not retain
        # an empty 12-byte capture container as if it were useful evidence.
        if current.writer.frames == 0 and current.fpga_log.is_file():
            current.fpga_log.unlink()
        try:
            vm_wrong = self._write_vm_wrong(current, remote_status, reason)
            self._append_wrong(
                current,
                kind="VM_FAILED",
                reason=reason,
                details={
                    "stage": remote_status.get("stage"),
                    "message": remote_status.get("message"),
                    "vmwrong": str(vm_wrong),
                    "remote_status": remote_status,
                },
            )
            self.last_timings = self._timing_summary(current)
            self._write_timing_report(current)
        except Exception as exc:
            # Failure evidence must not be silently discarded.  If it cannot
            # be saved, stop instead of resetting into a new round.
            with self._lock:
                if self.round is current:
                    self.enabled = False
                    self.state = "FAILED"
                    self.last_error = f"{reason}; 保存vmwrong.txt失败: {exc}"
            self.emit(
                "automation_failed",
                self.last_error,
                level="error",
                run_id=current.run_id,
            )
            return

        with self._lock:
            if self.round is not current:
                return
            self.last_vm_wrong_log = vm_wrong
        self._reset_after_skipped_round(
            current,
            reason=reason,
            event_type="automation_vm_round_skipped",
            message=(
                "VM任务失败，本轮已跳过并追加到automation/_wrong.txt；"
                "正在全局复位板卡以开始下一轮"
            ),
        )

    @classmethod
    def _is_recoverable_info_loss(cls, report: dict[str, Any]) -> bool:
        return (
            str(report.get("status", "")).upper() == "FAIL"
            and str(report.get("reason", "")) in cls.RECOVERABLE_INFO_LOSS_REASONS
        )

    def _skip_info_loss_round(
        self, current: Round, report: dict[str, Any], reason: str,
    ) -> None:
        """Preserve a missing-frame failure, reset, then continue automation."""

        self.remote.request_cancel(current.run_id)
        try:
            self._materialize_failure_text(current)
            report_path = current.local_dir / "info_loss_report.json"
            report_path.write_text(
                json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            self._append_wrong(
                current,
                kind="INFO_STREAM_MISSING",
                reason=reason,
                details={
                    "first_failure_hart": report.get("first_failure_hart"),
                    "first_failure_sequence": report.get("first_failure_sequence"),
                    "compared_instructions": report.get("compared_instructions"),
                    "comparison_reason": report.get("reason"),
                    "comparison_details": report.get("details") or {},
                    "info_loss_report": str(report_path),
                    "fpga_info": str(current.local_dir / "fpga_info.txt"),
                },
            )
            self._mark_timing(current, "transport_loss_detected")
            self.last_timings = self._timing_summary(current)
            self._write_timing_report(current)
        except Exception as exc:
            self.fail(f"{reason}; 保存automation/_wrong.txt失败: {exc}")
            return
        with self._lock:
            if self.round is current:
                self.last_error = reason
                self.last_result = dict(report)
        self._reset_after_skipped_round(
            current,
            reason=reason,
            event_type="automation_info_loss_round_skipped",
            message=(
                "检测到Info回传帧缺失，本轮已保留并追加到automation/_wrong.txt；"
                "正在全局复位板卡以开始下一轮"
            ),
        )

    def _begin_retransmit_generation(self, current: Round) -> None:
        """Archive the partial capture and reopen the canonical new generation."""

        with self._lock:
            if self.round is not current or not self.enabled:
                return
            current.writer.close()
            archive = current.local_dir / (
                f"fpga_info_partial_generation{current.retransmit_count}.eh2log"
            )
            if current.fpga_log.is_file():
                current.fpga_log.replace(archive)
            current.writer = InfoFrameLogWriter(current.fpga_log)
            current.info_done_harts = set()
            # EXE_END belongs to the completed execution, not to a dump
            # generation.  Keep it high so the completed retransmission can
            # compare immediately after both HxDN frames arrive.
            current.comparing = False
            current.failure_text_log = None
            current.retransmit_count += 1
            self.state = "RECEIVING_RETRANSMITTED_FPGA_LOG"
        self.emit(
            "automation_info_retransmit_begin",
            "已收到FPGA重传开始确认：旧代次已归档，正在从hart0 frame0接收新代次",
            run_id=current.run_id,
            retransmit_count=current.retransmit_count,
        )

    def _retry_info_loss_round(
        self, current: Round, report: dict[str, Any], reason: str,
    ) -> None:
        """Request retained-DDR replay rather than destroying the board state."""

        try:
            self._append_wrong(
                current,
                kind="INFO_STREAM_MISSING_RETRANSMIT",
                reason=reason,
                details={
                    "first_failure_hart": report.get("first_failure_hart"),
                    "first_failure_sequence": report.get("first_failure_sequence"),
                    "comparison_reason": report.get("reason"),
                    "comparison_details": report.get("details") or {},
                    "retransmit_count": current.retransmit_count + 1,
                },
            )
        except Exception as exc:
            self.fail(f"{reason}; 保存重传诊断失败: {exc}")
            return
        if self._request_info_retransmit is None:
            self.fail(f"{reason}; 未配置Info全量重传回调")
            return
        with self._lock:
            if self.round is not current or not self.enabled:
                return
            current.comparing = False
            self.state = "WAIT_INFO_RETRANSMIT_BEGIN"
            self.last_error = reason
        self.emit(
            "automation_info_retransmit_requested",
            "Info帧缺失：保留板级现场并请求DDR1全量重传，不执行自动复位",
            level="warning", run_id=current.run_id,
            first_failure_hart=report.get("first_failure_hart"),
            first_failure_sequence=report.get("first_failure_sequence"),
        )
        try:
            self._request_info_retransmit(reason)
        except Exception as exc:
            self.fail(f"{reason}; Info重传请求失败: {exc}")

    def _maybe_compare(self) -> None:
        with self._lock:
            current = self.round
            if (
                not self.enabled or current is None or current.comparing
                or current.info_done_harts != {0, 1}
                or not current.board_exe_end
                or not current.remote_status
                or not current.remote_status.get("spike_done")
            ):
                return
            current.comparing = True
            self._mark_timing(current, "comparison_start")
            current.writer.close()
            self.state = "COMPARING"
        threading.Thread(target=self._compare_worker, args=(current,),
                         name="eh2-auto-compare", daemon=True).start()

    def _compare_worker(self, current: Round) -> None:
        report_path = current.local_dir / "compare_report.json"

        def update_progress(count: int) -> None:
            with self._lock:
                if self.round is current:
                    current.compared_instructions = int(count)

        try:
            report = compare_run(
                current.fpga_log,
                current.remote_dir / "spike.log",
                current.remote_dir / "manifest.json",
                report_path,
                progress=update_progress,
            )
        except Exception as exc:
            with self._lock:
                if self.round is not current or self.recovering_skipped_round:
                    return
            self._mark_timing(current, "comparison_done")
            self.last_timings = self._timing_summary(current)
            self._write_timing_report(current)
            self._materialize_failure_text(current)
            self.fail(f"Windows流式比较异常: {exc}")
            return
        with self._lock:
            if self.round is not current or self.recovering_skipped_round:
                return
        self.last_result = report
        self._mark_timing(current, "comparison_done")
        self.last_timings = self._timing_summary(current)
        self._write_timing_report(current)
        update_progress(int(report.get("compared_instructions", 0)))
        self._record_comparison(current, report)
        if report.get("status") != "PASS":
            reason = (
                "比较FAIL："
                f"hart={report.get('first_failure_hart')} "
                f"sequence={report.get('first_failure_sequence')} "
                f"reason={report.get('reason')}"
            )
            if self._is_recoverable_info_loss(report):
                self._skip_info_loss_round(current, report, reason)
            else:
                self._materialize_failure_text(current)
                self.fail(reason)
            return

        summary = {
            "completed_at": datetime.now().astimezone().isoformat(timespec="milliseconds"),
            "run_id": current.run_id,
            "seed": current.seed,
            **report,
        }
        self.history.parent.mkdir(parents=True, exist_ok=True)
        with self.history.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(summary, ensure_ascii=False) + "\n")
        self.emit(
            "automation_compare_pass",
            f"本轮比较PASS：hart0={report['hart0_records']}，hart1={report['hart1_records']}；保留Spike TXT和报告，清理程序与FPGA二进制日志",
            result=summary,
        )
        self._cleanup_pass(current)
        with self._lock:
            if self.round is current:
                self.round = None
                self.preinit_pending = False
                self.program_ready_pending = False
                self.state = "RESETTING_AFTER_PASS"
            else:
                return
        self.emit(
            "automation_round_complete",
            "本轮比较PASS；已清理本轮临时文件，正在由上位机发送全局复位以开启下一轮",
            run_id=current.run_id,
        )
        if self._reset_board is None:
            self.fail("比较PASS后未配置HOST_GLOBAL_RESET回调")
            return
        try:
            self._reset_board()
        except Exception as exc:
            self.fail(f"比较PASS后发送HOST_GLOBAL_RESET失败: {exc}")

    def _cleanup_pass(self, current: Round) -> None:
        local = current.local_dir.resolve()
        local_parent = local.parent
        new_layout = (
            local.name.startswith("run_")
            and local_parent.name.startswith("session_")
            and local_parent.parent == self.runs_root.resolve()
        )
        legacy_layout = (
            local.name.startswith("run_")
            and local_parent == self.runs_root.resolve()
        )
        if not (new_layout or legacy_layout):
            raise RuntimeError(f"refusing to clean unexpected run path: {local}")
        # A PASS has been recorded in the small session/lifetime statistics.
        # Do not retain a per-round directory: every local FPGA capture,
        # Spike log, generated program and comparison scratch file belongs to
        # this successful disposable run.
        remote = current.remote_dir.resolve()
        expected_remote_parent = (self.remote.windows_shared_root / "runs").resolve()
        if remote.parent != expected_remote_parent:
            raise RuntimeError(f"refusing to clean unexpected run path: {remote}")
        if remote.is_dir():
            shutil.rmtree(remote)
        if local.is_dir():
            shutil.rmtree(local)

    @staticmethod
    def _remove_stale_run_directories(
        root: Path, keep: Path | None, prefixes: tuple[str, ...] = ("run_",),
    ) -> int:
        """Remove only approved direct children below the exact cache root."""

        root = root.resolve()
        if not root.is_dir():
            return 0
        keep_resolved = keep.resolve() if keep is not None else None
        removed = 0
        for item in list(root.iterdir()):
            if (
                not item.is_dir()
                or not any(item.name.startswith(prefix) for prefix in prefixes)
            ):
                continue
            target = item.resolve()
            if target.parent != root:
                raise RuntimeError(f"refusing to clean unexpected run path: {target}")
            if keep_resolved is not None and target == keep_resolved:
                continue
            shutil.rmtree(target)
            removed += 1
        return removed

    def clear_run_cache(self) -> dict[str, int]:
        """Delete previous automation outputs without touching an active round."""

        with self._lock:
            current = self.round
            active = bool(self.enabled)
            if current is not None and not active:
                current.writer.close()
                self.round = None
                self.state = "DISABLED"
                self.last_result = None
                self.last_error = None
                self.last_timings = None
            if not active:
                self.session_id = None
                self.session_dir = None
            keep_local = self.session_dir if active else None
            keep_remote = current.remote_dir if active and current is not None else None
        local_removed = self._remove_stale_run_directories(
            self.runs_root, keep_local, prefixes=("session_", "run_")
        )
        # Releases before the runlog layout used runtime/automation/runs.
        # Treat it as stale cache, but keep the same strict run_* child rule.
        legacy_removed = self._remove_stale_run_directories(
            self.runtime / "runs", None
        )
        remote_removed = self._remove_stale_run_directories(
            self.remote.windows_shared_root / "runs", keep_remote
        )
        return {
            "automation_local_runs": local_removed,
            "automation_legacy_runs": legacy_removed,
            "automation_shared_runs": remote_removed,
        }

    def _materialize_failure_text(self, current: Round) -> Path:
        """Decode the compact capture exactly once, and only for a failed run."""

        with self._lock:
            existing = current.failure_text_log
        if existing is not None and existing.is_file():
            return existing

        current.writer.close()
        target = current.local_dir / "fpga_info.txt"
        writer = DecodedInfoTextWriter(target)
        try:
            for event in current.system_events or []:
                writer.write_decoded(event)
            for timestamp_ns, raw in iter_info_frames(current.fpga_log):
                writer.write_raw(raw, timestamp_ns)
        finally:
            writer.close()
        with self._lock:
            current.failure_text_log = target
        self.emit(
            "automation_failure_txt_ready",
            "本轮出现错误，已生成无时间戳FPGA日志TXT",
            run_id=current.run_id,
            file=target.name,
        )
        return target

    def status(self) -> dict[str, Any]:
        with self._lock:
            current = self.round
            settings = self.settings
            # A failed/stopped Round is deliberately retained so its files and
            # diagnostics remain visible.  Retaining that object must not make
            # the UI treat the controller as busy: start() explicitly detaches
            # terminal rounds before beginning a new user-authorized run.
            can_start = (not self.enabled) and (
                current is None or self.state in {"FAILED", "STOPPED"}
            )
            return {
                "enabled": self.enabled,
                "can_start": can_start,
                "state": self.state,
                "strict_round_barrier": True,
                "run_id": current.run_id if current else None,
                "seed": current.seed if current else None,
                "remote_pid": current.remote_pid if current else None,
                "remote_status": dict(current.remote_status) if current and current.remote_status else None,
                "board_program_ready": current.board_program_ready if current else False,
                "program_send_started": current.program_send_started if current else False,
                "info_done_harts": sorted(current.info_done_harts) if current and current.info_done_harts else [],
                "board_exe_end": current.board_exe_end if current else False,
                "fpga_log_frames": current.writer.frames if current else 0,
                "fpga_log_bytes": current.writer.bytes if current else 0,
                "fpga_decoded_records": current.writer.records if current else 0,
                "executed_instructions": current.writer.records if current else 0,
                "compared_instructions": current.compared_instructions if current else 0,
                "fpga_decoded_file": (
                    current.failure_text_log.name
                    if current and current.failure_text_log is not None else None
                ),
                "local_run_dir": str(current.local_dir) if current else None,
                "shared_run_dir": str(current.remote_dir) if current else None,
                "automation_session_id": self.session_id,
                "automation_session_dir": (
                    str(self.session_dir) if self.session_dir is not None else None
                ),
                "last_vm_wrong_file": (
                    str(self.last_vm_wrong_log)
                    if self.last_vm_wrong_log is not None else None
                ),
                "vm_failure_reset_pending": self.recovering_skipped_round,
                "recoverable_failure_reset_pending": self.recovering_skipped_round,
                "last_wrong_file": (
                    str(self.last_wrong_log)
                    if self.last_wrong_log is not None else None
                ),
                "last_result": self.last_result,
                "last_error": self.last_error,
                "comparison_stats": dict(self.comparison_stats),
                "session_comparison_stats": dict(self.session_comparison_stats),
                "timings_seconds": (
                    self._timing_summary(current) if current else self.last_timings
                ),
                "settings": ({
                    "host": settings.host,
                    "port": settings.port,
                    "username": settings.username,
                    "instructions_per_hart": settings.instructions_per_hart,
                    "chunk_instructions": settings.chunk_instructions,
                    "workers": settings.workers,
                } if settings else None),
            }

    def accepting_info_frames(self) -> bool:
        with self._lock:
            return bool(
                self.round is not None and
                not self.round.writer.closed
            )

    def resolve_current_file(self, name: str) -> Path:
        with self._lock:
            if self.round is None:
                raise FileNotFoundError("没有当前自动化轮次")
            candidate = (self.round.local_dir / Path(name).name).resolve()
            if (candidate.parent != self.round.local_dir.resolve() or
                    not candidate.is_file()):
                raise FileNotFoundError(name)
            if candidate == self.round.fpga_log:
                self.round.writer.flush()
            return candidate
