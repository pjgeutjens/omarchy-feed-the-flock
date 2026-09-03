#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
qml_test_runner=/usr/lib/qt6/bin/qmltestrunner
[[ -x $qml_test_runner ]] || qml_test_runner=$(command -v qmltestrunner)

omarchy plugin validate "$plugin_dir"
grep -Fq '"id": "io.github.pjgeutjens.feed-the-flock"' "$plugin_dir/manifest.json"
grep -Fq 'module io.github.pjgeutjens.feedtheflock' "$plugin_dir/qmldir"
if grep -RIEq \
  'io\.github\.pjgeutjens\.agentfeed|~/.local/state/agent-feed|AGENT_FEED_|agent-feed\.db|AgentFeed(State|Presentation|KeyCatcher)' \
  --exclude-dir=.git --exclude-dir=publication --exclude=preview.png --exclude=validate.sh \
  "$plugin_dir"; then
  echo "legacy Agent Feed identifiers remain in the release" >&2
  exit 1
fi
grep -Fq 'omarchy plugin add https://github.com/pjgeutjens/omarchy-feed-the-flock.git --enable' \
  "$plugin_dir/README.md"
grep -Fq 'scripts/prepare-remove.sh' "$plugin_dir/README.md"
grep -Fq 'optional Dictation app (Voxtype)' "$plugin_dir/README.md"
qmllint -I "$OMARCHY_PATH/shell" \
  "$plugin_dir/FeedTheFlockState.qml" \
  "$plugin_dir/FeedTheFlockKeyCatcher.qml" \
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
for branded_file in FeedTheFlockPresentation.js Panel.qml workspace/index.html; do
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
if grep -Fq 'prepareBindings()' "$plugin_dir/Panel.qml"; then
  echo "opening keybinding settings must not modify user configuration" >&2
  exit 1
fi
grep -Fq 'iconText: "󰅁"' "$plugin_dir/PanelBucketControls.qml"
grep -Fq 'iconText: "󰅂"' "$plugin_dir/PanelBucketControls.qml"
grep -Fq 'iconText: "󰋺"' "$plugin_dir/PanelBucketControls.qml"
grep -Fq 'iconText: "󰈇"' "$plugin_dir/PanelBucketControls.qml"
grep -Fq 'iconText: "󰅁"' "$plugin_dir/PanelSectionControls.qml"
grep -Fq 'iconText: "󰅂"' "$plugin_dir/PanelSectionControls.qml"
grep -Fq '"hint": "oldest pending first"' "$plugin_dir/FeedTheFlockState.qml"
grep -Fq '"hint": "newest pending first"' "$plugin_dir/FeedTheFlockState.qml"
if grep -Eiq 'topmost|bottommost' "$plugin_dir/FeedTheFlockState.qml"; then
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
grep -Fq "function triggerSelectedAction(key, rawKey)" \
  "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "if (key === 'a' || key === 'o')" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "key === 's'" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "key === 't'" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq 'function moveSelectedSection' "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "event.key === '/'" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "event.key === '?'" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "messageClass: 'keyboard-reference'" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq 'max-height: calc(100dvh - 48px)' "$plugin_dir/workspace/styles/overlays.css"
grep -Fq "if (!container.hidden)" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "function recoverSearchFocus(event)" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "input.setRangeText(event.key" "$plugin_dir/workspace/js/viewer-navigation.js"
grep -Fq "confirmLabel: 'Move to Unsorted'" "$plugin_dir/workspace/js/section-view.js"
grep -Fq 'createViewportDragScroller' "$plugin_dir/workspace/js/section-view.js"
grep -Fq "event.key === 'Enter' && !apply.disabled" "$plugin_dir/workspace/js/routing.js"
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
grep -Fq 'command: [root.commandPath, "feed", "resume"]' \
  "$plugin_dir/FeedTheFlockState.qml"
if grep -Fq 'feed", "resume"' "$plugin_dir/BarWidget.qml"; then
  echo "bar widget must not independently resume the feed worker" >&2
  exit 1
fi
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
"$plugin_dir/tests/test-workspace-install.sh"
"$plugin_dir/tests/test-attachments.sh"
"$plugin_dir/tests/test-workspace.sh"
PYTHONPATH="$plugin_dir/bin" python3 "$plugin_dir/tests/test-feed-notifications.py"
(
  cd "$plugin_dir"
  env -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    "$qml_test_runner" -input tests/tst_presentation.qml
)
