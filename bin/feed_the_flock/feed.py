from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import select
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path

from .common import (
    ATTACHMENT_CLIPBOARD_LOCK,
    ATTACHMENT_DIR,
    ENTRYPOINT,
    FEED_LOCK,
    FEED_LOG,
    FEED_RESUME_LOCK,
    HERDR,
    open_private_log,
    read_regular_file,
    run_bounded,
    run_quiet,
)
from .store_core import (
    active_bucket,
    active_section,
    connect,
    feed_destination,
    promote_next_feed_section,
    set_setting,
    setting,
)

def safe_label(value: object, maximum: int) -> str:
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value)).replace("<", "‹").replace(">", "›")
    return " ".join(text.split())[:maximum]


def herdr_targets() -> tuple[list[dict[str, object]], str]:
    try:
        result = run_bounded(
            [HERDR, "api", "snapshot"], timeout=5,
            stdout_limit=512 * 1024, stderr_limit=64 * 1024,
        )
    except FileNotFoundError:
        return [], "Herdr is not installed"
    except subprocess.TimeoutExpired:
        return [], "Herdr did not respond"
    except ValueError:
        return [], "Herdr response exceeded the safety limit"
    if result.returncode != 0:
        message = (result.stderr or result.stdout).decode(errors="replace").strip() or "Herdr is unavailable"
        try:
            message = str(json.loads(message).get("error", {}).get("message", message))
        except (json.JSONDecodeError, AttributeError):
            pass
        return [], message[:240]
    try:
        response = json.loads(result.stdout.decode(errors="replace")).get("result", {})
        snapshot = response.get("snapshot", response)
        agents = snapshot.get("agents", [])
        raw_tabs = snapshot.get("tabs", [])
        tabs = {
            str(tab.get("tab_id", "")): safe_label(tab.get("label", ""), 120)
            for tab in (raw_tabs[:256] if isinstance(raw_tabs, list) else [])
            if isinstance(tab, dict)
        }
    except (json.JSONDecodeError, AttributeError, TypeError):
        return [], "Herdr returned invalid session data"
    targets: list[dict[str, object]] = []
    for agent in (agents[:128] if isinstance(agents, list) else []):
        if not isinstance(agent, dict):
            continue
        pane_id = str(agent.get("pane_id", ""))
        if not re.fullmatch(r"[A-Za-z0-9]+:p[A-Za-z0-9]+", pane_id):
            continue
        status = safe_label(agent.get("agent_status", "unknown"), 40)
        name = safe_label(agent.get("agent", "agent"), 80)
        tab_label = tabs.get(str(agent.get("tab_id", "")), "")
        context = safe_label(
            tab_label
            or agent.get("terminal_title_stripped")
            or Path(str(agent.get("foreground_cwd") or agent.get("cwd") or pane_id)).name
            or pane_id,
            120,
        )
        targets.append({
            "id": f"herdr:{pane_id}",
            "kind": "herdr",
            "label": f"{name} · {context}",
            "status": status,
            "available": status in {"idle", "done"},
            "paneId": pane_id,
        })
    return targets, ""


