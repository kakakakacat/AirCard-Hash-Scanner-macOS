#!/usr/bin/env python3
"""Minimal AirTraffic read primitive with immediate source-file restoration."""

from __future__ import annotations

import io
import json
import os
import plistlib
import posixpath
import secrets
import stat
import struct
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEVICE_HELPER = ROOT / "bin" / "device_helper" if (ROOT / "bin" / "device_helper").is_file() else ROOT / "build" / "device_helper"
AIRTRAFFIC_HOST = ROOT / "bin" / "airtraffic_host" if (ROOT / "bin" / "airtraffic_host").is_file() else ROOT / "build" / "airtraffic_host"
AIRLOCK_ROOT = "/var/mobile/Media/Airlock/Book"
SOURCE_PREFIX = "airlift-src-"
LINK_PREFIX = "airlift-link-"
RECOVERED_PREFIX = "airlift-recovered-"
SZ_EXTRA_ID = 0x5A53


def zip_info(name: str, mode: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(2026, 9, 14, 5, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = (mode & 0xFFFF) << 16
    info.extra = struct.pack("<HHH", SZ_EXTRA_ID, 2, mode & 0xFFFF)
    return info


def build_archive(target: str, payload: bytes) -> bytes:
    target_tail = target[1:]
    metadata = plistlib.dumps({"Version": 2}, fmt=plistlib.FMT_BINARY, sort_keys=True)
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", allowZip64=False) as archive:
        archive.writestr(zip_info("META-INF/", stat.S_IFDIR | 0o755), b"")
        archive.writestr(
            zip_info("META-INF/com.apple.ZipMetadata.plist", stat.S_IFREG | 0o600),
            metadata,
        )
        for directory in ("p0/", "p0/p1/", "p0/p1/p2/"):
            archive.writestr(zip_info(directory, stat.S_IFDIR | 0o755), b"")
        archive.writestr(
            zip_info("p0/p1/p2/link", stat.S_IFLNK | 0o777),
            f"../../../{target_tail}".encode(),
        )
        cursor = ""
        for component in target_tail.split("/"):
            cursor += component + "/"
            archive.writestr(zip_info(cursor, stat.S_IFDIR | 0o755), b"")
        archive.writestr(zip_info("payload", stat.S_IFREG | 0o600), payload)
    return output.getvalue()


def build_books(identifiers: list[str]) -> bytes:
    rows = [
        {"Persistent ID": identifier, "Item ID": str(index), "DSID": "1"}
        for index, identifier in enumerate(identifiers, 1)
    ]
    return plistlib.dumps({"Books": rows}, fmt=plistlib.FMT_BINARY, sort_keys=True)


def run_json(command: list[str], timeout: int) -> dict:
    completed = subprocess.run(
        command, check=False, capture_output=True, text=True, timeout=timeout
    )
    for line in reversed(completed.stdout.splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            value["exitCode"] = completed.returncode
            return value
    raise RuntimeError(f"{Path(command[0]).name} failed: {completed.stderr}")


def native(command: str, udid: str, *arguments: str) -> dict:
    return run_json([os.fspath(DEVICE_HELPER), command, udid, *arguments], timeout=60)


def operation_ok(result: dict) -> bool:
    return bool(
        result.get("exitCode") == 0
        and result.get("targetGatePassed")
        and result.get("operation", {}).get("ok")
    )


def write_file(udid: str, target: str, leaf: str, payload: bytes, retries: int = 3) -> bool:
    """Restore one file through the same AirTraffic primitive used for reading."""
    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"
            identifiers = [
                f"../../{source}/p0/p1/p2/link",
                f"../../{source}/payload",
            ]
            destinations = [link_destination, posixpath.join(link_destination, leaf)]

            with tempfile.TemporaryDirectory(prefix="airlift-restore-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()
                archive_path.write_bytes(build_archive(target, payload))
                books_path.write_bytes(build_books(identifiers))

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    raise RuntimeError("could not snapshot Books state")
                stage = native(
                    "stage", udid, source, link_destination, recovered,
                    os.fspath(archive_path), os.fspath(books_path), os.fspath(snapshot_root),
                )
                if not operation_ok(stage):
                    raise RuntimeError("could not stage source restoration")

                command = [os.fspath(AIRTRAFFIC_HOST), udid]
                for identifier, destination in zip(identifiers, destinations):
                    command.extend((identifier, destination))
                airtraffic = run_json(command, timeout=120)
                finish = native(
                    "finish-write", udid, source, link_destination, recovered,
                    os.fspath(snapshot_root),
                )
            if airtraffic.get("exitCode") == 0 and airtraffic.get("ok") and operation_ok(finish):
                return True
        except Exception:
            pass
        if attempt < retries:
            time.sleep(0.3 * attempt)
    return False


def read_file(udid: str, target: str, leaf: str, retries: int = 1) -> bytes | None:
    """Move one protected file to AFC, copy it, then restore it immediately."""
    if "/" in leaf or leaf in ("", ".", ".."):
        raise ValueError("leaf must be a plain file name")
    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"
            link_identifier = f"../../{source}/p0/p1/p2/link"
            target_path = posixpath.join(target, leaf)
            target_identifier = posixpath.relpath(target_path, AIRLOCK_ROOT)
            identifiers = [link_identifier, target_identifier]
            destinations = [link_destination, recovered]

            with tempfile.TemporaryDirectory(prefix="airlift-read-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                local_output = work / "recovered.bin"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()
                archive_path.write_bytes(build_archive(target, b"aircard-read-staging"))
                books_path.write_bytes(build_books(identifiers))

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    raise RuntimeError("could not snapshot Books state")
                stage = native(
                    "stage", udid, source, link_destination, recovered,
                    os.fspath(archive_path), os.fspath(books_path), os.fspath(snapshot_root),
                )
                if not operation_ok(stage):
                    native("finish-write", udid, source, link_destination, recovered,
                           os.fspath(snapshot_root))
                    raise RuntimeError("could not stage protected-file read")

                command = [os.fspath(AIRTRAFFIC_HOST), udid]
                for identifier, destination in zip(identifiers, destinations):
                    command.extend((identifier, destination))
                airtraffic = run_json(command, timeout=120)
                if airtraffic.get("exitCode") != 0 or not airtraffic.get("ok"):
                    native("finish-write", udid, source, link_destination, recovered,
                           os.fspath(snapshot_root))
                    raise RuntimeError("AirTraffic read failed")

                copied = native("afc-read", udid, recovered, os.fspath(local_output))
                if not operation_ok(copied) or not local_output.is_file():
                    # Keep the recovered file in Media; cleanup here could destroy the only copy.
                    return None
                data = local_output.read_bytes()
                restored = write_file(udid, target, leaf, data, retries=3)
                finish = native(
                    "finish-write", udid, source, link_destination, recovered,
                    os.fspath(snapshot_root),
                )
                if restored and operation_ok(finish):
                    return data
                if data:
                    return data
        except Exception:
            pass
        if attempt < retries:
            time.sleep(0.3 * attempt)
    return None
