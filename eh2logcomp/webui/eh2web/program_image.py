"""Raw program binary loading for the verified EH2 Ethernet path."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
from typing import Any

from .protocol import PROGRAM_DATA_BYTES, PROGRAM_FRAME_BYTES


DDR_BASE = 0x80000000
DDR_ADDRESS_LIMIT = 0x1_0000_0000
DEFAULT_MAX_PROGRAM_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class ProgramImage:
    filename: str
    source_format: str
    data: bytes
    base_address: int = DDR_BASE

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.data).hexdigest()

    @property
    def frame_count(self) -> int:
        return (len(self.data) + PROGRAM_DATA_BYTES - 1) // PROGRAM_DATA_BYTES

    @property
    def padded_bytes(self) -> int:
        return self.frame_count * PROGRAM_DATA_BYTES

    @property
    def padding_bytes(self) -> int:
        return self.padded_bytes - len(self.data)

    @property
    def last_ddr_address(self) -> int:
        return self.base_address + self.padded_bytes - 1

    def manifest(self) -> dict[str, Any]:
        return {
            "filename": self.filename,
            "format": self.source_format,
            "base_address": f"0x{self.base_address:08x}",
            "program_bytes": len(self.data),
            "padded_payload_bytes": self.padded_bytes,
            "padding_bytes": self.padding_bytes,
            "frame_count": self.frame_count,
            "frame_bytes": PROGRAM_FRAME_BYTES,
            "last_ddr_address": f"0x{self.last_ddr_address:08x}",
            "sha256": self.sha256,
            "preview_hex": self.data[:64].hex(" "),
        }


def parse_program_file(
    filename: str,
    content: bytes,
    max_bytes: int = DEFAULT_MAX_PROGRAM_BYTES,
) -> ProgramImage:
    suffix = Path(filename).suffix.lower()
    if suffix != ".bin":
        raise ValueError("只接受原始二进制 .bin 程序文件")
    data = bytes(content)
    if not data:
        raise ValueError("二进制程序为空")
    if len(data) > max_bytes:
        raise ValueError(f"程序超过{max_bytes}字节软件上限")

    frame_count = (len(data) + PROGRAM_DATA_BYTES - 1) // PROGRAM_DATA_BYTES
    padded_bytes = frame_count * PROGRAM_DATA_BYTES
    if DDR_BASE + padded_bytes > DDR_ADDRESS_LIMIT:
        raise ValueError("补零后的程序地址超过32位DDR地址空间")
    return ProgramImage(filename=Path(filename).name, source_format="binary", data=data)


def inspect_program_path(path: Path, max_bytes: int = DEFAULT_MAX_PROGRAM_BYTES) -> dict[str, Any]:
    source = path.resolve()
    if source.suffix.lower() != ".bin" or not source.is_file():
        raise ValueError("自动化程序必须是存在的原始.bin文件")
    size = source.stat().st_size
    if size <= 0:
        raise ValueError("二进制程序为空")
    if size > max_bytes:
        raise ValueError(f"程序超过{max_bytes}字节软件上限")
    frame_count = (size + PROGRAM_DATA_BYTES - 1) // PROGRAM_DATA_BYTES
    padded_bytes = frame_count * PROGRAM_DATA_BYTES
    if DDR_BASE + padded_bytes > DDR_ADDRESS_LIMIT:
        raise ValueError("补零后的程序地址超过32位DDR地址空间")
    digest = hashlib.sha256()
    preview = b""
    with source.open("rb", buffering=4 * 1024 * 1024) as handle:
        while True:
            block = handle.read(4 * 1024 * 1024)
            if not block:
                break
            if not preview:
                preview = block[:64]
            digest.update(block)
    return {
        "filename": source.name,
        "path": str(source),
        "format": "binary",
        "base_address": f"0x{DDR_BASE:08x}",
        "program_bytes": size,
        "padded_payload_bytes": padded_bytes,
        "padding_bytes": padded_bytes - size,
        "frame_count": frame_count,
        "frame_bytes": PROGRAM_FRAME_BYTES,
        "last_ddr_address": f"0x{DDR_BASE + padded_bytes - 1:08x}",
        "sha256": digest.hexdigest(),
        "preview_hex": preview.hex(" "),
    }
