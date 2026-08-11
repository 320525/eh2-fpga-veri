"""Windows/Npcap transport isolated from protocol and HTTP code."""

from __future__ import annotations

from collections.abc import Callable, Iterable
import platform
import threading
import time
from typing import Any


PacketCallback = Callable[[bytes], None]
ProgressCallback = Callable[[int, int], None]


class NetworkBackend:
    def __init__(self) -> None:
        self._sniffer: Any = None
        self._capture_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self.capture_interface: str | None = None

    @staticmethod
    def diagnostics() -> dict[str, Any]:
        result: dict[str, Any] = {
            "platform": platform.platform(),
            "windows": platform.system() == "Windows",
            "scapy_available": False,
            "pcap_provider": False,
            "error": None,
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
            if self._sniffer is not None:
                raise RuntimeError("监听已经启动")
            try:
                from scapy.all import AsyncSniffer  # type: ignore

                self._sniffer = AsyncSniffer(
                    iface=interface_id,
                    store=False,
                    filter="ether proto 0x88b5",
                    prn=lambda packet: callback(bytes(packet)),
                )
                self._sniffer.start()
                self.capture_interface = interface_id
            except Exception as exc:  # pragma: no cover - requires Npcap/NIC
                self._sniffer = None
                self.capture_interface = None
                raise RuntimeError(f"无法启动Npcap监听: {exc}") from exc

    def stop_capture(self) -> None:
        with self._capture_lock:
            sniffer = self._sniffer
            self._sniffer = None
            self.capture_interface = None
        if sniffer is not None:
            try:
                sniffer.stop(join=True)
            except Exception:
                pass

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
