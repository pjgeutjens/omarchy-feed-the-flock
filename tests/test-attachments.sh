#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_FEED_STATE_DIR="$tmp/state" AGENT_FEED_HERDR="$tmp/herdr"
export TRANSPORT_LOG="$tmp/transport.log"

cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == api && ${2:-} == snapshot ]]; then
  printf '%s\n' '{"id":"test","result":{"type":"session_snapshot","tabs":[{"tab_id":"w1:t2","label":"review"}],"agents":[{"agent":"pi","agent_status":"idle","cwd":"/tmp/project","pane_id":"w1:p2","tab_id":"w1:t2","terminal_title_stripped":"project"}]}}'
else
  printf 'herdr %s\n' "$*" >>"$TRANSPORT_LOG"
fi
EOF
cat >"$tmp/wl-paste" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == --list-types ]]; then printf 'text/plain\n'; else printf 'original clipboard'; fi
EOF
cat >"$tmp/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null || true
printf 'wl-copy %s\n' "$*" >>"$TRANSPORT_LOG"
EOF
chmod +x "$tmp/herdr" "$tmp/wl-paste" "$tmp/wl-copy"
export PATH="$tmp:$PATH"

cli="$root/bin/feed-the-flock"
"$cli" init
"$cli" note add 'Inspect both images'
note_id=$("$cli" state | jq -r '.notes[0].id')
mkdir -p "$AGENT_FEED_STATE_DIR/attachments"
printf first >"$AGENT_FEED_STATE_DIR/attachments/first.png"
printf second >"$AGENT_FEED_STATE_DIR/attachments/second.png"
sqlite3 "$AGENT_FEED_STATE_DIR/agent-feed.db" <<SQL
INSERT INTO attachments VALUES ('first', '$note_id', 'first.png', 'image/png', '$AGENT_FEED_STATE_DIR/attachments/first.png', 0, 1);
INSERT INTO attachments VALUES ('second', '$note_id', 'second.png', 'image/png', '$AGENT_FEED_STATE_DIR/attachments/second.png', 1, 2);
SQL
"$cli" target select herdr:w1:p2
"$cli" deliver "$note_id" >/dev/null
[[ $(grep -c 'herdr agent send-keys w1:p2 ctrl+v' "$TRANSPORT_LOG") == 2 ]]
grep -Fq 'herdr agent prompt w1:p2 Inspect both images' "$TRANSPORT_LOG"
grep -Fq 'wl-copy --type text/plain' "$TRANSPORT_LOG"
