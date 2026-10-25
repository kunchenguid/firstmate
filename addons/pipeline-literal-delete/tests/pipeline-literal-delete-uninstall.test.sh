#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.claude" "$T/home/.pi/agent"; printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"other-hook"}]}]}}' > "$T/home/.claude/settings.json"
E=(env HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/home/.config")
"${E[@]}" "$A/install.sh"; "${E[@]}" "$A/uninstall.sh"
jq -e '([.hooks.SessionStart[]?.hooks[]?.command] | index("other-hook") != null) and ([.hooks.SessionStart[]?.hooks[]?.command] | length == 1)' "$T/home/.claude/settings.json" >/dev/null
[ ! -e "$T/data/fm-pipeline-literal-delete/context.mjs" ] && [ ! -e "$T/home/.pi/agent/extensions/fm-literal-delete.ts" ]
before=$(sha256sum "$T/home/.claude/settings.json"); "${E[@]}" "$A/uninstall.sh" >/dev/null; [ "$before" = "$(sha256sum "$T/home/.claude/settings.json")" ]
echo PASS
