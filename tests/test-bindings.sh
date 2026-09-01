#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/hypr"
cat > "$tmp/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == binds && ${2:-} == -j ]]; then
  if [[ -f ${FAKE_BINDING_CONFLICT:-} ]]; then
    printf '%s\n' '[{"key":"F7","modmask":64,"description":"Existing workspace action","dispatcher":"workspace","arg":"7","source":"~/.config/hypr/bindings.lua"},{"key":"F7","modmask":64,"description":"","dispatcher":"exec","arg":"launch-existing"}]'
  else
    printf '%s\n' '[]'
  fi
elif [[ ${1:-} == configerrors ]]; then
  [[ ! -f ${FAKE_CONFIG_ERROR:-} ]] || printf '%s\n' 'synthetic configuration error'
fi
EOF
chmod +x "$tmp/bin/hyprctl"
: > "$tmp/hypr/bindings.lua"
cat > "$tmp/hypr/agent-feed-bindings.lua" <<'EOF'
-- Managed by Feed the Flock. Change this through the Omarchy widget.
-- No recording keybinding is assigned.
-- No feeding keybinding is assigned.
EOF
printf '%s\n' '-- Feed the Flock owns its configurable global keybindings.' \
  'pcall(require, "hypr.agent-feed-bindings")' >> "$tmp/hypr/bindings.lua"
export PATH="$tmp/bin:$PATH"
export AGENT_FEED_STATE_DIR="$tmp/state"
export AGENT_FEED_HYPR_CONFIG_DIR="$tmp/hypr"
export FAKE_BINDING_CONFLICT="$tmp/conflict"
export FAKE_CONFIG_ERROR="$tmp/config-error"
cli="$root/bin/feed-the-flock"

"$cli" init
"$cli" state | jq -e '
  .recordBinding == "" and .feedBinding == "" and .bindingsInstalled == true
' >/dev/null

"$cli" binding record set 'SUPER + F8' >/dev/null
"$cli" binding feed set 'CTRL + SHIFT + F8' >/dev/null
"$cli" state | jq -e '
  .recordBinding == "SUPER + F8" and .feedBinding == "CTRL + SHIFT + F8"
  and .bindingsInstalled == true
' >/dev/null
grep -Fq 'Start Feed the Flock capture' "$tmp/hypr/agent-feed-bindings.lua"
grep -Fq 'Toggle Feed the Flock delivery' "$tmp/hypr/agent-feed-bindings.lua"
grep -Fxq 'pcall(require, "hypr.agent-feed-bindings")' "$tmp/hypr/bindings.lua"

touch "$tmp/conflict"
set +e
conflict_json=$("$cli" binding record set 'SUPER + F7' 2>&1)
status=$?
set -e
[[ $status == 3 ]]
jq -e '
  .type == "binding_conflict" and .shortcut == "SUPER + F7"
  and .actions == [
    {"description":"Existing workspace action","dispatcher":"workspace","argument":"7","source":"~/.config/hypr/bindings.lua"},
    {"description":"Undescribed Hyprland action","dispatcher":"exec","argument":"launch-existing","source":"Live Hyprland registry; source file not exposed"}
  ]
' <<<"$conflict_json" >/dev/null
"$cli" state | jq -e '.recordBinding == "SUPER + F8" and .recordBindingOverride == false' >/dev/null

"$cli" binding record set 'SUPER + F7' --override >/dev/null
grep -Fq 'hl.unbind("SUPER + F7")' "$tmp/hypr/agent-feed-bindings.lua"
"$cli" state | jq -e '.recordBinding == "SUPER + F7" and .recordBindingOverride == true' >/dev/null

rm "$tmp/conflict"
"$cli" binding record set 'SUPER + F6' >/dev/null
! grep -Fq 'hl.unbind("SUPER + F7")' "$tmp/hypr/agent-feed-bindings.lua"
"$cli" state | jq -e '.recordBinding == "SUPER + F6" and .recordBindingOverride == false' >/dev/null

before_binding=$(sha256sum "$tmp/hypr/agent-feed-bindings.lua")
before_loader=$(sha256sum "$tmp/hypr/bindings.lua")
touch "$tmp/config-error"
if "$cli" binding record set 'SUPER + F5' >/dev/null 2>&1; then
  echo 'invalid Hyprland configuration was accepted' >&2
  exit 1
fi
[[ $(sha256sum "$tmp/hypr/agent-feed-bindings.lua") == "$before_binding" ]]
[[ $(sha256sum "$tmp/hypr/bindings.lua") == "$before_loader" ]]
"$cli" state | jq -e '.recordBinding == "SUPER + F6"' >/dev/null
rm "$tmp/config-error"

"$cli" binding record clear >/dev/null
"$cli" binding remove >/dev/null
[[ ! -e $tmp/hypr/agent-feed-bindings.lua ]]
! grep -Fq 'hypr.agent-feed-bindings' "$tmp/hypr/bindings.lua"
"$cli" state | jq -e '
  .recordBinding == "" and .feedBinding == "" and .bindingsInstalled == false
' >/dev/null

# Migrate the original fixed-key installation without losing its reversible overrides.
rm -rf "$tmp/state"
cat > "$tmp/hypr/agent-feed-bindings.lua" <<EOF
-- Managed by Feed the Flock. Remove with scripts/manage-binding.sh remove.
hl.unbind("SHIFT + F9")
hl.unbind("SHIFT + F10")
o.bind("SHIFT + F9", "Start Feed the Flock capture (push-to-talk)", "$cli record start")
o.bind("SHIFT + F9", "Stop Feed the Flock capture (push-to-talk)", "$cli record stop", { release = true })
o.bind("SHIFT + F10", "Toggle Feed the Flock delivery", "$cli feed toggle")
EOF
printf '%s\n' '-- Feed the Flock owns its configurable global keybindings.' \
  'pcall(require, "hypr.agent-feed-bindings")' > "$tmp/hypr/bindings.lua"
"$cli" init
"$cli" state | jq -e '
  .recordBinding == "SHIFT + F9" and .feedBinding == "SHIFT + F10"
  and .recordBindingOverride == true and .feedBindingOverride == true
  and .bindingsInstalled == true
' >/dev/null
"$cli" binding remove >/dev/null

python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
overlay = (root / "BindingsOverlay.qml").read_text()
panel = (root / "Panel.qml").read_text()
help_overlay = (root / "KeybindingsOverlay.qml").read_text()
assert 'text: "Configure keybindings"' in overlay
assert "ScrollView {\n      id: bodyScroll" in overlay
assert 'text: "Requested shortcut: " + root.pendingShortcut' in overlay
assert 'text: root.conflictActions.length === 1 ? "Occupied action" : "Occupied actions"' in overlay
assert 'wrapMode: Text.WordWrap' in overlay
assert 'text: "Action: " + String(modelData.dispatcher || "unknown")' in overlay
assert 'text: "Source: " + String(modelData.source || "Unknown")' in overlay
assert "Original preserved:" in overlay
assert "It never edits the existing action's source." in overlay
assert 'text: "Override temporarily"' in overlay
assert 'text === "k" || text === "K"' in panel
assert 'tooltipText: "Configure keybindings (K)"' in panel
assert '{ category: "Navigation", keys: "K", action: "Configure keybindings" }' in help_overlay
PY
