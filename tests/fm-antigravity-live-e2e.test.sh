#!/usr/bin/env bash
# Opt-in real Google Antigravity CLI guard.
# Requires a signed-in agy 1.1.26+, Herdr, jq, and an explicit Gemini model.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_TEST_ANTIGRAVITY_LIVE:-0}" != 1 ]; then
  echo "skip - set FM_TEST_ANTIGRAVITY_LIVE=1 and FM_TEST_ANTIGRAVITY_MODEL=<gemini-id> for the real Antigravity guard"
  exit 0
fi

MODEL=${FM_TEST_ANTIGRAVITY_MODEL:-}
EFFORT=${FM_TEST_ANTIGRAVITY_EFFORT:-low}
case "$MODEL" in gemini-*) ;; *) fail "FM_TEST_ANTIGRAVITY_MODEL must be an explicit Gemini model id" ;; esac
case "$EFFORT" in low|medium|high) ;; *) fail "FM_TEST_ANTIGRAVITY_EFFORT must be low, medium, or high" ;; esac
command -v agy >/dev/null 2>&1 || fail "agy is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is required"
version=$(agy --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
IFS=. read -r major minor patch <<EOF
$version
EOF
case "${major:-}:${minor:-}:${patch:-}" in *[!0-9:]*|:*|*::*|*:) fail "could not parse agy --version: '$version'" ;; esac
if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 1 ]; } \
  || { [ "$major" -eq 1 ] && [ "$minor" -eq 1 ] && [ "$patch" -lt 26 ]; }; then
  fail "Antigravity 1.1.26+ is required; found $version"
fi
agy models 2>/dev/null | awk -F '\t' -v wanted="$MODEL" '$1 == wanted { found=1 } END { exit !found }' \
  || fail "Gemini model '$MODEL' is not in the live agy catalog"

TMP_ROOT=$(fm_test_tmproot fm-antigravity-live)
WORKSPACE="$TMP_ROOT/workspace"
mkdir -p "$WORKSPACE/.agents/skills/live-antigravity-proof" "$WORKSPACE/state"
ln -s "$ROOT/bin" "$WORKSPACE/bin"
cat > "$WORKSPACE/AGENTS.md" <<'EOF'
# Live Antigravity proof

The instruction sentinel is `INSTRUCTION_LOADED_7F31`.
When the live verification asks for that sentinel, read this file and include it exactly.
EOF
cat > "$WORKSPACE/.agents/skills/live-antigravity-proof/SKILL.md" <<'EOF'
---
name: live-antigravity-proof
description: Use when the live Antigravity adapter verification requests its workspace skill sentinel.
---

# Live Antigravity proof

The skill sentinel is `SKILL_LOADED_4C92`.
Read the workspace AGENTS.md, then use the terminal tool exactly as the verification prompt requests.
EOF
cat > "$WORKSPACE/.agents/hooks.json" <<EOF
{
  "live-pre-invocation": {
    "PreInvocation": [
      {
        "type": "command",
        "command": "cat >> ../pre-invocation.jsonl; printf '\\n' >> ../pre-invocation.jsonl; printf '{}'"
      }
    ]
  },
  "live-pre-tool": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "cat >> ../pre-tool.jsonl; printf '\\n' >> ../pre-tool.jsonl; printf '{\"decision\":\"allow\"}'"
          }
        ]
      }
    ]
  },
  "live-stop": {
    "Stop": [
      {
        "type": "command",
        "command": "cat >> ../stop.jsonl; printf '\\n' >> ../stop.jsonl; printf '{\"decision\":\"stop\"}'"
      }
    ]
  },
  "firstmate-delegation-seatbelt": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "FM_ROOT_OVERRIDE=.. FM_HOME=.. '$ROOT/bin/fm-subagent-pretool-check.sh' --antigravity"
          }
        ]
      }
    ]
  }
}
EOF
cat > "$WORKSPACE/prompt.txt" <<EOF
This is a non-destructive adapter verification.
Read AGENTS.md and the live-antigravity-proof workspace skill.
Use the run_command terminal tool to run exactly:
pwd > cwd.out && printf 'TOOL_OK_88D2\\n' > tool.out
Then reply with exactly this one line and no other text:
AGY_LIVE_OK instruction=INSTRUCTION_LOADED_7F31 skill=SKILL_LOADED_4C92
EOF

