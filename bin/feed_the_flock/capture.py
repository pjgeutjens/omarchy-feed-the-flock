from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path

from .common import CAPTURE_DIR, ENTRYPOINT, LOG_PATH, VOXTYPE
from .store import (
    active_bucket,
    active_section,
    add_note_to_db,
    connect,
    normalized_phase,
    set_phase,
    set_setting,
    setting,
    unsorted_section_id,
)


def voxtype_class() -> str:
    try:
        result = subprocess.run(
            [VOXTYPE, "status", "--extended", "--format", "json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return str(json.loads(result.stdout or "{}").get("class", ""))
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return ""


def record_start(_: argparse.Namespace) -> None:
    with connect() as db:
        if normalized_phase(db) in {"recording", "transcribing"}:
            raise SystemExit("feed-the-flock: a capture is already active")
        if voxtype_class() != "idle":
            raise SystemExit("feed-the-flock: Voxtype is not ready")
        CAPTURE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        capture = CAPTURE_DIR / f"capture.{uuid.uuid4().hex}.txt"
        capture.touch(mode=0o600)
        bucket_id = active_bucket(db)
        section_id = active_section(db, bucket_id)
        metadata = {"path": str(capture), "bucketId": bucket_id, "sectionId": section_id}
        set_setting(db, "active_capture", json.dumps(metadata))
        set_phase(db, "recording")
        result = subprocess.run([VOXTYPE, "record", "start", f"--file={capture}"], check=False)
        if result.returncode != 0:
            set_setting(db, "active_capture", "")
            set_phase(db, "error", "Voxtype could not start recording.")
            capture.unlink(missing_ok=True)
            raise SystemExit(result.returncode)


def load_capture(db: sqlite3.Connection) -> dict[str, str]:
    try:
        value = json.loads(setting(db, "active_capture"))
    except json.JSONDecodeError as error:
        raise SystemExit("feed-the-flock: capture state is invalid") from error
    path = Path(str(value.get("path", "")))
    try:
        path.relative_to(CAPTURE_DIR)
    except ValueError as error:
        raise SystemExit("feed-the-flock: capture path is unsafe") from error
    if not path.name.startswith("capture.") or path.suffix != ".txt":
        raise SystemExit("feed-the-flock: capture path is unsafe")
    return {
        "path": str(path),
        "bucketId": str(value.get("bucketId", "inbox")),
        "sectionId": str(value.get("sectionId", "")),
    }


def record_stop(_: argparse.Namespace) -> None:
    with connect() as db:
        if normalized_phase(db) != "recording":
            raise SystemExit("feed-the-flock: no recording is active")
        capture = load_capture(db)
        result = subprocess.run([VOXTYPE, "record", "stop"], check=False)
        if result.returncode != 0:
            set_phase(db, "error", "Voxtype could not stop recording.")
            raise SystemExit(result.returncode)
        set_phase(db, "transcribing")
        db.commit()

    LOG_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    log = LOG_PATH.open("ab")
    subprocess.Popen(
        [
            sys.executable, str(ENTRYPOINT), "_finalize",
            capture["path"], capture["bucketId"], capture["sectionId"],
        ],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
        close_fds=True,
    )
    log.close()


def record_cancel(_: argparse.Namespace) -> None:
    with connect() as db:
        if normalized_phase(db) != "recording":
            raise SystemExit("feed-the-flock: no recording is active")
        capture = load_capture(db)
        subprocess.run([VOXTYPE, "record", "cancel"], check=False)
        Path(capture["path"]).unlink(missing_ok=True)
        set_setting(db, "active_capture", "")
        set_phase(db, "cancelled")


def finalize(args: argparse.Namespace) -> None:
    capture = Path(args.capture).resolve()
    try:
        capture.relative_to(CAPTURE_DIR.resolve())
    except ValueError:
        raise SystemExit("feed-the-flock: unsafe finalizer capture path")

    idle_since: float | None = None
    for _ in range(480):
        status = voxtype_class()
        if status == "idle":
            if capture.exists() and capture.stat().st_size > 0:
                text = capture.read_text(encoding="utf-8", errors="replace").strip()
                if text:
                    with connect() as db:
                        section_exists = db.execute(
                            "SELECT 1 FROM sections WHERE id = ? AND bucket_id = ?",
                            (args.section_id, args.bucket_id),
                        ).fetchone()
                        destination = args.section_id if section_exists else unsorted_section_id(args.bucket_id)
                        add_note_to_db(db, args.bucket_id, text, destination)
                        set_setting(db, "active_capture", "")
                        set_phase(db, "success")
                    capture.unlink(missing_ok=True)
                    return
            idle_since = idle_since or time.monotonic()
            if time.monotonic() - idle_since >= 1:
                with connect() as db:
                    set_setting(db, "active_capture", "")
                    set_phase(db, "cancelled")
                capture.unlink(missing_ok=True)
                return
        else:
            idle_since = None
        time.sleep(0.25)

    with connect() as db:
        set_setting(db, "active_capture", "")
        set_phase(db, "error", f"No completed transcription arrived. Capture retained at {capture}")