def targets_payload() -> dict[str, object]:
    targets, error = herdr_targets()
    all_targets = targets
    with connect() as db:
        selected_id = setting(db, "delivery_target", "")
        stored_label = setting(db, "delivery_target_label", "Target unavailable")
        current = next((target for target in all_targets if target["id"] == selected_id), None)
        selected_label = (
            str(current["label"]) if current
            else stored_label if selected_id
            else "Target unavailable"
        )
        changed = False
        if selected_label != stored_label:
            set_setting(db, "delivery_target_label", selected_label)
            changed = True
        try:
            stored_active_notes = json.loads(setting(db, "active_delivery_notes", "[]"))
            active_note_ids = (
                [str(note_id) for note_id in stored_active_notes]
                if isinstance(stored_active_notes, list) else []
            )
        except json.JSONDecodeError:
            active_note_ids = []
        if setting(db, "active_delivery_tracking", "0") != "1":
            set_setting(db, "active_delivery_tracking", "1")
            changed = True
            if not active_note_ids and current and current["status"] == "working":
                latest = db.execute(
                    "SELECT note_id FROM feed_queue WHERE delivered_at IS NOT NULL "
                    "ORDER BY delivery_sequence DESC LIMIT 1"
                ).fetchone()
                if latest:
                    active_note_ids = [str(latest["note_id"])]
                    set_setting(db, "active_delivery_notes", json.dumps(active_note_ids))
                    set_setting(db, "active_delivery_target", selected_id)
                    set_setting(db, "active_delivery_started", str(int(time.time())))
                    set_setting(db, "active_delivery_observed", "1")
        active_target_id = setting(db, "active_delivery_target", "")
        active_started = int(setting(db, "active_delivery_started", "0") or "0")
        active_observed = setting(db, "active_delivery_observed", "0") == "1"
        active_target = next(
            (target for target in all_targets if target["id"] == active_target_id), None
        )
        if active_note_ids and active_target and active_target["status"] == "working":
            if not active_observed:
                set_setting(db, "active_delivery_observed", "1")
                changed = True
        elif active_note_ids and (
            active_observed or not active_target or int(time.time()) - active_started >= 12
        ):
            active_note_ids = []
            set_setting(db, "active_delivery_notes", "[]")
            set_setting(db, "active_delivery_target", "")
            set_setting(db, "active_delivery_started", "0")
            set_setting(db, "active_delivery_observed", "0")
            changed = True
        if changed:
            db.commit()
        feed_enabled = setting(db, "feed_enabled", "0") == "1"
        delivery_mode = setting(db, "delivery_mode", "idle-active-next")
        queue_order = setting(db, "queue_order", "fifo")
    return {
        "targets": all_targets,
        "selectedTargetId": selected_id,
        "selectedTargetLabel": selected_label,
        "activeNoteIds": active_note_ids,
        "herdrError": error,
        "feedEnabled": feed_enabled,
        "deliveryMode": delivery_mode,
        "queueOrder": queue_order,
    }


DELIVERY_MODES = frozenset({
    "idle-active-next", "idle-active-batch", "idle-all-next", "idle-all-batch",
})
QUEUE_ORDERS = frozenset({"fifo", "lifo"})


def configure_routing(target_id: str, mode: str, order: str) -> dict[str, str]:
    """Validate and atomically replace the stopped feed's routing settings."""
    if mode not in DELIVERY_MODES:
        raise ValueError("unsupported delivery mode")
    if order not in QUEUE_ORDERS:
        raise ValueError("unsupported queue order")
    targets, error = herdr_targets()
    if error:
        raise ValueError(error)
    target = next((item for item in targets if item["id"] == target_id), None)
    if not target:
        raise ValueError("Herdr target is no longer available")
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        if setting(db, "feed_enabled", "0") == "1":
            raise ValueError("stop the feed before changing routing")
        set_setting(db, "delivery_target", target_id)
        set_setting(db, "delivery_target_label", str(target["label"]))
        set_setting(db, "delivery_mode", mode)
        set_setting(db, "queue_order", order)
        db.commit()
    return {
        "targetId": target_id,
        "targetLabel": str(target["label"]),
        "deliveryMode": mode,
        "queueOrder": order,
    }


def select_target(args: argparse.Namespace) -> None:
    payload = targets_payload()
    targets = payload["targets"]
    if not isinstance(targets, list):
        raise ValueError("delivery target response is invalid")
    target = next(
        (item for item in targets if isinstance(item, dict) and item.get("id") == args.target_id),
        None,
    )
    if not target:
        raise ValueError("delivery target is no longer available")
    with connect() as db:
        set_setting(db, "delivery_target", str(target["id"]))
        set_setting(db, "delivery_target_label", str(target["label"]))
        db.commit()


def select_mode(args: argparse.Namespace) -> None:
    with connect() as db:
        set_setting(db, "delivery_mode", args.mode)
        db.commit()


