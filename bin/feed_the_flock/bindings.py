from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sqlite3
import stat
import tempfile
from pathlib import Path

from .common import ENTRYPOINT, run_bounded

HYPR_CONFIG_DIR = Path(os.environ.get("FEED_THE_FLOCK_HYPR_CONFIG_DIR", Path.home() / ".config/hypr"))
BINDING_FILE = HYPR_CONFIG_DIR / "feed-the-flock-bindings.lua"
USER_BINDINGS = HYPR_CONFIG_DIR / "bindings.lua"
MANAGED_HEADER = "-- Managed by Feed the Flock. Change this through the Omarchy widget."
LEGACY_HEADER = "-- Managed by Feed the Flock. Remove with scripts/manage-binding.sh remove."
LOADER_COMMENT = "-- Feed the Flock owns its configurable global keybindings."
LEGACY_LOADER_COMMENT = "-- Feed the Flock owns its capture keybinding."
LOADER = 'pcall(require, "hypr.feed-the-flock-bindings")'
DEFAULT_RECORD_BINDING = "SHIFT + F9"
DEFAULT_FEED_BINDING = "SUPER + CTRL + SHIFT + F"
LEGACY_FEED_BINDING = "SHIFT + F10"
CAPTURE_SUBMAP = "feed-the-flock-shortcut-capture"
MAX_CONFIG_BYTES = 2 * 1024 * 1024


class BindingConflict(ValueError):
    def __init__(self, shortcut: str, actions: list[dict[str, str]]) -> None:
        self.shortcut = shortcut
        self.actions = actions
        super().__init__(f"keybinding is already in use: {shortcut}")

    def payload(self) -> dict[str, object]:
        return {
            "type": "binding_conflict",
            "shortcut": self.shortcut,
            "actions": self.actions,
        }


def _setting_exists(db: sqlite3.Connection, key: str) -> bool:
    return db.execute("SELECT 1 FROM settings WHERE key = ?", (key,)).fetchone() is not None


def _managed_file_data() -> bytes | None:
    try:
        descriptor = os.open(BINDING_FILE, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except (FileNotFoundError, OSError):
        return None
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid() \
                or details.st_size > MAX_CONFIG_BYTES:
            return None
        data = os.read(descriptor, MAX_CONFIG_BYTES + 1)
        return data if len(data) <= MAX_CONFIG_BYTES else None
    finally:
        os.close(descriptor)


def _migrated_binding_values() -> dict[str, object]:
    data = _managed_file_data()
    text = data.decode(errors="replace") if data is not None else ""
    recognized = text.startswith((MANAGED_HEADER, LEGACY_HEADER))
    if text.startswith(LEGACY_HEADER):
        record = DEFAULT_RECORD_BINDING
        feed = LEGACY_FEED_BINDING
    else:
        record_match = re.search(
            r'o\.bind\("([A-Z0-9 +_]+)", "Start Feed the Flock capture', text,
        )
        feed_match = re.search(
            r'o\.bind\("([A-Z0-9 +_]+)", "Toggle Feed the Flock delivery', text,
        )
        record = record_match.group(1) if record_match else ""
        feed = feed_match.group(1) if feed_match else ""
    return {
        "recordBinding": record,
        "recordBindingOverride": bool(record and f'hl.unbind("{record}")' in text),
        "feedBinding": feed,
        "feedBindingOverride": bool(feed and f'hl.unbind("{feed}")' in text),
        "bindingsInstalled": recognized,
    }


def binding_values(db: sqlite3.Connection, *, persist_migration: bool = True) -> dict[str, object]:
    from .store_core import set_setting, setting

    if not _setting_exists(db, "record_binding"):
        inferred = _migrated_binding_values()
        if persist_migration:
            set_setting(db, "record_binding", str(inferred["recordBinding"]))
            set_setting(db, "record_binding_override", "1" if inferred["recordBindingOverride"] else "0")
            set_setting(db, "feed_binding", str(inferred["feedBinding"]))
            set_setting(db, "feed_binding_override", "1" if inferred["feedBindingOverride"] else "0")
            set_setting(db, "bindings_installed", "1" if inferred["bindingsInstalled"] else "0")
            db.commit()
        return inferred
    return {
        "recordBinding": setting(db, "record_binding", ""),
        "recordBindingOverride": setting(db, "record_binding_override", "0") == "1",
        "feedBinding": setting(db, "feed_binding", ""),
        "feedBindingOverride": setting(db, "feed_binding_override", "0") == "1",
        "bindingsInstalled": setting(db, "bindings_installed", "0") == "1",
    }


def normalize_binding(value: str) -> tuple[str, str, int]:
    source = value.upper().replace("CONTROL", "CTRL").replace("META", "SUPER").replace("WIN", "SUPER")
    parts = [part.strip() for part in source.split("+")]
    if not parts or any(not part for part in parts):
        raise ValueError("use a keybinding such as SHIFT + F9")
    modifiers: list[str] = []
    key = ""
    aliases = {"SUPER": ("SUPER", 64), "CTRL": ("CTRL", 4), "SHIFT": ("SHIFT", 1), "ALT": ("ALT", 8)}
    modmask = 0
    for part in parts:
        if part in aliases:
            name, mask = aliases[part]
            if name in modifiers:
                raise ValueError(f"{name} appears more than once")
            modifiers.append(name)
            modmask += mask
        else:
            if key:
                raise ValueError("keybinding must contain exactly one key")
            if not re.fullmatch(r"[A-Z0-9][A-Z0-9_]*", part):
                raise ValueError(f"unsupported keybinding key: {part}")
            key = part
    if not key:
        raise ValueError("keybinding must contain a key")
    ordered = [name for name in ("SUPER", "CTRL", "SHIFT", "ALT") if name in modifiers]
    return " + ".join([*ordered, key]), key, modmask


def _conflict_field(value: object, limit: int) -> str:
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(value)).strip()[:limit]


