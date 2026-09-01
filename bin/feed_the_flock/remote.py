from __future__ import annotations

import argparse
import json
import re
import shlex
import sqlite3
from pathlib import Path

from .common import DB_PATH, run_bounded
from .store import active_bucket, active_section, connect, set_setting, setting

REMOTE_PLUGIN_COMMAND = "$HOME/.config/omarchy/plugins/io.github.pjgeutjens.agentfeed/bin/feed-the-flock"
ENDPOINT_PATTERN = re.compile(r"(?:[A-Za-z0-9][A-Za-z0-9._-]{0,63}@)?[A-Za-z0-9][A-Za-z0-9._-]{0,252}")
ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9:._-]{0,127}")


def validate_endpoint(value: str) -> str:
    endpoint = value.strip()
    if not ENDPOINT_PATTERN.fullmatch(endpoint):
        raise ValueError("endpoint must be an SSH hostname, IP, alias, or user@host")
    return endpoint


def remote_mode(db: sqlite3.Connection) -> tuple[bool, str]:
    endpoint = setting(db, "remote_endpoint", "")
    return setting(db, "remote_mode", "0") == "1" and bool(endpoint), endpoint


def remote_mode_readonly() -> bool:
    try:
        db = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return False
    try:
        row = db.execute("SELECT value FROM settings WHERE key = 'remote_mode'").fetchone()
        return bool(row and row[0] == "1")
    finally:
        db.close()


def remote_request(endpoint: str, arguments: list[str], *, limit: int = 12 * 1024 * 1024) -> object:
    endpoint = validate_endpoint(endpoint)
    for argument in arguments:
        if argument not in {"_remote-state", "_remote-workspace", "--bucket", "--section", "buckets", "bucket"} \
                and not ID_PATTERN.fullmatch(argument):
            raise ValueError("remote query contains an invalid identifier")
    remote_command = "exec " + REMOTE_PLUGIN_COMMAND + " " + " ".join(shlex.quote(argument) for argument in arguments)
    result = run_bounded(
        [
            "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1", "--", endpoint, remote_command,
        ],
        timeout=8, stdout_limit=limit, stderr_limit=64 * 1024,
    )
    if result.returncode != 0:
        message = result.stderr.decode(errors="replace").strip()
        raise ValueError(message[:300] or "remote Feed the Flock endpoint is unavailable")
    try:
        return json.loads(result.stdout.decode(errors="replace"))
    except json.JSONDecodeError as error:
        raise ValueError("remote Feed the Flock returned invalid data") from error


def _plain(value: object, maximum: int, *, multiline: bool = False) -> str:
    pattern = r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]" if multiline else r"[\x00-\x1f\x7f]"
    text = re.sub(pattern, "", str(value))
    return text[:maximum] if multiline else text.replace("<", "‹").replace(">", "›")[:maximum]


def _safe_id(value: object) -> str:
    identifier = str(value)
    if not ID_PATTERN.fullmatch(identifier):
        raise ValueError("remote feeder returned an invalid identifier")
    return identifier


def _sanitize_remote_state(value: dict[str, object]) -> None:
    raw_buckets = value.get("buckets", [])
    raw_sections = value.get("sections", [])
    raw_notes = value.get("notes", [])
    if not isinstance(raw_buckets, list) or len(raw_buckets) > 100 \
            or not isinstance(raw_sections, list) or len(raw_sections) > 200 \
            or not isinstance(raw_notes, list) or len(raw_notes) > 200:
        raise ValueError("remote feeder state exceeds the record limit")
    buckets: list[dict[str, object]] = []
    for item in raw_buckets:
        if not isinstance(item, dict):
            raise ValueError("remote feeder returned invalid bucket data")
        buckets.append({
            **item, "id": _safe_id(item.get("id", "")),
            "name": _plain(item.get("name", ""), 80),
        })
    sections: list[dict[str, object]] = []
    for item in raw_sections:
        if not isinstance(item, dict):
            raise ValueError("remote feeder returned invalid section data")
        sections.append({
            **item, "id": _safe_id(item.get("id", "")),
            "name": _plain(item.get("name", ""), 80),
        })
    notes: list[dict[str, object]] = []
    for item in raw_notes:
        if not isinstance(item, dict):
            raise ValueError("remote feeder returned invalid note data")
        notes.append({
            **item, "id": _safe_id(item.get("id", "")),
            "sectionId": _safe_id(item.get("sectionId", "")),
            "text": _plain(item.get("text", ""), 65536, multiline=True),
        })
    value["buckets"], value["sections"], value["notes"] = buckets, sections, notes
    for key in (
        "activeBucketId", "activeSectionId", "feedBucketId", "feedSectionId",
        "nextFeedBucketId", "nextFeedSectionId",
    ):
        raw = str(value.get(key, ""))
        value[key] = _safe_id(raw) if raw else ""
    for key in (
        "error", "captureBucketName", "captureSectionName", "feedBucketName",
        "feedSectionName", "nextFeedBucketName", "nextFeedSectionName",
    ):
        value[key] = _plain(value.get(key, ""), 160)


