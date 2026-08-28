from __future__ import annotations

import json
import importlib.util
from pathlib import Path
import re
import struct
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch


WEBUI_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WEBUI_ROOT))

from eh2web.automation import AutomationController  # noqa: E402
from eh2web.comparator import compare_run  # noqa: E402
from eh2web.info_log import DecodedInfoTextWriter, InfoFrameLogWriter  # noqa: E402
from eh2web.protocol import decode_frame  # noqa: E402
from eh2web.protocol import (  # noqa: E402
    BROADCAST_MAC,
    HART0_INFO_SOURCE_MAC,
    HART1_INFO_SOURCE_MAC,
    INFO_DATA_ETHERTYPE,
    INFO_DONE_ETHERTYPE,
    INFO_RECORD_BYTES,
    INFO_RECORDS_PER_FRAME,
    ethernet_frame,
)
from eh2web.remote import RemoteSettings  # noqa: E402
from eh2web.session import SessionRecorder  # noqa: E402


def _spike_pair(hart: int, pc: int, instruction: int, effects: str = "") -> str:
    return (
        f"core {hart}: 0x{pc:08x} (0x{instruction:08x})\n"
        f"core {hart}: 3 0x{pc:08x} (0x{instruction:08x}){effects}\n"
    )


def _data_frame(hart: int, records: list[tuple[int, int, int, int, int, int]],
                frame_number: int = 0) -> bytes:
    payload = frame_number.to_bytes(4, "big")
    for record in records:
        payload += struct.pack(">IIIIII", *record)
    payload += bytes((INFO_RECORDS_PER_FRAME - len(records)) * INFO_RECORD_BYTES)
    source = HART1_INFO_SOURCE_MAC if hart else HART0_INFO_SOURCE_MAC
    return ethernet_frame(BROADCAST_MAC, source, INFO_DATA_ETHERTYPE, payload)


def _done_frame(hart: int, records: int, frames: int = 1) -> bytes:
    last = 0xFFFF_FFFF if records == 0 else records - 1
    payload = (
        (b"H1DN" if hart else b"H0DN")
        + bytes((hart, 1))
        + INFO_RECORD_BYTES.to_bytes(2, "big")
        + records.to_bytes(4, "big")
        + frames.to_bytes(4, "big")
        + last.to_bytes(4, "big")
        + bytes(3) + bytes((hart ^ 1,)) + bytes(22)
    )
    source = HART1_INFO_SOURCE_MAC if hart else HART0_INFO_SOURCE_MAC
    return ethernet_frame(BROADCAST_MAC, source, INFO_DONE_ETHERTYPE, payload)


