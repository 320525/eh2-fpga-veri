"""Golden result loading and per-package comparison."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


COMPARE_FIELDS = (
    "count", "xor0", "xor1", "sum0", "sum1", "sum2", "sum3",
    "waw_count", "waw_sequences",
)


class GoldenResults:
    def __init__(self, path: Path):
        self.path = path
        self.document = json.loads(path.read_text(encoding="utf-8"))
        self.packages = {
            (int(item["hart"]), int(item["package"])): item
            for item in self.document.get("packages", [])
        }

    def compare(self, decoded: dict[str, Any]) -> dict[str, Any]:
        key = (int(decoded["hart_id"]), int(decoded["package_number"]))
        expected = self.packages.get(key)
        if expected is None:
            return {"status": "NO_GOLDEN", "mismatches": ["未找到对应hart/package黄金值"]}

        mismatches: list[str] = []
        for field in COMPARE_FIELDS:
            default_value = 0 if field == "waw_count" else ([] if field == "waw_sequences" else None)
            expected_value = expected.get(field, default_value)
            actual_value = decoded.get(field)
            if field not in ("count", "waw_count", "waw_sequences"):
                expected_value = str(expected_value).lower()
                actual_value = str(actual_value).lower()
            if actual_value != expected_value:
                mismatches.append(f"{field}: 实际={actual_value} 黄金={expected_value}")
        return {
            "status": "PASS" if not mismatches else "FAIL",
            "mismatches": mismatches,
            "expected": expected,
        }