def start_feed_worker() -> None:
    if os.environ.get("FEED_THE_FLOCK_DISABLE_WORKER") == "1":
        return
    log = open_private_log(FEED_LOG)
    subprocess.Popen(
        [sys.executable, str(ENTRYPOINT), "_feed-worker"],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        start_new_session=True, close_fds=True,
    )
    log.close()


def start_feed_resume_countdown() -> None:
    if os.environ.get("FEED_THE_FLOCK_DISABLE_WORKER") == "1":
        return
    log = open_private_log(FEED_LOG)
    subprocess.Popen(
        [sys.executable, str(ENTRYPOINT), "_feed-resume"],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        start_new_session=True, close_fds=True,
    )
    log.close()


def resume_notification_message(seconds: int, destination: str) -> str:
    return f"Resuming {destination} in {seconds}…\nClick to cancel"


def resume_notification(
    seconds: int, destination: str, replace_id: int = 0,
) -> tuple[subprocess.Popen[bytes] | None, int]:
    read_fd, write_fd = os.pipe()
    command = [
        "notify-send", "--app-name=Feed the Flock", "--urgency=normal",
        f"--expire-time={max(1500, (seconds + 1) * 1000)}", f"--id-fd={write_fd}",
        "--action=cancel=Click here to cancel",
    ]
    if replace_id:
        command.append(f"--replace-id={replace_id}")
    command.extend(("Feed the Flock", resume_notification_message(seconds, destination)))
    try:
        process = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, pass_fds=(write_fd,), close_fds=True,
        )
    except FileNotFoundError:
        os.close(read_fd)
        os.close(write_fd)
        return None, replace_id
    os.close(write_fd)
    notification_id = replace_id
    ready, _, _ = select.select([read_fd], [], [], 2.0)
    if ready:
        try:
            notification_id = int(os.read(read_fd, 64).decode().strip() or replace_id)
        except ValueError:
            pass
    os.close(read_fd)
    return process, notification_id


def notification_was_cancelled(process: subprocess.Popen[bytes] | None) -> bool:
    if process is None or process.poll() is None:
        return False
    output = process.stdout.read(256).decode(errors="replace").strip() if process.stdout else ""
    return output == "cancel"


def finish_resume_notification(notification_id: int, message: str) -> None:
    command = ["notify-send", "--app-name=Feed the Flock", "--expire-time=3000"]
    if notification_id:
        command.append(f"--replace-id={notification_id}")
    command.extend(("Feed the Flock", message))
    try:
        run_quiet(command, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        pass


def feed_resume_countdown(_: argparse.Namespace) -> None:
    FEED_RESUME_LOCK.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with FEED_RESUME_LOCK.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        with connect() as db:
            deadline = int(setting(db, "feed_resume_after", "0") or "0")
            enabled = setting(db, "feed_enabled", "0") == "1"
            bucket_id, section_id = feed_destination(db)
            destination_row = db.execute(
                "SELECT b.name AS bucket_name, s.name AS section_name "
                "FROM sections s JOIN buckets b ON b.id = s.bucket_id "
                "WHERE b.id = ? AND s.id = ?", (bucket_id, section_id),
            ).fetchone()
        if not enabled or deadline <= int(time.time()):
            return
        destination = safe_label(
            f"{destination_row['bucket_name']} / {destination_row['section_name']}", 120,
        )
        process: subprocess.Popen[bytes] | None = None
        notification_id = 0
        cancelled = False
        while True:
            remaining = max(0, deadline - int(time.time()))
            if remaining <= 0:
                break
            if process is not None:
                cancelled = notification_was_cancelled(process)
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=0.5)
                if cancelled:
                    break
            process, notification_id = resume_notification(
                remaining, destination, notification_id,
            )
            for tick in range(10):
                time.sleep(0.1)
                if notification_was_cancelled(process):
                    cancelled = True
                    break
                with connect() as db:
                    if setting(db, "feed_enabled", "0") != "1":
                        cancelled = True
                        break
            if cancelled:
                break
        if process is not None:
            if notification_was_cancelled(process):
                cancelled = True
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=0.5)
        with connect() as db:
            still_enabled = setting(db, "feed_enabled", "0") == "1"
            if cancelled and still_enabled:
                set_setting(db, "feed_enabled", "0")
            set_setting(db, "feed_resume_after", "0")
            db.commit()
        if cancelled:
            finish_resume_notification(notification_id, "Feed resumption canceled")
        else:
            start_feed_worker()
            finish_resume_notification(notification_id, f"Feed resumed · {destination}")


