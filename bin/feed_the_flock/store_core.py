from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import stat
import sys
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from .common import ATTACHMENT_DIR, DB_PATH, DEFAULT_BUCKETS, STATE_DIR

MAX_NOTE_BYTES = 64 * 1024
MAX_STATE_BYTES = 8 * 1024 * 1024


def checked_note_text(value: str) -> str:
    text = value.strip()
    if not text:
        raise ValueError("note text cannot be empty")
    if len(text.encode("utf-8")) > MAX_NOTE_BYTES:
        raise ValueError("note text must be at most 64 KB")
    return text


def unsorted_section_id(bucket_id: str) -> str:
    return f"{bucket_id}:unsorted"


def ensure_unsorted_section(db: sqlite3.Connection, bucket_id: str) -> str:
    section_id = unsorted_section_id(bucket_id)
    db.execute(
        "INSERT OR IGNORE INTO sections(id, bucket_id, name, position, system_kind) "
        "VALUES (?, ?, 'Unsorted', -1, 'unsorted')",
        (section_id, bucket_id),
    )
    db.execute(
        "UPDATE notes SET section_id = ? WHERE bucket_id = ? AND section_id IS NULL",
        (section_id, bucket_id),
    )
    db.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)",
        (f"active_section:{bucket_id}", section_id),
    )
    return section_id


