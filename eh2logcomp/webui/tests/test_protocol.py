from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import time
import unittest


WEBUI_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = WEBUI_ROOT.parent
sys.path.insert(0, str(WEBUI_ROOT))

from eh2web.program_image import parse_program_file  # noqa: E402
from eh2web.service import BoardService  # noqa: E402
import eh2web.service as service_module  # noqa: E402
from eh2web.protocol import (  # noqa: E402
    BROADCAST_MAC,
    HART0_INFO_SOURCE_MAC,
    HART1_INFO_SOURCE_MAC,
    HOST_SOURCE_MAC,
    INFO_DATA_ETHERTYPE,
    INFO_DATA_FRAME_BYTES,
    INFO_DONE_ETHERTYPE,
    INFO_DONE_FRAME_BYTES,
    INFO_RECORD_BYTES,
    INFO_RECORDS_PER_FRAME,
    PROGRAM_DEST_MAC,
    PROGRAM_ETHERTYPE,
    PROGRAM_FRAME_BYTES,
    PROGRAM_PAYLOAD_BYTES,
    SYSTEM_DEST_MAC,
    SYSTEM_ETHERTYPE,
    SYSTEM_FRAME_BYTES,
    SYSTEM_SOURCE_MAC,
    build_end_frame,
    build_host_global_reset_frame,
    build_host_info_retransmit_all_frame,
    build_host_send_stopped_frame,
    decode_frame,
    ethernet_frame,
    iter_program_frames,
)


class ProgramImageTests(unittest.TestCase):
    def test_verified_200k_binary_matches_existing_782_frame_image(self) -> None:
        build = REPOSITORY_ROOT / "programs" / "stress_200k_dualhart_system" / "build"
        program_path = build / "stress_200k_dualhart_system.bin"
        expected_frames_path = build / "stress_200k_program_frames.bin"
        program = program_path.read_bytes()
        image = parse_program_file(program_path.name, program)
        generated_frames = b"".join(iter_program_frames(image.data))

        self.assertEqual(len(program), 800_640)
        self.assertEqual(image.frame_count, 782)
        self.assertEqual(image.padded_bytes, 800_768)
        self.assertEqual(image.padding_bytes, 128)
        self.assertEqual(image.last_ddr_address, 0x800C37FF)
        self.assertEqual(image.sha256, "5d073f32602f986e6ae253f425046271c4255402067632da7c6ffd43e4a1ccfc")
        self.assertEqual(len(generated_frames), 782 * PROGRAM_FRAME_BYTES)
        self.assertEqual(generated_frames, expected_frames_path.read_bytes())
        self.assertEqual(
            hashlib.sha256(generated_frames).hexdigest(),
            "d5e6e51284caf9aac26efe3a846f5694405f07144b4f9a4516874ddaeb7e73ae",
        )

    def test_only_bin_is_accepted(self) -> None:
        with self.assertRaisesRegex(ValueError, "只接受原始二进制"):
            parse_program_file("program.txt", b"00 01 02 03")

    def test_last_program_frame_is_zero_padded(self) -> None:
        frames = list(iter_program_frames(b"\x01\x02\x03"))
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0][:6], PROGRAM_DEST_MAC)
        self.assertEqual(frames[0][6:12], HOST_SOURCE_MAC)
        self.assertEqual(int.from_bytes(frames[0][12:14], "big"), PROGRAM_ETHERTYPE)
        self.assertEqual(frames[0][14:18], (0).to_bytes(4, "big"))
        self.assertEqual(frames[0][18:21], b"\x01\x02\x03")
        self.assertEqual(frames[0][21:], b"\x00" * (PROGRAM_PAYLOAD_BYTES - 7))


