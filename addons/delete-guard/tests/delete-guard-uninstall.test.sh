#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.claude" "$T/home/.pi/agent" "$T/fm/bin" "$T/fm/state"
printf '#!/bin/sh\nexit 0\n' > "$T/fm/bin/fm-check-register.sh"; chmod +x "$T/fm/bin/fm-check-register.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/fm/bin/fm-check-unregister.sh"; chmod +x "$T/fm/bin/fm-check-unregister.sh"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-hook"}]}]}}' > "$T/home/.claude/settings.json"
mkdir -p "$T/pool1" "$T/home/.muxr/plans"; echo '{}' > "$T/pool1/settings.json" # a pool account's CLAUDE_CONFIG_DIR
jq -n --arg f "$T/pool1" '{accounts: [{provider: "claude", folder: $f}]}' > "$T/home/.muxr/plans/accounts-v1.json"
E=(env HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/home/.config")
"${E[@]}" "$A/install.sh" "$T/fm" >/dev/null
jq -e '[.hooks.PreToolUse[].hooks[].command] | length == 1 and (.[0] | contains("fm-delete-guard/guard.mjs"))' "$T/pool1/settings.json" >/dev/null
"${E[@]}" "$A/uninstall.sh" "$T/fm" >/dev/null
jq -e '[.hooks.PreToolUse[].hooks[].command] == ["other-hook"]' "$T/home/.claude/settings.json" >/dev/null
jq -e '(has("hooks") | not)' "$T/pool1/settings.json" >/dev/null
[ ! -e "$T/data/fm-delete-guard/guard.mjs" ] && [ ! -e "$T/home/.pi/agent/extensions/fm-rm-guard.ts" ]
before=$(sha256sum "$T/home/.claude/settings.json"); "${E[@]}" "$A/uninstall.sh" "$T/fm" >/dev/null; [ "$before" = "$(sha256sum "$T/home/.claude/settings.json")" ]
echo PASS
