"""SSH deployment/launch support for the VM-side riscv-dv/Spike worker."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import shlex
from typing import Any


@dataclass(frozen=True)
class RemoteSettings:
    host: str = "192.168.88.128"
    port: int = 22
    username: str = "mtw"
    password: str = ""
    instructions_per_hart: int = 10_000
    chunk_instructions: int = 10_000
    workers: int = 1


class RemoteJob:
    GUEST_HELPER = "/home/mtw/.cache/eh2logcomp_automation/webui_helper"
    GUEST_SHARED = "/mnt/hgfs/share/comp_log_dvspike"

    def __init__(self, webui_root: Path, windows_shared_root: Path):
        self.webui_root = webui_root.resolve()
        self.windows_shared_root = windows_shared_root.resolve()
        self.helper_source = self.webui_root / "vm_tools"

    @staticmethod
    def _client(settings: RemoteSettings):
        try:
            import paramiko  # type: ignore
        except Exception as exc:
            raise RuntimeError("缺少Paramiko；请重新运行install.ps1安装自动化依赖") from exc
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            settings.host,
            port=settings.port,
            username=settings.username,
            password=settings.password,
            timeout=10,
            banner_timeout=10,
            auth_timeout=10,
        )
        return client

    @staticmethod
    def _exec(client: Any, command: str, timeout: int = 30) -> str:
        _, stdout, stderr = client.exec_command(command, timeout=timeout)
        output = stdout.read().decode("utf-8", errors="replace")
        error = stderr.read().decode("utf-8", errors="replace")
        code = stdout.channel.recv_exit_status()
        if code:
            raise RuntimeError(f"VM命令失败({code}): {error.strip() or output.strip()}")
        return output

    def deploy_and_launch(self, settings: RemoteSettings, run_id: str, seed: int) -> int:
        required = ["remote_runner.py", "automation_testlist.yaml", "link.ld"]
        missing = [name for name in required if not (self.helper_source / name).is_file()]
        if missing:
            raise RuntimeError(f"VM helper files missing: {missing}")
        self.windows_shared_root.mkdir(parents=True, exist_ok=True)
        run_windows = self.windows_shared_root / "runs" / run_id
        run_windows.mkdir(parents=True, exist_ok=False)

        client = self._client(settings)
        try:
            self._exec(client, f"mkdir -p {shlex.quote(self.GUEST_HELPER)}", timeout=20)
            sftp = client.open_sftp()
            try:
                for name in required:
                    sftp.put(str(self.helper_source / name), f"{self.GUEST_HELPER}/{name}")
            finally:
                sftp.close()
            guest_run = f"{self.GUEST_SHARED}/runs/{run_id}"
            # A VM resumed from an old snapshot can retain a stale HGFS
            # directory enumeration even though Windows has just created the
            # run directory.  Issuing mkdir through the guest path is
            # idempotent and forces vmhgfs-fuse to resolve that exact entry.
            self._exec(client, f"mkdir -p {shlex.quote(guest_run)}", timeout=20)
            console = f"{guest_run}/remote_runner_console.log"
            command = [
                "python3", f"{self.GUEST_HELPER}/remote_runner.py",
                "--run-dir", guest_run,
                "--seed", str(seed),
                "--instructions-per-hart", str(settings.instructions_per_hart),
                "--chunk-instructions", str(settings.chunk_instructions),
                "--workers", str(settings.workers),
            ]
            shell_command = " ".join(shlex.quote(item) for item in command)
            launch = (
                f"nohup {shell_command} > {shlex.quote(console)} 2>&1 < /dev/null & echo $!"
            )
            result = self._exec(client, launch, timeout=20).strip().splitlines()
            if not result or not result[-1].isdigit():
                raise RuntimeError(f"VM worker did not return a PID: {result}")
            return int(result[-1])
        except Exception:
            # An empty directory is safe to leave as evidence of a failed launch.
            raise
        finally:
            client.close()

    def read_status(self, run_id: str) -> dict[str, Any] | None:
        path = self.windows_shared_root / "runs" / run_id / "status.json"
        if not path.is_file():
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None

    def run_path(self, run_id: str, name: str = "") -> Path:
        root = (self.windows_shared_root / "runs" / run_id).resolve()
        if root.parent != (self.windows_shared_root / "runs").resolve():
            raise ValueError("invalid run id")
        return root / name if name else root

    def request_cancel(self, run_id: str) -> None:
        run = self.run_path(run_id)
        if run.is_dir():
            (run / "cancel.request").write_text("cancelled by Windows WebUI\n", encoding="ascii")
