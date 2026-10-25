#!/usr/bin/env bash
# End to end: install into a throwaway HOME's ~/.claude, then drive the real claude binary with the model arguments labs
# and tools pass. The throwaway HOME has NO credential, so no API call is ever made (a banned model cannot run here);
# Claude Code still logs the model it dispatches to ("dispatching to firstParty model=<id>" in ~/.claude/debug), or that the
# prompt was blocked by a hook, which is what each case asserts: Sonnet runs, every Fable form ends on Haiku or is refused.
# Also: the installer never prints other settings, keeps them, backs up, is idempotent, upgrades an old install that mapped
# the sonnet alias to Haiku, restores.
# shellcheck disable=SC2016 # jq programs are literal
set -uo pipefail
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v claude >/dev/null || { echo "FAIL: claude not on PATH"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
fail=0
ok() { echo "ok: $*"; }; no() { echo "FAIL: $*"; fail=1; }
mkdir -p "$T/home/.claude" "$T/w"
echo '{"theme":"dark","env":{"KEEP_ME":"1","FAKE_SECRET":"sk-do-not-print-0000","ANTHROPIC_DEFAULT_SONNET_MODEL":"claude-haiku-5-5"},"hooks":{"PreToolUse":[]}}' > "$T/home/.claude/settings.json"
printf '{"hasCompletedOnboarding":true}\n' > "$T/home/.claude.json"
inst() { env -u CLAUDE_CONFIG_DIR -u XDG_DATA_HOME HOME="$T/home" "$ADDON/install.sh" "$@"; }

inst --dry-run > "$T/dry.out"
jq -e '.env.ANTHROPIC_DEFAULT_SONNET_MODEL == "claude-haiku-5-5"' "$T/home/.claude/settings.json" >/dev/null && [ ! -e "$T/home/.local/share/fm-claude-model-guard" ] \
  && ok "dry run writes nothing" || no "dry run wrote"
inst > "$T/install.out" && inst > "$T/reinstall.out"
cat "$T/dry.out" "$T/install.out" "$T/reinstall.out" | grep -q 'sk-do-not-print\|KEEP_ME\|theme' && no "installer printed other settings" || ok "installer prints only its own keys"
grep -q '^unchanged: ' "$T/reinstall.out" && ok "reinstall changes nothing" || no "reinstall not idempotent"
ls "$T/home/.claude/"settings.json.bak-claude-model-guard-* >/dev/null 2>&1 && ok "backup made" || no "no backup"
jq -e '.theme == "dark" and .env.KEEP_ME == "1" and .env.FAKE_SECRET == "sk-do-not-print-0000"
  and .env.ANTHROPIC_DEFAULT_SONNET_MODEL == null and .env.ANTHROPIC_DEFAULT_FABLE_MODEL == "claude-haiku-5-5"
  and .availableModels == null and ([.hooks.UserPromptSubmit[].hooks[].command, .hooks.PreToolUse[].hooks[].command] | length == 2 and all(endswith("/refuse-model.sh")))
  and .hooks.PreToolUse[0].matcher == "Agent|Task"' "$T/home/.claude/settings.json" >/dev/null && ok "stale sonnet mapping cleared, fable key set, other settings kept" || no "settings content"
cmp -s "$ADDON/refuse-model.sh" "$T/home/.local/share/fm-claude-model-guard/refuse-model.sh" && ok "hook installed" || no "hook not installed"

# dispatched <claude args...>: the model the real claude dispatches to, from its debug log, or "refused" when a hook blocked
# the prompt. $AM, when set, is passed as ANTHROPIC_MODEL.
dispatched() {
  rm -rf "$T/home/.claude/debug"
  (cd "$T/w" && env -u CLAUDE_CONFIG_DIR -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL \
    -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_FABLE_MODEL ${AM:+ANTHROPIC_MODEL="$AM"} HOME="$T/home" DISABLE_AUTOUPDATER=1 \
    timeout 60 claude -p hi "$@" --debug --output-format json >/dev/null 2>&1)
  grep -rqs 'operation blocked by hook' "$T/home/.claude/debug" && { echo refused; return; }
  grep -rhoE 'dispatching to [A-Za-z]+ model=[^ ]+' "$T/home/.claude/debug" 2>/dev/null | sed 's/.*model=//' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
for c in sonnet:claude-sonnet-5-5 fable:claude-haiku-5-5 claude-sonnet-5-5:claude-sonnet-5-5 claude-fable-5-1:refused \
  opus:claude-opus-5-5 haiku:claude-haiku-5-5 claude-opus-5-5:claude-opus-5-5 claude-haiku-5-5:claude-haiku-5-5; do
  got=$(dispatched --model "${c%:*}")
  [ "$got" = "${c##*:}" ] && ok "--model ${c%:*} -> $got" || no "--model ${c%:*} -> '${got:-no dispatch}', want ${c##*:}"
done
[ "$(dispatched --model=claude-fable-5-1)" = refused ] && ok "--model=claude-fable-5-1 -> refused" || no "--model= form not refused"
[ "$(dispatched)" = claude-opus-5-5 ] && ok "no --model -> claude-opus-5-5" || no "default model changed"
[ "$(AM=claude-fable-5-1 dispatched)" = refused ] && ok "ANTHROPIC_MODEL=claude-fable-5-1 -> refused" || no "ANTHROPIC_MODEL not refused"
jq '.model = "claude-fable-5-1"' "$T/home/.claude/settings.json" > "$T/s.json" && cp "$T/home/.claude/settings.json" "$T/keep.json" && cp "$T/s.json" "$T/home/.claude/settings.json"
[ "$(dispatched)" = refused ] && ok "settings model claude-fable-5-1 -> refused" || no "settings model not refused"
cp "$T/keep.json" "$T/home/.claude/settings.json"
G=$T/home/.local/share/fm-claude-model-guard/refuse-model.sh
echo '{"tool_input":{"model":"claude-fable-5-1"}}' | "$G" 2>/dev/null; [ $? -eq 2 ] && ok "Agent call with model claude-fable-5-1 refused" || no "Agent call not refused"
echo '{"tool_input":{"model":"claude-sonnet-5-5"}}' | "$G" && ok "Agent call with model claude-sonnet-5-5 allowed" || no "Agent sonnet refused"
echo '{"tool_input":{"model":"haiku"}}' | "$G" && ok "Agent call with model haiku allowed" || no "Agent haiku refused"

inst --restore > "$T/restore.out"
jq -e '.env.ANTHROPIC_DEFAULT_SONNET_MODEL == null and .env.ANTHROPIC_DEFAULT_FABLE_MODEL == null and .hooks.UserPromptSubmit == []
  and .env.KEEP_ME == "1" and .theme == "dark"' "$T/home/.claude/settings.json" >/dev/null && ok "restore removes only its keys" || no "restore"
[ "$(dispatched --model claude-haiku-5-5)" = claude-haiku-5-5 ] && ok "restored config still runs" || no "restored config"

[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
