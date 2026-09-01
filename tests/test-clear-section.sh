#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_FEED_STATE_DIR="$tmp/state"
cli="$root/bin/feed-the-flock"
db="$AGENT_FEED_STATE_DIR/agent-feed.db"

"$cli" init
"$cli" section add 'Clear Me'
section_id=$("$cli" state | jq -r '.activeSectionId')
"$cli" note add 'Pending clear note'
first_note=$("$cli" state | jq -r '.notes[] | select(.text == "Pending clear note") | .id')
"$cli" note add 'Submitted clear note'
second_note=$("$cli" state | jq -r '.notes[] | select(.text == "Submitted clear note") | .id')
"$cli" note sent "$second_note" sent
"$cli" section queue "$section_id"

"$cli" section select inbox:unsorted
"$cli" note add 'Unrelated note'
other_note=$("$cli" state | jq -r '.notes[] | select(.text == "Unrelated note") | .id')
"$cli" section select "$section_id"
mkdir -p "$AGENT_FEED_STATE_DIR/attachments" "$AGENT_FEED_STATE_DIR/attachments-escape"
printf managed >"$AGENT_FEED_STATE_DIR/attachments/clear.png"
printf unrelated >"$AGENT_FEED_STATE_DIR/attachments/other.png"
printf external >"$AGENT_FEED_STATE_DIR/attachments-escape/outside.png"
sqlite3 "$db" <<SQL
INSERT INTO attachments VALUES ('clear-managed', '$first_note', 'clear.png', 'image/png', '$AGENT_FEED_STATE_DIR/attachments/clear.png', 0, 1);
INSERT INTO attachments VALUES ('clear-external', '$first_note', 'outside.png', 'image/png', '$AGENT_FEED_STATE_DIR/attachments-escape/outside.png', 1, 2);
INSERT INTO attachments VALUES ('other-managed', '$other_note', 'other.png', 'image/png', '$AGENT_FEED_STATE_DIR/attachments/other.png', 0, 3);
SQL

if "$cli" section clear "$section_id" >/dev/null 2>&1; then
  echo 'section clear did not require confirmation' >&2
  exit 1
fi
if "$cli" section clear "$section_id" --confirm wrong-section >/dev/null 2>&1; then
  echo 'section clear accepted a mismatched confirmation' >&2
  exit 1
fi
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM notes WHERE section_id = '$section_id'") == 2 ]]
[[ -e $AGENT_FEED_STATE_DIR/attachments/clear.png ]]

sqlite3 "$db" "UPDATE feed_queue SET claim_token = 'active', claimed_at = strftime('%s','now') WHERE note_id = '$first_note'"
if "$cli" section clear "$section_id" --confirm "$section_id" >/dev/null 2>"$tmp/active-error"; then
  echo 'section clear removed an actively delivered note' >&2
  exit 1
fi
grep -Fq 'wait for active delivery' "$tmp/active-error"
sqlite3 "$db" "UPDATE feed_queue SET claim_token = NULL, claimed_at = NULL WHERE note_id = '$first_note'"

result=$("$cli" section clear "$section_id" --confirm "$section_id")
jq -e --arg id "$section_id" '
  .ok == true and .sectionId == $id and .sectionName == "Clear Me"
  and .deletedNotes == 2 and .deletedAttachments == 2
' <<<"$result" >/dev/null
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM sections WHERE id = '$section_id'") == 1 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM notes WHERE section_id = '$section_id'") == 0 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM feed_queue WHERE note_id IN ('$first_note', '$second_note')") == 0 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM attachments WHERE note_id IN ('$first_note', '$second_note')") == 0 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM section_feed_queue WHERE section_id = '$section_id'") == 1 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM notes WHERE id = '$other_note'") == 1 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM attachments WHERE id = 'other-managed'") == 1 ]]
[[ ! -e $AGENT_FEED_STATE_DIR/attachments/clear.png ]]
[[ -e $AGENT_FEED_STATE_DIR/attachments/other.png ]]
[[ -e $AGENT_FEED_STATE_DIR/attachments-escape/outside.png ]]
jq -e --arg id "$section_id" '.activeSectionId == $id and .notes == []' \
  <<<"$("$cli" state)" >/dev/null
