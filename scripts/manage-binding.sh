#!/usr/bin/env bash
set -euo pipefail

mode=${1:-install}
plugin_id=io.github.pjgeutjens.agentfeed
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
helper="$plugin_dir/bin/feed-the-flock"
binding_file="$HOME/.config/hypr/agent-feed-bindings.lua"
user_bindings="$HOME/.config/hypr/bindings.lua"
loader='pcall(require, "hypr.agent-feed-bindings")'
comment='-- Feed the Flock owns its capture keybinding.'

reload_and_validate() {
  hyprctl reload >/dev/null
  errors=$(hyprctl configerrors)
  if [[ -n $errors ]]; then
    printf 'Feed the Flock: Hyprland configuration errors:\n%s\n' "$errors" >&2
    return 1
  fi
}

case $mode in
  install)
    [[ -x $helper ]] || { printf 'Install Feed the Flock before its keybinding.\n' >&2; exit 1; }
    mkdir -p "$(dirname "$binding_file")"
    touch "$user_bindings"
    if ! grep -Fxq "$loader" "$user_bindings"; then
      cp -p "$user_bindings" "$user_bindings.bak.agent-feed.$(date +%s)"
    fi
    cat > "$binding_file" <<EOF
-- Managed by Feed the Flock. Remove with scripts/manage-binding.sh remove.
-- Shift+F9 was previously owned by Voice Notes; its source config is untouched.
hl.unbind("SHIFT + F9")
hl.unbind("SHIFT + F10")
o.bind("SHIFT + F9", "Start Feed the Flock capture (push-to-talk)", "$helper record start")
o.bind("SHIFT + F9", "Stop Feed the Flock capture (push-to-talk)", "$helper record stop", { release = true })
o.bind("SHIFT + F10", "Toggle Feed the Flock delivery", "$helper feed toggle")
EOF
    if ! grep -Fxq "$loader" "$user_bindings"; then
      printf '\n%s\n%s\n' "$comment" "$loader" >> "$user_bindings"
    fi
    reload_and_validate
    printf 'Feed the Flock now owns Shift+F9 for capture and Shift+F10 for delivery. Previous bindings were overridden, not deleted.\n'
    ;;
  remove)
    tmp=$(mktemp "$user_bindings.agent-feed.XXXXXX")
    awk -v comment="$comment" -v loader="$loader" '$0 != comment && $0 != loader { print }' \
      "$user_bindings" > "$tmp"
    chmod --reference="$user_bindings" "$tmp"
    mv -f "$tmp" "$user_bindings"
    rm -f "$binding_file"
    reload_and_validate
    printf 'Removed the Feed the Flock Shift+F9 and Shift+F10 overrides. Previous bindings can load again.\n'
    ;;
  *)
    printf 'Usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac
