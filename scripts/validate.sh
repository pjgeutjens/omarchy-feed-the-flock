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
  "$plugin_dir/BindingsOverlay.qml" \
  "$plugin_dir/PanelBucketControls.qml" \
  "$plugin_dir/PanelSectionControls.qml" \
  "$plugin_dir/PanelRoutingControls.qml" \
  "$plugin_dir/BarWidget.qml" \
  "$plugin_dir/Panel.qml"
python3 -m py_compile \
  "$plugin_dir/bin/feed-the-flock" \
  "$plugin_dir/bin/feed_the_flock/"*.py \
  "$plugin_dir/scripts/install-workspace.py"
for module in "$plugin_dir/workspace/js/"*.js; do
  node --check "$module"
done
for source in "$plugin_dir"/Panel*.qml "$plugin_dir/workspace/js/"*.js \
              "$plugin_dir/bin/feed_the_flock/"*.py; do
  line_count=$(wc -l < "$source")
  if (( line_count >= 800 )); then
    echo "$source has $line_count lines; split it before adding more behavior" >&2
    exit 1
  fi
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
[[ $(grep -Fc 'SearchableDropdown {' "$plugin_dir/PanelRoutingControls.qml") -eq 3 ]] || {
  echo "PanelRoutingControls.qml must use Omarchy SearchableDropdown for all routing controls" >&2
  exit 1
}
if grep -Fq 'ComboBox {' "$plugin_dir/PanelRoutingControls.qml"; then
  echo "PanelRoutingControls.qml still contains a platform-native ComboBox" >&2
  exit 1
fi
grep -Fq '|| modePicker.popupOpen || orderPicker.popupOpen' \
  "$plugin_dir/PanelRoutingControls.qml" || {
    echo "Panel key handling must pause while a routing dropdown is open" >&2
    exit 1
  }
grep -Fq '|| routingControls.popupOpen' "$plugin_dir/Panel.qml"
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
grep -Fq 'id="reset-all"' "$plugin_dir/workspace/index.html"
grep -Fq 'id="viewer-search-input"' "$plugin_dir/workspace/index.html"
grep -Fq "request('/api/notes/reset-all'" "$plugin_dir/workspace/js/app.js"
grep -Fq 'WORKSPACE_BROWSER_DIR = STATE_DIR / "workspace-browser"' \
  "$plugin_dir/bin/feed_the_flock/common.py"
grep -Fq '"--disable-extensions", "--no-first-run", "--no-default-browser-check"' \
  "$plugin_dir/bin/feed_the_flock/workspace.py"
grep -Fq "event.stopImmediatePropagation();" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "['j', 'k'].includes(key)" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "['h', 'l'].includes(key)" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "function triggerSelectedAction(key)" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "a: 'add', q: 'queue', f: 'feed', r: 'rename', c: 'clear', delete: 'delete'" \
  "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "event.key === '/'" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "event.key === '?'" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "if (!container.hidden)" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "function recoverSearchFocus(event)" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "input.setRangeText(event.key" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "confirmLabel: 'Move to Unsorted'" "$plugin_dir/workspace/js/section-view.js"
if grep -Fq 'Type “${section.name}” to confirm' "$plugin_dir/workspace/js/section-view.js"; then
  echo "section clearing still uses typed-title confirmation" >&2
  exit 1
fi
if grep -Fq "deleteSection.disabled = section.systemKind === 'unsorted'" \
    "$plugin_dir/workspace/js/section-view.js"; then
  echo "fallback section still renders an impossible delete action" >&2
  exit 1
fi
grep -Fq 'text: "Configure keybindings"' "$plugin_dir/BindingsOverlay.qml"
grep -Fq 'Original preserved:' "$plugin_dir/BindingsOverlay.qml"
grep -Fq 'text: "Source: " + String(modelData.source || "Unknown")' "$plugin_dir/BindingsOverlay.qml"
grep -Fq 'text === "k" || text === "K"' "$plugin_dir/Panel.qml"
grep -Fq 'width: root.keyColumnWidth' "$plugin_dir/KeybindingsOverlay.qml"
grep -Fq 'wrapMode: Text.WrapAnywhere' "$plugin_dir/KeybindingsOverlay.qml"
grep -Fq 'wrapMode: Text.WordWrap' "$plugin_dir/KeybindingsOverlay.qml"
if grep -Fq 'elide: Text.ElideRight' "$plugin_dir/KeybindingsOverlay.qml"; then
  echo "keybinding-reference labels must wrap rather than truncate" >&2
  exit 1
fi
bash -n "$plugin_dir/scripts/manage-binding.sh" "$plugin_dir/scripts/prepare-remove.sh"
"$plugin_dir/tests/test-cli.sh"
"$plugin_dir/tests/test-clear-section.sh"
"$plugin_dir/tests/test-bindings.sh"
"$plugin_dir/tests/test-safety.sh"
"$plugin_dir/tests/test-attachments.sh"
"$plugin_dir/tests/test-workspace.sh"
(
  cd "$plugin_dir"
  env -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    "$qml_test_runner" -input tests/tst_presentation.qml
)