def remote_state(endpoint: str, bucket_id: str = "", section_id: str = "") -> dict[str, object]:
    arguments = ["_remote-state"]
    if bucket_id:
        arguments.extend(["--bucket", bucket_id])
    if section_id:
        arguments.extend(["--section", section_id])
    value = remote_request(endpoint, arguments)
    if not isinstance(value, dict) or not isinstance(value.get("buckets"), list):
        raise ValueError("remote state has an unexpected shape")
    _sanitize_remote_state(value)
    value["remoteMode"] = True
    value["remoteEndpoint"] = endpoint
    value["readOnly"] = True
    return value


def connect_remote(args: argparse.Namespace) -> None:
    endpoint = validate_endpoint(args.endpoint)
    value = remote_state(endpoint)
    buckets = value.get("buckets", [])
    bucket_id = str(value.get("activeBucketId", ""))
    section_id = str(value.get("activeSectionId", ""))
    if not buckets:
        raise ValueError("remote Feed the Flock has no visible buckets")
    with connect() as db:
        if setting(db, "feed_enabled", "0") == "1":
            raise ValueError("stop the local feed before connecting to a remote feeder")
        if setting(db, "phase", "idle") in {"recording", "transcribing"}:
            raise ValueError("finish the local capture before connecting to a remote feeder")
        set_setting(db, "remote_endpoint", endpoint)
        set_setting(db, "remote_mode", "1")
        set_setting(db, "remote_bucket", bucket_id)
        set_setting(db, "remote_section", section_id)
        db.commit()
    print(json.dumps({"endpoint": endpoint, "bucketId": bucket_id, "sectionId": section_id}))


def disconnect_remote(_: argparse.Namespace) -> None:
    with connect() as db:
        set_setting(db, "remote_mode", "0")
        db.commit()


def select_remote_bucket(args: argparse.Namespace) -> None:
    with connect() as db:
        enabled, endpoint = remote_mode(db)
        if not enabled:
            raise ValueError("remote mode is not connected")
    value = remote_state(endpoint, args.bucket_id)
    with connect() as db:
        set_setting(db, "remote_bucket", str(value.get("activeBucketId", "")))
        set_setting(db, "remote_section", str(value.get("activeSectionId", "")))
        db.commit()


def select_remote_section(args: argparse.Namespace) -> None:
    with connect() as db:
        enabled, endpoint = remote_mode(db)
        bucket_id = setting(db, "remote_bucket", "")
        if not enabled:
            raise ValueError("remote mode is not connected")
    value = remote_state(endpoint, bucket_id, args.section_id)
    with connect() as db:
        set_setting(db, "remote_section", str(value.get("activeSectionId", "")))
        db.commit()


def proxied_state_command(_: argparse.Namespace) -> bool:
    with connect() as db:
        enabled, endpoint = remote_mode(db)
        bucket_id = setting(db, "remote_bucket", "")
        section_id = setting(db, "remote_section", "")
    if not enabled:
        return False
    value = remote_state(endpoint, bucket_id, section_id)
    print(json.dumps(value, ensure_ascii=False))
    return True


