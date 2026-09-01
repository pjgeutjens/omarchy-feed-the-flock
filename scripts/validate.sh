#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
qml_test_runner=/usr/lib/qt6/bin/qmltestrunner
[[ -x $qml_test_runner ]] || qml_test_runner=$(command -v qmltestrunner)

omarchy plugin validate "$plugin_dir"
qmllint -I "$OMARCHY_PATH/shell" \
  "$plugin_dir/AgentFeedState.qml" \
  "$plugin_dir/AgentFeedKeyCatcher.qml" \
  "$plugin_dir/KeybindingsOverlay.qml" \
  "$plugin_dir/NotesOverlay.qml" \
  "$plugin_dir/BarWidget.qml" \
  "$plugin_dir/Panel.qml"
python3 -m py_compile \
  "$plugin_dir/bin/feed-the-flock" \
  "$plugin_dir/bin/feed_the_flock/"*.py \
  "$plugin_dir/scripts/install-workspace.py"
for module in "$plugin_dir/workspace/js/"*.js; do
  node --check "$module"
done
for branded_file in AgentFeedPresentation.js Panel.qml workspace/index.html; do
  grep -Fq '󰆚' "$plugin_dir/$branded_file" || {
    echo "$branded_file does not use the md-cow product icon" >&2
    exit 1
  }
  if grep -Fq "$(printf '\363\260\263\206')" "$plugin_dir/$branded_file"; then
    echo "$branded_file still contains the legacy product icon" >&2
    exit 1
  fi
done
[[ $(grep -Fc 'SearchableDropdown {' "$plugin_dir/Panel.qml") -eq 3 ]] || {
  echo "Panel.qml must use Omarchy SearchableDropdown for all three routing controls" >&2
  exit 1
}
if grep -Fq 'ComboBox {' "$plugin_dir/Panel.qml"; then
  echo "Panel.qml still contains a platform-native ComboBox" >&2
  exit 1
fi
grep -Fq 'targetPicker.popupOpen || modePicker.popupOpen || orderPicker.popupOpen' \
  "$plugin_dir/Panel.qml" || {
    echo "Panel key handling must pause while a routing dropdown is open" >&2
    exit 1
  }
grep -Fq '"hint": "oldest pending first"' "$plugin_dir/AgentFeedState.qml"
grep -Fq '"hint": "newest pending first"' "$plugin_dir/AgentFeedState.qml"
if grep -Eiq 'topmost|bottommost' "$plugin_dir/AgentFeedState.qml"; then
  echo "queue-order hints still use visual-position terminology" >&2
  exit 1
fi
for asset in styles/theme.css styles/controls.css styles/overlays.css styles/document.css \
             styles/notes.css styles/responsive.css js/app.js; do
  grep -Fq "\"/$asset\"" "$plugin_dir/workspace/index.html" || {
    echo "workspace/index.html does not load $asset" >&2
    exit 1
  }
done
[[ $(wc -l < "$plugin_dir/bin/feed-the-flock") -lt 300 ]] || {
  echo "bin/feed-the-flock must remain a thin entry point" >&2
  exit 1
}
bash -n "$plugin_dir/scripts/manage-binding.sh" "$plugin_dir/scripts/prepare-remove.sh"
"$plugin_dir/tests/test-cli.sh"
"$plugin_dir/tests/test-safety.sh"
"$plugin_dir/tests/test-attachments.sh"
"$plugin_dir/tests/test-workspace.sh"
(
  cd "$plugin_dir"
  env -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    "$qml_test_runner" -input tests/tst_presentation.qml
)