def select_queue_order(args: argparse.Namespace) -> None:
    with connect() as db:
        set_setting(db, "queue_order", args.order)
        db.commit()


def feed_control(args: argparse.Namespace) -> None:
    with connect() as db:
        enabled = setting(db, "feed_enabled", "0") == "1"
        if args.action == "toggle":
            requested = not enabled
        elif args.action == "resume":
            requested = enabled
        else:
            requested = args.action == "start"
        if requested and not setting(db, "delivery_target", "").startswith("herdr:"):
            raise ValueError("select a Herdr target before starting the feed")
        if requested and not enabled and args.action != "resume":
            bucket_id = str(getattr(args, "bucket_id", "") or active_bucket(db))
            requested_section = str(getattr(args, "section_id", ""))
            section_id = requested_section or active_section(db, bucket_id)
            if not db.execute(
                "SELECT 1 FROM sections WHERE id = ? AND bucket_id = ?", (section_id, bucket_id)
            ).fetchone():
                raise ValueError("the selected feed section is unavailable")
            set_setting(db, "feed_bucket", bucket_id)
            set_setting(db, "feed_section", section_id)
            db.execute("DELETE FROM section_feed_queue WHERE section_id = ?", (section_id,))
        if args.action == "resume" and requested:
            deadline = int(setting(db, "feed_resume_after", "0") or "0")
            if deadline <= int(time.time()):
                set_setting(db, "feed_resume_after", str(int(time.time()) + 10))
                db.commit()
        elif args.action != "resume":
            set_setting(db, "feed_enabled", "1" if requested else "0")
            set_setting(db, "feed_resume_after", "0")
            db.commit()
    if requested:
        if args.action == "resume":
            start_feed_resume_countdown()
        else:
            start_feed_worker()
    if not getattr(args, "quiet", False):
        print("on" if requested else "off")


def clipboard_snapshot() -> tuple[str, bytes] | None:
    listed = run_bounded(
        ["wl-paste", "--list-types"], timeout=3,
        stdout_limit=32 * 1024, stderr_limit=16 * 1024,
    )
    if listed.returncode != 0:
        return None
    types = [
        value.strip() for value in listed.stdout.decode(errors="replace").splitlines() if value.strip()
    ]
    preferred = next((value for value in types if value.startswith("image/")), None)
    if not preferred:
        preferred = next((value for value in types if value.startswith("text/plain")), None)
    if not preferred:
        return None
    pasted = run_bounded(
        ["wl-paste", "--type", preferred], timeout=3,
        stdout_limit=8 * 1024 * 1024, stderr_limit=16 * 1024,
    )
    return (preferred, pasted.stdout) if pasted.returncode == 0 else None


def restore_clipboard(snapshot: tuple[str, bytes] | None) -> None:
    command = ["wl-copy", "--clear"] if snapshot is None else ["wl-copy", "--type", snapshot[0]]
    run_quiet(command, input_data=None if snapshot is None else snapshot[1], timeout=3)


def run_herdr_prompt(target: dict[str, object], text: str) -> None:
    try:
        result = run_bounded(
            [HERDR, "agent", "prompt", str(target["paneId"]), text], timeout=12,
            stdout_limit=64 * 1024, stderr_limit=64 * 1024,
        )
    except FileNotFoundError as error:
        raise ValueError("Herdr is not installed") from error
    except subprocess.TimeoutExpired as error:
        raise ValueError("Herdr did not accept the prompt in time") from error
    except ValueError as error:
        raise ValueError("Herdr returned too much output") from error
    if result.returncode != 0:
        message = (result.stderr or result.stdout).decode(errors="replace").strip() or "Herdr rejected the prompt"
        try:
            message = str(json.loads(message).get("error", {}).get("message", message))
        except (json.JSONDecodeError, AttributeError):
            pass
        raise ValueError(message[:240])


