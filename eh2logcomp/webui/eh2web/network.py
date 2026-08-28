"""Windows/Npcap transport isolated from protocol and HTTP code."""

from __future__ import annotations

from collections.abc import Callable, Iterable
import platform
import threading
import time
from ctypes import POINTER, byref, create_string_buffer, c_ubyte
from typing import Any


PacketCallback = Callable[[bytes], None]
ProgressCallback = Callable[[int, int], None]


class NetworkBackend:
    # The 200k dual-hart image returns about 4.9 MiB in one line-rate burst.
    # Keep substantially more data in the Npcap kernel buffer so Python text
    # decoding never has to run in real time with the wire.
    CAPTURE_BUFFER_BYTES = 64 * 1024 * 1024

    def __init__(self) -> None:
        self._sniffer: Any = None
        self._capture_handle: Any = None
        self._capture_thread: threading.Thread | None = None
        self._capture_stop = threading.Event()
        self._capture_stats = {"received": 0, "dropped": 0, "interface_dropped": 0}
        self._capture_error: str | None = None
        self._capture_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self.capture_interface: str | None = None

    def diagnostics(self) -> dict[str, Any]:
        handle = self._capture_handle
        if handle is not None and platform.system() == "Windows":
            try:
                from scapy.libs.winpcapy import pcap_stat, pcap_stats  # type: ignore

                statistics = pcap_stat()
                if pcap_stats(handle, byref(statistics)) == 0:
                    self._capture_stats = {
                        "received": int(statistics.ps_recv),
                        "dropped": int(statistics.ps_drop),
                        "interface_dropped": int(statistics.ps_ifdrop),
                    }
            except Exception:
                pass
        result: dict[str, Any] = {
            "platform": platform.platform(),
            "windows": platform.system() == "Windows",
            "scapy_available": False,
            "pcap_provider": False,
            "error": None,
            "capture_buffer_bytes": self.CAPTURE_BUFFER_BYTES,
            "capture_stats": dict(self._capture_stats),
            "capture_error": self._capture_error,
        }
        try:
            from scapy.all import conf  # type: ignore

            result["scapy_available"] = True
            result["pcap_provider"] = bool(conf.use_pcap)
            result["scapy_version"] = str(conf.version)
        except Exception as exc:  # pragma: no cover - depends on host setup
            result["error"] = str(exc)
        return result

    @staticmethod
    def list_interfaces() -> list[dict[str, Any]]:
        try:
            from scapy.all import conf  # type: ignore
        except Exception as exc:  # pragma: no cover - depends on installed deps
            raise RuntimeError(f"Scapy不可用: {exc}") from exc

        interfaces: list[dict[str, Any]] = []
        for iface in conf.ifaces.values():
            identifier = str(
                getattr(iface, "network_name", None)
                or getattr(iface, "name", None)
                or getattr(iface, "index", "")
            )
            if not identifier:
                continue
            interfaces.append(
                {
                    "id": identifier,
                    "name": str(getattr(iface, "name", identifier)),
                    "description": str(getattr(iface, "description", "")),
                    "mac": str(getattr(iface, "mac", "") or ""),
                    "ipv4": str(getattr(iface, "ip", "") or ""),
                    "index": getattr(iface, "index", None),
                }
            )
        interfaces.sort(key=lambda item: (item["description"], item["name"]))
        return interfaces

    def start_capture(self, interface_id: str, callback: PacketCallback) -> None:
        with self._capture_lock:
            if self._sniffer is not None or self._capture_handle is not None:
                raise RuntimeError("监听已经启动")
            self._capture_stats = {"received": 0, "dropped": 0, "interface_dropped": 0}
            self._capture_error = None
            self._capture_stop.clear()
            try:
                if platform.system() == "Windows":
                    self._start_native_npcap(interface_id, callback)
                    self.capture_interface = interface_id
                    return
                from scapy.all import AsyncSniffer  # type: ignore

                self._sniffer = AsyncSniffer(
                    iface=interface_id,
                    store=False,
                    # System messages, 1444-byte instruction-info frames and
                    # per-hart completion frames use three distinct types.
                    filter=(
                        "ether proto 0x88b5 or "
                        "ether proto 0x88b7 or ether proto 0x88b8"
                    ),
                    prn=lambda packet: callback(bytes(packet)),
                )
                self._sniffer.start()
                self.capture_interface = interface_id
            except Exception as exc:  # pragma: no cover - requires Npcap/NIC
                self._sniffer = None
                self.capture_interface = None
                raise RuntimeError(f"无法启动Npcap监听: {exc}") from exc

    def _start_native_npcap(self, interface_id: str, callback: PacketCallback) -> None:
        """Open Npcap with a large pre-activation buffer and a raw receive loop."""

        from scapy.libs.winpcapy import (  # type: ignore
            PCAP_ERRBUF_SIZE, bpf_program, pcap_activate, pcap_close,
            pcap_compile, pcap_create, pcap_freecode, pcap_geterr,
            pcap_next_ex, pcap_pkthdr, pcap_set_buffer_size,
            pcap_set_promisc, pcap_set_snaplen, pcap_set_timeout,
            pcap_setfilter,
        )

        errbuf = create_string_buffer(PCAP_ERRBUF_SIZE)
        handle = pcap_create(interface_id.encode("utf-8"), errbuf)
        if not handle:
            raise RuntimeError(errbuf.value.decode(errors="replace") or "pcap_create失败")

        def detail() -> str:
            return bytes(pcap_geterr(handle) or b"").decode(errors="replace")

        def check(result: int, operation: str) -> None:
            if result != 0:
                raise RuntimeError(f"{operation}失败: {detail() or result}")

        try:
            check(pcap_set_snaplen(handle, 2048), "设置Npcap抓包长度")
            check(pcap_set_promisc(handle, 1), "设置Npcap混杂模式")
            check(pcap_set_timeout(handle, 1), "设置Npcap读取超时")
            check(
                pcap_set_buffer_size(handle, self.CAPTURE_BUFFER_BYTES),
                "设置Npcap 64MiB内核缓冲",
            )
            status = pcap_activate(handle)
            if status < 0:
                raise RuntimeError(f"激活Npcap失败: {detail() or status}")

            program = bpf_program()
            expression = b"ether proto 0x88b5 or ether proto 0x88b7 or ether proto 0x88b8"
            if pcap_compile(handle, byref(program), expression, 1, 0xFFFF_FFFF) != 0:
                raise RuntimeError(f"编译Npcap过滤器失败: {detail()}")
            try:
                if pcap_setfilter(handle, byref(program)) != 0:
                    raise RuntimeError(f"安装Npcap过滤器失败: {detail()}")
            finally:
                pcap_freecode(byref(program))
        except Exception:
            pcap_close(handle)
            raise

        self._capture_handle = handle

        def receive_loop() -> None:
            header = POINTER(pcap_pkthdr)()
            data = POINTER(c_ubyte)()
            try:
                while not self._capture_stop.is_set():
                    result = pcap_next_ex(handle, byref(header), byref(data))
                    if result == 0:
                        continue
                    if result < 0:
                        if not self._capture_stop.is_set():
                            self._capture_error = detail() or f"pcap_next_ex={result}"
                        return
                    # No Scapy packet dissection occurs on this hot path.
                    callback(bytes(data[: int(header.contents.caplen)]))
            except Exception as exc:  # pragma: no cover - hardware/Npcap only
                self._capture_error = str(exc)

        self._capture_thread = threading.Thread(
            target=receive_loop, name="eh2-npcap-raw-rx", daemon=True
        )
        self._capture_thread.start()

    def stop_capture(self) -> None:
        with self._capture_lock:
            sniffer = self._sniffer
            self._sniffer = None
            handle = self._capture_handle
            capture_thread = self._capture_thread
            self._capture_stop.set()
            self.capture_interface = None
        if sniffer is not None:
            try:
                sniffer.stop(join=True)
            except Exception:
                pass
        if handle is not None:
            if capture_thread is not None:
                capture_thread.join(timeout=2.0)
            try:
                from scapy.libs.winpcapy import pcap_close, pcap_stat, pcap_stats  # type: ignore

                statistics = pcap_stat()
                if pcap_stats(handle, byref(statistics)) == 0:
                    self._capture_stats = {
                        "received": int(statistics.ps_recv),
                        "dropped": int(statistics.ps_drop),
                        "interface_dropped": int(statistics.ps_ifdrop),
                    }
                pcap_close(handle)
            finally:
                with self._capture_lock:
                    self._capture_handle = None
                    self._capture_thread = None

    def send_sequence(
        self,
        interface_id: str,
        frames: Iterable[bytes],
        total_frames: int,
        trailer: bytes | None,
        inter_frame_seconds: float,
        progress: ProgressCallback,
        packet_sent: PacketCallback,
        cancel_event: threading.Event | None = None,
    ) -> bool:
        """Send data frames, then submit trailer immediately on the same L2 socket."""

        if inter_frame_seconds < 0:
            raise ValueError("帧间隔不能为负数")
        with self._send_lock:
            try:
                from scapy.all import Ether, conf  # type: ignore

                socket = conf.L2socket(iface=interface_id)
            except Exception as exc:  # pragma: no cover - requires Npcap/NIC
                raise RuntimeError(f"无法打开二层发送句柄: {exc}") from exc

            sent = 0
            try:
                for frame in frames:
                    if cancel_event is not None and cancel_event.is_set():
                        return True
                    result = socket.send(Ether(frame))
                    if isinstance(result, int) and result < 0:
                        raise RuntimeError("Npcap拒绝了程序帧")
                    packet_sent(frame)
                    sent += 1
                    progress(sent, total_frames)
                    if inter_frame_seconds > 0 and sent < total_frames:
                        if cancel_event is not None:
                            if cancel_event.wait(inter_frame_seconds):
                                return True
                        else:
                            deadline = time.perf_counter() + inter_frame_seconds
                            remaining = deadline - time.perf_counter()
                            if remaining > 0:
                                time.sleep(remaining)
                if cancel_event is not None and cancel_event.is_set():
                    return True
                if sent != total_frames:
                    raise RuntimeError(f"生成帧数异常: 期望{total_frames}, 实际{sent}")
                if trailer is not None:
                    result = socket.send(Ether(trailer))
                    if isinstance(result, int) and result < 0:
                        raise RuntimeError("Npcap拒绝了结束帧")
                    packet_sent(trailer)
                return False
            finally:
                socket.close()

    def send_frame(
        self,
        interface_id: str,
        frame: bytes,
        packet_sent: PacketCallback,
    ) -> None:
        """Send one control frame after any active bulk sender has stopped."""

        with self._send_lock:
            try:
                from scapy.all import Ether, conf  # type: ignore

                socket = conf.L2socket(iface=interface_id)
            except Exception as exc:  # pragma: no cover - requires Npcap/NIC
                raise RuntimeError(f"无法打开二层发送句柄: {exc}") from exc
            try:
                result = socket.send(Ether(frame))
                if isinstance(result, int) and result < 0:
                    raise RuntimeError("Npcap拒绝了控制帧")
                packet_sent(frame)
            finally:
                socket.close()
