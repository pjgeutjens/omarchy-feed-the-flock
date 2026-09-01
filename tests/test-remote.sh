#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
server=""
trap '[[ -z $server ]] || kill "$server" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
command=${!#}
command=${command/exec \$HOME\/.config\/omarchy\/plugins\/io.github.pjgeutjens.agentfeed\/bin\/feed-the-flock/exec "$FAKE_PLUGIN_ROOT/bin/feed-the-flock"}
AGENT_FEED_STATE_DIR="$FAKE_REMOTE_STATE" AGENT_FEED_DISABLE_WORKER=1 bash -c "$command"
EOF
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH"
export FAKE_PLUGIN_ROOT="$root"
export FAKE_REMOTE_STATE="$tmp/remote-state"
export AGENT_FEED_DISABLE_WORKER=1

AGENT_FEED_STATE_DIR="$FAKE_REMOTE_STATE" "$root/bin/feed-the-flock" init
AGENT_FEED_STATE_DIR="$FAKE_REMOTE_STATE" "$root/bin/feed-the-flock" note add 'Remote inspection note'

export AGENT_FEED_STATE_DIR="$tmp/local-state"
export AGENT_FEED_WORKSPACE_PORT=47833
cli="$root/bin/feed-the-flock"
"$cli" init
"$cli" remote connect example-host >/dev/null
"$cli" state | jq -e '
  .remoteMode == true and .remoteEndpoint == "example-host"
  and .notes[0].text == "Remote inspection note" and .readOnly == true
' >/dev/null
"$cli" remote bucket ideas
"$cli" state | jq -e '.activeBucketId == "ideas" and .remoteMode == true' >/dev/null
"$cli" remote bucket inbox

"$cli" _workspace-serve >/dev/null 2>&1 &
server=$!
for _ in {1..30}; do
  curl -fsS http://127.0.0.1:47833/api/buckets >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS http://127.0.0.1:47833/api/buckets | jq -e '.readOnly == true' >/dev/null
curl -fsS 'http://127.0.0.1:47833/api/bucket?id=inbox' \
  | jq -e '.readOnly == true and .sections[0].notes[0].text == "Remote inspection note"' >/dev/null
[[ $(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  --data '{"name":"blocked"}' http://127.0.0.1:47833/api/bucket/create) == 400 ]]

"$cli" remote disconnect
"$cli" state | jq -e '.remoteMode == false' >/dev/null
