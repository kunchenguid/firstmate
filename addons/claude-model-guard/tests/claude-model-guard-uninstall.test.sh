#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.claude"; printf '%s\n' '{"env":{"KEEP":"yes"},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"other-hook"}]}]}}' > "$T/home/.claude/settings.json"
E=(env HOME="$T/home" XDG_DATA_HOME="$T/data" CLAUDE_CONFIG_DIR="$T/home/.claude")
"${E[@]}" "$A/install.sh" >/dev/null; "${E[@]}" "$A/uninstall.sh" >/dev/null
jq -e '.env.KEEP == "yes" and ([.hooks.UserPromptSubmit[].hooks[].command] == ["other-hook"]) and (.env.ANTHROPIC_DEFAULT_SONNET_MODEL == null) and (.env.ANTHROPIC_DEFAULT_FABLE_MODEL == null) and ([.hooks.PreToolUse[]?.hooks[]?.command] | length == 0)' "$T/home/.claude/settings.json" >/dev/null
[ ! -e "$T/data/fm-claude-model-guard/refuse-model.sh" ]; before=$(sha256sum "$T/home/.claude/settings.json"); "${E[@]}" "$A/uninstall.sh" >/dev/null; [ "$before" = "$(sha256sum "$T/home/.claude/settings.json")" ]; echo 'PASS claude-model-guard uninstall'