def binding_conflicts(key: str, modmask: int) -> list[dict[str, str]]:
    result = run_bounded(["hyprctl", "binds", "-j"], timeout=5, stdout_limit=1024 * 1024)
    if result.returncode != 0:
        raise ValueError("could not inspect existing Hyprland keybindings")
    try:
        bindings = json.loads(result.stdout.decode(errors="replace"))
    except json.JSONDecodeError as error:
        raise ValueError("Hyprland returned invalid keybinding data") from error
    if not isinstance(bindings, list) or len(bindings) > 4096:
        raise ValueError("Hyprland returned too many keybindings")
    own_descriptions = {
        "Start Feed the Flock capture (push-to-talk)",
        "Stop Feed the Flock capture (push-to-talk)",
        "Toggle Feed the Flock delivery",
    }
    conflicts: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()
    for binding in bindings:
        if not isinstance(binding, dict):
            continue
        if str(binding.get("key", "")).upper() != key or binding.get("modmask") != modmask:
            continue
        description = _conflict_field(binding.get("description", ""), 160)
        if description in own_descriptions:
            continue
        dispatcher = _conflict_field(binding.get("dispatcher", "unknown"), 80) or "unknown"
        argument = _conflict_field(binding.get("arg", ""), 160)
        source = _conflict_field(
            binding.get("source", binding.get("source_file", "")), 240,
        ) or "Live Hyprland registry; source file not exposed"
        signature = (description, dispatcher, argument)
        if signature in seen:
            continue
        seen.add(signature)
        conflicts.append({
            "description": description or "Undescribed Hyprland action",
            "dispatcher": dispatcher,
            "argument": argument,
            "source": source,
        })
        if len(conflicts) >= 8:
            break
    return conflicts


def _read_snapshot(path: Path) -> tuple[bool, bytes, int]:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except FileNotFoundError:
        return False, b"", 0o600
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid() \
                or details.st_size > MAX_CONFIG_BYTES:
            raise ValueError(f"refusing unsafe configuration file: {path}")
        chunks: list[bytes] = []
        remaining = MAX_CONFIG_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(data) > MAX_CONFIG_BYTES:
        raise ValueError(f"configuration file exceeds 2 MB: {path}")
    return True, data, stat.S_IMODE(details.st_mode)


