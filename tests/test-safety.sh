#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONPATH="$root/bin" python3 - <<'PY'
import subprocess
import sys
import tempfile
from pathlib import Path

from feed_the_flock.common import open_private_log, run_bounded
from feed_the_flock.workspace import image_dimensions

try:
    run_bounded(
        [sys.executable, "-c", "import sys; sys.stdout.write('x' * 200000)"],
        timeout=3, stdout_limit=1024, stderr_limit=1024,
    )
except ValueError:
    pass
else:
    raise SystemExit("producer-side output limit was not enforced")

png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + (32).to_bytes(4, "big") + (24).to_bytes(4, "big")
assert image_dimensions(png, "image/png") == (32, 24)
oversized = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + (9000).to_bytes(4, "big") + (24).to_bytes(4, "big")
try:
    image_dimensions(oversized, "image/png")
except ValueError:
    pass
else:
    raise SystemExit("oversized decoded image was accepted")

try:
    run_bounded([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.1)
except subprocess.TimeoutExpired:
    pass
else:
    raise SystemExit("wall-clock command timeout was not enforced")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    log_path = root / "worker.log"
    log_path.write_bytes(b"x" * 2048)
    with open_private_log(log_path, max_bytes=1024) as log:
        log.write(b"fresh\n")
    assert log_path.read_bytes() == b"fresh\n"
    assert log_path.stat().st_mode & 0o777 == 0o600

    outside = root / "outside.txt"
    outside.write_text("must survive")
    link = root / "linked.log"
    link.symlink_to(outside)
    try:
        open_private_log(link)
    except OSError:
        pass
    else:
        raise SystemExit("log helper followed a symlink")
    assert outside.read_text() == "must survive"
PY
