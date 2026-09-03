from __future__ import annotations

import argparse
import json
import re
import sqlite3
import time
import uuid
from pathlib import Path

from .store_core import (
    active_bucket,
    active_section,
    checked_note_text,
    connect,
    ensure_unsorted_section,
    feed_destination,
    feed_section_queue,
    remove_note_attachments,
    set_setting,
    setting,
    unlink_attachment_files,
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


def clear_section_notes(section_id: str, notes_mode: str) -> dict[str, object]:
    if not section_id:
        raise ValueError("section id is required")
    if notes_mode not in {"move", "discard"}:
        raise ValueError("invalid section note handling")
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        section = db.execute(
            "SELECT id, name, bucket_id, system_kind FROM sections WHERE id = ?", (section_id,)
        ).fetchone()
        if not section:
            raise ValueError("section no longer exists")
        note_ids = [
            str(row[0]) for row in db.execute(
                "SELECT id FROM notes WHERE section_id = ? ORDER BY position, created_at",
                (section_id,),
            )
        ]
        if note_ids:
            placeholders = ",".join("?" for _ in note_ids)
            if db.execute(
                f"SELECT 1 FROM feed_queue WHERE note_id IN ({placeholders}) "
                "AND claim_token IS NOT NULL LIMIT 1",
                tuple(note_ids),
            ).fetchone():
                raise ValueError("wait for active delivery to finish before clearing this section")
        attachment_count = 0
        attachment_paths: list[Path] = []
        moved_count = 0
        if note_ids and notes_mode == "move":
            if section["system_kind"] == "unsorted":
                raise ValueError("notes are already in Unsorted")
            destination = ensure_unsorted_section(db, str(section["bucket_id"]))
            next_position = db.execute(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM notes WHERE section_id = ?",
                (destination,),
            ).fetchone()[0]
            for offset, note_id in enumerate(note_ids):
                db.execute(
                    "UPDATE notes SET section_id = ?, position = ? WHERE id = ?",
                    (destination, next_position + offset, note_id),
                )
            moved_count = len(note_ids)
        elif note_ids:
            attachment_count = db.execute(
                f"SELECT COUNT(*) FROM attachments WHERE note_id IN ({placeholders})",
                tuple(note_ids),
            ).fetchone()[0]
            attachment_paths = remove_note_attachments(db, note_ids)
            db.execute(
                f"DELETE FROM feed_queue WHERE note_id IN ({placeholders})", tuple(note_ids)
            )
            db.execute(f"DELETE FROM notes WHERE id IN ({placeholders})", tuple(note_ids))
        db.commit()
    unlink_attachment_files(attachment_paths)
    return {
        "ok": True,
        "sectionId": section_id,
        "sectionName": str(section["name"]),
        "mode": notes_mode,
        "movedNotes": moved_count,
        "deletedNotes": len(note_ids) if notes_mode == "discard" else 0,
        "deletedAttachments": int(attachment_count),
    }


def clear_section(args: argparse.Namespace) -> None:
    print(json.dumps(clear_section_notes(args.section_id, args.notes), ensure_ascii=False))


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


def reset_all_notes() -> int:
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        if setting(db, "feed_enabled", "0") == "1":
            raise ValueError("stop the feed before resetting all notes")
        if db.execute(
            "SELECT 1 FROM feed_queue WHERE claim_token IS NOT NULL LIMIT 1"
        ).fetchone():
            raise ValueError("wait for the active submission to finish before resetting all notes")
        db.execute(
            "INSERT OR IGNORE INTO feed_queue(note_id, enqueued_at) "
            "SELECT id, created_at FROM notes"
        )
        reset_count = int(db.execute(
            "SELECT COUNT(*) FROM feed_queue WHERE delivered_at IS NOT NULL"
        ).fetchone()[0])
        db.execute(
            "UPDATE feed_queue SET delivered_at = NULL, error = '', claim_token = NULL, "
            "claimed_at = NULL, delivery_kind = NULL, delivery_sequence = NULL"
        )
        set_setting(db, "active_delivery_notes", "[]")
        set_setting(db, "active_delivery_target", "")
        set_setting(db, "active_delivery_started", "0")
        set_setting(db, "active_delivery_observed", "0")
        db.commit()
    return reset_count


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
