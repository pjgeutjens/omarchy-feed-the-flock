#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONPATH="$root/bin" python3 - <<'PY'
import json
import subprocess
import sys

from feed_the_flock.common import run_bounded
from feed_the_flock.feed import parse_herdr_targets
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

snapshot = json.dumps({"result": {"snapshot": {
    "tabs": [{"tab_id": "w1:t1", "label": "Work <b>"}],
    "agents": [{"pane_id": "w1:p1", "tab_id": "w1:t1", "agent": "omp", "agent_status": "idle"}],
}}}).encode()
targets = parse_herdr_targets(snapshot)
assert targets[0]["id"] == "herdr:w1:p1"
assert targets[0]["available"] is False
assert targets[0]["status"] == "untracked"
assert "herdr integration install omp" in targets[0]["waitError"]
assert "<" not in targets[0]["label"]

tracked_snapshot = json.dumps({"result": {"snapshot": {
    "tabs": [],
    "agents": [{
        "pane_id": "w1:p2", "agent": "omp", "agent_status": "idle", "state_change_seq": 42,
        "agent_session": {"source": "herdr:omp", "value": "session-id"},
    }],
}}}).encode()
tracked = parse_herdr_targets(tracked_snapshot)[0]
assert tracked["available"] is True
assert tracked["stateChangeSeq"] == 42

try:
    run_bounded([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.1)
except subprocess.TimeoutExpired:
    pass
else:
    raise SystemExit("wall-clock command timeout was not enforced")
PY
