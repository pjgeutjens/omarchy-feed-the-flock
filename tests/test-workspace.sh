#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
server=''
trap '[[ -z $server ]] || kill "$server" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export AGENT_FEED_STATE_DIR="$tmp/state" AGENT_FEED_EXPORT_DIR="$tmp/exports"
export AGENT_FEED_WORKSPACE_PORT=47832
export AGENT_FEED_DISABLE_WORKER=1 AGENT_FEED_HERDR="$tmp/herdr"
cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == api && ${2:-} == snapshot ]]; then
  printf '%s\n' '{"id":"test","result":{"type":"session_snapshot","tabs":[{"tab_id":"w1:t2","label":"review"}],"agents":[{"agent":"pi","agent_status":"idle","cwd":"/tmp/project","pane_id":"w1:p2","tab_id":"w1:t2","terminal_title_stripped":"project"}]}}'
fi
EOF
chmod +x "$tmp/herdr"
cli="$root/bin/feed-the-flock"
"$cli" init
"$cli" note add 'Viewer feed control test'
"$cli" bucket select ideas
"$cli" target select herdr:w1:p2
"$cli" _workspace-serve >"$tmp/workspace.log" 2>&1 & server=$!
for _ in {1..30}; do
  curl -fsS http://127.0.0.1:47832/js/app.js >/dev/null 2>&1 && break
  sleep 0.1
done

# Event streams and ordinary API requests must release every SQLite descriptor.
baseline_fds=$(find "/proc/$server/fd" -maxdepth 1 -type l | wc -l)
sse_clients=()
for index in {1..4}; do
  timeout 3 curl -sN http://127.0.0.1:47832/api/events >"$tmp/events-$index" 2>/dev/null &
  sse_clients+=("$!")
done
sleep 0.5
for index in {1..30}; do
  curl -fsS http://127.0.0.1:47832/api/buckets >/dev/null
  curl -fsS http://127.0.0.1:47832/api/targets >/dev/null
  "$cli" state >/dev/null
  "$cli" note add "Connection lifecycle $index"
done
for client in "${sse_clients[@]}"; do wait "$client" || true; done
grep -Fq 'event: change' "$tmp/events-1"
# The server discovers a closed SSE client on its next 15-second keepalive.
sleep 16
curl -fsS http://127.0.0.1:47832/api/buckets >/dev/null
if find "/proc/$server/fd" -maxdepth 1 -type l -lname '*agent-feed.db-* (deleted)' | grep -q .; then
  echo "workspace retained deleted SQLite sidecar descriptors" >&2
  find "/proc/$server/fd" -maxdepth 1 -type l -lname '*agent-feed.db-* (deleted)' -printf '%f -> %l\n' >&2
  exit 1
fi
after_fds=$(find "/proc/$server/fd" -maxdepth 1 -type l | wc -l)
(( after_fds <= baseline_fds + 4 )) || {
  echo "workspace descriptor count grew from $baseline_fds to $after_fds" >&2
  exit 1
}

curl -fsS http://127.0.0.1:47832/api/targets \
  | jq -e '.selectedTargetId == "herdr:w1:p2"
    and ([.targets[].id] | index("clipboard")) == null
    and ([.targets[].kind] | all(. == "herdr"))' >/dev/null
[[ $(curl -sS -o /dev/null -w '%{http_code}' -H 'Origin: https://evil.example' \
  http://127.0.0.1:47832/api/buckets) == 400 ]]
[[ $(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: evil.example' \
  http://127.0.0.1:47832/api/buckets) == 400 ]]
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"action":"start","bucketId":"inbox","sectionId":"inbox:unsorted"}' \
  http://127.0.0.1:47832/api/feed | jq -e '.feedEnabled == true' >/dev/null
jq -e '.activeBucketId == "ideas" and .feedBucketId == "inbox"
  and .feedSectionId == "inbox:unsorted" and .feedEnabled == true' \
  <<<"$("$cli" state)" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"action":"stop"}' http://127.0.0.1:47832/api/feed \
  | jq -e '.feedEnabled == false' >/dev/null
jq -e '.feedEnabled == false' <<<"$("$cli" state)" >/dev/null

exported=$(curl -fsS 'http://127.0.0.1:47832/api/bucket/export?id=inbox')
grep -Fq '# Inbox' <<<"$exported"
grep -Fq -- '- [ ] Viewer feed control test' <<<"$exported"
saved_export=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"id":"inbox"}' http://127.0.0.1:47832/api/bucket/export)
jq -e --arg path "$tmp/exports/Inbox.md" '.path == $path' <<<"$saved_export" >/dev/null
grep -Fq -- '- [ ] Viewer feed control test' "$tmp/exports/Inbox.md"
import_payload=$(jq -n --arg markdown $'# Imported Viewer\n\n## Queue\n\n- [ ] Pending import\n- [x] Submitted import\n' \
  '{markdown: $markdown}')
imported=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$import_payload" http://127.0.0.1:47832/api/bucket/import)
jq -e '.id == "imported-viewer" and .noteCount == 2' <<<"$imported" >/dev/null
curl -fsS 'http://127.0.0.1:47832/api/bucket?id=imported-viewer' \
  | jq -e '.name == "Imported Viewer" and .noteCount == 2 and .submittedCount == 1
    and .sections[0].name == "Queue"' >/dev/null