def prompt_herdr_target(
    target: dict[str, object], text: str, attachments: list[tuple[bytes, str]] | None = None
) -> None:
    attachments = attachments or []
    if not attachments:
        run_herdr_prompt(target, text)
        return
    ATTACHMENT_CLIPBOARD_LOCK.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with ATTACHMENT_CLIPBOARD_LOCK.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            snapshot = clipboard_snapshot()
        except (FileNotFoundError, subprocess.TimeoutExpired, ValueError) as error:
            raise ValueError("Wayland clipboard data is unavailable or exceeds 8 MB") from error
        try:
            for attachment, mime_type in attachments:
                try:
                    copied_returncode = run_quiet(
                        ["wl-copy", "--type", mime_type], input_data=attachment, timeout=5,
                    )
                except OSError as error:
                    raise ValueError(f"could not stage image on clipboard: {error}") from error
                except subprocess.TimeoutExpired as error:
                    raise ValueError("clipboard image staging timed out") from error
                if copied_returncode != 0:
                    raise ValueError("Wayland clipboard rejected the image")
                try:
                    pasted = run_bounded(
                        [HERDR, "agent", "send-keys", str(target["paneId"]), "ctrl+v"],
                        timeout=5, stdout_limit=32 * 1024, stderr_limit=32 * 1024,
                    )
                except OSError as error:
                    raise ValueError(f"could not send image paste key: {error}") from error
                except subprocess.TimeoutExpired as error:
                    raise ValueError("Herdr image paste key timed out") from error
                except ValueError as error:
                    raise ValueError("Herdr image paste response exceeded the safety limit") from error
                if pasted.returncode != 0:
                    message = pasted.stderr.decode(errors="replace").strip()
                    raise ValueError(message[:240] or "the target agent rejected image paste")
                time.sleep(0.35)
            run_herdr_prompt(target, text)
        finally:
            try:
                restore_clipboard(snapshot)
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass


def claim_feed_notes(note_ids: list[str]) -> str:
    token = uuid.uuid4().hex
    with connect() as db:
        db.execute("BEGIN IMMEDIATE")
        for note_id in note_ids:
            changed = db.execute(
                "UPDATE feed_queue SET claim_token = ?, claimed_at = ?, error = '' "
                "WHERE note_id = ? AND delivered_at IS NULL AND claim_token IS NULL",
                (token, int(time.time()), note_id),
            ).rowcount
            if changed != 1:
                db.rollback()
                raise ValueError("note was already sent or is currently being submitted")
        db.commit()
    return token


def finish_feed_claim(
    note_ids: list[str], token: str, error: str = "", delivery_kind: str = "worker",
    target_id: str = "",
) -> None:
    with connect() as db:
        sequence = db.execute(
            "SELECT COALESCE(MAX(delivery_sequence), 0) FROM feed_queue"
        ).fetchone()[0]
        delivered_at = int(time.time())
        for note_id in note_ids:
            if error:
                db.execute(
                    "UPDATE feed_queue SET claim_token = NULL, claimed_at = NULL, error = ? "
                    "WHERE note_id = ? AND claim_token = ?",
                    (error[:240], note_id, token),
                )
            else:
                sequence += 1
                db.execute(
                    "UPDATE feed_queue SET delivered_at = ?, delivery_kind = ?, "
                    "delivery_sequence = ?, claim_token = NULL, claimed_at = NULL, error = '' "
                    "WHERE note_id = ? AND claim_token = ?",
                    (delivered_at, delivery_kind, sequence, note_id, token),
                )
        if not error and target_id:
            set_setting(db, "active_delivery_notes", json.dumps(note_ids))
            set_setting(db, "active_delivery_target", target_id)
            set_setting(db, "active_delivery_started", str(delivered_at))
            set_setting(db, "active_delivery_observed", "0")
        db.commit()


