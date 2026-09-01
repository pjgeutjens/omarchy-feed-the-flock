#!/usr/bin/env python3
"""Install workspace assets without overwriting locally customized files."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

MAX_ASSET_BYTES = 2 * 1024 * 1024
MAX_ASSETS = 128


def read_regular(path: Path, maximum: int = MAX_ASSET_BYTES) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_size > maximum:
            raise ValueError(f"unsafe or oversized file: {path}")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b"".join(chunks)
        if len(value) > maximum:
            raise ValueError(f"oversized file: {path}")
        return value
    finally:
        os.close(descriptor)


def digest(path: Path) -> str:
    return hashlib.sha256(read_regular(path)).hexdigest()


def atomic_write(path: Path, content: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: install-workspace.py SOURCE DESTINATION")
    source, destination = map(Path, sys.argv[1:])
    state_dir = Path(os.environ.get(
        "AGENT_FEED_STATE_DIR", Path.home() / ".local/state/agent-feed"
    ))
    manifest_path = state_dir / "workspace-assets.json"
    try:
        loaded = json.loads(read_regular(manifest_path, 1024 * 1024).decode("utf-8"))
        previous = loaded if isinstance(loaded, dict) else {}
    except (OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError):
        previous = {}

    destination.mkdir(parents=True, exist_ok=True)
    candidates = sorted(source.rglob("*"))
    source_files: dict[str, Path] = {}
    for path in candidates:
        try:
            details = path.lstat()
        except OSError:
            continue
        if stat.S_ISLNK(details.st_mode):
            raise ValueError(f"workspace source must not contain symlinks: {path}")
        if stat.S_ISREG(details.st_mode):
            source_files[path.relative_to(source).as_posix()] = path
    if len(source_files) > MAX_ASSETS:
        raise ValueError(f"workspace contains more than {MAX_ASSETS} assets")

    current: dict[str, str] = {}
    conflicts: list[str] = []
    for relative, source_path in source_files.items():
        content = read_regular(source_path)
        shipped_hash = hashlib.sha256(content).hexdigest()
        current[relative] = shipped_hash
        target = destination / relative
        try:
            installed_hash = digest(target)
            target_exists = True
        except (OSError, ValueError):
            installed_hash = ""
            target_exists = target.exists() or target.is_symlink()
        previous_hash = str(previous.get(relative, ""))
        safe_to_update = not target_exists or installed_hash in {previous_hash, shipped_hash}
        if safe_to_update:
            atomic_write(target, content)
            target.with_name(target.name + ".upstream").unlink(missing_ok=True)
        else:
            atomic_write(target.with_name(target.name + ".upstream"), content)
            conflicts.append(relative)

    for relative, previous_hash in previous.items():
        if relative in source_files or not isinstance(previous_hash, str):
            continue
        target = destination / relative
        try:
            if digest(target) == previous_hash:
                target.unlink()
        except (OSError, ValueError):
            pass

    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_write(
        manifest_path, json.dumps(current, indent=2, sort_keys=True).encode("utf-8") + b"\n",
        mode=0o600,
    )

    if conflicts:
        print("Preserved customized workspace assets:", file=sys.stderr)
        for relative in conflicts:
            print(f"  {relative} (new version: {relative}.upstream)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
