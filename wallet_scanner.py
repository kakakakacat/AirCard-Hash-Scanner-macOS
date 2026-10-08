#!/usr/bin/env python3
"""Device detection and Wallet cover writer used by the macOS application.

Card discovery is intentionally implemented in Swift via the read-only unified
device log stream. This module never reads protected Wallet metadata.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from apply_card_skin import (
    DEVICE_HELPER,
    remove_files,
    write_file,
    write_files_batch,
)
from card_assets import CACHE_FILES, build_card_assets

CARD_ID = re.compile(r"^[A-Za-z0-9+_-]{27}=$")


def _last_json_line(output: str):
    for line in reversed(output.splitlines()):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return None


def list_devices() -> list[dict]:
    if not DEVICE_HELPER.is_file() or not os.access(DEVICE_HELPER, os.X_OK):
        return []
    try:
        completed = subprocess.run(
            [os.fspath(DEVICE_HELPER), "list"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    value = _last_json_line(completed.stdout)
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


def connected_iphone() -> dict | None:
    usable = [item for item in list_devices() if item.get("udid") and item.get("product")]
    phones = [item for item in usable if str(item.get("product", "")).startswith("iPhone")]
    return (phones or usable or [None])[0]


def device_response() -> dict:
    device = connected_iphone()
    if not device:
        return {"connected": False, "error": "no_trusted_iphone"}
    return {
        "connected": True,
        "udid": device.get("udid"),
        "name": device.get("name") or "iPhone",
        "version": device.get("version") or "Unknown",
        "product": device.get("product") or "iPhone",
        "error": None,
    }


def normalize_hash(raw: object) -> str | None:
    if not isinstance(raw, str):
        return None
    value = raw.strip().strip("'\",()<>;[]{}")
    for suffix in (".pkpass", ".cache", ".pkcache"):
        if value.endswith(suffix):
            value = value[: -len(suffix)]
    return value if CARD_ID.fullmatch(value) else None


def progress_writer(path: Path | None):
    def write(value: float) -> None:
        if path is not None:
            path.write_text(f"{max(0.0, min(1.0, value)):.2f}", encoding="utf-8")
    return write


def flash_cover(udid: str, card_hash: str, image_path: Path, report_progress=None) -> dict:
    """Apply one cover using the original Mac three-asset write behavior."""
    report = report_progress or (lambda _value: None)
    if normalize_hash(card_hash) != card_hash:
        return {"ok": False, "error": "Invalid Wallet card hash."}
    if not image_path.is_file():
        return {"ok": False, "error": "Artwork file was not found."}

    try:
        report(0.08)
        with tempfile.TemporaryDirectory(prefix="aircard-cover-") as temporary:
            prepared = Path(temporary) / "cover.png"
            subprocess.run(
                ["/usr/bin/sips", "-s", "format", "png", "-z", "969", "1536",
                 str(image_path), "--out", str(prepared)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            assets = build_card_assets(prepared.read_bytes())
        report(0.22)
    except (OSError, subprocess.SubprocessError) as error:
        return {"ok": False, "error": f"Unable to prepare artwork: {error}"}

    pass_directory = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    report(0.28)
    wrote = write_files_batch(udid, pass_directory, list(assets), retries=3)
    if not wrote:
        wrote = all(
            write_file(udid, pass_directory, leaf, payload, retries=3)
            for leaf, payload in assets
        )
    if not wrote:
        return {"ok": False, "error": "Unable to write the three Wallet artwork files."}
    report(0.72)

    cache_ok = True
    for index, suffix in enumerate((".cache", ".pkcache")):
        cache_directory = f"/var/mobile/Library/Passes/Cards/{card_hash}{suffix}"
        cache_ok = remove_files(
            udid, cache_directory, list(CACHE_FILES), retries=3
        ) and cache_ok
        report(0.84 if index == 0 else 0.96)
    if not cache_ok:
        return {
            "ok": False,
            "error": "Artwork was written, but one or more rendered Wallet caches could not be removed.",
        }
    report(1.0)
    return {"ok": True, "error": None}


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "--device":
        print(json.dumps(device_response(), ensure_ascii=False))
        return 0
    if command == "--flash" and len(sys.argv) in (4, 6):
        progress_path = (
            Path(sys.argv[5])
            if len(sys.argv) == 6 and sys.argv[4] == "--progress-file"
            else None
        )
        report = progress_writer(progress_path)
        report(0.03)
        device = connected_iphone()
        if not device:
            print(json.dumps({"ok": False, "error": "No trusted iPhone found."}))
            return 0
        report(0.05)
        result = flash_cover(
            str(device["udid"]), sys.argv[2], Path(sys.argv[3]), report
        )
        print(json.dumps(result, ensure_ascii=False))
        return 0
    print(json.dumps({"ok": False, "error": "Use --device or --flash."}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
