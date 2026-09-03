#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id=io.github.pjgeutjens.agentfeed
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"

if [[ $source_dir == "$plugin_dir" ]]; then
  echo "install-local.sh is only for a separate development checkout; use omarchy plugin update here" >&2
  exit 1
fi

"$source_dir/scripts/validate.sh"
rm -rf "$plugin_dir/bin/feed_the_flock" "$plugin_dir/bin/__pycache__"
mkdir -p "$plugin_dir/bin/feed_the_flock" "$plugin_dir/workspace" "$plugin_dir/scripts"
install -m755 "$source_dir/scripts/install-workspace.py" "$plugin_dir/scripts/install-workspace.py"
install -m755 "$source_dir/scripts/manage-binding.sh" "$plugin_dir/scripts/manage-binding.sh"
install -m755 "$source_dir/scripts/prepare-remove.sh" "$plugin_dir/scripts/prepare-remove.sh"
install -m644 "$source_dir/bin/feed_the_flock/"*.py "$plugin_dir/bin/feed_the_flock/"
install -m755 "$source_dir/bin/feed-the-flock" "$plugin_dir/bin/feed-the-flock"
python3 "$source_dir/scripts/install-workspace.py" "$source_dir/workspace" "$plugin_dir/workspace"
for file in manifest.json qmldir AgentFeedState.qml AgentFeedPresentation.js AgentFeedKeyCatcher.qml KeybindingsOverlay.qml NotesOverlay.qml BindingsOverlay.qml PanelBucketControls.qml PanelSectionControls.qml PanelRoutingControls.qml BarWidget.qml Panel.qml README.md; do
  install -m644 "$source_dir/$file" "$plugin_dir/$file"
done
"$plugin_dir/bin/feed-the-flock" init
if [[ -f $HOME/.config/hypr/agent-feed-bindings.lua ]]; then
  "$source_dir/scripts/manage-binding.sh" install
fi

omarchy plugin validate "$plugin_dir"
omarchy-shell shell rescanPlugins >/dev/null
if ! omarchy plugin list --json | jq -e --arg id "$plugin_id" \
  'any(.[]; .id == $id and .enabled == true)' >/dev/null; then
  omarchy plugin enable "$plugin_id" --section right
fi
omarchy-shell shell rescanPlugins >/dev/null
printf 'Installed and enabled %s\n' "$plugin_id"
