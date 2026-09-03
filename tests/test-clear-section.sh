#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FEED_THE_FLOCK_STATE_DIR="$tmp/state"
cli="$root/bin/feed-the-flock"
db="$FEED_THE_FLOCK_STATE_DIR/feed-the-flock.db"

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
mkdir -p "$FEED_THE_FLOCK_STATE_DIR/attachments" "$FEED_THE_FLOCK_STATE_DIR/attachments-escape"
printf managed >"$FEED_THE_FLOCK_STATE_DIR/attachments/clear.png"
printf unrelated >"$FEED_THE_FLOCK_STATE_DIR/attachments/other.png"
printf external >"$FEED_THE_FLOCK_STATE_DIR/attachments-escape/outside.png"
sqlite3 "$db" <<SQL
INSERT INTO attachments VALUES ('clear-managed', '$first_note', 'clear.png', 'image/png', '$FEED_THE_FLOCK_STATE_DIR/attachments/clear.png', 0, 1);
INSERT INTO attachments VALUES ('clear-external', '$first_note', 'outside.png', 'image/png', '$FEED_THE_FLOCK_STATE_DIR/attachments-escape/outside.png', 1, 2);
INSERT INTO attachments VALUES ('other-managed', '$other_note', 'other.png', 'image/png', '$FEED_THE_FLOCK_STATE_DIR/attachments/other.png', 0, 3);
SQL

sqlite3 "$db" "UPDATE feed_queue SET claim_token = 'active', claimed_at = strftime('%s','now') WHERE note_id = '$first_note'"
if "$cli" section clear "$section_id" --notes move >/dev/null 2>"$tmp/active-error"; then
  echo 'section clear removed an actively delivered note' >&2
  exit 1
fi
grep -Fq 'wait for active delivery' "$tmp/active-error"
sqlite3 "$db" "UPDATE feed_queue SET claim_token = NULL, claimed_at = NULL WHERE note_id = '$first_note'"

result=$("$cli" section clear "$section_id" --notes move)
jq -e --arg id "$section_id" '
  .ok == true and .sectionId == $id and .sectionName == "Clear Me"
  and .mode == "move" and .movedNotes == 2 and .deletedNotes == 0
  and .deletedAttachments == 0
' <<<"$result" >/dev/null
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM sections WHERE id = '$section_id'") == 1 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM notes WHERE section_id = '$section_id'") == 0 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM feed_queue WHERE note_id IN ('$first_note', '$second_note')") == 2 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM attachments WHERE note_id IN ('$first_note', '$second_note')") == 2 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM section_feed_queue WHERE section_id = '$section_id'") == 1 ]]
[[ -e $FEED_THE_FLOCK_STATE_DIR/attachments/clear.png ]]
[[ -e $FEED_THE_FLOCK_STATE_DIR/attachments-escape/outside.png ]]

sqlite3 "$db" <<SQL
UPDATE notes SET section_id = '$section_id', position = 0 WHERE id = '$first_note';
UPDATE notes SET section_id = '$section_id', position = 1 WHERE id = '$second_note';
SQL
result=$("$cli" section clear "$section_id")
jq -e --arg id "$section_id" '
  .ok == true and .sectionId == $id and .sectionName == "Clear Me"
  and .mode == "discard" and .movedNotes == 0
  and .deletedNotes == 2 and .deletedAttachments == 2
' <<<"$result" >/dev/null
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM sections WHERE id = '$section_id'") == 1 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM notes WHERE section_id = '$section_id'") == 0 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM feed_queue WHERE note_id IN ('$first_note', '$second_note')") == 0 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM attachments WHERE note_id IN ('$first_note', '$second_note')") == 0 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM section_feed_queue WHERE section_id = '$section_id'") == 1 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM notes WHERE id = '$other_note'") == 1 ]]
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM attachments WHERE id = 'other-managed'") == 1 ]]
[[ ! -e $FEED_THE_FLOCK_STATE_DIR/attachments/clear.png ]]
[[ -e $FEED_THE_FLOCK_STATE_DIR/attachments/other.png ]]
[[ -e $FEED_THE_FLOCK_STATE_DIR/attachments-escape/outside.png ]]
jq -e --arg id "$section_id" '.activeSectionId == $id and .notes == []' \
  <<<"$("$cli" state)" >/dev/null
