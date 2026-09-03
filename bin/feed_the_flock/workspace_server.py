from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import socket
import sqlite3
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .common import (
    ATTACHMENT_DIR,
    WORKSPACE_HOST,
    WORKSPACE_HTML,
    WORKSPACE_PORT,
    read_regular_file,
)
from .feed import configure_routing, deliver_note, feed_control, targets_payload
from .store import (
    add_bucket,
    add_feed_section_queue,
    add_note_to_db,
    add_section,
    clear_section_notes,
    delete_bucket,
    delete_section,
    move_bucket,
    place_section,
    remove_feed_section_queue,
    reset_all_notes,
    rename_bucket,
    rename_section,
    select_feed_section,
    select_feed_section_now,
    set_note_sent,
)
from .store_core import (
    active_bucket,
    checked_note_text,
    connect,
    remove_note_attachments,
    unlink_attachment_files,
)
from .workspace_content import (
    IMAGE_TYPES,
    MAX_ATTACHMENT_BYTES,
    attachment_file,
    bucket_document,
    bucket_markdown_text,
    database_signature,
    image_dimensions,
    import_bucket_markdown,
    omarchy_theme,
    place_note_in_section,
    write_bucket_export,
)


class WorkspaceHandler(BaseHTTPRequestHandler):
    server_version = "AgentFeedWorkspace/1"

    def log_message(self, format: str, *args: object) -> None:
        return

    def json_response(self, status: int, payload: object) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        if len(body) > 12 * 1024 * 1024:
            status = 413
            body = b'{"error":"workspace response exceeds 12 MB"}'
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def validate_local_request(self) -> None:
        allowed_hosts = {
            f"{WORKSPACE_HOST}:{WORKSPACE_PORT}", f"localhost:{WORKSPACE_PORT}",
        }
        if self.headers.get("Host", "") not in allowed_hosts:
            raise ValueError("invalid workspace host")
        origin = self.headers.get("Origin", "")
        if origin:
            parsed_origin = urllib.parse.urlparse(origin)
            if parsed_origin.scheme != "http" or parsed_origin.netloc not in allowed_hosts:
                raise ValueError("cross-origin workspace requests are not allowed")

    def read_json(self) -> dict[str, object]:
        if not self.headers.get("Content-Type", "").lower().startswith("application/json"):
            raise ValueError("workspace mutations require application/json")
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 12_000_000:
            raise ValueError("invalid request body")
        value = json.loads(self.rfile.read(length))
        if not isinstance(value, dict):
            raise ValueError("request body must be an object")
        return value

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        try:
            self.validate_local_request()
            if parsed.path == "/api/events":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                try:
                    version = database_signature()
                    elapsed = 0.0
                    total_elapsed = 0.0
                    self.wfile.write(b"retry: 1000\n\n")
                    self.wfile.flush()
                    while total_elapsed < 300:
                        time.sleep(0.5)
                        elapsed += 0.5
                        total_elapsed += 0.5
                        current = database_signature()
                        if current != version:
                            version = current
                            self.wfile.write(b"event: change\ndata: updated\n\n")
                            self.wfile.flush()
                            elapsed = 0.0
                        elif elapsed >= 15:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                            elapsed = 0.0
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return
                return
            if parsed.path == "/api/bucket/export":
                bucket_id = urllib.parse.parse_qs(parsed.query).get("id", [""])[0]
                with connect() as db:
                    bucket_name, markdown = bucket_markdown_text(db, bucket_id)
                body = markdown.encode("utf-8")
                file_stem = re.sub(r"[^A-Za-z0-9._-]+", "-", bucket_name).strip("-") or "bucket"
                self.send_response(200)
                self.send_header("Content-Type", "text/markdown; charset=utf-8")
                self.send_header("Content-Disposition", f'attachment; filename="{file_stem}.md"')
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed.path == "/api/attachment":
                attachment_id = urllib.parse.parse_qs(parsed.query).get("id", [""])[0]
                with connect() as db:
                    path, mime_type, file_name = attachment_file(db, attachment_id)
                body = read_regular_file(path, root=ATTACHMENT_DIR, max_bytes=8 * 1024 * 1024)
                safe_name = file_name.replace('"', "")
                self.send_response(200)
                self.send_header("Content-Type", mime_type)
                self.send_header("Content-Disposition", f'inline; filename="{safe_name}"')
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "private, max-age=300")
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed.path.startswith(("/styles/", "/js/")):
                workspace_root = WORKSPACE_HTML.parent.resolve()
                asset = (workspace_root / parsed.path.lstrip("/")).resolve()
                if workspace_root not in asset.parents or asset.suffix not in {".css", ".js"}:
                    self.json_response(404, {"error": "not found"})
                    return
                try:
                    body = read_regular_file(asset, root=workspace_root, max_bytes=2 * 1024 * 1024)
                except (OSError, ValueError):
                    self.json_response(404, {"error": "not found"})
                    return
                content_type = "text/css" if asset.suffix == ".css" else "text/javascript"
                self.send_response(200)
                self.send_header("Content-Type", f"{content_type}; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed.path == "/api/theme":
                self.json_response(200, omarchy_theme())
                return
            if parsed.path == "/api/buckets":
                with connect() as db:
                    buckets = [
                        {
                            "id": row["id"], "name": row["name"],
                            "count": row["note_count"], "submitted": row["submitted_count"],
                            "queued": row["queued_count"],
                        }
                        for row in db.execute(
                            "SELECT b.id, b.name, COUNT(n.id) AS note_count, "
                            "COUNT(CASE WHEN q.delivered_at IS NOT NULL THEN n.id END) AS submitted_count, "
                            "COUNT(CASE WHEN n.id IS NOT NULL AND q.delivered_at IS NULL THEN n.id END) AS queued_count "
                            "FROM buckets b LEFT JOIN notes n ON n.bucket_id = b.id "
                            "LEFT JOIN feed_queue q ON q.note_id = n.id "
                            "GROUP BY b.id ORDER BY b.position, b.name"
                        )
                    ]
                self.json_response(200, {"buckets": buckets})
                return
            if parsed.path == "/api/targets":
                self.json_response(200, targets_payload())
                return
            if parsed.path == "/api/bucket":
                bucket_id = urllib.parse.parse_qs(parsed.query).get("id", ["inbox"])[0]
                with connect() as db:
                    self.json_response(200, bucket_document(db, bucket_id))
                return
            if parsed.path in {"/", "/index.html"}:
                body = read_regular_file(
                    WORKSPACE_HTML, root=WORKSPACE_HTML.parent, max_bytes=512 * 1024,
                )
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            self.json_response(404, {"error": "not found"})
        except (OSError, sqlite3.Error, ValueError, json.JSONDecodeError) as error:
            self.json_response(400, {"error": str(error)})

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        try:
            self.validate_local_request()
            value = self.read_json()
            if parsed.path == "/api/shutdown":
                self.json_response(200, {"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            if parsed.path == "/api/attachment/create":
                note_id = str(value.get("noteId", ""))
                mime_type = str(value.get("mimeType", ""))
                encoded = str(value.get("data", ""))
                if mime_type not in IMAGE_TYPES:
                    raise ValueError("only PNG, JPEG, WebP, and GIF images are supported")
                try:
                    body = base64.b64decode(encoded, validate=True)
                except (ValueError, binascii.Error) as error:
                    raise ValueError("attachment data is invalid") from error
                if not body or len(body) > MAX_ATTACHMENT_BYTES:
                    raise ValueError("images must be between 1 byte and 8 MB")
                image_dimensions(body, mime_type)
                attachment_id = uuid.uuid4().hex
                file_name = re.sub(r"[^A-Za-z0-9._ -]", "_", str(value.get("name", "image")))[:100]
                if not file_name:
                    file_name = "image" + IMAGE_TYPES[mime_type]
                path = ATTACHMENT_DIR / f"{attachment_id}{IMAGE_TYPES[mime_type]}"
                ATTACHMENT_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
                with connect() as db:
                    if not db.execute("SELECT 1 FROM notes WHERE id = ?", (note_id,)).fetchone():
                        raise ValueError("note no longer exists")
                    count = db.execute(
                        "SELECT COUNT(*) FROM attachments WHERE note_id = ?", (note_id,)
                    ).fetchone()[0]
                    if count >= 5:
                        raise ValueError("a note can have at most 5 images")
                    descriptor = os.open(
                        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600,
                    )
                    try:
                        with os.fdopen(descriptor, "wb") as stream:
                            stream.write(body)
                        db.execute(
                            "INSERT INTO attachments(id, note_id, file_name, mime_type, file_path, position, created_at) "
                            "VALUES (?, ?, ?, ?, ?, ?, ?)",
                            (attachment_id, note_id, file_name, mime_type, str(path), count, int(time.time())),
                        )
                        db.commit()
                    except Exception:
                        path.unlink(missing_ok=True)
                        raise
                self.json_response(200, {"id": attachment_id})
                return
            if parsed.path == "/api/attachment/delete":
                attachment_id = str(value.get("id", ""))
                with connect() as db:
                    path, _, _ = attachment_file(db, attachment_id)
                    db.execute("DELETE FROM attachments WHERE id = ?", (attachment_id,))
                    db.commit()
                unlink_attachment_files([path])
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/routing":
                result = configure_routing(
                    str(value.get("targetId", "")),
                    str(value.get("deliveryMode", "")),
                    str(value.get("queueOrder", "")),
                )
                self.json_response(200, result)
                return
            if parsed.path == "/api/feed":
                action = str(value.get("action", ""))
                if action not in {"start", "stop"}:
                    raise ValueError("feed action must be start or stop")
                feed_control(argparse.Namespace(
                    action=action,
                    bucket_id=str(value.get("bucketId", "")),
                    section_id=str(value.get("sectionId", "")),
                    quiet=True,
                ))
                self.json_response(200, {"feedEnabled": action == "start"})
                return
            if parsed.path == "/api/notes/reset-all":
                self.json_response(200, {
                    "ok": True, "resetCount": reset_all_notes(),
                })
                return
            if parsed.path == "/api/bucket/export":
                with connect() as db:
                    path = write_bucket_export(db, str(value.get("id", "")))
                display_path = "~/" + str(path.relative_to(Path.home())) if path.is_relative_to(Path.home()) else str(path)
                self.json_response(200, {"path": str(path), "displayPath": display_path})
                return
            if parsed.path == "/api/bucket/import":
                markdown = str(value.get("markdown", ""))
                with connect() as db:
                    db.execute("BEGIN IMMEDIATE")
                    bucket_id, note_count = import_bucket_markdown(db, markdown)
                    db.commit()
                self.json_response(200, {"id": bucket_id, "noteCount": note_count})
                return
            if parsed.path == "/api/bucket/create":
                add_bucket(argparse.Namespace(name=str(value.get("name", ""))))
                with connect() as db:
                    self.json_response(200, {"id": active_bucket(db)})
                return
            if parsed.path == "/api/bucket/rename":
                rename_bucket(argparse.Namespace(
                    bucket_id=str(value.get("id", "")), name=str(value.get("name", "")),
                ))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/bucket/move":
                move_bucket(argparse.Namespace(
                    bucket_id=str(value.get("id", "")), direction=str(value.get("direction", "")),
                ))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/bucket/delete":
                delete_bucket(argparse.Namespace(bucket_id=str(value.get("id", ""))))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/create":
                add_section(argparse.Namespace(
                    name=str(value.get("name", "")), bucket_id=str(value.get("bucketId", "")),
                ))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/feed":
                select_feed_section(argparse.Namespace(section_id=str(value.get("id", ""))))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/feed-now":
                select_feed_section_now(argparse.Namespace(section_id=str(value.get("id", ""))))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/queue":
                add_feed_section_queue(argparse.Namespace(section_id=str(value.get("id", ""))))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/dequeue":
                remove_feed_section_queue(argparse.Namespace(section_id=str(value.get("id", ""))))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/rename":
                rename_section(argparse.Namespace(
                    section_id=str(value.get("id", "")), name=str(value.get("name", "")),
                ))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/clear":
                section_id = str(value.get("id", ""))
                self.json_response(200, clear_section_notes(
                    section_id, str(value.get("notes", "")),
                ))
                return
            if parsed.path == "/api/section/delete":
                notes_mode = str(value.get("notes", "move"))
                if notes_mode not in {"move", "discard"}:
                    raise ValueError("invalid section note handling")
                delete_section(argparse.Namespace(
                    section_id=str(value.get("id", "")), notes=notes_mode,
                ))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/section/place":
                before = value.get("beforeSectionId")
                place_section(argparse.Namespace(
                    section_id=str(value.get("sectionId", "")),
                    before_section_id=str(before) if before else None,
                ))
                self.json_response(200, {"ok": True})
                return
            if parsed.path == "/api/deliver":
                self.json_response(
                    200,
                    deliver_note(str(value.get("noteId", "")), str(value.get("targetId", ""))),
                )
                return
            if parsed.path == "/api/note/feed-now":
                self.json_response(
                    200, deliver_note(str(value.get("id", "")), force_working=True),
                )
                return
            with connect() as db:
                if parsed.path == "/api/note/sent":
                    set_note_sent(argparse.Namespace(
                        note_id=str(value.get("id", "")),
                        state="sent" if value.get("sent") is True else "unsent",
                    ))
                    self.json_response(200, {"ok": True})
                    return
                if parsed.path == "/api/note/delete":
                    note_id = str(value.get("id", ""))
                    row = db.execute(
                        "SELECT section_id, position FROM notes WHERE id = ?", (note_id,)
                    ).fetchone()
                    if not row:
                        raise ValueError("note no longer exists")
                    attachment_paths = remove_note_attachments(db, [note_id])
                    db.execute("DELETE FROM feed_queue WHERE note_id = ?", (note_id,))
                    db.execute("DELETE FROM notes WHERE id = ?", (note_id,))
                    db.execute(
                        "UPDATE notes SET position = position - 1 WHERE section_id = ? AND position > ?",
                        (row["section_id"], row["position"]),
                    )
                    db.commit()
                    unlink_attachment_files(attachment_paths)
                    self.json_response(200, {"ok": True})
                    return
                if parsed.path == "/api/note/update":
                    note_id = str(value.get("id", ""))
                    text = checked_note_text(str(value.get("text", "")))
                    if not db.execute("UPDATE notes SET text = ? WHERE id = ?", (text, note_id)).rowcount:
                        raise ValueError("note no longer exists")
                    db.commit()
                    self.json_response(200, {"ok": True})
                    return
                if parsed.path == "/api/note/create":
                    section_id, text = str(value.get("sectionId", "")), str(value.get("text", "")).strip()
                    before = value.get("beforeNoteId")
                    section = db.execute(
                        "SELECT bucket_id FROM sections WHERE id = ?", (section_id,)
                    ).fetchone()
                    if not section:
                        raise ValueError("section does not exist")
                    note_id = add_note_to_db(db, section["bucket_id"], text, section_id)
                    if before:
                        place_note_in_section(db, note_id, section_id, str(before))
                    db.commit()
                    self.json_response(200, {"id": note_id})
                    return
                if parsed.path == "/api/note/place":
                    before = value.get("beforeNoteId")
                    db.execute("BEGIN IMMEDIATE")
                    place_note_in_section(
                        db, str(value.get("noteId", "")), str(value.get("sectionId", "")),
                        str(before) if before else None,
                    )
                    db.commit()
                    self.json_response(200, {"ok": True})
                    return
            self.json_response(404, {"error": "not found"})
        except (OSError, sqlite3.Error, ValueError, json.JSONDecodeError) as error:
            self.json_response(400, {"error": str(error)})


class BoundedWorkspaceServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(
        self,
        server_address: tuple[str, int],
        request_handler: type[BaseHTTPRequestHandler],
        bind_and_activate: bool = True,
    ) -> None:
        self._request_slots = threading.BoundedSemaphore(16)
        super().__init__(server_address, request_handler, bind_and_activate)

    def process_request(self, request: socket.socket, client_address: object) -> None:
        if not self._request_slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._request_slots.release()
            raise

    def process_request_thread(self, request: socket.socket, client_address: object) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()
