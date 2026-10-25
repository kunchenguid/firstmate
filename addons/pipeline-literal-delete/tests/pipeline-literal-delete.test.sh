#!/usr/bin/env bash
# shellcheck disable=SC2016 # the rule text and hook commands are the test subject: their literal $ and $(...) must not expand
# Integration: install into a throwaway HOME/XDG copy and check the rule reaches the pipeline-agent
# instruction surfaces (the installed pi extension's before_agent_start handler and the Claude
# SessionStart hook command exactly as settings.json names it), the rerun changes nothing, and a
# blocked $VAR delete prints the delete-guard literal-path hint.
# Usage: pipeline-literal-delete.test.sh
set -euo pipefail
unset FM_TASK_ID FM_TASK_INBOX FM_HOME
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO=$(cd "$ADDON/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.claude" "$T/home/.pi/agent/extensions"
echo '{"model":"keep-me","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-hook"}]}]}}' > "$T/home/.claude/settings.json"
fail=0
ok() { echo "ok: $*"; }; no() { echo "FAIL: $*"; fail=1; }
inst() { env -u XDG_DATA_HOME HOME="$T/home" "$ADDON/install.sh" "$@"; }

inst --dry-run > "$T/dry.out"
grep -q 'dry run: nothing written' "$T/dry.out" && ok "dry run reports nothing written" || no "dry run output: $(cat "$T/dry.out")"
[ ! -e "$T/home/.local/share/fm-pipeline-literal-delete/rule.txt" ] && ok "dry run writes nothing" || no "dry run wrote files"
inst > "$T/install.out" && inst > "$T/reinstall.out"
[ "$(grep -c '^unchanged: ' "$T/reinstall.out")" -eq 4 ] && ok "rerun changes nothing" || no "rerun not idempotent: $(cat "$T/reinstall.out")"
ls "$T/home/.claude/settings.json.bak-pipeline-literal-delete-"* >/dev/null 2>&1 && ok "backup made" || no "no backup"
jq -e '.model == "keep-me" and ([.hooks.PreToolUse[].hooks[].command] | index("other-hook") == 0)' "$T/home/.claude/settings.json" >/dev/null && ok "claude settings merged, existing settings kept" || no "claude settings merge"

RULE=$T/home/.local/share/fm-pipeline-literal-delete/rule.txt
grep -qF 'Never delete a $VAR set in an earlier command' "$RULE" && ok "rule text installed" || no "rule text wrong"
grep -qF 'a delete-guard block is final' "$RULE" && ok "rule names the final block" || no "rule missing the final-block line"
grep -qF "$RULE" "$T/home/.pi/agent/extensions/fm-literal-delete.ts" && ok "pi extension reads the installed rule" || no "pi extension rule path"

# claude surface: run the SessionStart hook command exactly as settings.json names it.
CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$T/home/.claude/settings.json")
OUT=$(eval "$CMD")
echo "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null && ok "SessionStart hook shape" || no "hook shape: $OUT"
echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -qF 'Never delete a $VAR set in an earlier command' && ok "claude session context carries the rule" || no "claude context missing rule"

# pi surface: drive the installed extension's before_agent_start handler the way pi does.
cat > "$T/driver.mjs" <<'EOF'
const mod = await import(process.argv[2]);
let handler;
mod.default({ on: (ev, h) => { if (ev === "before_agent_start") handler = h; } });
const r = await handler({ systemPrompt: "BASE" });
if (!r || typeof r.systemPrompt !== "string" || !r.systemPrompt.startsWith("BASE")) {
	console.error("handler did not extend the system prompt");
	process.exit(1);
}
console.log(r.systemPrompt);
EOF
OUT=$(node "$T/driver.mjs" "$T/home/.pi/agent/extensions/fm-literal-delete.ts")
echo "$OUT" | grep -qF '## Fleet delete rule' && echo "$OUT" | grep -qF 'Never delete a $VAR set in an earlier command' && ok "pi system prompt carries the rule" || no "pi system prompt: $OUT"

# the delete-guard block message names the literal-path form for a $VAR set in an earlier command.
MSG=$(printf '{"tool_input":{"command":"SCRATCH=$(cut -d= -f2 /tmp/live.env); kill $(cat /tmp/p.pid) 2>/dev/null\\nrm -rf $SCRATCH"},"cwd":"/w"}' | node "$REPO/delete-guard/guard.mjs" --runtime pi 2>&1 >/dev/null || true)
echo "$MSG" | grep -qF 'rm -rf -- /tmp/tmp.Ab12' && echo "$MSG" | grep -qF 'unknown to the guard' && ok "delete-guard block message names the literal-path form" || no "block message: $MSG"

[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
