#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="$plugin_dir/bin/feed-the-flock"

"$helper" feed stop >/dev/null 2>&1 || true
"$helper" _workspace-stop >/dev/null 2>&1 || true
phase=$("$helper" state 2>/dev/null | jq -r '.phase // "idle"' 2>/dev/null || printf idle)
if [[ $phase == recording || $phase == transcribing ]]; then
  "$helper" record cancel >/dev/null 2>&1 || true
fi
if [[ -f $HOME/.config/hypr/feed-the-flock-bindings.lua ]]; then
  "$plugin_dir/scripts/manage-binding.sh" remove
fi
printf '%s\n' 'Feed the Flock background work and bindings are stopped.'
printf '%s\n' 'Now run: omarchy plugin remove io.github.pjgeutjens.feed-the-flock'
printf '%s\n' 'Persisted notes and attachments remain under ~/.local/state/feed-the-flock.'