def remote_workspace_payload(kind: str, identifier: str = "") -> object:
    with connect() as db:
        enabled, endpoint = remote_mode(db)
    if not enabled:
        raise ValueError("remote mode is not connected")
    arguments = ["_remote-workspace", kind]
    if identifier:
        arguments.append(identifier)
    value = remote_request(endpoint, arguments)
    if not isinstance(value, dict):
        raise ValueError("remote workspace returned invalid data")
    if kind == "buckets":
        raw_buckets = value.get("buckets", [])
        if not isinstance(raw_buckets, list) or len(raw_buckets) > 100:
            raise ValueError("remote workspace returned too many buckets")
        value["buckets"] = [
            {
                **bucket, "id": _safe_id(bucket.get("id", "")),
                "name": _plain(bucket.get("name", ""), 80),
            }
            for bucket in raw_buckets if isinstance(bucket, dict)
        ]
        if len(value["buckets"]) != len(raw_buckets):
            raise ValueError("remote workspace returned invalid bucket data")
    else:
        sections = value.get("sections", [])
        if not isinstance(sections, list) or len(sections) > 200:
            raise ValueError("remote workspace returned too many sections")
        note_count = 0
        for section in sections:
            if not isinstance(section, dict):
                raise ValueError("remote workspace returned invalid section data")
            section["id"] = _safe_id(section.get("id", ""))
            section["name"] = _plain(section.get("name", ""), 80)
            notes = section.get("notes", [])
            if not isinstance(notes, list):
                raise ValueError("remote workspace returned invalid note data")
            note_count += len(notes)
            if note_count > 20_000:
                raise ValueError("remote workspace returned too many notes")
            for note in notes:
                if not isinstance(note, dict):
                    raise ValueError("remote workspace returned invalid note data")
                note["id"] = _safe_id(note.get("id", ""))
                note["text"] = _plain(note.get("text", ""), 65536, multiline=True)
                note["attachments"] = []
        value["name"] = _plain(value.get("name", ""), 80)
    value["readOnly"] = True
    value["remoteEndpoint"] = endpoint
    return value


def register_remote_parser(commands: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    remote = commands.add_parser("remote")
    remote_commands = remote.add_subparsers(dest="remote_command", required=True)
    remote_connect = remote_commands.add_parser("connect")
    remote_connect.add_argument("endpoint")
    remote_connect.set_defaults(func=connect_remote)
    remote_commands.add_parser("disconnect").set_defaults(func=disconnect_remote)
    remote_bucket = remote_commands.add_parser("bucket")
    remote_bucket.add_argument("bucket_id")
    remote_bucket.set_defaults(func=select_remote_bucket)
    remote_section = remote_commands.add_parser("section")
    remote_section.add_argument("section_id")
    remote_section.set_defaults(func=select_remote_section)

    remote_state_parser = commands.add_parser("_remote-state")
    remote_state_parser.add_argument("--bucket", dest="bucket_id", default="")
    remote_state_parser.add_argument("--section", dest="section_id", default="")
    remote_state_parser.set_defaults(func=serve_remote_state)
    remote_workspace_parser = commands.add_parser("_remote-workspace")
    remote_workspace_parser.add_argument("kind", choices=("buckets", "bucket"))
    remote_workspace_parser.add_argument("identifier", nargs="?", default="")
    remote_workspace_parser.set_defaults(func=serve_remote_workspace)


def serve_remote_state(args: argparse.Namespace) -> None:
    from .store import state_command

    args.local_only = True
    state_command(args)


def serve_remote_workspace(args: argparse.Namespace) -> None:
    from .workspace import bucket_document

    with connect() as db:
        if args.kind == "buckets":
            buckets = [
                {
                    "id": row["id"], "name": row["name"], "count": row["note_count"],
                    "submitted": row["submitted_count"], "queued": row["queued_count"],
                }
                for row in db.execute(
                    "SELECT b.id, b.name, COUNT(n.id) AS note_count, "
                    "COUNT(CASE WHEN q.delivered_at IS NOT NULL THEN n.id END) AS submitted_count, "
                    "COUNT(CASE WHEN n.id IS NOT NULL AND q.delivered_at IS NULL THEN n.id END) AS queued_count "
                    "FROM buckets b LEFT JOIN notes n ON n.bucket_id = b.id "
                    "LEFT JOIN feed_queue q ON q.note_id = n.id "
                    "GROUP BY b.id ORDER BY b.position, b.name LIMIT 100"
                )
            ]
            print(json.dumps({"buckets": buckets, "readOnly": True}, ensure_ascii=False))
            return
        document = bucket_document(db, args.identifier)
        sections = document.get("sections", [])
        for section in sections if isinstance(sections, list) else []:
            if not isinstance(section, dict):
                continue
            notes = section.get("notes", [])
            for note in notes if isinstance(notes, list) else []:
                if not isinstance(note, dict):
                    continue
                attachments = note.get("attachments", [])
                note["attachmentCount"] = len(attachments) if isinstance(attachments, list) else 0
                note["attachments"] = []
        print(json.dumps({**document, "readOnly": True}, ensure_ascii=False))


def remote_state_defaults() -> tuple[str, str]:
    with connect() as db:
        bucket_id = active_bucket(db)
        return bucket_id, active_section(db, bucket_id)
