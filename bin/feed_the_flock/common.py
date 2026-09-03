from __future__ import annotations

import os
import signal
import stat
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Sequence

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
ENTRYPOINT = PLUGIN_ROOT / "bin/feed-the-flock"
STATE_DIR = Path(os.environ.get("AGENT_FEED_STATE_DIR", Path.home() / ".local/state/agent-feed"))
DB_PATH = STATE_DIR / "agent-feed.db"
CAPTURE_DIR = STATE_DIR / "captures"
ATTACHMENT_DIR = STATE_DIR / "attachments"
EXPORT_DIR = Path(os.environ.get("AGENT_FEED_EXPORT_DIR", Path.home() / "Downloads"))
ATTACHMENT_CLIPBOARD_LOCK = STATE_DIR / "attachment-clipboard.lock"
LOG_PATH = STATE_DIR / "finalizer.log"
WORKSPACE_HOST = "127.0.0.1"
WORKSPACE_PORT = int(os.environ.get("AGENT_FEED_WORKSPACE_PORT", "47731"))
WORKSPACE_HTML = PLUGIN_ROOT / "workspace/index.html"
WORKSPACE_LOG = STATE_DIR / "workspace.log"
WORKSPACE_BROWSER_DIR = STATE_DIR / "workspace-browser"
FEED_LOG = STATE_DIR / "feed.log"
FEED_LOCK = STATE_DIR / "feed.lock"
FEED_RESUME_LOCK = STATE_DIR / "feed-resume.lock"
OMARCHY_THEME_NAME = Path.home() / ".local/state/omarchy/current/theme.name"
OMARCHY_USER_THEMES = Path.home() / ".config/omarchy/themes"
OMARCHY_SYSTEM_THEMES = Path("/usr/share/omarchy/themes")
VOXTYPE = os.environ.get("AGENT_FEED_VOXTYPE", "voxtype")
HERDR = os.environ.get("AGENT_FEED_HERDR", "herdr")
DEFAULT_BUCKETS = (("inbox", "Inbox"), ("agent-feed", "Agent Feed"), ("ideas", "Ideas"))
MAX_LOG_BYTES = 1024 * 1024


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run_bounded(
    command: Sequence[str], *, timeout: float, stdout_limit: int = 256 * 1024,
    stderr_limit: int = 64 * 1024,
) -> CommandResult:
    """Run a command with wall-clock and producer-side output bounds."""
    process = subprocess.Popen(
        list(command), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    overflow = threading.Event()

    def drain(name: str, stream: BinaryIO, limit: int) -> None:
        while chunk := stream.read(16 * 1024):
            remaining = limit + 1 - len(buffers[name])
            if remaining > 0:
                buffers[name].extend(chunk[:remaining])
            if len(buffers[name]) > limit:
                overflow.set()
                _kill_process_group(process)
                return

    threads = [
        threading.Thread(target=drain, args=("stdout", process.stdout, stdout_limit), daemon=True),
        threading.Thread(target=drain, args=("stderr", process.stderr, stderr_limit), daemon=True),
    ]
    for thread in threads:
        thread.start()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_process_group(process)
        process.wait(timeout=1)
        raise
    finally:
        for thread in threads:
            thread.join(timeout=1)
    if overflow.is_set():
        raise ValueError("command output exceeded the safety limit")
    return CommandResult(process.returncode, bytes(buffers["stdout"]), bytes(buffers["stderr"]))


def run_quiet(command: Sequence[str], *, timeout: float, input_data: bytes | None = None) -> int:
    """Run a command without retained output and kill its process group on timeout."""
    process = subprocess.Popen(
        list(command), stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        process.communicate(input=input_data, timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_process_group(process)
        process.wait(timeout=1)
        raise
    return process.returncode


def open_private_log(path: Path, *, max_bytes: int = MAX_LOG_BYTES) -> BinaryIO:
    """Open one owner-only regular log and cap retained output before appending."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid():
            raise ValueError("log path is unsafe")
        os.fchmod(descriptor, 0o600)
        if details.st_size > max_bytes:
            os.ftruncate(descriptor, 0)
        return os.fdopen(descriptor, "ab")
    except Exception:
        os.close(descriptor)
        raise


def read_regular_file(path: Path, *, root: Path, max_bytes: int) -> bytes:
    """Read one bounded regular file without following its final path component."""
    absolute = Path(os.path.abspath(path))
    root_absolute = Path(os.path.abspath(root))
    try:
        absolute.relative_to(root_absolute)
    except ValueError as error:
        raise ValueError("file path escapes its managed directory") from error
    descriptor = os.open(absolute, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode):
            raise ValueError("file is not regular")
        if details.st_uid != os.getuid():
            raise ValueError("file has an unexpected owner")
        if details.st_size > max_bytes:
            raise ValueError("file exceeds the safety limit")
        chunks: list[bytes] = []
        remaining = max_bytes + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b"".join(chunks)
        if len(value) > max_bytes:
            raise ValueError("file exceeds the safety limit")
        return value
    finally:
        os.close(descriptor)