def _atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError(f"refusing symbolic-link configuration path: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _lua_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _binding_config(values: dict[str, object]) -> bytes:
    helper = shlex.quote(str(ENTRYPOINT))
    lines = [MANAGED_HEADER]
    record = str(values["recordBinding"])
    feed = str(values["feedBinding"])
    if record:
        if values["recordBindingOverride"]:
            lines.append(f'hl.unbind("{_lua_string(record)}")')
        lines.extend([
            f'o.bind("{_lua_string(record)}", "Start Feed the Flock capture (push-to-talk)", "{_lua_string(helper + " record start")}")',
            f'o.bind("{_lua_string(record)}", "Stop Feed the Flock capture (push-to-talk)", "{_lua_string(helper + " record stop")}", {{ release = true }})',
        ])
    else:
        lines.append("-- No recording keybinding is assigned.")
    if feed:
        if values["feedBindingOverride"]:
            lines.append(f'hl.unbind("{_lua_string(feed)}")')
        lines.append(f'o.bind("{_lua_string(feed)}", "Toggle Feed the Flock delivery", "{_lua_string(helper + " feed toggle")}")')
    else:
        lines.append("-- No feeding keybinding is assigned.")
    lines.extend([
        "-- Global binds are suspended while the panel captures a replacement shortcut.",
        f'hl.define_submap("{CAPTURE_SUBMAP}", function()',
        '  hl.bind("ESCAPE", hl.dsp.submap("reset"), {',
        '    description = "Cancel Feed the Flock keybinding capture",',
        "    non_consuming = true,",
        "  })",
        "end)",
        "",
    ])
    return "\n".join(lines).encode()


def _with_loader(snapshot: tuple[bool, bytes, int]) -> bytes:
    _, data, _ = snapshot
    text = data.decode(errors="strict") if data else ""
    lines = text.splitlines()
    if LOADER not in lines:
        if text and not text.endswith("\n"):
            text += "\n"
        text += f"\n{LOADER_COMMENT}\n{LOADER}\n"
    return text.encode()


def _without_loader(snapshot: tuple[bool, bytes, int]) -> bytes:
    _, data, _ = snapshot
    lines = data.decode(errors="strict").splitlines()
    return ("\n".join(
        line for line in lines if line not in {LOADER_COMMENT, LEGACY_LOADER_COMMENT, LOADER}
    ).rstrip() + "\n").encode()


def _reload_hyprland() -> None:
    result = run_bounded(["hyprctl", "reload"], timeout=8, stdout_limit=64 * 1024)
    if result.returncode != 0:
        raise ValueError("Hyprland could not reload the keybinding configuration")
    errors = run_bounded(["hyprctl", "configerrors"], timeout=5, stdout_limit=128 * 1024)
    message = errors.stdout.decode(errors="replace").strip()
    if errors.returncode != 0 or message:
        raise ValueError(f"Hyprland rejected the keybinding configuration: {message[:400]}")


def _restore(path: Path, snapshot: tuple[bool, bytes, int]) -> None:
    existed, data, mode = snapshot
    if existed:
        _atomic_write(path, data, mode)
    else:
        path.unlink(missing_ok=True)


def apply_bindings(db: sqlite3.Connection, values: dict[str, object]) -> None:
    from .store_core import set_setting

    binding_snapshot = _read_snapshot(BINDING_FILE)
    user_snapshot = _read_snapshot(USER_BINDINGS)
    if binding_snapshot[0] and not binding_snapshot[1].decode(errors="replace").startswith(
        (MANAGED_HEADER, LEGACY_HEADER)
    ):
        raise ValueError(f"leaving an unrecognized binding file untouched: {BINDING_FILE}")
    try:
        _atomic_write(BINDING_FILE, _binding_config(values), binding_snapshot[2] if binding_snapshot[0] else 0o600)
        _atomic_write(USER_BINDINGS, _with_loader(user_snapshot), user_snapshot[2] if user_snapshot[0] else 0o600)
        _reload_hyprland()
    except Exception:
        _restore(BINDING_FILE, binding_snapshot)
        _restore(USER_BINDINGS, user_snapshot)
        try:
            _reload_hyprland()
        except (OSError, ValueError):
            pass
        raise
    for key, value in (
        ("record_binding", values["recordBinding"]),
        ("record_binding_override", "1" if values["recordBindingOverride"] else "0"),
        ("feed_binding", values["feedBinding"]),
        ("feed_binding_override", "1" if values["feedBindingOverride"] else "0"),
        ("bindings_installed", "1"),
    ):
        set_setting(db, key, str(value))
    db.commit()


def set_binding(args: argparse.Namespace) -> None:
    from .store_core import connect

    normalized, key, modmask = normalize_binding(args.shortcut)
    with connect() as db:
        values = binding_values(db)
        other = str(values["feedBinding"] if args.kind == "record" else values["recordBinding"])
        if normalized == other:
            raise ValueError("that keybinding is already used by the other Feed the Flock action")
        conflicts = binding_conflicts(key, modmask)
        preserve_override = (
            normalized == str(values[f"{args.kind}Binding"])
            and bool(values[f"{args.kind}BindingOverride"])
        )
        if conflicts and not args.override and not preserve_override:
            raise BindingConflict(normalized, conflicts)
        override_active = preserve_override or bool(conflicts and args.override)
        values[f"{args.kind}Binding"] = normalized
        values[f"{args.kind}BindingOverride"] = override_active
        apply_bindings(db, values)
    print(f"{args.kind.title()} keybinding: {normalized}" + (" (override active)" if override_active else ""))


def clear_binding(args: argparse.Namespace) -> None:
    from .store_core import connect

    with connect() as db:
        values = binding_values(db)
        values[f"{args.kind}Binding"] = ""
        values[f"{args.kind}BindingOverride"] = False
        apply_bindings(db, values)
    print(f"{args.kind.title()} keybinding: not assigned")


def install_default_bindings(_: argparse.Namespace) -> None:
    from .store_core import connect

    with connect() as db:
        values = binding_values(db)
        if not values["recordBinding"] and not binding_conflicts("F9", 1):
            values["recordBinding"] = DEFAULT_RECORD_BINDING
            values["recordBindingOverride"] = False
        if not values["feedBinding"] and not binding_conflicts("F", 69):
            values["feedBinding"] = DEFAULT_FEED_BINDING
            values["feedBindingOverride"] = False
        apply_bindings(db, values)
    print(f"Recording keybinding: {values['recordBinding']}")
    print(f"Feeding keybinding: {values['feedBinding']}")


def register_binding_parser(commands: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    binding = commands.add_parser("binding")
    binding_commands = binding.add_subparsers(dest="binding_command", required=True)
    binding_commands.add_parser("install").set_defaults(func=install_default_bindings)
    binding_commands.add_parser("remove").set_defaults(func=remove_binding_integration)
    for kind in ("record", "feed"):
        binding_kind = binding_commands.add_parser(kind)
        binding_kind_commands = binding_kind.add_subparsers(dest="binding_action", required=True)
        binding_set = binding_kind_commands.add_parser("set")
        binding_set.add_argument("shortcut")
        binding_set.add_argument("--override", action="store_true")
        binding_set.set_defaults(func=set_binding, kind=kind)
        binding_kind_commands.add_parser("clear").set_defaults(func=clear_binding, kind=kind)


def remove_binding_integration(_: argparse.Namespace) -> None:
    from .store_core import connect, set_setting

    with connect() as db:
        binding_snapshot = _read_snapshot(BINDING_FILE)
        user_snapshot = _read_snapshot(USER_BINDINGS)
        if binding_snapshot[0] and not binding_snapshot[1].decode(errors="replace").startswith(
            (MANAGED_HEADER, LEGACY_HEADER)
        ):
            raise ValueError(f"leaving an unrecognized binding file untouched: {BINDING_FILE}")
        try:
            BINDING_FILE.unlink(missing_ok=True)
            if user_snapshot[0]:
                _atomic_write(USER_BINDINGS, _without_loader(user_snapshot), user_snapshot[2])
            _reload_hyprland()
        except Exception:
            _restore(BINDING_FILE, binding_snapshot)
            _restore(USER_BINDINGS, user_snapshot)
            try:
                _reload_hyprland()
            except (OSError, ValueError):
                pass
            raise
        for key, value in (
            ("record_binding", ""), ("record_binding_override", "0"),
            ("feed_binding", ""), ("feed_binding_override", "0"),
            ("bindings_installed", "0"),
        ):
            set_setting(db, key, value)
        db.commit()
    print("Removed the Feed the Flock Hyprland integration; notes and state were preserved.")
