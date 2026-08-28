"""Ethernet frame construction and decoding for the EH2 board protocol."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from typing import Any


PROGRAM_DEST_MAC = bytes.fromhex("02 12 34 56 78 ff")
SYSTEM_DEST_MAC = bytes.fromhex("02 32 05 25 00 ff")
HOST_SOURCE_MAC = bytes.fromhex("02 32 05 25 00 fe")
BROADCAST_MAC = bytes.fromhex("ff ff ff ff ff ff")
SYSTEM_SOURCE_MAC = SYSTEM_DEST_MAC
HART0_INFO_SOURCE_MAC = bytes.fromhex("02 32 05 25 10 00")
HART1_INFO_SOURCE_MAC = bytes.fromhex("02 32 05 25 10 01")
INFO_SOURCE_MACS = {
    HART0_INFO_SOURCE_MAC: 0,
    HART1_INFO_SOURCE_MAC: 1,
}

PROGRAM_ETHERTYPE = 0x88B6
SYSTEM_ETHERTYPE = 0x88B5
INFO_DATA_ETHERTYPE = 0x88B7
INFO_DONE_ETHERTYPE = 0x88B8
PROGRAM_DATA_BYTES = 1024
PROGRAM_SEQUENCE_BYTES = 4
PROGRAM_PAYLOAD_BYTES = PROGRAM_SEQUENCE_BYTES + PROGRAM_DATA_BYTES
SYSTEM_PAYLOAD_BYTES = 46
INFO_RECORD_BYTES = 24
INFO_RECORDS_PER_FRAME = 60
INFO_DATA_PAYLOAD_BYTES = 4 + INFO_RECORD_BYTES * INFO_RECORDS_PER_FRAME
INFO_DONE_PAYLOAD_BYTES = 46
HOST_SEND_STOPPED_CODE = 0x44124445
HOST_GLOBAL_RESET_CODE = 0x44134445
HOST_INFO_RETRANSMIT_ALL_CODE = 0x44144445
PROGRAM_FRAME_BYTES = 14 + PROGRAM_PAYLOAD_BYTES
INFO_DATA_FRAME_BYTES = 14 + INFO_DATA_PAYLOAD_BYTES
INFO_DONE_FRAME_BYTES = 14 + INFO_DONE_PAYLOAD_BYTES
SYSTEM_FRAME_BYTES = 14 + SYSTEM_PAYLOAD_BYTES


SYSTEM_CODES: dict[int, tuple[str, str, str]] = {
    0x11111111: ("PREINIT_DONE", "PRECONFIG", "MAC、PHY、MIG 初始化完成"),
    0x22222222: ("SYSTEM_FUNCTION_CHECK_PASS", "READY", "指令/数据 DDR 通路检查通过，进入READY准备流程"),
    0x22220011: ("SYSTEM_FUNCTION_CHECK_DATA_FAIL", "ERROR", "数据 DDR 检查失败，等待上位机停止确认后全局复位"),
    0x22220022: ("SYSTEM_FUNCTION_CHECK_INSTR_FAIL", "ERROR", "指令 DDR 检查失败，等待上位机停止确认后全局复位"),
    0x33333333: ("READY", "PROGRAM_WRITE", "READY帧发送完成，硬件已进入PROGRAM_WRITE"),
    0x44004444: ("PROGRAM_WRITE_START", "KEEP", "第一帧程序已开始AXI写入"),
    0x44114444: ("RECEIVE_DONE", "KEEP", "已收到外部结束帧"),
    0x44444444: ("PROGRAM_WRITE_DONE", "EXECUTE", "程序帧与最后一次 DMA 均已完成"),
    0x44440011: ("PROGRAM_WRITE_OVERTIME", "ERROR", "程序写入超过20秒"),
    0x44440022: ("PROGRAM_WRITE_ERROR", "ERROR", "程序写入错误"),
    0x44440033: ("PROGRAM_FIFO_ERROR", "ERROR", "程序接收 FIFO 错误"),
    0x44440044: ("PROGRAM_DMA_ERROR", "ERROR", "程序 DataMover/DMA 错误"),
    0x44440055: ("PROGRAM_FRAME_SEQUENCE_ERROR", "ERROR", "接收过程中发现程序帧编号不连续，立即停止发送"),
    0x44440066: ("PROGRAM_FRAME_COUNT_ERROR", "ERROR", "结束帧总包数与实际接收帧数不一致"),
    0x55000000: ("HART0_EXEC_START", "EXECUTE", "hart0 首条指令已提交"),
    0x55010000: ("HART1_EXEC_START", "EXECUTE", "hart1 首条指令已提交"),
    0x550000FF: ("HART0_EXEC_DONE", "EXECUTE", "hart0 已到达执行结束标志"),
    0x550100FF: ("HART1_EXEC_DONE", "EXECUTE", "hart1 已到达执行结束标志"),
    0x55555555: ("EH2_DONE", "END", "双 hart 执行完成，进入END并开始回传逐指令信息"),
    0x66660011: ("HART0_NONBLOCK_OVERFLOW", "ERROR", "hart0 nonblock buffer overflow"),
    0x66660012: ("HART1_NONBLOCK_OVERFLOW", "ERROR", "hart1 nonblock buffer overflow"),
    0x66660021: ("HART0_TOHASH_OVERFLOW", "ERROR", "hart0 to-hash FIFO overflow"),
    0x66660022: ("HART1_TOHASH_OVERFLOW", "ERROR", "hart1 to-hash FIFO overflow"),
    0x66660033: ("TX_MAC_FIFO_OVERFLOW", "ERROR", "TX MAC FIFO overflow"),
    0x66660044: ("TX_STREAM_ERROR", "ERROR", "TX 日志流错误"),
    0x66660051: ("LEGACY_HART0_WAW_OVERFLOW", "ERROR", "旧归约路径保留错误码；本系统不产生"),
    0x66660052: ("LEGACY_HART1_WAW_OVERFLOW", "ERROR", "旧归约路径保留错误码；本系统不产生"),
    0x66660061: ("LEGACY_HART0_BANK_CONFLICT", "ERROR", "旧package bank路径保留错误码；本系统不产生"),
    0x66660062: ("LEGACY_HART1_BANK_CONFLICT", "ERROR", "旧package bank路径保留错误码；本系统不产生"),
    0x66660071: ("INFO_RX_FIFO_OVERFLOW", "ERROR", "系统信息 RX FIFO overflow"),
    0x66660072: ("INFO_TX_FIFO_OVERFLOW", "ERROR", "系统信息 TX FIFO overflow"),
    0x66660073: ("RX_FRAME_BUFFER_OVERFLOW", "ERROR", "MAC RX 帧缓冲 overflow"),
    0x66660074: ("RX_FRAME_LENGTH_ERROR", "ERROR", "接收帧长度错误"),
    0x66660075: ("MAC_RX_FCS_ERROR", "ERROR", "TEMAC 检测到接收帧 FCS 错误"),
    0x66660081: ("MAC_CONFIG_ERROR", "ERROR", "MAC 配置错误"),
    0x66660082: ("PHY_INIT_ERROR", "ERROR", "PHY 初始化错误"),
    0x66660083: ("PHY_LINK_ERROR", "ERROR", "PHY 链路错误"),
    0x66660091: ("MIG0_INIT_TIMEOUT", "ERROR", "指令 DDR MIG0 初始化超时"),
    0x66660092: ("MIG1_INIT_TIMEOUT", "ERROR", "数据 DDR MIG1 初始化超时"),
    0x666600A1: ("DDR_CLEAR_ERROR", "ERROR", "数据 DDR 清零错误"),
    0x666600A2: ("DDR_CHECK_ERROR", "ERROR", "DDR 检查错误"),
    0x666600B1: ("EH2_INIT_ERROR", "ERROR", "EH2 初始化错误"),
    0x666600B2: ("IFU_AXI_ERROR", "ERROR", "EH2 IFU AXI 错误"),
    0x666600B3: ("LSU_AXI_ERROR", "ERROR", "EH2 LSU AXI 错误"),
    0x666600C1: ("HART0_INFO_FIFO_OVERFLOW", "ERROR", "hart0 物理 XPM 指令信息 FIFO 写溢出"),
    0x666600C2: ("HART1_INFO_FIFO_OVERFLOW", "ERROR", "hart1 物理 XPM 指令信息 FIFO 写溢出"),
    0x666600C3: ("INFO_DDR_DMA_ERROR", "ERROR", "指令信息写 DDR DMA 或 DDR1 区域错误"),
    0x666600C4: ("INFO_DUMP_AXI_ERROR", "ERROR", "DDR1 指令信息回传读 DMA 收到 AXI RRESP 错误"),
    0x666600C5: ("HART0_WAW_CAUSE_ERROR", "ERROR", "hart0 WAW 取消原因配对错误"),
    0x666600C6: ("HART1_WAW_CAUSE_ERROR", "ERROR", "hart1 WAW 取消原因配对错误"),
    0x666600C7: ("INFO_DUMP_READ_PROTOCOL_ERROR", "ERROR", "DDR1 指令信息回传读 DMA 的 RLAST/长度协议错误"),
    0x666600C8: ("INFO_DUMP_FRAME_PROTOCOL_ERROR", "ERROR", "指令信息整帧缓冲的构帧序号/last/占用协议错误"),
    0x666600C9: ("INFO_DUMP_RELEASE_ERROR", "ERROR", "指令信息双帧槽释放计数下溢"),
    0x666600D1: ("HART0_INFO_QUEUE_OVERFLOW", "ERROR", "hart0 记录生成端 16 条弹性队列真实溢出"),
    0x666600D2: ("HART1_INFO_QUEUE_OVERFLOW", "ERROR", "hart1 记录生成端 16 条弹性队列真实溢出"),
    0x666600D3: ("HART0_INFO_CAPTURE_OVERFLOW", "ERROR", "hart0 EH2 提交记录捕获级溢出"),
    0x666600D4: ("HART1_INFO_CAPTURE_OVERFLOW", "ERROR", "hart1 EH2 提交记录捕获级溢出"),
    0x666600F1: ("ILLEGAL_STATE", "ERROR", "控制器非法状态"),
    0x77770001: ("INFO_RETRANSMIT_BEGIN", "KEEP", "FPGA已接受全量Info重传请求；上位机丢弃旧代次并从hart0 frame0重新收集"),
    0x77777777: ("EXE_END", "END", "本轮Info回传结束；FPGA保持END，等待上位机比较PASS后发送全局复位"),
}


def mac_text(value: bytes) -> str:
    return value.hex(":")


def ethernet_frame(dest: bytes, source: bytes, ethertype: int, payload: bytes) -> bytes:
    if len(dest) != 6 or len(source) != 6:
        raise ValueError("MAC address must contain 6 bytes")
    return dest + source + ethertype.to_bytes(2, "big") + payload


def build_program_frame(sequence: int, program_data: bytes) -> bytes:
    if not 0 <= sequence <= 0xFFFF_FFFF:
        raise ValueError("program sequence must fit in 32 bits")
    if len(program_data) != PROGRAM_DATA_BYTES:
        raise ValueError("program data must be exactly 1024 bytes")
    payload = sequence.to_bytes(PROGRAM_SEQUENCE_BYTES, "big") + program_data
    return ethernet_frame(PROGRAM_DEST_MAC, HOST_SOURCE_MAC, PROGRAM_ETHERTYPE, payload)


def iter_program_frames(program: bytes) -> Iterator[bytes]:
    if not program:
        raise ValueError("program image is empty")
    padded_size = ((len(program) + PROGRAM_DATA_BYTES - 1) // PROGRAM_DATA_BYTES) * PROGRAM_DATA_BYTES
    padded = program.ljust(padded_size, b"\x00")
    for sequence, offset in enumerate(range(0, padded_size, PROGRAM_DATA_BYTES)):
        yield build_program_frame(sequence, padded[offset : offset + PROGRAM_DATA_BYTES])


def iter_program_file_frames(path: Path) -> Iterator[bytes]:
    """Stream a large raw image without copying the complete file into RAM."""

    with path.open("rb", buffering=4 * 1024 * 1024) as handle:
        sequence = 0
        while True:
            block = handle.read(PROGRAM_DATA_BYTES)
            if not block:
                if sequence == 0:
                    raise ValueError("program image is empty")
                return
            yield build_program_frame(sequence, block.ljust(PROGRAM_DATA_BYTES, b"\x00"))
            sequence += 1


def build_end_frame(total_frames: int) -> bytes:
    if not 0 <= total_frames <= 0xFFFF_FFFF:
        raise ValueError("total frame count must fit in 32 bits")
    payload = b"\xff" * 4 + total_frames.to_bytes(4, "big") + b"\x00" * 38
    return ethernet_frame(SYSTEM_DEST_MAC, HOST_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)


def build_host_send_stopped_frame() -> bytes:
    """Acknowledge that all host program-frame transmission has stopped."""

    payload = HOST_SEND_STOPPED_CODE.to_bytes(4, "big") + b"\x00" * 42
    return ethernet_frame(SYSTEM_DEST_MAC, HOST_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)


def build_host_global_reset_frame() -> bytes:
    """Build the state-independent operator board-reset command."""

    payload = HOST_GLOBAL_RESET_CODE.to_bytes(4, "big") + b"\x00" * 42
    return ethernet_frame(SYSTEM_DEST_MAC, HOST_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)


def build_host_info_retransmit_all_frame() -> bytes:
    """Request a fresh hart0-then-hart1 DDR1 Info replay without reset."""

    payload = HOST_INFO_RETRANSMIT_ALL_CODE.to_bytes(4, "big") + b"\x00" * 42
    return ethernet_frame(SYSTEM_DEST_MAC, HOST_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)


def build_preconfig_program_frame() -> bytes:
    return build_program_frame(0, b"\xff" * PROGRAM_DATA_BYTES)


def _strip_optional_fcs(raw: bytes) -> tuple[bytes, bool]:
    if len(raw) in (SYSTEM_FRAME_BYTES + 4, PROGRAM_FRAME_BYTES + 4,
                    INFO_DATA_FRAME_BYTES + 4, INFO_DONE_FRAME_BYTES + 4):
        return raw[:-4], True
    return raw, False


def _decode_info_record(raw: bytes, record_index: int) -> dict[str, Any]:
    if len(raw) != INFO_RECORD_BYTES:
        raise ValueError("instruction-info record must contain 24 bytes")
    metadata = int.from_bytes(raw[12:16], "big")
    return {
        "record_index": record_index,
        "sequence": int.from_bytes(raw[0:4], "big"),
        "pc": f"0x{int.from_bytes(raw[4:8], 'big'):08x}",
        "instruction": f"0x{int.from_bytes(raw[8:12], 'big'):08x}",
        "metadata": f"0x{metadata:08x}",
        "waw_cancel_kind": (metadata >> 30) & 0x3,
        "hart_metadata": (metadata >> 16) & 0x1,
        "privilege": (metadata >> 14) & 0x3,
        "event_type": (metadata >> 12) & 0x3,
        "register_number": metadata & 0xFFF,
        "data": f"0x{int.from_bytes(raw[16:20], 'big'):08x}",
        "waw_cancel_number": int.from_bytes(raw[20:24], "big"),
        "padding": raw == bytes(INFO_RECORD_BYTES),
    }


def decode_frame(raw_input: bytes) -> dict[str, Any]:
    raw, had_fcs = _strip_optional_fcs(bytes(raw_input))
    if len(raw) < 14:
        return {"kind": "invalid", "reason": "以太网帧短于14字节", "length": len(raw)}

    destination = raw[0:6]
    source = raw[6:12]
    ethertype = int.from_bytes(raw[12:14], "big")
    payload = raw[14:]
    common: dict[str, Any] = {
        "destination_mac": mac_text(destination),
        "source_mac": mac_text(source),
        "ethertype": f"0x{ethertype:04x}",
        "length": len(raw),
        "capture_included_fcs": had_fcs,
    }

    if source == SYSTEM_SOURCE_MAC and ethertype == SYSTEM_ETHERTYPE:
        if destination != BROADCAST_MAC:
            return {"kind": "invalid", "reason": "系统信息帧目的MAC不是广播地址", **common}
        if len(payload) != SYSTEM_PAYLOAD_BYTES:
            return {"kind": "invalid", "reason": "系统信息payload不是46字节", **common}
        code = int.from_bytes(payload[0:4], "big")
        name, state, description = SYSTEM_CODES.get(
            code, ("UNKNOWN_SYSTEM_CODE", "UNKNOWN", "未定义的系统信息码")
        )
        fixed_ok = payload[4:6] == b"\x03\x20"
        reserved_ok = payload[6:] == b"\x00" * 40
        return {
            "kind": "system",
            "code": f"{code:08x}",
            "name": name,
            "state": state,
            "description": description,
            "fixed_0320_ok": fixed_ok,
            "reserved_zero_ok": reserved_ok,
            "valid": fixed_ok and reserved_ok and code in SYSTEM_CODES,
            **common,
        }

    if source in INFO_SOURCE_MACS and ethertype == INFO_DATA_ETHERTYPE:
        if destination != BROADCAST_MAC:
            return {"kind": "invalid", "reason": "指令信息数据帧目的MAC不是广播地址", **common}
        if len(payload) != INFO_DATA_PAYLOAD_BYTES:
            return {"kind": "invalid", "reason": "指令信息数据帧payload不是1444字节", **common}

        hart_id = INFO_SOURCE_MACS[source]
        frame_number = int.from_bytes(payload[0:4], "big")
        records = [
            _decode_info_record(
                payload[4 + index * INFO_RECORD_BYTES :
                        4 + (index + 1) * INFO_RECORD_BYTES],
                index,
            )
            for index in range(INFO_RECORDS_PER_FRAME)
        ]
        metadata_hart_ok = all(
            item["padding"] or item["hart_metadata"] == hart_id
            for item in records
        )
        return {
            "kind": "info_data",
            "hart_id": hart_id,
            "frame_number": frame_number,
            "records": records,
            "records_per_frame": INFO_RECORDS_PER_FRAME,
            "metadata_hart_ok": metadata_hart_ok,
            "valid": metadata_hart_ok,
            **common,
        }

    if source in INFO_SOURCE_MACS and ethertype == INFO_DONE_ETHERTYPE:
        if destination != BROADCAST_MAC:
            return {"kind": "invalid", "reason": "指令信息结束帧目的MAC不是广播地址", **common}
        if len(payload) != INFO_DONE_PAYLOAD_BYTES:
            return {"kind": "invalid", "reason": "指令信息结束帧payload不是46字节", **common}

        hart_id = INFO_SOURCE_MACS[source]
        expected_magic = b"H1DN" if hart_id else b"H0DN"
        total_records = int.from_bytes(payload[8:12], "big")
        total_frames = int.from_bytes(payload[12:16], "big")
        expected_frames = (
            total_records + INFO_RECORDS_PER_FRAME - 1
        ) // INFO_RECORDS_PER_FRAME
        expected_last_sequence = 0xFFFF_FFFF if total_records == 0 else total_records - 1
        last_sequence = int.from_bytes(payload[16:20], "big")
        reserved_ok = payload[20:23] == b"\x00" * 3 and payload[24:] == b"\x00" * 22
        fields_ok = (
            payload[0:4] == expected_magic
            and payload[4] == hart_id
            and payload[5] == 1
            and payload[6:8] == INFO_RECORD_BYTES.to_bytes(2, "big")
            and total_frames == expected_frames
            and last_sequence == expected_last_sequence
            and payload[23] == (hart_id ^ 1)
            and reserved_ok
        )
        return {
            "kind": "info_done",
            "hart_id": hart_id,
            "magic": payload[0:4].decode("ascii", errors="replace"),
            "version": payload[5],
            "record_bytes": int.from_bytes(payload[6:8], "big"),
            "total_records": total_records,
            "total_frames": total_frames,
            "expected_frames_from_records": expected_frames,
            "last_sequence": last_sequence,
            "peer_hart_marker": payload[23],
            "reserved_zero_ok": reserved_ok,
            "valid": fields_ok,
            **common,
        }

    return {"kind": "ignored", "reason": "不是本系统返回帧", **common}
