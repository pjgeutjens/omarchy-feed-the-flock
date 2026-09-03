#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FEED_THE_FLOCK_STATE_DIR="$tmp/state" FEED_THE_FLOCK_EXPORT_DIR="$tmp/exports"
cat >"$tmp/voxtype" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == status ]]; then
  printf '{"class":"idle"}\n'
elif [[ ${1:-} == record && ${2:-} == start ]]; then
  for argument in "$@"; do
    case $argument in --file=*) printf 'Captured in selected section' >"${argument#--file=}";; esac
  done
fi
EOF
chmod +x "$tmp/voxtype"
export FEED_THE_FLOCK_VOXTYPE="$tmp/voxtype"
cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == api && ${2:-} == snapshot ]]; then
  status=${FAKE_HERDR_STATUS:-idle}
  printf '%s\n' "{\"id\":\"test\",\"result\":{\"type\":\"session_snapshot\",\"tabs\":[{\"tab_id\":\"w1:t2\",\"label\":\"review\"}],\"agents\":[{\"agent\":\"pi\",\"agent_status\":\"$status\",\"cwd\":\"/tmp/project\",\"pane_id\":\"w1:p2\",\"tab_id\":\"w1:t2\",\"terminal_title_stripped\":\"project\"}]}}"
elif [[ ${1:-} == agent && ${2:-} == prompt ]]; then
  printf '%s\n' "$@" >"$FAKE_HERDR_LOG"
  printf '%s\n' '{"id":"test","result":{"type":"agent_prompt"}}'
else
  exit 2
fi
EOF
chmod +x "$tmp/herdr"
export FEED_THE_FLOCK_HERDR="$tmp/herdr" FAKE_HERDR_LOG="$tmp/herdr.log" FEED_THE_FLOCK_DISABLE_WORKER=1 FAKE_HERDR_STATUS=idle
cli="$root/bin/feed-the-flock"

"$cli" init
state=$("$cli" state)
jq -e '.activeBucketId == "inbox" and (.buckets | length) == 3 and .totalCount == 0' <<< "$state" >/dev/null
"$cli" bucket delete ideas
"$cli" init
jq -e '(.buckets | length) == 2 and ([.buckets[].id] | index("ideas")) == null' \
  <<< "$("$cli" state)" >/dev/null
"$cli" bucket add "Ideas"
"$cli" bucket select inbox
targets=$("$cli" targets)
jq -e '.selectedTargetId == "" and .selectedTargetLabel == "Target unavailable"
  and ([.targets[].kind] | all(. == "herdr"))
  and ([.targets[].id] | index("clipboard")) == null' <<< "$targets" >/dev/null
if "$cli" target select clipboard >/dev/null 2>&1; then
  echo "clipboard was accepted as a delivery target" >&2
  exit 1
fi
python3 - "$FEED_THE_FLOCK_STATE_DIR/feed-the-flock.db" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE settings SET value = 'clipboard' WHERE key = 'delivery_target'")
    db.execute("UPDATE settings SET value = 'Clipboard' WHERE key = 'delivery_target_label'")
PY
jq -e '.selectedTargetId == "" and .selectedTargetLabel == "Target unavailable"' \
  <<< "$("$cli" targets)" >/dev/null
if "$cli" feed start >/dev/null 2>&1; then
  echo "feed started without a Herdr target" >&2
  exit 1
fi

oversized_note=$(python3 -c 'print("x" * 65537, end="")')
if "$cli" note add "$oversized_note" >/dev/null 2>&1; then
  echo "oversized note was accepted" >&2
  exit 1
fi
safe_import="$tmp/safe-import.md"
printf '# Symlink Import\n\n## Notes\n\n- [ ] unsafe path test\n' > "$safe_import"
ln -s "$safe_import" "$tmp/import-link.md"
if "$cli" bucket import "$tmp/import-link.md" >/dev/null 2>&1; then
  echo "symlinked Markdown import was accepted" >&2
  exit 1
fi

"$cli" note add "First note"
"$cli" note add "Second note"
state=$("$cli" state)
first=$(jq -r '.notes[0].id' <<< "$state")
second=$(jq -r '.notes[1].id' <<< "$state")
[[ $(jq -r '.notes | map(.text) | join("|")' <<< "$state") == 'First note|Second note' ]]

"$cli" note move "$second" up
state=$("$cli" state)
[[ $(jq -r '.notes | map(.text) | join("|")' <<< "$state") == 'Second note|First note' ]]