class ComparatorTests(unittest.TestCase):
    def _fixture(self, root: Path, bad_cancel: bool = False,
                 out_of_order: bool = False) -> tuple[Path, Path, Path, Path]:
        start_pc = 0x80000000
        h0_stop = 0x80000008
        h1_stop = 0x80000108
        nop = 0x00000013
        hardware_start = 0x7FCF9073
        hardware_stop = 0x01EE2023
        manifest = {
            "reset_vector": 0x80000000,
            "patches": [
                {"name": "eh2_hart_start_patch", "pc": start_pc,
                 "hardware_instruction": hardware_start},
                {"name": "eh2_h0_stop_patch", "pc": h0_stop,
                 "hardware_instruction": hardware_stop},
                {"name": "eh2_h1_stop_patch", "pc": h1_stop,
                 "hardware_instruction": hardware_stop},
            ],
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        spike_path = root / "spike.log"
        spike_path.write_text(
            _spike_pair(0, start_pc, nop)
            + _spike_pair(0, start_pc + 4, 0x00100293, " x5 0x00000001")
            + _spike_pair(0, h0_stop, nop)
            + _spike_pair(1, 0x80000100, 0x00200293, " x5 0x00000002")
            + _spike_pair(1, 0x80000104, 0x00300293, " x5 0x00000003")
            + _spike_pair(1, h1_stop, nop),
            encoding="utf-8",
        )

        # metadata = hart, M-mode privilege, event kind and register number.
        h0 = [
            (0, start_pc, hardware_start, 0x0000E7FC, 2, 0),
            (1, start_pc + 4, 0x00100293, 0x0000D005, 1, 0),
            (2, h0_stop, hardware_stop, 0x0000C000, 0, 0),
        ]
        # The first hart1 x5 write is a WAW victim.  Its data is zero and the
        # cancel number points at the later same-hart x5 writer (sequence 1).
        h1 = [
            (0, 0x80000100, 0x00200293, 0x4001D005, 0, 2 if bad_cancel else 1),
            (1, 0x80000104, 0x00300293, 0x0001D005, 3, 0),
            (2, h1_stop, hardware_stop, 0x0001C000, 0, 0),
        ]
        if out_of_order:
            h1 = [h1[1], h1[0], h1[2]]
        fpga_path = root / "fpga_info.txt"
        with_writer = DecodedInfoTextWriter(fpga_path)
        try:
            for stamp, raw in enumerate((
                _data_frame(0, h0), _done_frame(0, len(h0)),
                _data_frame(1, h1), _done_frame(1, len(h1)),
            ), 1):
                decoded = decode_frame(raw)
                decoded["received_at"] = f"test-{stamp}"
                with_writer.write_decoded(decoded)
        finally:
            with_writer.close()
        return fpga_path, spike_path, manifest_path, root / "compare_report.json"

    def test_single_file_log_and_waw_comparison_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fpga, spike, manifest, report = self._fixture(root)
            text = fpga.read_text(encoding="utf-8")
            self.assertIn("INFO_DATA\t", text)
            self.assertIn("INFO_DONE\t", text)
            self.assertNotIn("test-1", text)
            progress: list[int] = []
            result = compare_run(fpga, spike, manifest, report, progress=progress.append)
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(result["hart0_records"], 3)
            self.assertEqual(result["hart1_records"], 3)
            self.assertEqual(result["compared_instructions"], 6)
            self.assertEqual(progress[-1], 6)
            self.assertTrue((root / "spike.log.txt").is_file())
            self.assertEqual(
                (root / "spike.log.txt").read_text(encoding="utf-8"),
                spike.read_text(encoding="utf-8"),
            )
            self.assertEqual(list(root.glob("*.expected")), [])
            self.assertEqual(list(root.glob("*.normalized.bin")), [])

    def test_bad_waw_cancel_number_reports_first_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fpga, spike, manifest, report = self._fixture(root, bad_cancel=True)
            result = compare_run(fpga, spike, manifest, report)
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(result["first_failure_hart"], 1)
            self.assertEqual(result["first_failure_sequence"], 0)
            self.assertEqual(result["compared_instructions"], 4)
            self.assertIn("WAW", result["reason"])
            text_report = (root / "comparison_result.txt").read_text(encoding="utf-8")
            self.assertIn("first_failure_hart=1", text_report)
            self.assertIn("first_failure_sequence=0", text_report)
            self.assertNotIn("2026-", text_report)

    def test_nonblocking_waw_record_may_arrive_out_of_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fpga, spike, manifest, report = self._fixture(
                root, out_of_order=True
            )
            result = compare_run(fpga, spike, manifest, report)
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(result["hart1_records"], 3)

    def test_discontinuous_info_frame_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fpga, spike, manifest, report = self._fixture(root)
            text = fpga.read_text(encoding="utf-8")
            fpga.write_text(
                text.replace("\tframe=0\t", "\tframe=7\t", INFO_RECORDS_PER_FRAME),
                encoding="utf-8",
            )
            result = compare_run(fpga, spike, manifest, report)
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(result["reason"], "Info frame number discontinuity")


class RoundBarrierTests(unittest.TestCase):
    @staticmethod
    def _wait_for_round(controller: AutomationController) -> None:
        deadline = time.time() + 2
        while controller.round is None and time.time() < deadline:
            time.sleep(0.01)

    def test_second_ready_does_not_start_a_concurrent_round(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            shared = root / "shared"
            launches: list[str] = []
            controller = AutomationController(webui, lambda *_args, **_kwargs: None,
                                              lambda: None, lambda _path: None, shared)
            controller.remote.deploy_and_launch = (  # type: ignore[method-assign]
                lambda _settings, run_id, _seed: launches.append(run_id) or 123
            )
            try:
                controller.start(RemoteSettings(password="test", instructions_per_hart=10_000,
                                                chunk_instructions=10_000, workers=1), None)
                controller.on_system({"valid": True, "code": "22222222"})
                self._wait_for_round(controller)
                self.assertIsNotNone(controller.round)
                first = controller.round.run_id  # type: ignore[union-attr]
                controller.on_system({"valid": True, "code": "22222222"})
                time.sleep(0.05)
                self.assertEqual(launches, [first])
                self.assertEqual(controller.round.run_id, first)  # type: ignore[union-attr]
            finally:
                controller.shutdown()

    def test_button_can_take_over_at_222_or_333(self) -> None:
        for last_code in ("22222222", "33333333"):
            with self.subTest(last_code=last_code), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                webui = root / "webui"
                (webui / "vm_tools").mkdir(parents=True)
                launches: list[str] = []
                controller = AutomationController(webui, lambda *_args, **_kwargs: None,
                                                  lambda: None, lambda _path: None,
                                                  root / "shared")
                controller.remote.deploy_and_launch = (  # type: ignore[method-assign]
                    lambda _settings, run_id, _seed: launches.append(run_id) or 456
                )
                try:
                    controller.start(RemoteSettings(password="test"), last_code)
                    self._wait_for_round(controller)
                    self.assertIsNotNone(controller.round)
                    self.assertEqual(len(launches), 1)
                    self.assertEqual(controller.round.board_program_ready,  # type: ignore[union-attr]
                                     last_code == "33333333")
                finally:
                    controller.shutdown()

    def test_failed_round_is_preserved_but_next_click_can_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            launches: list[str] = []
            controller = AutomationController(webui, lambda *_args, **_kwargs: None,
                                              lambda: None, lambda _path: None,
                                              root / "shared")
            controller.remote.deploy_and_launch = (  # type: ignore[method-assign]
                lambda _settings, run_id, _seed: launches.append(run_id) or 789
            )
            settings = RemoteSettings(password="test")
            try:
                controller.start(settings, "22222222")
                self._wait_for_round(controller)
                self.assertIsNotNone(controller.round)
                failed_run = controller.round
                failed_dir = failed_run.local_dir  # type: ignore[union-attr]

                controller.fail("FPGA reported error code 0x666600c1")
                failed_status = controller.status()
                self.assertFalse(failed_status["enabled"])
                self.assertTrue(failed_status["can_start"])
                self.assertEqual(failed_status["run_id"], failed_run.run_id)  # type: ignore[union-attr]
                self.assertTrue(failed_dir.is_dir())

                # This is the same action as a second click.  It detaches the
                # terminal Round without deleting any captured failure files.
                restarted = controller.start(settings, None)
                self.assertTrue(restarted["enabled"])
                self.assertFalse(restarted["can_start"])
                self.assertIsNone(restarted["run_id"])
                self.assertTrue(failed_dir.is_dir())
            finally:
                controller.shutdown()

    def test_vm_failed_round_is_logged_reset_and_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            shared = root / "shared"
            launches: list[str] = []
            resets: list[str] = []
            preconfigs: list[str] = []
            controller = AutomationController(
                webui,
                lambda *_args, **_kwargs: None,
                lambda: preconfigs.append("preconfig"),
                lambda _path: None,
                shared,
                reset_board=lambda: resets.append("reset"),
            )
            controller.remote.deploy_and_launch = (  # type: ignore[method-assign]
                lambda _settings, run_id, _seed: launches.append(run_id) or 900
            )
            try:
                controller.start(RemoteSettings(password="test"), "33333333")
                self._wait_for_round(controller)
                current = controller.round
                self.assertIsNotNone(current)
                assert current is not None
                session_dir = controller.session_dir
                self.assertIsNotNone(session_dir)
                assert session_dir is not None
                self.assertEqual(current.local_dir.parent, session_dir)
                session_manifest = session_dir / "automation_session.json"
                self.assertTrue(session_manifest.is_file())
                self.assertNotIn(
                    '"password"', session_manifest.read_text(encoding="utf-8")
                )
                current.remote_dir.mkdir(parents=True, exist_ok=True)
                (current.remote_dir / "status.json").write_text(
                    '{"stage":"FAILED","message":"atomic audit failed"}\n',
                    encoding="utf-8",
                )
                (current.remote_dir / "remote_runner_console.log").write_text(
                    "Traceback: atomic audit failed\n", encoding="utf-8"
                )
                failed_status = {
                    "stage": "FAILED",
                    "failed": True,
                    "message": "atomic audit failed",
                    "program_ready": True,
                }

                controller._skip_vm_failed_round(current, failed_status)

                wrong = current.local_dir / "vmwrong.txt"
                self.assertTrue(wrong.is_file())
                wrong_text = wrong.read_text(encoding="utf-8")
                self.assertIn("run_id=" + current.run_id, wrong_text)
                self.assertIn("atomic audit failed", wrong_text)
                self.assertIn("remote_runner_console.log", wrong_text)
                aggregate_wrong = controller.runs_root / "_wrong.txt"
                self.assertTrue(aggregate_wrong.is_file())
                aggregate_text = aggregate_wrong.read_text(encoding="utf-8")
                self.assertIn("[VM_FAILED]", aggregate_text)
                self.assertIn("run_id=" + current.run_id, aggregate_text)
                self.assertIn("atomic audit failed", aggregate_text)
                self.assertEqual(resets, ["reset"])
                self.assertTrue(controller.enabled)
                self.assertIsNone(controller.round)
                self.assertTrue(controller.status()["vm_failure_reset_pending"])

                # Buffered state from the failed epoch cannot launch a run.
                controller.on_system({"valid": True, "code": "33333333"})
                time.sleep(0.05)
                self.assertEqual(len(launches), 1)

                # Only the new PREINIT releases recovery.  The ordinary
                # PRECONFIG->222 sequence then starts a fresh random round.
                controller.on_system({"valid": True, "code": "11111111"})
                deadline = time.time() + 2
                while not preconfigs and time.time() < deadline:
                    time.sleep(0.01)
                self.assertEqual(preconfigs, ["preconfig"])
                self.assertFalse(controller.status()["vm_failure_reset_pending"])
                controller.on_system({"valid": True, "code": "22222222"})
                deadline = time.time() + 2
                while len(launches) < 2 and time.time() < deadline:
                    time.sleep(0.01)
                self.assertEqual(len(launches), 2)
                self.assertIsNotNone(controller.round)
                self.assertNotEqual(controller.round.run_id, current.run_id)  # type: ignore[union-attr]
                self.assertEqual(controller.round.local_dir.parent, session_dir)  # type: ignore[union-attr]

                # A new explicit button click gets a new top-level session.
                controller.stop("test session boundary")
                controller.start(RemoteSettings(password="test"), None)
                self.assertIsNotNone(controller.session_dir)
                self.assertNotEqual(controller.session_dir, session_dir)
            finally:
                controller.shutdown()

    def test_info_frame_loss_is_logged_reset_and_continues_without_retransmit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            resets: list[str] = []
            retransmits: list[str] = []
            preconfigs: list[str] = []
            launches: list[str] = []
            controller = AutomationController(
                webui,
                lambda *_args, **_kwargs: None,
                lambda: preconfigs.append("preconfig"),
                lambda _path: None,
                root / "shared",
                reset_board=lambda: resets.append("reset"),
                request_info_retransmit=lambda reason: retransmits.append(reason),
            )
            controller.remote.deploy_and_launch = (  # type: ignore[method-assign]
                lambda _settings, run_id, _seed: launches.append(run_id) or 901
            )
            try:
                controller.start(RemoteSettings(password="test"), "22222222")
                self._wait_for_round(controller)
                current = controller.round
                self.assertIsNotNone(current)
                assert current is not None
                report = {
                    "status": "FAIL",
                    "reason": "Info frame number discontinuity",
                    "first_failure_hart": 1,
                    "first_failure_sequence": 4920,
                    "compared_instructions": 17324,
                    "details": {"expected": 82, "actual": 95},
                }
                with patch("eh2web.automation.compare_run", return_value=report):
                    controller._compare_worker(current)

                aggregate_wrong = controller.runs_root / "_wrong.txt"
                text = aggregate_wrong.read_text(encoding="utf-8")
                self.assertIn("[INFO_STREAM_MISSING]", text)
                self.assertIn("first_failure_sequence", text)
                self.assertIn("4920", text)
                self.assertEqual(resets, ["reset"])
                self.assertEqual(retransmits, [])
                self.assertTrue(controller.enabled)
                self.assertIsNone(controller.round)
                self.assertEqual(
                    controller.status()["state"],
                    "RESETTING_AFTER_SKIPPED_ROUND",
                )
                self.assertEqual(
                    controller.status()["session_comparison_stats"]["fail_comparisons"],
                    1,
                )
            finally:
                controller.shutdown()

    def test_only_transport_loss_comparison_reasons_are_recoverable(self) -> None:
        self.assertTrue(AutomationController._is_recoverable_info_loss({
            "status": "FAIL", "reason": "Info frame number discontinuity",
        }))
        self.assertTrue(AutomationController._is_recoverable_info_loss({
            "status": "FAIL",
            "reason": "Info done count does not match captured stream",
        }))
        self.assertTrue(AutomationController._is_recoverable_info_loss({
            "status": "FAIL",
            "reason": "FPGA Info log does not contain both completion frames",
        }))
        self.assertFalse(AutomationController._is_recoverable_info_loss({
            "status": "FAIL", "reason": "architectural data mismatch",
        }))
        self.assertFalse(AutomationController._is_recoverable_info_loss({
            "status": "FAIL", "reason": "PC/instruction/metadata mismatch",
        }))

    def test_exe_end_without_both_done_frames_discards_and_resets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            resets: list[str] = []
            retransmits: list[str] = []
            controller = AutomationController(
                webui,
                lambda *_args, **_kwargs: None,
                lambda: None,
                lambda _path: None,
                root / "shared",
                reset_board=lambda: resets.append("reset"),
                request_info_retransmit=lambda reason: retransmits.append(reason),
            )
            controller.remote.deploy_and_launch = (  # type: ignore[method-assign]
                lambda _settings, _run_id, _seed: 902
            )
            try:
                controller.start(RemoteSettings(password="test"), "22222222")
                self._wait_for_round(controller)
                current = controller.round
                self.assertIsNotNone(current)
                assert current is not None

                controller.on_system({"valid": True, "code": "77777777"})

                self.assertEqual(resets, ["reset"])
                self.assertEqual(retransmits, [])
                self.assertIsNone(controller.round)
                self.assertTrue(
                    (current.local_dir / "info_loss_report.json").is_file()
                )
                self.assertIn(
                    "[INFO_STREAM_MISSING]",
                    controller.wrong_log.read_text(encoding="utf-8"),
                )
            finally:
                controller.shutdown()

    def test_automation_creates_txt_only_after_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            controller = AutomationController(
                webui, lambda *_args, **_kwargs: None,
                lambda: None, lambda _path: None, root / "shared",
            )
            controller.remote.deploy_and_launch = (  # type: ignore[method-assign]
                lambda _settings, _run_id, _seed: 321
            )
            try:
                controller.start(RemoteSettings(password="test"), "22222222")
                self._wait_for_round(controller)
                current = controller.round
                self.assertIsNotNone(current)
                assert current is not None
                self.assertIsInstance(current.writer, InfoFrameLogWriter)
                self.assertEqual(current.fpga_log.suffix, ".eh2log")
                self.assertFalse((current.local_dir / "fpga_info.txt").exists())

                current.writer.write(_data_frame(0, [(0, 1, 2, 3, 4, 0)]))
                controller.fail("test failure")
                controller.on_system({"valid": True, "code": "11111111"})
                failure_txt = current.local_dir / "fpga_info.txt"
                self.assertTrue(failure_txt.is_file())
                self.assertIn("INFO_DATA\t", failure_txt.read_text(encoding="utf-8"))
                self.assertEqual(controller.status()["fpga_decoded_file"], "fpga_info.txt")
            finally:
                controller.shutdown()


class ComparisonCounterTests(unittest.TestCase):
    def test_total_pass_fail_counts_persist_across_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            shared = root / "shared"
            controller = AutomationController(webui, lambda *_args, **_kwargs: None,
                                              lambda: None, lambda _path: None, shared)
            try:
                controller._record_comparison(  # type: ignore[arg-type]
                    SimpleNamespace(run_id="run_pass", seed=1), {"status": "PASS"}
                )
                controller._record_comparison(  # type: ignore[arg-type]
                    SimpleNamespace(run_id="run_fail", seed=2), {"status": "FAIL"}
                )
                self.assertEqual(controller.status()["comparison_stats"], {
                    "total_comparisons": 2,
                    "pass_comparisons": 1,
                    "fail_comparisons": 1,
                    "last_run_id": "run_fail",
                    "last_status": "FAIL",
                    "updated_at": controller.comparison_stats["updated_at"],
                })
            finally:
                controller.shutdown()

            reloaded = AutomationController(webui, lambda *_args, **_kwargs: None,
                                            lambda: None, lambda _path: None, shared)
            try:
                stats = reloaded.status()["comparison_stats"]
                self.assertEqual(stats["total_comparisons"], 2)
                self.assertEqual(stats["pass_comparisons"], 1)
                self.assertEqual(stats["fail_comparisons"], 1)
                self.assertEqual(stats["last_run_id"], "run_fail")
            finally:
                reloaded.shutdown()

    def test_displayed_session_counts_reset_on_each_automation_start(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            controller = AutomationController(
                webui, lambda *_args, **_kwargs: None,
                lambda: None, lambda _path: None, root / "shared",
            )
            try:
                current = SimpleNamespace(run_id="before_start", seed=1)
                controller._record_comparison(  # type: ignore[arg-type]
                    current, {"status": "PASS", "compared_instructions": 111}
                )
                controller._record_comparison(  # type: ignore[arg-type]
                    current, {"status": "FAIL", "compared_instructions": 222}
                )
                self.assertEqual(
                    controller.status()["session_comparison_stats"],
                    {
                        "total_comparisons": 2,
                        "pass_comparisons": 1,
                        "fail_comparisons": 1,
                        "compared_instructions": 333,
                    },
                )

                controller.start(RemoteSettings(password="test"), None)
                self.assertEqual(
                    controller.status()["session_comparison_stats"],
                    {
                        "total_comparisons": 0,
                        "pass_comparisons": 0,
                        "fail_comparisons": 0,
                        "compared_instructions": 0,
                    },
                )
                # Lifetime accounting remains intact even though the displayed
                # counters are scoped to this button-started automation session.
                self.assertEqual(controller.status()["comparison_stats"]["total_comparisons"], 2)
            finally:
                controller.shutdown()


class TextLogFormatTests(unittest.TestCase):
    def test_user_facing_txt_files_omit_timestamps(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            recorder = SessionRecorder(Path(temporary) / "runtime")
            recorder.start("test-interface")
            try:
                recorder.record_event({
                    "time": "2026-08-26T12:34:56.789+08:00",
                    "type": "test",
                    "data": {"received_at": "2026-08-26T12:34:56.789+08:00"},
                })
                snapshot = recorder.save_log_snapshot({
                    "received_at": "2026-08-26T12:34:56.789+08:00",
                    "nested": {"completed_at": "2026-08-26T12:35:00+08:00"},
                    "status": "FAIL",
                })
                events = (recorder.current_dir / "events.txt").read_text(encoding="utf-8")
                saved = snapshot.read_text(encoding="utf-8")
                self.assertNotIn("2026-08-26", events)
                self.assertNotIn('"time"', events)
                self.assertNotIn("2026-08-26", saved)
                self.assertNotIn("received_at", saved)
                self.assertNotIn("completed_at", saved)
                self.assertIn('"status": "FAIL"', saved)
            finally:
                recorder.close()

    def test_system_txt_retains_latest_100_and_errors_use_separate_txt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            recorder = SessionRecorder(Path(temporary) / "runtime")
            recorder.start("test-interface")
            try:
                for index in range(105):
                    decoded = {
                        "kind": "system",
                        "code": f"{index:08x}",
                        "name": f"SYSTEM_{index}",
                        "state": "KEEP",
                        "description": f"message {index}",
                        "valid": True,
                        "received_at": "2026-08-26T12:34:56.789+08:00",
                    }
                    recorder.record_system(decoded)
                error = {
                    "kind": "system",
                    "code": "666600c4",
                    "name": "INFO_DUMP_AXI_ERROR",
                    "state": "ERROR",
                    "description": "DDR1 read response error",
                    "valid": True,
                }
                recorder.record_error_code(error)
                recorder.files()

                system_text = (recorder.current_dir / "system_messages.txt").read_text(
                    encoding="utf-8"
                )
                error_text = (recorder.current_dir / "error_codes.txt").read_text(
                    encoding="utf-8"
                )
                self.assertEqual(system_text.count("SYSTEM\t"), 100)
                self.assertNotIn("code=0x00000004", system_text)
                self.assertIn("code=0x00000005", system_text)
                self.assertIn("code=0x00000068", system_text)
                self.assertIn("code=0x666600c4", error_text)
                self.assertNotIn("2026-08-26", system_text)
                self.assertNotIn("message 104", error_text)
            finally:
                recorder.close()


class CacheCleanupTests(unittest.TestCase):
    def test_cleanup_removes_only_stale_run_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            shared = root / "shared"
            controller = AutomationController(
                webui, lambda *_args, **_kwargs: None,
                lambda: None, lambda _path: None, shared,
            )
            try:
                local_old = controller.runs_root / "run_old"
                local_session_old = controller.runs_root / "session_old"
                legacy_old = controller.runtime / "runs" / "run_old"
                remote_old = shared / "runs" / "run_old"
                local_unrelated = controller.runs_root / "keep_notes"
                remote_unrelated = shared / "runs" / "keep_notes"
                for path in (
                    local_old, local_session_old, legacy_old, remote_old,
                    local_unrelated, remote_unrelated
                ):
                    path.mkdir(parents=True)
                    (path / "evidence.txt").write_text("test", encoding="utf-8")

                result = controller.clear_run_cache()
                self.assertEqual(result["automation_local_runs"], 2)
                self.assertEqual(result["automation_legacy_runs"], 1)
                self.assertEqual(result["automation_shared_runs"], 1)
                self.assertFalse(local_old.exists())
                self.assertFalse(local_session_old.exists())
                self.assertFalse(legacy_old.exists())
                self.assertFalse(remote_old.exists())
                self.assertTrue(local_unrelated.is_dir())
                self.assertTrue(remote_unrelated.is_dir())
            finally:
                controller.shutdown()

    def test_pass_cleanup_removes_entire_local_and_remote_round(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webui = root / "webui"
            (webui / "vm_tools").mkdir(parents=True)
            shared = root / "shared"
            controller = AutomationController(
                webui, lambda *_args, **_kwargs: None,
                lambda: None, lambda _path: None, shared,
            )
            try:
                session = controller.runs_root / "session_pass"
                local = session / "run_pass"
                remote = shared / "runs" / "run_pass"
                local.mkdir(parents=True)
                controller.session_dir = session
                remote.mkdir(parents=True)
                fpga = local / "fpga_info.eh2log"
                fpga.write_bytes(b"capture")
                for name in (
                    "spike.log.txt", "manifest.json", "compare_report.json",
                    "comparison_result.txt", "timing_report.txt",
                ):
                    (local / name).write_text(name, encoding="utf-8")
                (remote / "program.bin").write_bytes(b"program")
                current = SimpleNamespace(
                    local_dir=local, remote_dir=remote, fpga_log=fpga
                )
                controller._cleanup_pass(current)  # type: ignore[arg-type]
                self.assertFalse(local.exists())
                self.assertFalse(remote.exists())
            finally:
                controller.shutdown()


class FrontendContractTests(unittest.TestCase):
    def test_page_contains_every_element_required_by_app_script(self) -> None:
        """Prevent a partial static-file deployment from disabling the whole UI."""
        html = (WEBUI_ROOT / "static" / "index.html").read_text(encoding="utf-8")
        script = (WEBUI_ROOT / "static" / "app.js").read_text(encoding="utf-8")
        required_ids = set(re.findall(r"document\\.getElementById\\('([^']+)'\\)", script))
        page_ids = set(re.findall(r'\\bid="([^"]+)"', html))
        self.assertSetEqual(
            required_ids - page_ids,
            set(),
            f"index.html misses elements required by app.js: {sorted(required_ids - page_ids)}",
        )


class GeneratedHarnessTests(unittest.TestCase):
    @staticmethod
    def _load_remote_runner() -> object:
        runner_path = WEBUI_ROOT / "vm_tools" / "remote_runner.py"
        # fcntl is Linux-only; the worker helpers tested here are portable.
        original_fcntl = sys.modules.get("fcntl")
        sys.modules["fcntl"] = SimpleNamespace()
        try:
            spec = importlib.util.spec_from_file_location(
                "remote_runner_local_storage_test", runner_path
            )
            assert spec is not None and spec.loader is not None
            runner = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(runner)
            return runner
        finally:
            if original_fcntl is None:
                sys.modules.pop("fcntl", None)
            else:
                sys.modules["fcntl"] = original_fcntl

    def test_each_stop_store_is_followed_by_fence_before_parking_jump(self) -> None:
        source = (WEBUI_ROOT / "vm_tools" / "remote_runner.py").read_text(
            encoding="utf-8"
        )
        for hart in (0, 1):
            stop = source.index(f"eh2_h{hart}_stop_patch:")
            barrier = source.index("  fence rw, rw", stop)
            parking_jump = source.index(f"  j eh2_h{hart}_post", stop)
            self.assertLess(stop, barrier)
            self.assertLess(barrier, parking_jump)

    def test_atomic_addresses_are_limited_to_each_hart_dccm_page(self) -> None:
        runner_path = WEBUI_ROOT / "vm_tools" / "remote_runner.py"
        source = runner_path.read_text(encoding="utf-8")
        self.assertIn("AMO_LIMIT = 0xF0050000", source)
        self.assertIn("TemporaryDirectory", source)
        self.assertIn("publish_file(local_raw, raw_log)", source)
        self.assertNotIn("eh2_spike_done_count", source)
        self.assertIn("eh2_spike_h0_done", source)
        self.assertIn("eh2_spike_h1_done", source)

        runner = self._load_remote_runner()

        manifest = {
            "memory_layout": {
                "amo_hart0_start": 0xF0040000,
                "amo_hart0_end_exclusive": 0xF0040040,
                "amo_hart1_start": 0xF0040040,
                "amo_hart1_end_exclusive": 0xF0040080,
            }
        }
        with tempfile.TemporaryDirectory() as temporary:
            trace = Path(temporary) / "spike.log"
            trace.write_text(
                "core   0: 3 0x80000100 (0x44aa282f) x16 0 mem 0xf004003c\n"
                "core   1: 3 0x80000200 (0x1000a2af) x5 0 mem 0xf0040040\n",
                encoding="utf-8",
            )
            self.assertEqual(runner.validate_atomic_trace(trace, manifest), 2)
            trace.write_text(
                "core   0: 3 0x80000100 (0x44aa282f) x16 0 mem 0xf0040040\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "hart-private DCCM"):
                runner.validate_atomic_trace(trace, manifest)

    def test_riscvdv_build_is_local_and_only_final_artifacts_are_published(self) -> None:
        source = (WEBUI_ROOT / "vm_tools" / "remote_runner.py").read_text(
            encoding="utf-8"
        )
        self.assertIn('prefix="eh2logcomp_riscvdv_", dir="/tmp"', source)
        self.assertIn("run_generator_worker, worker, generator, work_dir", source)
        self.assertIn("compile_chunk, index, chunks, work_dir", source)
        self.assertIn(
            'publish_file(work_dir / "program.bin", run_dir / "program.bin")',
            source,
        )
        self.assertIn("archive_failed_work_dir(work_dir, run_dir)", source)

        runner = self._load_remote_runner()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root / "local" / "program.bin"
            shared = root / "share" / "program.bin"
            local.parent.mkdir(parents=True)
            local.write_bytes(b"complete binary")
            runner.publish_file(local, shared)
            self.assertEqual(shared.read_bytes(), b"complete binary")


if __name__ == "__main__":
    unittest.main()
