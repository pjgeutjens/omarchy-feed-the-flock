#!/usr/bin/env bash
set -euo pipefail

mode=${1:-install}
plugin_id=io.github.pjgeutjens.agentfeed
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
helper="$plugin_dir/bin/feed-the-flock"

[[ -x $helper ]] || {
  printf 'Install Feed the Flock before configuring its keybindings.\n' >&2
  exit 1
}

case $mode in
  install) exec "$helper" binding install ;;
  remove) exec "$helper" binding remove ;;
  *)
    printf 'Usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac
