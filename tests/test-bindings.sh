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
    printf '%s\n' '[{"key":"F7","modmask":64,"description":"Existing action"}]'
  else
    printf '%s\n' '[]'
  fi
elif [[ ${1:-} == configerrors ]]; then
  exit 0
fi
EOF
chmod +x "$tmp/bin/hyprctl"
: > "$tmp/hypr/bindings.lua"
export PATH="$tmp/bin:$PATH"
export AGENT_FEED_STATE_DIR="$tmp/state"
export AGENT_FEED_HYPR_CONFIG_DIR="$tmp/hypr"
export FAKE_BINDING_CONFLICT="$tmp/conflict"
cli="$root/bin/feed-the-flock"

"$cli" init
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
"$cli" binding record set 'SUPER + F7' >/dev/null 2>&1
status=$?
set -e
[[ $status == 3 ]]
"$cli" binding record set 'SUPER + F7' --override >/dev/null
grep -Fq 'hl.unbind("SUPER + F7")' "$tmp/hypr/agent-feed-bindings.lua"
"$cli" state | jq -e '.recordBindingOverride == true' >/dev/null

"$cli" binding record clear >/dev/null
"$cli" binding remove >/dev/null
[[ ! -e $tmp/hypr/agent-feed-bindings.lua ]]
! grep -Fq 'hypr.agent-feed-bindings' "$tmp/hypr/bindings.lua"
