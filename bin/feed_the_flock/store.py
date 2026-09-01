from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from .common import DB_PATH, DEFAULT_BUCKETS, STATE_DIR

MAX_NOTE_BYTES = 64 * 1024


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
    db.execute("PRAGMA journal_mode=WAL")
    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(DB_PATH) + suffix)
        try:
            sidecar_descriptor = os.open(sidecar, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        except FileNotFoundError:
            continue
        try:
            os.fchmod(sidecar_descriptor, 0o600)
        finally:
            os.close(sidecar_descriptor)
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
    for position, (bucket_id, name) in enumerate(DEFAULT_BUCKETS):
        db.execute(
            "INSERT OR IGNORE INTO buckets(id, name, position) VALUES (?, ?, ?)",
            (bucket_id, name, position),
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
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('delivery_target', 'clipboard')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('delivery_target_label', 'Clipboard')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('delivery_mode', 'idle-active-next')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('feed_enabled', '0')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('queue_order', 'fifo')")
    db.execute("INSERT OR IGNORE INTO settings(key, value) "
               "SELECT 'feed_bucket', value FROM settings WHERE key = 'active_bucket'")
    feed_bucket_id = db.execute(
        "SELECT value FROM settings WHERE key = 'feed_bucket'"
    ).fetchone()[0]
    db.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES ('feed_section', ?)",
        (db.execute(
            "SELECT value FROM settings WHERE key = ?",
            (f"active_section:{feed_bucket_id}",),
        ).fetchone()[0],),
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
    for path in paths:
        path.unlink(missing_ok=True)


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
    return bucket_id if exists else "inbox"


def active_section(db: sqlite3.Connection, bucket_id: str) -> str:
    section_id = setting(db, f"active_section:{bucket_id}", unsorted_section_id(bucket_id))
    exists = db.execute(
        "SELECT 1 FROM sections WHERE id = ? AND bucket_id = ?", (section_id, bucket_id)
    ).fetchone()
    return section_id if exists else ensure_unsorted_section(db, bucket_id)


def feed_destination(db: sqlite3.Connection) -> tuple[str, str]:
    bucket_id = setting(db, "feed_bucket", active_bucket(db))
    if not db.execute("SELECT 1 FROM buckets WHERE id = ?", (bucket_id,)).fetchone():
        bucket_id = active_bucket(db)
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
        print(
            json.dumps(
                {
                    "phase": phase,
                    "error": setting(db, "error"),
                    "captureBucketName": capture_bucket_name,
                    "captureSectionName": capture_section_name,
                    "activeBucketId": selected,
                    "activeSectionId": selected_section,
                    "feedBucketId": feed_bucket_id,
                    "feedSectionId": feed_section_id,
                    "feedSectionName": feed_section_row["name"],
                    "feedBucketName": feed_section_row["bucket_name"],
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
            )
        )


def select_bucket(args: argparse.Namespace) -> None:
    with connect() as db:
        if not db.execute("SELECT 1 FROM buckets WHERE id = ?", (args.bucket_id,)).fetchone():
            raise SystemExit(f"feed-the-flock: unknown bucket: {args.bucket_id}")
        set_setting(db, "active_bucket", args.bucket_id)
        db.commit()


def add_bucket(args: argparse.Namespace) -> None:
    name = " ".join(args.name.strip().split())
    if not name:
        raise SystemExit("feed-the-flock: bucket name cannot be empty")
    if len(name) > 40:
        raise SystemExit("feed-the-flock: bucket name must be at most 40 characters")
    with connect() as db:
        if db.execute("SELECT COUNT(*) FROM buckets").fetchone()[0] >= 100:
            raise ValueError("at most 100 buckets are supported")
        if db.execute("SELECT 1 FROM buckets WHERE name = ? COLLATE NOCASE", (name,)).fetchone():
            raise SystemExit(f"feed-the-flock: bucket already exists: {name}")
        stem = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "bucket"
        bucket_id = stem
        suffix = 2
        while db.execute("SELECT 1 FROM buckets WHERE id = ?", (bucket_id,)).fetchone():
            bucket_id = f"{stem}-{suffix}"
            suffix += 1
        position = db.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM buckets").fetchone()[0]
        db.execute(
            "INSERT INTO buckets(id, name, position) VALUES (?, ?, ?)",
            (bucket_id, name, position),
        )
        ensure_unsorted_section(db, bucket_id)
        set_setting(db, "active_bucket", bucket_id)
        db.commit()


def rename_bucket(args: argparse.Namespace) -> None:
    name = " ".join(args.name.strip().split())
    if not name or len(name) > 40:
        raise ValueError("bucket name must be between 1 and 40 characters")
    with connect() as db:
        if not db.execute("SELECT 1 FROM buckets WHERE id = ?", (args.bucket_id,)).fetchone():
            raise ValueError("bucket no longer exists")
        duplicate = db.execute(
            "SELECT 1 FROM buckets WHERE id != ? AND name = ? COLLATE NOCASE",
            (args.bucket_id, name),
        ).fetchone()
        if duplicate:
            raise ValueError("bucket name already exists")
        db.execute("UPDATE buckets SET name = ? WHERE id = ?", (name, args.bucket_id))
        db.commit()


def move_bucket(args: argparse.Namespace) -> None:
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        ordered = [row[0] for row in db.execute("SELECT id FROM buckets ORDER BY position, name")]
        if args.bucket_id not in ordered:
            raise ValueError("bucket no longer exists")
        index = ordered.index(args.bucket_id)
        target = index - 1 if args.direction == "left" else index + 1
        if target < 0 or target >= len(ordered):
            db.commit()
            return
        ordered[index], ordered[target] = ordered[target], ordered[index]
        for position, bucket_id in enumerate(ordered):
            db.execute("UPDATE buckets SET position = ? WHERE id = ?", (position, bucket_id))
        db.commit()


def delete_bucket(args: argparse.Namespace) -> None:
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        if db.execute("SELECT COUNT(*) FROM buckets").fetchone()[0] <= 1:
            raise ValueError("cannot delete the final bucket")
        if not db.execute("SELECT 1 FROM buckets WHERE id = ?", (args.bucket_id,)).fetchone():
            raise ValueError("bucket no longer exists")
        deleted_note_ids = [
            row[0] for row in db.execute("SELECT id FROM notes WHERE bucket_id = ?", (args.bucket_id,))
        ]
        attachment_paths = remove_note_attachments(db, deleted_note_ids)
        db.execute(
            "DELETE FROM feed_queue WHERE note_id IN (SELECT id FROM notes WHERE bucket_id = ?)",
            (args.bucket_id,),
        )
        db.execute(
            "DELETE FROM section_feed_queue WHERE section_id IN "
            "(SELECT id FROM sections WHERE bucket_id = ?)", (args.bucket_id,),
        )
        db.execute("DELETE FROM notes WHERE bucket_id = ?", (args.bucket_id,))
        db.execute("DELETE FROM sections WHERE bucket_id = ?", (args.bucket_id,))
        db.execute("DELETE FROM buckets WHERE id = ?", (args.bucket_id,))
        ordered = [row[0] for row in db.execute("SELECT id FROM buckets ORDER BY position, name")]
        for position, bucket_id in enumerate(ordered):
            db.execute("UPDATE buckets SET position = ? WHERE id = ?", (position, bucket_id))
        if setting(db, "active_bucket", "") == args.bucket_id:
            set_setting(db, "active_bucket", ordered[0])
        if setting(db, "feed_bucket", "") == args.bucket_id:
            set_setting(db, "feed_bucket", ordered[0])
            set_setting(db, "feed_section", active_section(db, ordered[0]))
        db.commit()
    unlink_attachment_files(attachment_paths)


def select_section(args: argparse.Namespace) -> None:
    with connect() as db:
        bucket_id = active_bucket(db)
        if not db.execute(
            "SELECT 1 FROM sections WHERE id = ? AND bucket_id = ?", (args.section_id, bucket_id)
        ).fetchone():
            raise SystemExit(f"feed-the-flock: unknown section: {args.section_id}")
        set_setting(db, f"active_section:{bucket_id}", args.section_id)
        db.commit()


def write_feed_section_queue(db: sqlite3.Connection, section_ids: list[str]) -> None:
    db.execute("DELETE FROM section_feed_queue")
    queued_at = int(time.time())
    for position, section_id in enumerate(section_ids):
        db.execute(
            "INSERT INTO section_feed_queue(section_id, position, queued_at) VALUES (?, ?, ?)",
            (section_id, position, queued_at + position),
        )


def select_feed_section(args: argparse.Namespace) -> None:
    """Compatibility command: place a section first in the waiting queue."""
    with connect() as db:
        section = db.execute("SELECT 1 FROM sections WHERE id = ?", (args.section_id,)).fetchone()
        if not section:
            raise ValueError("section no longer exists")
        if args.section_id == feed_destination(db)[1]:
            raise ValueError("section is currently feeding")
        queued = [
            row["section_id"] for row in feed_section_queue(db)
            if row["section_id"] != args.section_id
        ]
        write_feed_section_queue(db, [args.section_id, *queued])
        db.commit()


def add_feed_section_queue(args: argparse.Namespace) -> None:
    with connect() as db:
        if not db.execute("SELECT 1 FROM sections WHERE id = ?", (args.section_id,)).fetchone():
            raise ValueError("section no longer exists")
        if args.section_id == feed_destination(db)[1]:
            raise ValueError("section is currently feeding")
        queued = [row["section_id"] for row in feed_section_queue(db)]
        if args.section_id not in queued:
            queued.append(args.section_id)
            write_feed_section_queue(db, queued)
            db.commit()


def remove_feed_section_queue(args: argparse.Namespace) -> None:
    with connect() as db:
        queued = [
            row["section_id"] for row in feed_section_queue(db)
            if row["section_id"] != args.section_id
        ]
        write_feed_section_queue(db, queued)
        db.commit()


def select_feed_section_now(args: argparse.Namespace) -> None:
    with connect() as db:
        section = db.execute(
            "SELECT bucket_id FROM sections WHERE id = ?", (args.section_id,)
        ).fetchone()
        if not section:
            raise ValueError("section no longer exists")
        old_bucket_id, old_section_id = feed_destination(db)
        queued = [
            row["section_id"] for row in feed_section_queue(db)
            if row["section_id"] not in {args.section_id, old_section_id}
        ]
        if old_section_id != args.section_id:
            old_pending = db.execute(
                "SELECT COUNT(*) FROM feed_queue q JOIN notes n ON n.id = q.note_id "
                "WHERE q.delivered_at IS NULL AND n.bucket_id = ? AND n.section_id = ?",
                (old_bucket_id, old_section_id),
            ).fetchone()[0]
            if old_pending:
                queued.insert(0, old_section_id)
        write_feed_section_queue(db, queued)
        set_setting(db, "feed_bucket", section["bucket_id"])
        set_setting(db, "feed_section", args.section_id)
        db.commit()


def add_section(args: argparse.Namespace) -> None:
    name = " ".join(args.name.strip().split())
    if not name:
        raise SystemExit("feed-the-flock: section name cannot be empty")
    if len(name) > 50:
        raise SystemExit("feed-the-flock: section name must be at most 50 characters")
    with connect() as db:
        bucket_id = getattr(args, "bucket_id", None) or active_bucket(db)
        if not db.execute("SELECT 1 FROM buckets WHERE id = ?", (bucket_id,)).fetchone():
            raise ValueError("bucket no longer exists")
        if db.execute(
            "SELECT COUNT(*) FROM sections WHERE bucket_id = ?", (bucket_id,)
        ).fetchone()[0] >= 200:
            raise ValueError("at most 200 sections per bucket are supported")
        if db.execute(
            "SELECT 1 FROM sections WHERE bucket_id = ? AND name = ? COLLATE NOCASE",
            (bucket_id, name),
        ).fetchone():
            raise SystemExit(f"feed-the-flock: section already exists: {name}")
        stem = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "section"
        section_id = f"{bucket_id}:{stem}"
        suffix = 2
        while db.execute("SELECT 1 FROM sections WHERE id = ?", (section_id,)).fetchone():
            section_id = f"{bucket_id}:{stem}-{suffix}"
            suffix += 1
        position = db.execute(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM sections WHERE bucket_id = ?",
            (bucket_id,),
        ).fetchone()[0]
        db.execute(
            "INSERT INTO sections(id, bucket_id, name, position) VALUES (?, ?, ?, ?)",
            (section_id, bucket_id, name, position),
        )
        set_setting(db, f"active_section:{bucket_id}", section_id)
        db.commit()


def rename_section(args: argparse.Namespace) -> None:
    name = " ".join(args.name.strip().split())
    if not name or len(name) > 50:
        raise ValueError("section name must be between 1 and 50 characters")
    with connect() as db:
        section = db.execute("SELECT bucket_id FROM sections WHERE id = ?", (args.section_id,)).fetchone()
        if not section:
            raise ValueError("section no longer exists")
        duplicate = db.execute(
            "SELECT 1 FROM sections WHERE bucket_id = ? AND id != ? AND name = ? COLLATE NOCASE",
            (section["bucket_id"], args.section_id, name),
        ).fetchone()
        if duplicate:
            raise ValueError("section name already exists")
        db.execute("UPDATE sections SET name = ? WHERE id = ?", (name, args.section_id))
        db.commit()


def delete_section(args: argparse.Namespace) -> None:
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        section = db.execute(
            "SELECT bucket_id, system_kind FROM sections WHERE id = ?", (args.section_id,)
        ).fetchone()
        if not section:
            raise ValueError("section no longer exists")
        if section["system_kind"] == "unsorted":
            raise ValueError("Unsorted is the fallback section and cannot be deleted")
        destination = ensure_unsorted_section(db, section["bucket_id"])
        notes = [
            row[0] for row in db.execute(
                "SELECT id FROM notes WHERE section_id = ? ORDER BY position, created_at",
                (args.section_id,),
            )
        ]
        attachment_paths: list[Path] = []
        if getattr(args, "notes", "move") == "discard":
            attachment_paths = remove_note_attachments(db, notes)
            db.execute(
                "DELETE FROM feed_queue WHERE note_id IN "
                "(SELECT id FROM notes WHERE section_id = ?)", (args.section_id,),
            )
            db.execute("DELETE FROM notes WHERE section_id = ?", (args.section_id,))
        else:
            next_position = db.execute(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM notes WHERE section_id = ?",
                (destination,),
            ).fetchone()[0]
            for offset, note_id in enumerate(notes):
                db.execute(
                    "UPDATE notes SET section_id = ?, position = ? WHERE id = ?",
                    (destination, next_position + offset, note_id),
                )
        db.execute("DELETE FROM section_feed_queue WHERE section_id = ?", (args.section_id,))
        db.execute("DELETE FROM sections WHERE id = ?", (args.section_id,))
        ordered = [
            row[0] for row in db.execute(
                "SELECT id FROM sections WHERE bucket_id = ? ORDER BY position, name",
                (section["bucket_id"],),
            )
        ]
        for position, section_id in enumerate(ordered):
            db.execute("UPDATE sections SET position = ? WHERE id = ?", (position, section_id))
        if setting(db, f"active_section:{section['bucket_id']}", "") == args.section_id:
            set_setting(db, f"active_section:{section['bucket_id']}", destination)
        if setting(db, "feed_section", "") == args.section_id:
            set_setting(db, "feed_section", destination)
        db.commit()
    unlink_attachment_files(attachment_paths)


def place_section(args: argparse.Namespace) -> None:
    if args.section_id == args.before_section_id:
        return
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        section = db.execute(
            "SELECT bucket_id, system_kind FROM sections WHERE id = ?", (args.section_id,)
        ).fetchone()
        if not section:
            raise ValueError("section no longer exists")
        if args.before_section_id:
            before = db.execute(
                "SELECT bucket_id, system_kind FROM sections WHERE id = ?",
                (args.before_section_id,),
            ).fetchone()
            if not before or before["bucket_id"] != section["bucket_id"]:
                raise ValueError("target section does not exist in this bucket")
        ordered = [
            row[0] for row in db.execute(
                "SELECT id FROM sections WHERE bucket_id = ? AND id != ? ORDER BY position, name",
                (section["bucket_id"], args.section_id),
            )
        ]
        insertion = ordered.index(args.before_section_id) if args.before_section_id else len(ordered)
        ordered.insert(insertion, args.section_id)
        for position, section_id in enumerate(ordered):
            db.execute("UPDATE sections SET position = ? WHERE id = ?", (position, section_id))
        db.commit()


def move_section(args: argparse.Namespace) -> None:
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        section = db.execute(
            "SELECT bucket_id, system_kind FROM sections WHERE id = ?", (args.section_id,)
        ).fetchone()
        if not section:
            raise ValueError("section no longer exists")
        ordered = [
            row[0] for row in db.execute(
                "SELECT id FROM sections WHERE bucket_id = ? ORDER BY position, name",
                (section["bucket_id"],),
            )
        ]
        index = ordered.index(args.section_id)
        target = index - 1 if args.direction == "left" else index + 1
        if target < 0 or target >= len(ordered):
            db.commit()
            return
        ordered[index], ordered[target] = ordered[target], ordered[index]
        for position, section_id in enumerate(ordered):
            db.execute("UPDATE sections SET position = ? WHERE id = ?", (position, section_id))
        db.commit()


def add_note_to_db(db: sqlite3.Connection, bucket_id: str, text: str, section_id: str | None = None) -> str:
    text = checked_note_text(text)
    if db.execute("SELECT COUNT(*) FROM notes WHERE bucket_id = ?", (bucket_id,)).fetchone()[0] >= 2000:
        raise ValueError("at most 2,000 notes per bucket are supported")
    section_id = section_id or ensure_unsorted_section(db, bucket_id)
    position = db.execute(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM notes WHERE section_id = ?", (section_id,)
    ).fetchone()[0]
    note_id = str(uuid.uuid4())
    created_at = int(time.time())
    db.execute(
        "INSERT INTO notes(id, bucket_id, section_id, text, position, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (note_id, bucket_id, section_id, text, position, created_at),
    )
    db.execute(
        "INSERT INTO feed_queue(note_id, enqueued_at) VALUES (?, ?)",
        (note_id, created_at),
    )
    return note_id


def add_note(args: argparse.Namespace) -> None:
    with connect() as db:
        bucket_id = args.bucket_id or active_bucket(db)
        section_id = args.section_id or active_section(db, bucket_id)
        add_note_to_db(db, bucket_id, args.text, section_id)
        db.commit()


def update_note(args: argparse.Namespace) -> None:
    text = checked_note_text(args.text)
    with connect() as db:
        changed = db.execute("UPDATE notes SET text = ? WHERE id = ?", (text, args.note_id)).rowcount
        if not changed:
            raise SystemExit("feed-the-flock: note no longer exists")
        db.commit()


def move_note(args: argparse.Namespace) -> None:
    delta = -1 if args.direction == "up" else 1
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        current = db.execute(
            "SELECT id, bucket_id, section_id, position FROM notes WHERE id = ?", (args.note_id,)
        ).fetchone()
        if not current:
            raise SystemExit("feed-the-flock: note no longer exists")
        neighbor = db.execute(
            "SELECT id, position FROM notes WHERE section_id = ? AND position = ?",
            (current["section_id"], current["position"] + delta),
        ).fetchone()
        if neighbor:
            temporary = -1
            db.execute("UPDATE notes SET position = ? WHERE id = ?", (temporary, current["id"]))
            db.execute("UPDATE notes SET position = ? WHERE id = ?", (current["position"], neighbor["id"]))
            db.execute("UPDATE notes SET position = ? WHERE id = ?", (neighbor["position"], current["id"]))
        db.commit()


def move_note_to_section(args: argparse.Namespace) -> None:
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        note = db.execute(
            "SELECT bucket_id, section_id, position FROM notes WHERE id = ?", (args.note_id,)
        ).fetchone()
        if not note:
            raise SystemExit("feed-the-flock: note no longer exists")
        if not db.execute(
            "SELECT 1 FROM sections WHERE id = ? AND bucket_id = ?",
            (args.section_id, note["bucket_id"]),
        ).fetchone():
            raise SystemExit("feed-the-flock: target section does not exist")
        if note["section_id"] == args.section_id:
            db.commit()
            return
        db.execute(
            "UPDATE notes SET position = position - 1 WHERE section_id = ? AND position > ?",
            (note["section_id"], note["position"]),
        )
        new_position = db.execute(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM notes WHERE section_id = ?",
            (args.section_id,),
        ).fetchone()[0]
        db.execute(
            "UPDATE notes SET section_id = ?, position = ? WHERE id = ?",
            (args.section_id, new_position, args.note_id),
        )
        db.commit()


def place_note(args: argparse.Namespace) -> None:
    if args.note_id == args.before_note_id:
        return
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        note = db.execute("SELECT section_id FROM notes WHERE id = ?", (args.note_id,)).fetchone()
        target = db.execute("SELECT section_id FROM notes WHERE id = ?", (args.before_note_id,)).fetchone()
        if not note or not target or note["section_id"] != target["section_id"]:
            raise SystemExit("feed-the-flock: notes must be in the same section to reorder")
        ordered = [
            row[0] for row in db.execute(
                "SELECT id FROM notes WHERE section_id = ? ORDER BY position, created_at",
                (note["section_id"],),
            )
        ]
        ordered.remove(args.note_id)
        ordered.insert(ordered.index(args.before_note_id), args.note_id)
        for position, note_id in enumerate(ordered):
            db.execute("UPDATE notes SET position = ? WHERE id = ?", (position, note_id))
        db.commit()


def set_note_sent(args: argparse.Namespace) -> None:
    sent = args.state == "sent"
    with connect() as db:
        note = db.execute("SELECT created_at FROM notes WHERE id = ?", (args.note_id,)).fetchone()
        if not note:
            raise ValueError("note no longer exists")
        db.execute(
            "INSERT OR IGNORE INTO feed_queue(note_id, enqueued_at) VALUES (?, ?)",
            (args.note_id, note["created_at"]),
        )
        sequence = None
        if sent:
            sequence = db.execute(
                "SELECT COALESCE(MAX(delivery_sequence), 0) + 1 FROM feed_queue"
            ).fetchone()[0]
        db.execute(
            "UPDATE feed_queue SET delivered_at = ?, error = '', delivery_kind = ?, "
            "delivery_sequence = ?, claim_token = NULL, claimed_at = NULL WHERE note_id = ?",
            (
                int(time.time()) if sent else None,
                "manual" if sent else None,
                sequence,
                args.note_id,
            ),
        )
        db.commit()


def delete_note(args: argparse.Namespace) -> None:
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT section_id, position FROM notes WHERE id = ?", (args.note_id,)).fetchone()
        attachment_paths: list[Path] = []
        if row:
            attachment_paths = remove_note_attachments(db, [args.note_id])
            db.execute("DELETE FROM feed_queue WHERE note_id = ?", (args.note_id,))
            db.execute("DELETE FROM notes WHERE id = ?", (args.note_id,))
            db.execute(
                "UPDATE notes SET position = position - 1 WHERE section_id = ? AND position > ?",
                (row["section_id"], row["position"]),
            )
        db.commit()
    unlink_attachment_files(attachment_paths)