git -C "$WORKSPACE" init -q

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name antigravity-live-e2e)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true; fm_test_cleanup' EXIT HUP INT TERM
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not provision the isolated Herdr lab"

created=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$WORKSPACE" --label antigravity-live --no-focus) \
  || fail "could not create the live Antigravity workspace"
pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$pane" ] || fail "Herdr did not return a pane id"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
cmd="agy --dangerously-skip-permissions --add-dir $(shell_quote "$WORKSPACE") --model $(shell_quote "$MODEL") --effort $(shell_quote "$EFFORT") --prompt-interactive \"\$(cat $(shell_quote "$WORKSPACE/prompt.txt"))\""
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$pane" "$cmd" >/dev/null \
  || fail "could not launch Antigravity"

capture=
attempt=0
while [ "$attempt" -lt 180 ]; do
  capture=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" \
    --source recent --lines 500 --format text 2>/dev/null || true)
  if printf '%s' "$capture" | grep -Fq 'AGY_LIVE_OK instruction=INSTRUCTION_LOADED_7F31 skill=SKILL_LOADED_4C92' \
    && [ -s "$WORKSPACE/tool.out" ] && [ -s "$WORKSPACE/stop.jsonl" ]; then
    break
  fi
  sleep 1
  attempt=$((attempt + 1))
done

printf '%s' "$capture" | grep -Fq 'AGY_LIVE_OK instruction=INSTRUCTION_LOADED_7F31 skill=SKILL_LOADED_4C92' \
  || fail "Antigravity never returned both instruction and skill sentinels"
[ "$(cat "$WORKSPACE/tool.out" 2>/dev/null)" = TOOL_OK_88D2 ] \
  || fail "autonomous terminal execution did not produce the tool sentinel"
[ "$(cat "$WORKSPACE/cwd.out" 2>/dev/null)" = "$WORKSPACE" ] \
  || fail "terminal tools did not run in the exact added workspace"
[ -s "$WORKSPACE/pre-invocation.jsonl" ] || fail "PreInvocation hook did not fire"
[ -s "$WORKSPACE/pre-tool.jsonl" ] || fail "PreToolUse hook did not fire"
[ -s "$WORKSPACE/stop.jsonl" ] || fail "Stop hook did not fire"
jq -se --arg model "$MODEL" 'length > 0 and all(.[]; .modelName == $model)' "$WORKSPACE/pre-invocation.jsonl" >/dev/null \
  || fail "PreInvocation did not report the explicitly selected Gemini model"
jq -se 'any(.[]; .toolCall.name == "run_command" and (.toolCall.args.CommandLine | contains("pwd > cwd.out")))' \
  "$WORKSPACE/pre-tool.jsonl" >/dev/null || fail "PreToolUse did not observe the required terminal call"
jq -se 'any(.[]; .terminationReason and (.fullyIdle | type == "boolean"))' "$WORKSPACE/stop.jsonl" >/dev/null \
  || fail "Stop hook payload was missing its native lifecycle fields"
agent=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$pane" 2>/dev/null \
  | jq -r '.result.agent.agent // empty' || true)
[ "$agent" = agy ] || fail "Herdr did not identify the live process as agy"
printf '%s' "$capture" | grep -qi 'Gemini' || fail "the TUI did not display a Gemini model"
printf '%s' "$capture" | grep -qi "$EFFORT" || fail "the TUI did not display effort '$EFFORT'"

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$pane" /quit >/dev/null || true
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" Enter >/dev/null || true
pass "real Antigravity $version used Gemini, workspace instructions and skill, autonomous tools, native hooks, model/effort, and agy identity"
