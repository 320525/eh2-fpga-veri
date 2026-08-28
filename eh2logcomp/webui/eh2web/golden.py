"""Verified 200k-program image reference used by the WebUI."""

from __future__ import annotations

import json
from pathlib import Path
class ProgramReference:
    def __init__(self, path: Path):
        self.path = path
        self.document = json.loads(path.read_text(encoding="utf-8"))
