"""EH2 Board WebUI HTTP/WebSocket entry point."""

from __future__ import annotations

import argparse
import asyncio
from contextlib import asynccontextmanager
import json
import os
from pathlib import Path
import threading
import webbrowser
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from eh2web.service import BoardService
from eh2web.remote import RemoteSettings


ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
CONFIG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))


def _frontend_version() -> str:
    """Return a new cache key whenever a shipped frontend asset changes."""

    assets = (STATIC / "index.html", STATIC / "app.js", STATIC / "styles.css")
    return str(max(path.stat().st_mtime_ns for path in assets))


FRONTEND_VERSION = _frontend_version()


class WebSocketHub:
    def __init__(self) -> None:
        self.loop: asyncio.AbstractEventLoop | None = None
        self.clients: set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self.clients.add(websocket)

    async def disconnect(self, websocket: WebSocket) -> None:
        async with self._lock:
            self.clients.discard(websocket)

    async def broadcast(self, event: dict[str, Any]) -> None:
        async with self._lock:
            clients = list(self.clients)
        dead: list[WebSocket] = []
        for client in clients:
            try:
                await client.send_json(event)
            except Exception:
                dead.append(client)
        if dead:
            async with self._lock:
                for client in dead:
                    self.clients.discard(client)

    def publish_from_worker(self, event: dict[str, Any]) -> None:
        if self.loop is not None and self.loop.is_running():
            asyncio.run_coroutine_threadsafe(self.broadcast(event), self.loop)


hub = WebSocketHub()
service = BoardService(
    ROOT,
    hub.publish_from_worker,
    max_program_bytes=int(CONFIG.get("max_program_bytes", 64 * 1024 * 1024)),
    windows_shared_root=Path(CONFIG.get("windows_shared_root", "D:/share/comp_log_dvspike")),
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    hub.loop = asyncio.get_running_loop()
    try:
        yield
    finally:
        if service.capture_running:
            service.stop_capture()
        service.automation.shutdown()


app = FastAPI(title="EH2 Board WebUI", version="1.0.0", lifespan=lifespan)


@app.middleware("http")
async def disable_frontend_cache(request, call_next):
    """Never let an old HTML document run against a newer JavaScript bundle."""

    response = await call_next(request)
    if request.url.path == "/" or request.url.path.startswith("/static/"):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        response.headers["X-EH2-WebUI-Version"] = FRONTEND_VERSION
    return response


class CaptureRequest(BaseModel):
    interface_id: str


class SendRequest(BaseModel):
    force: bool = False
    inter_frame_us: int = Field(default=0, ge=0, le=100_000)


class ProgramSendRequest(SendRequest):
    upload_id: str


class AutomationStartRequest(BaseModel):
    host: str = "192.168.88.128"
    port: int = Field(default=22, ge=1, le=65535)
    username: str = "mtw"
    password: str
    instructions_per_hart: int = Field(default=10_000, ge=1, le=100_000_000)
    chunk_instructions: int = Field(default=10_000, ge=1000, le=1_000_000)
    workers: int = Field(default=1, ge=1, le=4)


@app.get("/")
async def index() -> HTMLResponse:
    document = (STATIC / "index.html").read_text(encoding="utf-8")
    document = document.replace("__EH2_ASSET_VERSION__", FRONTEND_VERSION)
    return HTMLResponse(document)


@app.get("/api/status")
async def status() -> dict[str, Any]:
    return service.status()


@app.get("/api/interfaces")
async def interfaces() -> dict[str, Any]:
    try:
        return {"interfaces": service.list_interfaces(), "diagnostics": service.network.diagnostics()}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/api/capture/start")
async def capture_start(request: CaptureRequest) -> dict[str, Any]:
    try:
        return {"ok": True, **service.start_capture(request.interface_id)}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/capture/stop")
async def capture_stop() -> dict[str, Any]:
    service.stop_capture()
    return {"ok": True}


@app.post("/api/board/reset")
async def board_reset() -> dict[str, Any]:
    try:
        service.reset_board()
        return {"ok": True}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/program/inspect")
async def program_inspect(file: UploadFile = File(...)) -> dict[str, Any]:
    try:
        content = await file.read()
        return {"ok": True, "manifest": service.inspect_program(file.filename or "program.bin", content)}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    finally:
        await file.close()


@app.post("/api/preconfig/send")
async def preconfig_send(request: SendRequest) -> dict[str, Any]:
    try:
        service.send_preconfig(force=request.force, inter_frame_us=request.inter_frame_us)
        return {"ok": True}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/program/send")
async def program_send(request: ProgramSendRequest) -> dict[str, Any]:
    try:
        service.send_program(
            upload_id=request.upload_id,
            force=request.force,
            inter_frame_us=request.inter_frame_us,
        )
        return {"ok": True}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/end/send")
async def end_send() -> dict[str, Any]:
    try:
        service.send_end_only()
        return {"ok": True}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/logs/clear")
async def logs_clear() -> dict[str, Any]:
    service.clear_logs()
    return {"ok": True}


@app.post("/api/cache/clear")
async def cache_clear() -> dict[str, Any]:
    try:
        return {"ok": True, **service.clear_run_cache()}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/logs/save")
async def logs_save() -> dict[str, Any]:
    try:
        return {"ok": True, "file": service.save_logs()}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/automation/start")
async def automation_start(request: AutomationStartRequest) -> dict[str, Any]:
    if not service.capture_running:
        raise HTTPException(status_code=400, detail="必须先选择FPGA物理网卡并启动监听")
    try:
        settings = RemoteSettings(**request.model_dump())
        return {"ok": True, "automation": service.automation.start(settings, service.last_system_code)}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/automation/stop")
async def automation_stop() -> dict[str, Any]:
    service.automation.stop()
    return {"ok": True, "automation": service.automation.status()}


@app.get("/api/golden")
async def golden() -> dict[str, Any]:
    return service.golden_document()


@app.get("/api/session/files")
async def session_files() -> dict[str, Any]:
    return {"files": service.recorder.files()}


@app.get("/api/session/download/{name}")
async def session_download(name: str) -> FileResponse:
    try:
        path = service.recorder.resolve_current_file(name)
        return FileResponse(path, filename=path.name)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/api/session/view/{name}")
async def session_view(name: str) -> FileResponse:
    try:
        path = service.recorder.resolve_current_file(name)
        return FileResponse(path, media_type="text/plain; charset=utf-8")
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/api/automation/view/{name}")
async def automation_view(name: str) -> FileResponse:
    try:
        path = service.automation.resolve_current_file(name)
        return FileResponse(path, media_type="text/plain; charset=utf-8")
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await hub.connect(websocket)
    await websocket.send_json({"type": "snapshot", "data": service.status()})
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        await hub.disconnect(websocket)
    except Exception:
        await hub.disconnect(websocket)


app.mount("/static", StaticFiles(directory=STATIC), name="static")


def main() -> None:
    parser = argparse.ArgumentParser(description="EH2 Board WebUI")
    parser.add_argument("--no-browser", action="store_true", help="do not open the browser automatically")
    args = parser.parse_args()
    host = str(os.environ.get("EH2_WEB_HOST", CONFIG.get("http_host", "127.0.0.1")))
    port = int(os.environ.get("EH2_WEB_PORT", CONFIG.get("http_port", 3205)))
    no_browser = args.no_browser or os.environ.get("EH2_WEB_NO_BROWSER") == "1"
    if not no_browser:
        url = f"http://127.0.0.1:{port}/?v={FRONTEND_VERSION}"
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    import uvicorn

    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
