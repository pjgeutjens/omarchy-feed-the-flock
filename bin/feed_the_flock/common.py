from __future__ import annotations

import os
from pathlib import Path

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
FEED_LOG = STATE_DIR / "feed.log"
FEED_LOCK = STATE_DIR / "feed.lock"
FEED_RESUME_LOCK = STATE_DIR / "feed-resume.lock"
OMARCHY_THEME_NAME = Path.home() / ".local/state/omarchy/current/theme.name"
OMARCHY_USER_THEMES = Path.home() / ".config/omarchy/themes"
OMARCHY_SYSTEM_THEMES = Path("/usr/share/omarchy/themes")
VOXTYPE = os.environ.get("AGENT_FEED_VOXTYPE", "voxtype")
HERDR = os.environ.get("AGENT_FEED_HERDR", "herdr")
DEFAULT_BUCKETS = (("inbox", "Inbox"), ("agent-feed", "Agent Feed"), ("ideas", "Ideas"))