def attachment_files(db: sqlite3.Connection, note_ids: list[str]) -> list[tuple[bytes, str]]:
    if not note_ids:
        return []
    placeholders = ",".join("?" for _ in note_ids)
    root = ATTACHMENT_DIR.resolve()
    attachments: list[tuple[bytes, str]] = []
    for row in db.execute(
        f"SELECT file_path, mime_type FROM attachments WHERE note_id IN ({placeholders}) "
        "ORDER BY note_id, position, created_at",
        tuple(note_ids),
    ):
        try:
            content = read_regular_file(
                Path(row["file_path"]), root=root, max_bytes=8 * 1024 * 1024,
            )
        except (OSError, ValueError) as error:
            raise ValueError("an attached image file is unavailable or unsafe") from error
        attachments.append((content, str(row["mime_type"])))
    return attachments


def deliver_note(
    note_id: str, target_id: str | None = None, force_working: bool = False
) -> dict[str, object]:
    if not target_id:
        with connect() as db:
            target_id = setting(db, "delivery_target", "")
    if not target_id.startswith("herdr:"):
        raise ValueError("unsupported delivery target")
    targets, error = herdr_targets()
    if error:
        raise ValueError(error)
    target = next((item for item in targets if item["id"] == target_id), None)
    if not target:
        raise ValueError("Herdr agent is no longer available")
    if force_working:
        if target["status"] not in {"idle", "done", "working"}:
            raise ValueError(f"Herdr agent is {target['status']}; prompt injection is unavailable")
    elif not target["available"]:
        raise ValueError(f"Herdr agent is {target['status']}; wait until it is idle")
    with connect() as db:
        note = db.execute("SELECT text FROM notes WHERE id = ?", (note_id,)).fetchone()
        attachments = attachment_files(db, [note_id]) if note else []
    if not note:
        raise ValueError("note no longer exists")
    token = claim_feed_notes([note_id])
    try:
        prompt_herdr_target(target, str(note["text"]), attachments)
    except ValueError as error:
        finish_feed_claim([note_id], token, str(error))
        raise
    finish_feed_claim(
        [note_id], token, delivery_kind="feed_now" if force_working else "manual",
        target_id=target_id,
    )
    return {"ok": True, "targetId": target_id, "label": target["label"]}


def targets_command(_: argparse.Namespace) -> None:
    print(json.dumps(targets_payload(), ensure_ascii=False))


def deliver_command(args: argparse.Namespace) -> None:
    print(json.dumps(
        deliver_note(args.note_id, args.target_id, force_working=bool(args.force)),
        ensure_ascii=False,
    ))


def pending_feed_notes(
    db: sqlite3.Connection, mode: str, queue_order: str
) -> list[sqlite3.Row]:
    bucket_id, section_id = feed_destination(db)
    parameters: list[object] = [bucket_id]
    section_filter = ""
    section_order = "s.position, s.name"
    if mode.startswith("idle-active-"):
        section_filter = " AND n.section_id = ?"
        parameters.append(section_id)
    else:
        anchor = db.execute("SELECT position FROM sections WHERE id = ?", (section_id,)).fetchone()[0]
        section_order = "CASE WHEN s.position >= ? THEN 0 ELSE 1 END, s.position, s.name"
        parameters.append(anchor)
    return db.execute(
        "SELECT q.note_id, n.text, n.section_id, s.name AS section_name "
        "FROM feed_queue q JOIN notes n ON n.id = q.note_id "
        "JOIN sections s ON s.id = n.section_id "
        "WHERE q.delivered_at IS NULL AND q.claim_token IS NULL AND n.bucket_id = ?" + section_filter + " "
        "ORDER BY " + section_order + ", n.position "
        + ("DESC, n.created_at DESC" if queue_order == "lifo" else "ASC, n.created_at ASC"),
        tuple(parameters),
    ).fetchmany(200)