"$cli" note delete "$first"
[[ $("$cli" state | jq '.totalCount') == 1 ]]

"$cli" bucket select ideas
"$cli" note add "An idea"
state=$("$cli" state)
idea_id=$(jq -r '.notes[0].id' <<< "$state")
"$cli" note update "$idea_id" "A better idea"
state=$("$cli" state)
jq -e '.activeBucketId == "ideas" and .notes[0].text == "A better idea" and .totalCount == 2' <<< "$state" >/dev/null

"$cli" bucket add "Work Notes"
"$cli" bucket rename work-notes "Work Queue"
"$cli" bucket rename work-notes "Work Notes"
"$cli" section add "Interface"
interface_section=$("$cli" state | jq -r '.activeSectionId')
"$cli" section queue "$interface_section"
"$cli" bucket select ideas
jq -e --arg section "$interface_section" \
  '.activeBucketId == "ideas" and .feedBucketId == "inbox"
   and .nextFeedBucketId == "work-notes" and .nextFeedSectionId == $section' \
  <<< "$("$cli" state)" >/dev/null
"$cli" section feed-now "$interface_section"
jq -e --arg section "$interface_section" \
  '.feedBucketId == "work-notes" and .feedSectionId == $section
   and .nextFeedBucketId == "inbox" and (.feedQueue | length) == 1' \
  <<< "$("$cli" state)" >/dev/null
"$cli" section dequeue inbox:unsorted
jq -e '.feedQueue | length == 0' <<< "$("$cli" state)" >/dev/null
"$cli" bucket select work-notes
"$cli" section select "$interface_section"
"$cli" record start
state=$("$cli" state)
jq -e --arg section "$interface_section" \
  '.phase == "recording" and .activeSectionId == $section
   and .captureBucketName == "Work Notes" and .captureSectionName == "Interface"' \
  <<< "$state" >/dev/null
"$cli" record stop
for _ in {1..40}; do
  state=$("$cli" state)
  [[ $(jq -r '.phase' <<< "$state") == success ]] && break
  sleep 0.1
done
jq -e --arg section "$interface_section" \
  '.activeSectionId == $section and .notes[0].sectionId == $section
   and .notes[0].text == "Captured in selected section"' <<< "$state" >/dev/null
"$cli" note delete "$(jq -r '.notes[0].id' <<< "$state")"

cancelled_capture="$FEED_THE_FLOCK_STATE_DIR/captures/capture.cancel-test.txt"
printf 'Must not become a note' >"$cancelled_capture"
python3 - "$FEED_THE_FLOCK_STATE_DIR/feed-the-flock.db" "$cancelled_capture" <<'PY'
import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE settings SET value = 'transcribing' WHERE key = 'phase'")
    db.execute(
        "UPDATE settings SET value = ? WHERE key = 'active_capture'",
        (json.dumps({
            "path": sys.argv[2],
            "bucketId": "work-notes",
            "sectionId": "work-notes:interface",
        }),),
    )
PY
"$cli" record cancel
[[ ! -e $cancelled_capture ]]
jq -e '.phase == "cancelled"' <<< "$("$cli" state)" >/dev/null
"$cli" _finalize "$cancelled_capture" work-notes "$interface_section"
if "$cli" state | jq -e '.notes[] | select(.text == "Must not become a note")' >/dev/null; then
  echo "cancelled transcription was added after finalizer cancellation" >&2
  exit 1
fi

"$cli" note add "Animate incoming notes"
state=$("$cli" state)
work_note=$(jq -r '.notes[0].id' <<< "$state")
targets=$("$cli" targets)
jq -e '.targets[] | select(.id == "herdr:w1:p2")
  | .available == true and .label == "pi · review"' <<< "$targets" >/dev/null
"$cli" target select herdr:w1:p2
jq -e '.selectedTargetId == "herdr:w1:p2" and .selectedTargetLabel == "pi · review"' \
  <<< "$("$cli" targets)" >/dev/null
"$cli" mode select idle-all-batch
"$cli" order select lifo
[[ $("$cli" feed start) == on ]]
jq -e --arg section "$interface_section" \
  '.deliveryMode == "idle-all-batch" and .queueOrder == "lifo" and .feedEnabled == true
   and .feedBucketId == "work-notes" and .feedSectionId == $section' \
  <<< "$("$cli" state)" >/dev/null
"$cli" init
jq -e --arg bucket work-notes --arg section "$interface_section" \
  '.activeBucketId == $bucket and .activeSectionId == $section and .feedEnabled == true' \
  <<< "$("$cli" state)" >/dev/null
