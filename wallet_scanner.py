#!/usr/bin/env python3
"""USB Wallet metadata reader used by the minimal macOS application."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

from apply_card_skin import (
    DEVICE_HELPER,
    read_file,
    remove_files,
    write_file,
    write_files_batch,
)
from card_assets import CACHE_FILES, build_card_assets

PASSES_DIRECTORY = "/var/mobile/Library/Passes"
DATABASE_NAME = "passes23.sqlite"
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


def read_cards(database_path: Path) -> list[dict]:
    uri = f"file:{database_path}?mode=ro"
    database = sqlite3.connect(uri, uri=True)
    try:
        columns = {
            str(row[1]).upper()
            for row in database.execute("PRAGMA table_info(PASS)")
        }
        if not columns or "UNIQUE_ID" not in columns:
            raise RuntimeError("Wallet PASS table or UNIQUE_ID column is missing")
        organization = "ORGANIZATION_NAME" if "ORGANIZATION_NAME" in columns else "NULL"
        localized = "LOCALIZED_DESCRIPTION" if "LOCALIZED_DESCRIPTION" in columns else "NULL"
        serial = "SERIAL_NUMBER" if "SERIAL_NUMBER" in columns else "NULL"
        query = (
            f"SELECT UNIQUE_ID, {organization}, {localized}, {serial} "
            "FROM PASS WHERE UNIQUE_ID IS NOT NULL"
        )
        cards: list[dict] = []
        seen: set[str] = set()
        for unique_id, organization_name, localized_name, _serial in database.execute(query):
            card_hash = normalize_hash(unique_id)
            if not card_hash or card_hash in seen:
                continue
            seen.add(card_hash)
            names = [organization_name, localized_name]
            name = next(
                (item.strip() for item in names if isinstance(item, str) and item.strip()),
                None,
            )
            cards.append({"hash": card_hash, "name": name})
        return cards
    finally:
        database.close()


def scan_wallet(udid: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="aircard-wallet-scan-") as temporary:
        directory = Path(temporary)
        database_path = directory / DATABASE_NAME
        database_bytes = read_file(udid, PASSES_DIRECTORY, DATABASE_NAME, retries=1)
        if not database_bytes:
            return {"ok": False, "cards": [], "error": "Unable to read Wallet database."}
        database_path.write_bytes(database_bytes)

        try:
            cards = read_cards(database_path)
        except sqlite3.DatabaseError:
            # A live SQLite database may need its WAL/SHM sidecars for a consistent read.
            for suffix in ("-wal", "-shm"):
                data = read_file(udid, PASSES_DIRECTORY, DATABASE_NAME + suffix, retries=1)
                if data:
                    (directory / (DATABASE_NAME + suffix)).write_bytes(data)
            try:
                cards = read_cards(database_path)
            except (sqlite3.DatabaseError, RuntimeError) as error:
                return {"ok": False, "cards": [], "error": str(error)}
        except RuntimeError as error:
            return {"ok": False, "cards": [], "error": str(error)}

        if not cards:
            return {"ok": False, "cards": [], "error": "No Wallet card hashes were found."}
        return {"ok": True, "cards": cards, "error": None}


def flash_cover(udid: str, card_hash: str, image_path: Path) -> dict:
    """Apply one cover using the original Mac three-asset write behavior."""
    if normalize_hash(card_hash) != card_hash:
        return {"ok": False, "error": "Invalid Wallet card hash."}
    if not image_path.is_file():
        return {"ok": False, "error": "Artwork file was not found."}

    try:
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
    except (OSError, subprocess.SubprocessError) as error:
        return {"ok": False, "error": f"Unable to prepare artwork: {error}"}

    pass_directory = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    wrote = write_files_batch(udid, pass_directory, list(assets), retries=3)
    if not wrote:
        wrote = all(
            write_file(udid, pass_directory, leaf, payload, retries=3)
            for leaf, payload in assets
        )
    if not wrote:
        return {"ok": False, "error": "Unable to write the three Wallet artwork files."}

    cache_ok = True
    for suffix in (".cache", ".pkcache"):
        cache_directory = f"/var/mobile/Library/Passes/Cards/{card_hash}{suffix}"
        cache_ok = remove_files(
            udid, cache_directory, list(CACHE_FILES), retries=3
        ) and cache_ok
    if not cache_ok:
        return {
            "ok": False,
            "error": "Artwork was written, but one or more rendered Wallet caches could not be removed.",
        }
    return {"ok": True, "error": None}


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "--device":
        print(json.dumps(device_response(), ensure_ascii=False))
        return 0
    if command == "--scan":
        device = connected_iphone()
        if not device:
            print(json.dumps({"ok": False, "cards": [], "error": "No trusted iPhone found."}))
            return 0
        result = scan_wallet(str(device["udid"]))
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if command == "--flash" and len(sys.argv) == 4:
        device = connected_iphone()
        if not device:
            print(json.dumps({"ok": False, "error": "No trusted iPhone found."}))
            return 0
        result = flash_cover(str(device["udid"]), sys.argv[2], Path(sys.argv[3]))
        print(json.dumps(result, ensure_ascii=False))
        return 0
    print(json.dumps({"ok": False, "error": "Use --device, --scan or --flash."}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