def _open_connection() -> sqlite3.Connection:
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE_DIR.chmod(0o700)
    try:
        descriptor = os.open(DB_PATH, os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW)
    except FileNotFoundError:
        descriptor = os.open(
            DB_PATH, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600,
        )
    os.close(descriptor)
    DB_PATH.chmod(0o600)
    db = sqlite3.connect(DB_PATH, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=10000")
    journal_mode = str(db.execute("PRAGMA journal_mode=DELETE").fetchone()[0]).lower()
    if journal_mode != "delete":
        db.close()
        raise sqlite3.OperationalError("could not enable safe SQLite rollback journaling")
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS buckets (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          position INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sections (
          id TEXT PRIMARY KEY,
          bucket_id TEXT NOT NULL REFERENCES buckets(id),
          name TEXT NOT NULL,
          position INTEGER NOT NULL,
          system_kind TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS notes (
          id TEXT PRIMARY KEY,
          bucket_id TEXT NOT NULL REFERENCES buckets(id),
          section_id TEXT REFERENCES sections(id),
          text TEXT NOT NULL,
          position INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS attachments (
          id TEXT PRIMARY KEY,
          note_id TEXT NOT NULL REFERENCES notes(id),
          file_name TEXT NOT NULL,
          mime_type TEXT NOT NULL,
          file_path TEXT NOT NULL,
          position INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS attachments_note_id ON attachments(note_id, position);
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS feed_queue (
          note_id TEXT PRIMARY KEY,
          enqueued_at INTEGER NOT NULL,
          delivered_at INTEGER,
          error TEXT NOT NULL DEFAULT '',
          claim_token TEXT,
          claimed_at INTEGER,
          delivery_kind TEXT,
          delivery_sequence INTEGER
        );
        CREATE TABLE IF NOT EXISTS section_feed_queue (
          section_id TEXT PRIMARY KEY,
          position INTEGER NOT NULL,
          queued_at INTEGER NOT NULL
        );
        """
    )
    note_columns = {row[1] for row in db.execute("PRAGMA table_info(notes)")}
    if "section_id" not in note_columns:
        db.execute("ALTER TABLE notes ADD COLUMN section_id TEXT REFERENCES sections(id)")
    queue_columns = {row[1] for row in db.execute("PRAGMA table_info(feed_queue)")}
    if "claim_token" not in queue_columns:
        db.execute("ALTER TABLE feed_queue ADD COLUMN claim_token TEXT")
    if "claimed_at" not in queue_columns:
        db.execute("ALTER TABLE feed_queue ADD COLUMN claimed_at INTEGER")
    if "delivery_kind" not in queue_columns:
        db.execute("ALTER TABLE feed_queue ADD COLUMN delivery_kind TEXT")
    if "delivery_sequence" not in queue_columns:
        db.execute("ALTER TABLE feed_queue ADD COLUMN delivery_sequence INTEGER")
    next_sequence = db.execute(
        "SELECT COALESCE(MAX(delivery_sequence), 0) FROM feed_queue"
    ).fetchone()[0]
    for delivered in db.execute(
        "SELECT rowid FROM feed_queue WHERE delivered_at IS NOT NULL "
        "AND delivery_sequence IS NULL ORDER BY delivered_at, rowid"
    ).fetchall():
        next_sequence += 1
        db.execute(
            "UPDATE feed_queue SET delivery_sequence = ? WHERE rowid = ?",
            (next_sequence, delivered["rowid"]),
        )
    db.execute(
        "UPDATE feed_queue SET claim_token = NULL, claimed_at = NULL "
        "WHERE claimed_at IS NOT NULL AND claimed_at < ?",
        (int(time.time()) - 60,),
    )
    defaults_initialized = db.execute(
        "SELECT 1 FROM settings WHERE key = 'initial_buckets_created'"
    ).fetchone()
    if not defaults_initialized:
        if db.execute("SELECT COUNT(*) FROM buckets").fetchone()[0] == 0:
            for position, (bucket_id, name) in enumerate(DEFAULT_BUCKETS):
                db.execute(
                    "INSERT INTO buckets(id, name, position) VALUES (?, ?, ?)",
                    (bucket_id, name, position),
                )
        db.execute(
            "INSERT INTO settings(key, value) VALUES ('initial_buckets_created', '1')"
        )
    for row in db.execute("SELECT id FROM buckets"):
        ensure_unsorted_section(db, row[0])
    db.execute("UPDATE sections SET position = -1 WHERE system_kind = 'unsorted' AND position = 999999")
    db.execute(
        "INSERT OR IGNORE INTO feed_queue(note_id, enqueued_at) "
        "SELECT id, created_at FROM notes"
    )
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('active_bucket', 'inbox')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('phase', 'idle')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('phase_at', '0')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('error', '')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('delivery_target', '')")
    db.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES "
        "('delivery_target_label', 'Target unavailable')"
    )
    db.execute(
        "UPDATE settings SET value = '' WHERE key = 'delivery_target' AND value = 'clipboard'"
    )
    db.execute(
        "UPDATE settings SET value = 'Target unavailable' "
        "WHERE key = 'delivery_target_label' AND value = 'Clipboard' "
        "AND (SELECT value FROM settings WHERE key = 'delivery_target') = ''"
    )
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('delivery_mode', 'idle-active-next')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('feed_enabled', '0')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('queue_order', 'fifo')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) "
               "SELECT 'feed_bucket', value FROM settings WHERE key = 'active_bucket'")
    feed_bucket_id = db.execute(
        "SELECT value FROM settings WHERE key = 'feed_bucket'"
    ).fetchone()[0]
    feed_section = db.execute(
        "SELECT value FROM settings WHERE key = ?",
        (f"active_section:{feed_bucket_id}",),
    ).fetchone()
    db.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES ('feed_section', ?)",
        (str(feed_section[0]) if feed_section else "",),
    )
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('feed_resume_after', '0')")
    db.commit()
    return db


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    """Open one transactional store connection and always close its descriptors."""
    db = _open_connection()
    try:
        with db:
            yield db
    finally:
        db.close()


def remove_note_attachments(db: sqlite3.Connection, note_ids: list[str]) -> list[Path]:
    if not note_ids:
        return []
    placeholders = ",".join("?" for _ in note_ids)
    paths = [
        Path(row[0]) for row in db.execute(
            f"SELECT file_path FROM attachments WHERE note_id IN ({placeholders})",
            tuple(note_ids),
        )
    ]
    db.execute(
        f"DELETE FROM attachments WHERE note_id IN ({placeholders})", tuple(note_ids)
    )
    return paths


def unlink_attachment_files(paths: list[Path]) -> None:
    if not paths:
        return
    try:
        descriptor = os.open(
            ATTACHMENT_DIR, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
        )
    except OSError:
        return
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid():
            return
        managed_parent = ATTACHMENT_DIR.absolute()
        for path in paths:
            candidate = path.absolute()
            if candidate.parent != managed_parent or candidate.name in {"", ".", ".."}:
                continue
            try:
                os.unlink(candidate.name, dir_fd=descriptor)
            except FileNotFoundError:
                pass
    finally:
        os.close(descriptor)


def setting(db: sqlite3.Connection, key: str, fallback: str = "") -> str:
    row = db.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return str(row[0]) if row else fallback


def set_setting(db: sqlite3.Connection, key: str, value: str) -> None:
    db.execute(
        "INSERT INTO settings(key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )


def set_phase(db: sqlite3.Connection, phase: str, error: str = "") -> None:
    set_setting(db, "phase", phase)
    set_setting(db, "phase_at", str(int(time.time() * 1000)))
    set_setting(db, "error", error)
    db.commit()


def normalized_phase(db: sqlite3.Connection) -> str:
    phase = setting(db, "phase", "idle")
    if phase in {"success", "cancelled"}:
        phase_at = int(setting(db, "phase_at", "0") or 0)
        if int(time.time() * 1000) - phase_at >= 2000:
            set_phase(db, "idle")
            return "idle"
    return phase if phase in {"idle", "recording", "transcribing", "success", "cancelled", "error"} else "idle"


def active_bucket(db: sqlite3.Connection) -> str:
    bucket_id = setting(db, "active_bucket", "inbox")
    exists = db.execute("SELECT 1 FROM buckets WHERE id = ?", (bucket_id,)).fetchone()
    if exists:
        return bucket_id
    fallback = db.execute("SELECT id FROM buckets ORDER BY position, name LIMIT 1").fetchone()
    return str(fallback[0]) if fallback else ""


def active_section(db: sqlite3.Connection, bucket_id: str) -> str:
    if not bucket_id or not db.execute(
        "SELECT 1 FROM buckets WHERE id = ?", (bucket_id,)
    ).fetchone():
        return ""
    section_id = setting(db, f"active_section:{bucket_id}", unsorted_section_id(bucket_id))
    exists = db.execute(
        "SELECT 1 FROM sections WHERE id = ? AND bucket_id = ?", (section_id, bucket_id)
    ).fetchone()
    return section_id if exists else ensure_unsorted_section(db, bucket_id)


def feed_destination(db: sqlite3.Connection) -> tuple[str, str]:
    selected_bucket_id = active_bucket(db)
    bucket_id = setting(db, "feed_bucket", selected_bucket_id)
    if not db.execute("SELECT 1 FROM buckets WHERE id = ?", (bucket_id,)).fetchone():
        bucket_id = selected_bucket_id
    if not bucket_id:
        return "", ""
    section_id = setting(db, "feed_section", active_section(db, bucket_id))
    if not db.execute(
        "SELECT 1 FROM sections WHERE id = ? AND bucket_id = ?", (section_id, bucket_id)
    ).fetchone():
        section_id = active_section(db, bucket_id)
    return bucket_id, section_id


def feed_section_queue(db: sqlite3.Connection) -> list[sqlite3.Row]:
    db.execute(
        "DELETE FROM section_feed_queue WHERE section_id NOT IN (SELECT id FROM sections)"
    )
    rows = db.execute(
        "SELECT q.section_id, s.bucket_id, s.name, b.name AS bucket_name, q.position "
        "FROM section_feed_queue q JOIN sections s ON s.id = q.section_id "
        "JOIN buckets b ON b.id = s.bucket_id ORDER BY q.position, q.queued_at"
    ).fetchall()
    for position, row in enumerate(rows):
        if row["position"] != position:
            db.execute(
                "UPDATE section_feed_queue SET position = ? WHERE section_id = ?",
                (position, row["section_id"]),
            )
    return rows


def next_feed_destination(db: sqlite3.Connection) -> tuple[str, str] | None:
    queue = feed_section_queue(db)
    return (queue[0]["bucket_id"], queue[0]["section_id"]) if queue else None


def promote_next_feed_section(db: sqlite3.Connection) -> bool:
    queue = feed_section_queue(db)
    if not queue:
        return False
    first = queue[0]
    set_setting(db, "feed_bucket", first["bucket_id"])
    set_setting(db, "feed_section", first["section_id"])
    db.execute("DELETE FROM section_feed_queue WHERE section_id = ?", (first["section_id"],))
    remaining = feed_section_queue(db)
    for position, row in enumerate(remaining):
        db.execute(
            "UPDATE section_feed_queue SET position = ? WHERE section_id = ?",
            (position, row["section_id"]),
        )
    db.commit()
    return True


def state_command(_: argparse.Namespace) -> None:
    with connect() as db:
        selected = active_bucket(db)
        selected_section = active_section(db, selected)
        feed_bucket_id, feed_section_id = feed_destination(db)
        queue_rows = feed_section_queue(db)
        queue_positions = {
            row["section_id"]: position for position, row in enumerate(queue_rows)
        }
        feed_queue = [
            {
                "sectionId": row["section_id"], "sectionName": row["name"],
                "bucketId": row["bucket_id"], "bucketName": row["bucket_name"],
                "position": position,
            }
            for position, row in enumerate(queue_rows)
        ]
        next_feed_bucket_id = queue_rows[0]["bucket_id"] if queue_rows else ""
        next_feed_section_id = queue_rows[0]["section_id"] if queue_rows else ""
        feed_section_row = db.execute(
            "SELECT s.name, b.name AS bucket_name FROM sections s "
            "JOIN buckets b ON b.id = s.bucket_id WHERE s.id = ?", (feed_section_id,)
        ).fetchone()
        next_feed_row = queue_rows[0] if queue_rows else None
        phase = normalized_phase(db)
        feed_enabled = setting(db, "feed_enabled", "0") == "1"
        delivery_mode = setting(db, "delivery_mode", "idle-active-next")
        queue_bucket_id = feed_bucket_id if feed_enabled else selected
        queue_section_id = feed_section_id if feed_enabled else selected_section
        active_queue_filter = ""
        active_queue_parameters: list[object] = [queue_bucket_id]
        if delivery_mode.startswith("idle-active-"):
            active_queue_filter = " AND n.section_id = ?"
            active_queue_parameters.append(queue_section_id)
        active_queue_count = db.execute(
            "SELECT COUNT(*) FROM feed_queue q JOIN notes n ON n.id = q.note_id "
            "WHERE q.delivered_at IS NULL AND n.bucket_id = ?" + active_queue_filter,
            tuple(active_queue_parameters),
        ).fetchone()[0]
        buckets = [
            {
                "id": row["id"], "name": row["name"], "count": row["pending_count"],
                "pendingCount": row["pending_count"],
                "submittedCount": row["submitted_count"], "messageCount": row["message_count"],
            }
            for row in db.execute(
                "SELECT b.id, b.name, COUNT(n.id) AS message_count, "
                "COUNT(CASE WHEN q.delivered_at IS NULL THEN n.id END) AS pending_count, "
                "COUNT(CASE WHEN q.delivered_at IS NOT NULL THEN n.id END) AS submitted_count "
                "FROM buckets b LEFT JOIN notes n ON n.bucket_id = b.id "
                "LEFT JOIN feed_queue q ON q.note_id = n.id "
                "GROUP BY b.id ORDER BY b.position, b.name LIMIT 100"
            )
        ]
        sections = [
            {
                "id": row["id"],
                "name": row["name"],
                "count": row["pending_count"],
                "pendingCount": row["pending_count"],
                "submittedCount": row["submitted_count"],
                "messageCount": row["message_count"],
                "systemKind": row["system_kind"],
                "feedCurrent": row["id"] == feed_section_id and feed_enabled,
                "feedNext": row["id"] == next_feed_section_id,
                "feedQueuePosition": queue_positions.get(row["id"], -1),
            }
            for row in db.execute(
                "SELECT s.id, s.name, s.system_kind, COUNT(n.id) AS message_count, "
                "COUNT(CASE WHEN q.delivered_at IS NULL THEN n.id END) AS pending_count, "
                "COUNT(CASE WHEN q.delivered_at IS NOT NULL THEN n.id END) AS submitted_count "
                "FROM sections s LEFT JOIN notes n ON n.section_id = s.id "
                "LEFT JOIN feed_queue q ON q.note_id = n.id "
                "WHERE s.bucket_id = ? GROUP BY s.id "
                "ORDER BY s.position, s.name LIMIT 200",
                (selected,),
            )
        ]
        notes = [
            {
                "id": row["id"],
                "sectionId": row["section_id"],
                "text": row["text"],
                "position": row["position"],
                "createdAt": row["created_at"],
                "sent": bool(row["sent"]),
            }
            for row in db.execute(
                "SELECT n.id, n.section_id, substr(n.text, 1, 8192) AS text, n.position, n.created_at, "
                "q.delivered_at IS NOT NULL AS sent FROM notes n "
                "LEFT JOIN feed_queue q ON q.note_id = n.id "
                "WHERE n.bucket_id = ? AND n.section_id = ? AND q.delivered_at IS NULL "
                "ORDER BY n.position, n.created_at LIMIT 200",
                (selected, selected_section),
            )
        ]
        capture_bucket_name = ""
        capture_section_name = ""
        if phase in {"recording", "transcribing"}:
            try:
                capture_metadata = json.loads(setting(db, "active_capture", "{}"))
                capture_destination = db.execute(
                    "SELECT b.name AS bucket_name, s.name AS section_name "
                    "FROM buckets b JOIN sections s ON s.bucket_id = b.id "
                    "WHERE b.id = ? AND s.id = ?",
                    (capture_metadata.get("bucketId", ""), capture_metadata.get("sectionId", "")),
                ).fetchone()
                if capture_destination:
                    capture_bucket_name = capture_destination["bucket_name"]
                    capture_section_name = capture_destination["section_name"]
            except (json.JSONDecodeError, AttributeError):
                pass
        from .bindings import binding_values
        bindings = binding_values(db, persist_migration=False)
        payload = json.dumps(
            {
                "phase": phase,
                **bindings,
                "error": setting(db, "error"),
                "captureBucketName": capture_bucket_name,
                "captureSectionName": capture_section_name,
                "activeBucketId": selected,
                "activeSectionId": selected_section,
                "feedBucketId": feed_bucket_id,
                "feedSectionId": feed_section_id,
                "feedSectionName": feed_section_row["name"] if feed_section_row else "",
                "feedBucketName": feed_section_row["bucket_name"] if feed_section_row else "",
                "nextFeedBucketId": next_feed_bucket_id,
                "nextFeedSectionId": next_feed_section_id,
                "nextFeedBucketName": next_feed_row["bucket_name"] if next_feed_row else "",
                "nextFeedSectionName": next_feed_row["name"] if next_feed_row else "",
                "feedQueue": feed_queue,
                "deliveryMode": delivery_mode,
                "feedEnabled": feed_enabled,
                "queueOrder": setting(db, "queue_order", "fifo"),
                "pendingCount": active_queue_count,
                "buckets": buckets,
                "sections": sections,
                "notes": notes,
                "totalCount": sum(bucket["count"] for bucket in buckets),
            },
            ensure_ascii=False,
        ).encode("utf-8")
        if len(payload) > MAX_STATE_BYTES:
            raise ValueError("state response exceeds the 8 MB safety limit")
        sys.stdout.buffer.write(payload + b"\n")
