#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_FEED_STATE_DIR="$tmp/state" AGENT_FEED_DISABLE_WORKER=0
export AGENT_FEED_HERDR="$tmp/herdr" FAKE_HERDR_ROOT="$tmp/herdr-state"
mkdir -p "$FAKE_HERDR_ROOT"
printf 'idle\n' > "$FAKE_HERDR_ROOT/status"
printf '10\n' > "$FAKE_HERDR_ROOT/seq"
printf '1\n' > "$FAKE_HERDR_ROOT/tracked"
printf 'omp\n' > "$FAKE_HERDR_ROOT/agent"
: > "$FAKE_HERDR_ROOT/prompts"

cat > "$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == api && ${2:-} == snapshot ]]; then
  status=$(<"$FAKE_HERDR_ROOT/status")
  seq=$(<"$FAKE_HERDR_ROOT/seq")
  agent=$(<"$FAKE_HERDR_ROOT/agent")
  session=""
  if [[ $(<"$FAKE_HERDR_ROOT/tracked") == 1 ]]; then
    session=",\"agent_session\":{\"agent\":\"$agent\",\"kind\":\"id\",\"source\":\"herdr:$agent\",\"value\":\"session-id\"}"
  fi
  printf '%s\n' "{\"result\":{\"snapshot\":{\"tabs\":[],\"agents\":[{\"agent\":\"$agent\",\"agent_status\":\"$status\",\"state_change_seq\":$seq$session,\"pane_id\":\"w1:p2\",\"tab_id\":\"w1:t1\"}]}}}"
elif [[ ${1:-} == agent && ${2:-} == prompt ]]; then
  printf '%s\n' "${4:-}" >> "$FAKE_HERDR_ROOT/prompts"
  printf '%s\n' '{"result":{"type":"agent_prompt"}}'
else
  exit 2
fi
EOF
chmod +x "$tmp/herdr"
cli="$root/bin/feed-the-flock"

wait_for_prompt_count() {
  local expected=$1 count
  for _ in {1..50}; do
    count=$(wc -l < "$FAKE_HERDR_ROOT/prompts")
    [[ $count == "$expected" ]] && return 0
    sleep 0.1
  done
  printf 'expected %s delivered prompts, found %s\n' "$expected" "$count" >&2
  return 1
}

"$cli" init
"$cli" note add 'first queued turn'
"$cli" note add 'second queued turn'
"$cli" target select herdr:w1:p2
"$cli" feed start >/dev/null
wait_for_prompt_count 1

# A stale Idle snapshot after delivery must not turn the second note into steering.
sleep 2
[[ $(wc -l < "$FAKE_HERDR_ROOT/prompts") == 1 ]]

# A visible Working -> Idle lifecycle releases the next queued note.
printf 'working\n' > "$FAKE_HERDR_ROOT/status"
printf '11\n' > "$FAKE_HERDR_ROOT/seq"
sleep 1
[[ $(wc -l < "$FAKE_HERDR_ROOT/prompts") == 1 ]]
printf 'idle\n' > "$FAKE_HERDR_ROOT/status"
printf '12\n' > "$FAKE_HERDR_ROOT/seq"
wait_for_prompt_count 2
for _ in {1..30}; do
  [[ $("$cli" state | jq -r .feedEnabled) == false ]] && break
  sleep 0.1
done
[[ $("$cli" state | jq -r .feedEnabled) == false ]]


# A fast completed lifecycle can be recognized from its advanced state sequence.
printf '14\n' > "$FAKE_HERDR_ROOT/seq"
"$cli" note add 'third queued turn'
"$cli" feed start >/dev/null
wait_for_prompt_count 3
"$cli" note add 'fourth queued turn'
printf '16\n' > "$FAKE_HERDR_ROOT/seq"
wait_for_prompt_count 4

"$cli" feed stop >/dev/null

# Without lifecycle integration, wait-mode delivery fails closed before starting.
printf '0\n' > "$FAKE_HERDR_ROOT/tracked"
"$cli" note add 'must remain pending'
if "$cli" feed start >"$tmp/untracked.out" 2>"$tmp/untracked.err"; then
  echo 'untracked OMP feed unexpectedly started' >&2
  exit 1
fi
grep -Fq 'herdr integration install omp' "$tmp/untracked.err"
[[ $("$cli" state | jq -r .feedEnabled) == false ]]
