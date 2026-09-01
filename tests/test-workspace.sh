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
  printf '%s\n' '{"id":"test","result":{"type":"session_snapshot","tabs":[{"tab_id":"w1:t2","label":"review"}],"agents":[{"agent":"pi","agent_status":"idle","state_change_seq":1,"agent_session":{"agent":"pi","kind":"id","source":"herdr:pi","value":"test-session"},"cwd":"/tmp/project","pane_id":"w1:p2","tab_id":"w1:t2","terminal_title_stripped":"project"}]}}'
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