class ProtocolTests(unittest.TestCase):
    def test_end_frame(self) -> None:
        frame = build_end_frame(782)
        self.assertEqual(len(frame), SYSTEM_FRAME_BYTES)
        self.assertEqual(frame[:6], SYSTEM_DEST_MAC)
        self.assertEqual(frame[6:12], HOST_SOURCE_MAC)
        self.assertEqual(int.from_bytes(frame[12:14], "big"), SYSTEM_ETHERTYPE)
        self.assertEqual(frame[14:18], b"\xff" * 4)
        self.assertEqual(frame[18:22], (782).to_bytes(4, "big"))
        self.assertEqual(frame[22:], b"\x00" * 38)

    def test_host_send_stopped_frame(self) -> None:
        frame = build_host_send_stopped_frame()
        self.assertEqual(len(frame), SYSTEM_FRAME_BYTES)
        self.assertEqual(frame[:6], SYSTEM_DEST_MAC)
        self.assertEqual(frame[6:12], HOST_SOURCE_MAC)
        self.assertEqual(int.from_bytes(frame[12:14], "big"), SYSTEM_ETHERTYPE)
        self.assertEqual(frame[14:18], bytes.fromhex("44 12 44 45"))
        self.assertEqual(frame[18:], b"\x00" * 42)

    def test_host_global_reset_frame(self) -> None:
        frame = build_host_global_reset_frame()
        self.assertEqual(len(frame), SYSTEM_FRAME_BYTES)
        self.assertEqual(frame[:6], SYSTEM_DEST_MAC)
        self.assertEqual(frame[6:12], HOST_SOURCE_MAC)
        self.assertEqual(int.from_bytes(frame[12:14], "big"), SYSTEM_ETHERTYPE)
        self.assertEqual(frame[14:18], bytes.fromhex("44 13 44 45"))
        self.assertEqual(frame[18:], b"\x00" * 42)

    def test_host_info_retransmit_all_frame(self) -> None:
        frame = build_host_info_retransmit_all_frame()
        self.assertEqual(len(frame), SYSTEM_FRAME_BYTES)
        self.assertEqual(frame[:6], SYSTEM_DEST_MAC)
        self.assertEqual(frame[6:12], HOST_SOURCE_MAC)
        self.assertEqual(int.from_bytes(frame[12:14], "big"), SYSTEM_ETHERTYPE)
        self.assertEqual(frame[14:18], bytes.fromhex("44 14 44 45"))
        self.assertEqual(frame[18:], b"\x00" * 42)

    def test_error_and_end_state_mapping(self) -> None:
        for code in (0x44440055, 0x44440066, 0x66660075):
            payload = code.to_bytes(4, "big") + bytes.fromhex("03 20") + b"\x00" * 40
            decoded = decode_frame(
                ethernet_frame(BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
            )
            self.assertEqual(decoded["state"], "ERROR")
            self.assertTrue(decoded["valid"])
        payload = (0x77777777).to_bytes(4, "big") + bytes.fromhex("03 20") + b"\x00" * 40
        decoded = decode_frame(
            ethernet_frame(BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
        )
        self.assertEqual(decoded["state"], "END")
        self.assertTrue(decoded["valid"])
        payload = (0x77770001).to_bytes(4, "big") + bytes.fromhex("03 20") + b"\x00" * 40
        decoded = decode_frame(
            ethernet_frame(BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
        )
        self.assertEqual(decoded["name"], "INFO_RETRANSMIT_BEGIN")
        self.assertEqual(decoded["state"], "KEEP")

    def test_info_dump_error_subcauses_are_distinct(self) -> None:
        expected = {
            0x666600C4: "INFO_DUMP_AXI_ERROR",
            0x666600C7: "INFO_DUMP_READ_PROTOCOL_ERROR",
            0x666600C8: "INFO_DUMP_FRAME_PROTOCOL_ERROR",
            0x666600C9: "INFO_DUMP_RELEASE_ERROR",
        }
        for code, name in expected.items():
            payload = code.to_bytes(4, "big") + bytes.fromhex("03 20") + b"\x00" * 40
            decoded = decode_frame(
                ethernet_frame(BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
            )
            self.assertEqual(decoded["name"], name)
            self.assertEqual(decoded["state"], "ERROR")

    def test_info_write_pipeline_error_stages_are_distinct(self) -> None:
        expected = {
            0x666600C1: "HART0_INFO_FIFO_OVERFLOW",
            0x666600C2: "HART1_INFO_FIFO_OVERFLOW",
            0x666600D1: "HART0_INFO_QUEUE_OVERFLOW",
            0x666600D2: "HART1_INFO_QUEUE_OVERFLOW",
            0x666600D3: "HART0_INFO_CAPTURE_OVERFLOW",
            0x666600D4: "HART1_INFO_CAPTURE_OVERFLOW",
        }
        for code, name in expected.items():
            payload = code.to_bytes(4, "big") + bytes.fromhex("03 20") + b"\x00" * 40
            decoded = decode_frame(
                ethernet_frame(BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
            )
            self.assertEqual(decoded["name"], name)
            self.assertEqual(decoded["state"], "ERROR")
            self.assertTrue(decoded["valid"])

    def test_system_frame_decode(self) -> None:
        payload = bytes.fromhex("33 33 33 33 03 20") + b"\x00" * 40
        raw = ethernet_frame(BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
        decoded = decode_frame(raw)
        self.assertEqual(decoded["kind"], "system")
        self.assertEqual(decoded["code"], "33333333")
        self.assertEqual(decoded["name"], "READY")
        self.assertEqual(decoded["state"], "PROGRAM_WRITE")
        self.assertTrue(decoded["valid"])


class InfoStreamServiceTests(unittest.TestCase):
    @staticmethod
    def _record(hart: int, sequence: int) -> bytes:
        metadata = (hart << 16) | 1
        return (
            sequence.to_bytes(4, "big")
            + (0x80000000 + sequence * 4).to_bytes(4, "big")
            + (0x00000013).to_bytes(4, "big")
            + metadata.to_bytes(4, "big")
            + sequence.to_bytes(4, "big")
            + (0).to_bytes(4, "big")
        )

    @classmethod
    def _data_frame(
        cls, hart: int, frame_number: int, first_sequence: int, count: int
    ) -> bytes:
        payload = frame_number.to_bytes(4, "big")
        payload += b"".join(
            cls._record(hart, first_sequence + index) for index in range(count)
        )
        payload += b"\x00" * ((INFO_RECORDS_PER_FRAME - count) * INFO_RECORD_BYTES)
        source = HART1_INFO_SOURCE_MAC if hart else HART0_INFO_SOURCE_MAC
        return ethernet_frame(BROADCAST_MAC, source, INFO_DATA_ETHERTYPE, payload)

    @classmethod
    def _data_frame_sequences(
        cls, hart: int, frame_number: int, sequences: list[int]
    ) -> bytes:
        payload = frame_number.to_bytes(4, "big")
        payload += b"".join(cls._record(hart, item) for item in sequences)
        payload += b"\x00" * (
            (INFO_RECORDS_PER_FRAME - len(sequences)) * INFO_RECORD_BYTES
        )
        source = HART1_INFO_SOURCE_MAC if hart else HART0_INFO_SOURCE_MAC
        return ethernet_frame(BROADCAST_MAC, source, INFO_DATA_ETHERTYPE, payload)

    @staticmethod
    def _done_frame(hart: int, total_records: int) -> bytes:
        total_frames = (total_records + INFO_RECORDS_PER_FRAME - 1) // INFO_RECORDS_PER_FRAME
        last_sequence = 0xFFFF_FFFF if total_records == 0 else total_records - 1
        payload = (
            (b"H1DN" if hart else b"H0DN")
            + bytes((hart, 1)) + INFO_RECORD_BYTES.to_bytes(2, "big")
            + total_records.to_bytes(4, "big")
            + total_frames.to_bytes(4, "big")
            + last_sequence.to_bytes(4, "big")
            + b"\x00\x00\x00" + bytes((hart ^ 1,)) + b"\x00" * 22
        )
        source = HART1_INFO_SOURCE_MAC if hart else HART0_INFO_SOURCE_MAC
        return ethernet_frame(BROADCAST_MAC, source, INFO_DONE_ETHERTYPE, payload)

    def test_cross_frame_and_done_count_comparison(self) -> None:
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        service._on_packet(self._data_frame(0, 0, 0, 60))
        service._on_packet(self._data_frame(0, 1, 60, 1))
        service._on_packet(self._done_frame(0, 61))
        status = service.status()
        self.assertEqual(status["comparison_summary"]["hart0_frames"], 2)
        self.assertEqual(status["comparison_summary"]["hart0_records"], 61)
        self.assertEqual(status["info_done"]["0"]["host_compare"], "PASS")

    def test_out_of_order_sequences_are_covered_at_done(self) -> None:
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        service._on_packet(self._data_frame_sequences(0, 0, [1, 0, 2]))
        service._on_packet(self._done_frame(0, 3))
        status = service.status()
        self.assertEqual(status["comparison_summary"]["hart0_records"], 3)
        self.assertEqual(status["info_done"]["0"]["host_compare"], "PASS")

    def test_duplicate_sequence_is_latched_until_done(self) -> None:
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        service._on_packet(self._data_frame_sequences(0, 0, [0, 0, 2]))
        service._on_packet(self._done_frame(0, 3))
        status = service.status()
        self.assertTrue(status["comparison_summary"]["stream_error"][0])
        self.assertEqual(status["info_done"]["0"]["host_compare"], "FAIL")

    def test_discontinuous_frame_is_latched_until_done(self) -> None:
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        service._on_packet(self._data_frame(1, 1, 0, 1))
        service._on_packet(self._done_frame(1, 1))
        status = service.status()
        self.assertTrue(status["comparison_summary"]["stream_error"][1])
        self.assertEqual(status["info_done"]["1"]["host_compare"], "FAIL")

    def test_complete_200k_record_receive_accounting(self) -> None:
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        totals = (100_023, 100_021)
        for hart, total in enumerate(totals):
            sequence = 0
            frame_number = 0
            while sequence < total:
                count = min(INFO_RECORDS_PER_FRAME, total - sequence)
                service._on_packet(
                    self._data_frame(hart, frame_number, sequence, count)
                )
                sequence += count
                frame_number += 1
            service._on_packet(self._done_frame(hart, total))

        status = service.status()
        summary = status["comparison_summary"]
        self.assertEqual(summary["status"], "PASS")
        self.assertEqual(summary["hart0_records"], totals[0])
        self.assertEqual(summary["hart1_records"], totals[1])
        self.assertEqual(summary["hart0_frames"], 1668)
        self.assertEqual(summary["hart1_frames"], 1668)

    def test_hart_execution_status_decode(self) -> None:
        expected = {
            0x55000000: "HART0_EXEC_START",
            0x55010000: "HART1_EXEC_START",
            0x550000FF: "HART0_EXEC_DONE",
            0x550100FF: "HART1_EXEC_DONE",
        }
        for code, name in expected.items():
            with self.subTest(code=f"{code:08x}"):
                payload = code.to_bytes(4, "big") + bytes.fromhex("03 20") + b"\x00" * 40
                raw = ethernet_frame(
                    BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload
                )
                decoded = decode_frame(raw)
                self.assertEqual(decoded["name"], name)
                self.assertEqual(decoded["state"], "EXECUTE")
                self.assertTrue(decoded["valid"])

    def test_system_status_retains_only_latest_100_messages(self) -> None:
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        try:
            for index in range(105):
                # All frames are valid protocol messages while the final code
                # remains observable, proving deque eviction rather than drops.
                code = 0x55000000 if index % 2 == 0 else 0x55010000
                payload = code.to_bytes(4, "big") + bytes.fromhex("03 20") + b"\x00" * 40
                service._on_packet(
                    ethernet_frame(
                        BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload
                    )
                )
            messages = service.status()["system_messages"]
            self.assertEqual(len(messages), 100)
            self.assertEqual(messages[-1]["code"], "55000000")
        finally:
            service.automation.shutdown()

    def test_resetting_watchdog_retries_without_stopping_automation(self) -> None:
        original_timeout = service_module.RESET_RECOVERY_TIMEOUT_SECONDS
        service_module.RESET_RECOVERY_TIMEOUT_SECONDS = 0.01
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        calls: list[tuple[bool, int]] = []
        try:
            service.capture_running = True
            service.interface_id = "test-interface"
            service.board_state = "RESETTING"

            def fake_reset(*, preserve_automation: bool, recovery_attempt: int) -> None:
                calls.append((preserve_automation, recovery_attempt))

            service._send_board_reset = fake_reset  # type: ignore[method-assign]
            service._arm_reset_recovery_watchdog(reason="test", attempt=0)
            time.sleep(0.08)
            self.assertEqual(calls, [(True, 1)])
        finally:
            service.capture_running = False
            service.automation.shutdown()
            service_module.RESET_RECOVERY_TIMEOUT_SECONDS = original_timeout

    def test_info_loss_does_not_send_a_second_reset_while_resetting(self) -> None:
        service = BoardService(WEBUI_ROOT, lambda _event: None)
        resets: list[str] = []
        try:
            service.capture_running = True
            service.board_state = "RESETTING"
            service.automation.on_info_stream_loss = (  # type: ignore[method-assign]
                lambda *_args, **_kwargs: False
            )
            service._send_board_reset = (  # type: ignore[method-assign]
                lambda **_kwargs: resets.append("reset")
            )

            service._discard_info_stream("late frame after reset")

            self.assertEqual(resets, [])
        finally:
            service.capture_running = False
            service.automation.shutdown()

    def test_info_data_frame_decode_with_waw(self) -> None:
        payload = bytearray(4 + INFO_RECORDS_PER_FRAME * INFO_RECORD_BYTES)
        payload[0:4] = (7).to_bytes(4, "big")
        metadata = (2 << 30) | (1 << 16) | (3 << 14) | (1 << 12) | 9
        record = (
            (1234).to_bytes(4, "big")
            + (0x80000100).to_bytes(4, "big")
            + (0x00C12023).to_bytes(4, "big")
            + metadata.to_bytes(4, "big")
            + (0xDEADBEEF).to_bytes(4, "big")
            + (1200).to_bytes(4, "big")
        )
        payload[4:4 + INFO_RECORD_BYTES] = record
        raw = ethernet_frame(
            BROADCAST_MAC, HART1_INFO_SOURCE_MAC, INFO_DATA_ETHERTYPE, payload
        )
        decoded = decode_frame(raw)
        self.assertEqual(len(raw), INFO_DATA_FRAME_BYTES)
        self.assertEqual(decoded["kind"], "info_data")
        self.assertEqual(decoded["hart_id"], 1)
        self.assertEqual(decoded["frame_number"], 7)
        self.assertEqual(decoded["records"][0]["sequence"], 1234)
        self.assertEqual(decoded["records"][0]["pc"], "0x80000100")
        self.assertEqual(decoded["records"][0]["waw_cancel_kind"], 2)
        self.assertEqual(decoded["records"][0]["waw_cancel_number"], 1200)
        self.assertTrue(decoded["records"][1]["padding"])
        self.assertTrue(decoded["valid"])

    def test_info_done_frame_decode(self) -> None:
        total_records = 121
        total_frames = 3
        payload = (
            b"H0DN" + b"\x00\x01" + INFO_RECORD_BYTES.to_bytes(2, "big")
            + total_records.to_bytes(4, "big")
            + total_frames.to_bytes(4, "big")
            + (total_records - 1).to_bytes(4, "big")
            + b"\x00\x00\x00\x01" + b"\x00" * 22
        )
        raw = ethernet_frame(
            BROADCAST_MAC, HART0_INFO_SOURCE_MAC, INFO_DONE_ETHERTYPE, payload
        )
        decoded = decode_frame(raw)
        self.assertEqual(len(raw), INFO_DONE_FRAME_BYTES)
        self.assertEqual(decoded["kind"], "info_done")
        self.assertEqual(decoded["hart_id"], 0)
        self.assertEqual(decoded["total_records"], 121)
        self.assertEqual(decoded["total_frames"], 3)
        self.assertEqual(decoded["last_sequence"], 120)
        self.assertTrue(decoded["valid"])


if __name__ == "__main__":
    unittest.main()