def batch_selection(notes: list[sqlite3.Row]) -> list[sqlite3.Row]:
    selected: list[sqlite3.Row] = []
    total_bytes = 0
    for note in notes[:100]:
        note_bytes = len(str(note["text"]).encode("utf-8"))
        if selected and total_bytes + note_bytes > 512 * 1024:
            break
        selected.append(note)
        total_bytes += note_bytes
    return selected


def batch_prompt(notes: list[sqlite3.Row]) -> str:
    lines = ["Feed the Flock batch:", ""]
    section = ""
    for note in notes:
        if note["section_name"] != section:
            section = str(note["section_name"])
            lines.extend((f"## {section}", ""))
        lines.extend((f"- {str(note['text']).strip()}", ""))
    return "\n".join(lines).strip()


def feed_worker(_: argparse.Namespace) -> None:
    FEED_LOCK.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with FEED_LOCK.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        while True:
            with connect() as db:
                if setting(db, "feed_enabled", "0") != "1":
                    return
                resume_after = int(setting(db, "feed_resume_after", "0") or "0")
                if resume_after > int(time.time()):
                    should_pause = True
                    target_id = ""
                    mode = ""
                    queue_order = ""
                    notes = []
                else:
                    should_pause = False
                    target_id = setting(db, "delivery_target", "")
                    mode = setting(db, "delivery_mode", "idle-active-next")
                    queue_order = setting(db, "queue_order", "fifo")
                    current_bucket_id, current_section_id = feed_destination(db)
                    current_pending = db.execute(
                        "SELECT COUNT(*) FROM feed_queue q JOIN notes n ON n.id = q.note_id "
                        "WHERE q.delivered_at IS NULL AND n.bucket_id = ? AND n.section_id = ?",
                        (current_bucket_id, current_section_id),
                    ).fetchone()[0]
                    if current_pending == 0:
                        promote_next_feed_section(db)
                    current_bucket_id, current_section_id = feed_destination(db)
                    notes = pending_feed_notes(db, mode, queue_order)
                    if not notes:
                        claim_parameters: list[object] = [current_bucket_id]
                        claim_section_filter = ""
                        if mode.startswith("idle-active-"):
                            current_bucket_id, current_section_id = feed_destination(db)
                            claim_parameters = [current_bucket_id, current_section_id]
                            claim_section_filter = " AND n.section_id = ?"
                        claimed_pending = db.execute(
                            "SELECT COUNT(*) FROM feed_queue q JOIN notes n ON n.id = q.note_id "
                            "WHERE q.delivered_at IS NULL AND q.claim_token IS NOT NULL "
                            "AND n.bucket_id = ?" + claim_section_filter,
                            tuple(claim_parameters),
                        ).fetchone()[0]
                        if claimed_pending == 0:
                            set_setting(db, "feed_enabled", "0")
                            set_setting(db, "feed_resume_after", "0")
                            db.commit()
                            return
            if should_pause:
                time.sleep(0.25)
                continue
            if not target_id or not notes:
                time.sleep(0.75)
                continue
            targets, error = herdr_targets()
            target = next((item for item in targets if item["id"] == target_id), None)
            if error or not target or not target["available"]:
                time.sleep(0.75)
                continue
            selected = batch_selection(notes) if mode.endswith("batch") else notes[:1]
            if mode.startswith("idle-all-") and selected:
                with connect() as db:
                    set_setting(db, "feed_section", str(selected[0]["section_id"]))
                    db.commit()
            text = batch_prompt(selected) if mode.endswith("batch") else str(selected[0]["text"])
            note_ids = [str(note["note_id"]) for note in selected]
            try:
                token = claim_feed_notes(note_ids)
            except ValueError:
                time.sleep(0.25)
                continue
            try:
                with connect() as db:
                    attachments = attachment_files(db, note_ids)
                prompt_herdr_target(target, text, attachments)
            except ValueError as error:
                finish_feed_claim(note_ids, token, str(error))
                time.sleep(1.5)
                continue
            finish_feed_claim(note_ids, token, target_id=target_id)
            time.sleep(1.0)
