#!/usr/bin/env python3
"""Install workspace assets without overwriting locally customized files."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: install-workspace.py SOURCE DESTINATION")
    source, destination = map(Path, sys.argv[1:])
    state_dir = Path(os.environ.get(
        "AGENT_FEED_STATE_DIR", Path.home() / ".local/state/agent-feed"
    ))
    manifest_path = state_dir / "workspace-assets.json"
    try:
        previous = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        previous = {}

    destination.mkdir(parents=True, exist_ok=True)
    current: dict[str, str] = {}
    conflicts: list[str] = []
    source_files = {
        path.relative_to(source).as_posix(): path
        for path in source.rglob("*") if path.is_file()
    }

    for relative, source_path in sorted(source_files.items()):
        target = destination / relative
        shipped_hash = digest(source_path)
        current[relative] = shipped_hash
        installed_hash = digest(target) if target.is_file() else ""
        previous_hash = str(previous.get(relative, ""))
        safe_to_update = not target.exists() or installed_hash in {previous_hash, shipped_hash}
        if safe_to_update:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, target)
            target.with_name(target.name + ".upstream").unlink(missing_ok=True)
        else:
            upstream = target.with_name(target.name + ".upstream")
            upstream.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, upstream)
            conflicts.append(relative)

    for relative, previous_hash in previous.items():
        if relative in source_files:
            continue
        target = destination / relative
        if target.is_file() and digest(target) == previous_hash:
            target.unlink()

    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = manifest_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(manifest_path)

    if conflicts:
        print("Preserved customized workspace assets:", file=sys.stderr)
        for relative in conflicts:
            print(f"  {relative} (new version: {relative}.upstream)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
