#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

source_workspace="$temporary/source"
installed_workspace="$temporary/installed"
state_dir="$temporary/state"
mkdir -p "$source_workspace/js" "$source_workspace/styles"

printf '%s\n' 'shipped v1' > "$source_workspace/index.html"
printf '%s\n' 'script v1' > "$source_workspace/js/app.js"
printf '%s\n' 'style v1' > "$source_workspace/styles/theme.css"

AGENT_FEED_STATE_DIR="$state_dir" \
  python3 "$root/scripts/install-workspace.py" "$source_workspace" "$installed_workspace"

printf '%s\n' 'my custom viewer' > "$installed_workspace/index.html"
printf '%s\n' 'my extra viewer file' > "$installed_workspace/custom-viewer.html"
printf '%s\n' 'shipped v2' > "$source_workspace/index.html"
printf '%s\n' 'script v2' > "$source_workspace/js/app.js"
rm "$source_workspace/styles/theme.css"

install_output=$(AGENT_FEED_STATE_DIR="$state_dir" \
  python3 "$root/scripts/install-workspace.py" "$source_workspace" "$installed_workspace" 2>&1)

[[ $(<"$installed_workspace/index.html") == 'my custom viewer' ]]
[[ $(<"$installed_workspace/index.html.upstream") == 'shipped v2' ]]
[[ $(<"$installed_workspace/custom-viewer.html") == 'my extra viewer file' ]]
[[ $(<"$installed_workspace/js/app.js") == 'script v2' ]]
[[ ! -e "$installed_workspace/styles/theme.css" ]]
grep -Fq 'Preserved customized workspace assets:' <<< "$install_output"
grep -Fq 'index.html (new version: index.html.upstream)' <<< "$install_output"

printf 'Workspace update preservation tests passed.\n'
