from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import unittest


WEBUI_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = WEBUI_ROOT.parent
sys.path.insert(0, str(WEBUI_ROOT))

from eh2web.golden import GoldenResults  # noqa: E402
from eh2web.program_image import parse_program_file  # noqa: E402
from eh2web.protocol import (  # noqa: E402
    BROADCAST_MAC,
    HOST_SOURCE_MAC,
    LOG_SOURCE_MAC,
    PROGRAM_DEST_MAC,
    PROGRAM_ETHERTYPE,
    PROGRAM_FRAME_BYTES,
    PROGRAM_PAYLOAD_BYTES,
    SYSTEM_DEST_MAC,
    SYSTEM_ETHERTYPE,
    SYSTEM_FRAME_BYTES,
    SYSTEM_SOURCE_MAC,
    build_end_frame,
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
        self.assertEqual(decoded["state"], "RESETTING")

    def test_system_frame_decode(self) -> None:
        payload = bytes.fromhex("33 33 33 33 03 20") + b"\x00" * 40
        raw = ethernet_frame(BROADCAST_MAC, SYSTEM_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
        decoded = decode_frame(raw)
        self.assertEqual(decoded["kind"], "system")
        self.assertEqual(decoded["code"], "33333333")
        self.assertEqual(decoded["name"], "READY")
        self.assertEqual(decoded["state"], "PROGRAM_WRITE")
        self.assertTrue(decoded["valid"])

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

    def test_log_frame_decode_with_waw(self) -> None:
        payload = bytearray(1024)
        payload[0:2] = (7).to_bytes(2, "big")
        payload[2] = 1
        payload[4:8] = (1234).to_bytes(4, "big")
        values = [1, 2, 3, 4, 5, 6]
        for index, value in enumerate(values):
            payload[8 + index * 8 : 16 + index * 8] = value.to_bytes(8, "big")
        payload[56:58] = (2).to_bytes(2, "big")
        payload[58:60] = (15).to_bytes(2, "big")
        payload[60:62] = (65535).to_bytes(2, "big")
        raw = ethernet_frame(BROADCAST_MAC, LOG_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)
        decoded = decode_frame(raw)
        self.assertEqual(decoded["kind"], "log")
        self.assertEqual(decoded["hart_id"], 1)
        self.assertEqual(decoded["package_number"], 7)
        self.assertEqual(decoded["count"], 1234)
        self.assertEqual(decoded["xor0"], "0000000000000001")
        self.assertEqual(decoded["sum3"], "0000000000000006")
        self.assertEqual(decoded["waw_sequences"], [15, 65535])
        self.assertTrue(decoded["valid"])

    def test_known_golden_package_comparison(self) -> None:
        golden = GoldenResults(WEBUI_ROOT / "golden" / "stress_200k_system_golden.json")
        decoded = {
            "hart_id": 0,
            "package_number": 0,
            "count": 65536,
            "waw_count": 4,
            "waw_sequences": [18, 20, 26, 28],
            "xor0": "d31849f405d7893f",
            "xor1": "f362cffb3bd01126",
            "sum0": "40883202d86e0925",
            "sum1": "c155b99763889958",
            "sum2": "f97364871915ade9",
            "sum3": "7ec3152548d669c5",
        }
        self.assertEqual(golden.compare(decoded)["status"], "PASS")
        decoded["sum3"] = "0000000000000000"
        comparison = golden.compare(decoded)
        self.assertEqual(comparison["status"], "FAIL")
        self.assertIn("sum3", comparison["mismatches"][0])

    def test_waw_sequence_list_is_part_of_golden_comparison(self) -> None:
        golden = GoldenResults(WEBUI_ROOT / "golden" / "stress_200k_system_golden.json")
        expected = golden.packages[(1, 0)]
        decoded = {
            "hart_id": 1,
            "package_number": 0,
            **{name: expected[name] for name in (
                "count", "xor0", "xor1", "sum0", "sum1", "sum2", "sum3",
                "waw_count", "waw_sequences",
            )},
        }
        self.assertEqual(golden.compare(decoded)["status"], "PASS")
        decoded["waw_sequences"] = decoded["waw_sequences"][:-1]
        comparison = golden.compare(decoded)
        self.assertEqual(comparison["status"], "FAIL")
        self.assertTrue(
            any("waw_sequences" in item for item in comparison["mismatches"])
        )


if __name__ == "__main__":
    unittest.main()