[[ $("$cli" feed resume) == on ]]
[[ $("$cli" feed stop) == off ]]
"$cli" deliver "$work_note" | jq -e '.ok == true' >/dev/null
[[ $(paste -sd '|' "$FAKE_HERDR_LOG") == 'agent|prompt|w1:p2|Animate incoming notes' ]]
jq -e --arg id "$work_note" '([.notes[].id] | index($id)) == null' \
  <<< "$("$cli" state)" >/dev/null
"$cli" note sent "$work_note" unsent
jq -e --arg id "$work_note" '.notes[] | select(.id == $id) | .sent == false' \
  <<< "$("$cli" state)" >/dev/null
"$cli" note add "Submit while working"
force_note=$("$cli" state | jq -r '.notes[] | select(.text == "Submit while working") | .id')
export FAKE_HERDR_STATUS=working
"$cli" deliver "$force_note" --force | jq -e '.ok == true' >/dev/null
jq -e --arg id "$force_note" '.activeNoteIds == [$id]' <<< "$("$cli" targets)" >/dev/null
jq -e --arg id "$force_note" '([.notes[].id] | index($id)) == null' \
  <<< "$("$cli" state)" >/dev/null
[[ $(sqlite3 "$FEED_THE_FLOCK_STATE_DIR/feed-the-flock.db" \
  "SELECT delivery_kind FROM feed_queue WHERE note_id = '$force_note'") == feed_now ]]
export FAKE_HERDR_STATUS=idle
jq -e '.activeNoteIds == []' <<< "$("$cli" targets)" >/dev/null
"$cli" section add "Archive"
archive_section=$("$cli" state | jq -r '.activeSectionId')
"$cli" note move-section "$work_note" "$archive_section"
"$cli" section place "$archive_section" "$interface_section"
[[ $("$cli" state | jq -r '.sections | map(.name) | join("|")') == 'Unsorted|Archive|Interface' ]]
"$cli" section move work-notes:unsorted right
[[ $("$cli" state | jq -r '.sections | map(.name) | join("|")') == 'Archive|Unsorted|Interface' ]]
"$cli" section move work-notes:unsorted left
"$cli" section rename "$archive_section" "Archived"
"$cli" section delete "$archive_section"
"$cli" section select work-notes:unsorted
state=$("$cli" state)
jq -e '.activeBucketId == "work-notes"
  and (.buckets | map(.name) | index("Work Notes") != null)
  and .notes[0].text == "Animate incoming notes"' <<< "$state" >/dev/null

markdown=$("$cli" bucket markdown work-notes)
grep -Fq '# Work Notes' "$markdown"
grep -Fq '## Unsorted' "$markdown"
grep -Fq -- '- [ ] Animate incoming notes' "$markdown"
import_markdown="$tmp/import.md"
sed 's/^# Work Notes$/# Imported Work Notes/' "$markdown" > "$import_markdown"
[[ $("$cli" bucket import "$import_markdown") == imported-work-notes ]]
jq -e '.activeBucketId == "imported-work-notes"
  and (.notes | map(.text) | index("Animate incoming notes") != null)' \
  <<< "$("$cli" state)" >/dev/null
"$cli" bucket select work-notes

"$cli" section add "Disposable"
disposable_section=$("$cli" state | jq -r '.activeSectionId')
"$cli" note add "Delete with section"
disposable_note=$("$cli" state | jq -r '.notes[0].id')
"$cli" section delete "$disposable_section" --notes discard
[[ $(sqlite3 "$FEED_THE_FLOCK_STATE_DIR/feed-the-flock.db" \
  "SELECT COUNT(*) FROM notes WHERE id = '$disposable_note'") == 0 ]]
"$cli" bucket add "Temporary"
"$cli" bucket delete temporary
"$cli" seed-demo
state=$("$cli" state)
jq -e '.activeBucketId == "feed-the-flock"
  and (.sections | map(.name) | index("Organization") != null)
  and .totalCount >= 11' <<< "$state" >/dev/null

sqlite3 "$FEED_THE_FLOCK_STATE_DIR/feed-the-flock.db" \
  "UPDATE feed_queue SET delivered_at = strftime('%s','now'), claim_token = NULL"
"$cli" feed start >/dev/null
"$cli" _feed-worker
jq -e '.feedEnabled == false' <<< "$("$cli" state)" >/dev/null
