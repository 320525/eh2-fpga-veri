"""Ethernet frame construction and decoding for the EH2 board protocol."""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any


PROGRAM_DEST_MAC = bytes.fromhex("02 12 34 56 78 ff")
SYSTEM_DEST_MAC = bytes.fromhex("02 32 05 25 00 ff")
HOST_SOURCE_MAC = bytes.fromhex("02 32 05 25 00 fe")
BROADCAST_MAC = bytes.fromhex("ff ff ff ff ff ff")
SYSTEM_SOURCE_MAC = SYSTEM_DEST_MAC
LOG_SOURCE_MAC = PROGRAM_DEST_MAC

PROGRAM_ETHERTYPE = 0x88B6
SYSTEM_ETHERTYPE = 0x88B5
PROGRAM_DATA_BYTES = 1024
PROGRAM_SEQUENCE_BYTES = 4
PROGRAM_PAYLOAD_BYTES = PROGRAM_SEQUENCE_BYTES + PROGRAM_DATA_BYTES
LOG_PAYLOAD_BYTES = 1024
SYSTEM_PAYLOAD_BYTES = 46
HOST_SEND_STOPPED_CODE = 0x44124445
PROGRAM_FRAME_BYTES = 14 + PROGRAM_PAYLOAD_BYTES
LOG_FRAME_BYTES = 14 + LOG_PAYLOAD_BYTES
SYSTEM_FRAME_BYTES = 14 + SYSTEM_PAYLOAD_BYTES
MAX_WAW_COUNT = (LOG_PAYLOAD_BYTES - 58) // 2


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
    0x55555555: ("EH2_DONE", "END", "双 hart 执行及日志发送完成"),
    0x66660011: ("HART0_NONBLOCK_OVERFLOW", "ERROR", "hart0 nonblock buffer overflow"),
    0x66660012: ("HART1_NONBLOCK_OVERFLOW", "ERROR", "hart1 nonblock buffer overflow"),
    0x66660021: ("HART0_TOHASH_OVERFLOW", "ERROR", "hart0 to-hash FIFO overflow"),
    0x66660022: ("HART1_TOHASH_OVERFLOW", "ERROR", "hart1 to-hash FIFO overflow"),
    0x66660033: ("TX_MAC_FIFO_OVERFLOW", "ERROR", "TX MAC FIFO overflow"),
    0x66660044: ("TX_STREAM_ERROR", "ERROR", "TX 日志流错误"),
    0x66660051: ("HART0_WAW_OVERFLOW", "ERROR", "hart0 WAW 序号超过483项"),
    0x66660052: ("HART1_WAW_OVERFLOW", "ERROR", "hart1 WAW 序号超过483项"),
    0x66660061: ("HART0_PACKAGE_BANK_CONFLICT", "ERROR", "hart0 package bank 冲突"),
    0x66660062: ("HART1_PACKAGE_BANK_CONFLICT", "ERROR", "hart1 package bank 冲突"),
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
    0x666600F1: ("ILLEGAL_STATE", "ERROR", "控制器非法状态"),
    0x77777777: ("EXE_END", "RESETTING", "本轮结束，硬件正在执行全局复位并将重新进入PRECONFIG"),
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


def build_end_frame(total_frames: int) -> bytes:
    if not 0 <= total_frames <= 0xFFFF_FFFF:
        raise ValueError("total frame count must fit in 32 bits")
    payload = b"\xff" * 4 + total_frames.to_bytes(4, "big") + b"\x00" * 38
    return ethernet_frame(SYSTEM_DEST_MAC, HOST_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)


def build_host_send_stopped_frame() -> bytes:
    """Acknowledge that all host program-frame transmission has stopped."""

    payload = HOST_SEND_STOPPED_CODE.to_bytes(4, "big") + b"\x00" * 42
    return ethernet_frame(SYSTEM_DEST_MAC, HOST_SOURCE_MAC, SYSTEM_ETHERTYPE, payload)


def build_preconfig_program_frame() -> bytes:
    return build_program_frame(0, b"\xff" * PROGRAM_DATA_BYTES)


def _strip_optional_fcs(raw: bytes) -> tuple[bytes, bool]:
    if len(raw) in (SYSTEM_FRAME_BYTES + 4, PROGRAM_FRAME_BYTES + 4,
                    LOG_FRAME_BYTES + 4):
        return raw[:-4], True
    return raw, False


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

    if source == LOG_SOURCE_MAC and ethertype == SYSTEM_ETHERTYPE:
        if destination != BROADCAST_MAC:
            return {"kind": "invalid", "reason": "日志帧目的MAC不是广播地址", **common}
        if len(payload) != LOG_PAYLOAD_BYTES:
            return {"kind": "invalid", "reason": "日志payload不是1024字节", **common}

        package_number = int.from_bytes(payload[0:2], "big")
        hart_id = payload[2] & 0x01
        hart_reserved_ok = (payload[2] & 0xFE) == 0 and payload[3] == 0
        count = int.from_bytes(payload[4:8], "big")
        names = ("xor0", "xor1", "sum0", "sum1", "sum2", "sum3")
        reductions = {
            name: payload[8 + index * 8 : 16 + index * 8].hex()
            for index, name in enumerate(names)
        }
        waw_count = int.from_bytes(payload[56:58], "big")
        waw_fits = waw_count <= MAX_WAW_COUNT
        waw_end = 58 + min(waw_count, MAX_WAW_COUNT) * 2
        waw_sequences = [
            int.from_bytes(payload[offset : offset + 2], "big")
            for offset in range(58, waw_end, 2)
        ]
        trailing_zero_ok = waw_fits and payload[waw_end:] == b"\x00" * (len(payload) - waw_end)
        return {
            "kind": "log",
            "package_number": package_number,
            "hart_id": hart_id,
            "count": count,
            **reductions,
            "waw_count": waw_count,
            "waw_sequences": waw_sequences,
            "header_reserved_ok": hart_reserved_ok,
            "waw_count_valid": waw_fits,
            "trailing_zero_ok": trailing_zero_ok,
            "valid": hart_reserved_ok and waw_fits and trailing_zero_ok,
            **common,
        }

    return {"kind": "ignored", "reason": "不是本系统返回帧", **common}
