#!/usr/bin/env bash
# Opt-in credentialed Codex 0.144.4 automatic-compaction experiment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_CODEX_LIVE_COMPACTION:-0}" != 1 ]; then
  pass "durable memory: live Codex automatic-compaction experiment skipped (opt in with FM_CODEX_LIVE_COMPACTION=1)"
  exit 0
fi

command -v codex >/dev/null 2>&1 || fail "Codex CLI is required for the live compaction experiment"
[ "$(codex --version)" = "codex-cli 0.144.4" ] || fail "live compaction experiment requires codex-cli 0.144.4"

EVIDENCE_ROOT=${FM_CODEX_COMPACTION_EVIDENCE_ROOT:-/var/folders/fd/lyw7_hdx0j39x560w1s0lngw0000gn/T/no-mistakes-evidence/fm-memory-codex-auto-compact}
RUN_DIR="$EVIDENCE_ROOT/2026-07-20-$$"
HOME_DIR="$RUN_DIR/home"
PROBE_ROOT="$RUN_DIR/probe-repo"
PROMPT_FILE="$RUN_DIR/prompt.txt"
SEED_EVENTS_FILE="$RUN_DIR/codex-seed-events.jsonl"
EVENTS_FILE="$RUN_DIR/codex-events.jsonl"
STDERR_FILE="$RUN_DIR/codex-stderr.txt"
MARKER="FM_AUTO_COMPACT_RECOVERY_20260720"
PRECOMPACT_CHECKPOINT=""
PRECOMPACT_EVENT=""
THREAD_ID=""
CODEX_HOOK_CONFIG=()

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$PROBE_ROOT/bin" "$PROBE_ROOT/.codex"
cp "$ROOT/bin/fm-memory.js" "$ROOT/bin/fm-memory.sh" "$ROOT/bin/fm-memory-codex-hook.sh" "$PROBE_ROOT/bin/"
chmod +x "$PROBE_ROOT/bin/fm-memory.js" "$PROBE_ROOT/bin/fm-memory.sh" "$PROBE_ROOT/bin/fm-memory-codex-hook.sh"
jq '{hooks:{PreCompact:.hooks.PreCompact,PostCompact:.hooks.PostCompact,UserPromptSubmit:.hooks.UserPromptSubmit,Stop:[{hooks:[.hooks.Stop[0].hooks[] | select(.command | contains("fm-memory-codex-hook.sh"))]}]}}' "$ROOT/.codex/hooks.json" > "$PROBE_ROOT/.codex/hooks.json"
printf '%s\n' 'This repository is an isolated read-only compaction experiment. Follow the user prompt exactly and do not inspect files or run session startup.' > "$PROBE_ROOT/AGENTS.md"
git -C "$PROBE_ROOT" init -q -b main
git -C "$PROBE_ROOT" add AGENTS.md .codex/hooks.json bin
git -C "$PROBE_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
CODEX_HOOK_CONFIG=(
  -c "hooks.PreCompact=[{hooks=[{type=\"command\",command=\"$PROBE_ROOT/bin/fm-memory-codex-hook.sh pre\",timeout=30}]}]"
  -c "hooks.PostCompact=[{hooks=[{type=\"command\",command=\"$PROBE_ROOT/bin/fm-memory-codex-hook.sh post\",timeout=30}]}]"
  -c "hooks.UserPromptSubmit=[{hooks=[{type=\"command\",command=\"$PROBE_ROOT/bin/fm-memory-codex-hook.sh prompt\",timeout=30}]}]"
  -c "hooks.Stop=[{hooks=[{type=\"command\",command=\"$PROBE_ROOT/bin/fm-memory-codex-hook.sh stop\",timeout=30}]}]"
)
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
jq -cn --arg marker "$MARKER" '{objective:$marker,completed:[],pending:["verify automatic compaction recovery"],decisions:[],constraints:["automatic compaction remains enabled"],blockers:[],active_tasks:[],evidence:[],next_safe_action:"Return the objective marker exactly",provenance:["test:codex-0.144.4-auto-compaction"],sensitivity:"private"}' |
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROBE_ROOT" "$PROBE_ROOT/bin/fm-memory.sh" checkpoint --reason live-auto-compact --runtime codex --session live-probe --input - >/dev/null

{
  printf '%s\n' 'This is a read-only automatic-compaction experiment.'
  printf '%s\n' 'Use the shell tool once to run `printf COMPACTION_TOOL_OK`, then finish the task.'
  printf '%s\n' 'After the shell tool completes, reply SEED_COMPLETE.'
  awk 'BEGIN { for (i = 0; i < 3000; i += 1) print "bounded automatic compaction probe context" }'
} > "$PROMPT_FILE"

RUST_LOG=codex_core::session::turn=trace FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROBE_ROOT" codex exec --json --sandbox read-only --dangerously-bypass-hook-trust \
  --disable token_budget --strict-config -c model_auto_compact_token_limit=8000 "${CODEX_HOOK_CONFIG[@]}" -C "$PROBE_ROOT" - < "$PROMPT_FILE" > "$SEED_EVENTS_FILE" 2> "$STDERR_FILE" || fail "credentialed Codex history-seeding turn failed; inspect $STDERR_FILE"
THREAD_ID=$(jq -r 'select(.type == "thread.started") | .thread_id' "$SEED_EVENTS_FILE" | head -n 1)
[ -n "$THREAD_ID" ] || fail "Codex history-seeding turn did not report a thread id"
RUST_LOG=codex_core::session::turn=trace FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROBE_ROOT" codex exec --json --sandbox read-only --dangerously-bypass-hook-trust \
  --disable token_budget --strict-config -c model_auto_compact_token_limit=8000 "${CODEX_HOOK_CONFIG[@]}" -C "$PROBE_ROOT" resume "$THREAD_ID" \
  'Use the shell tool once to run `printf RESUME_TOOL_OK`. If a RECOVERY CAPSULE then arrives through a hook continuation, reply with its objective value exactly and nothing else. If no capsule arrives, reply NO_RECOVERY_CAPSULE.' > "$EVENTS_FILE" 2>> "$STDERR_FILE" || fail "credentialed Codex automatic-compaction resume failed; inspect $STDERR_FILE"

jq -e --arg marker "$MARKER" 'select(.type == "item.completed" and .item.type == "agent_message" and ((.item.text // "") | contains($marker)))' "$EVENTS_FILE" >/dev/null || fail "bounded recovery did not reach a subsequent Codex model turn; inspect $EVENTS_FILE"
PRECOMPACT_CHECKPOINT=$(find "$HOME_DIR/data/memory/checkpoints" -type f -name '*.md' -exec rg -l '"reason":"pre-compact"' {} + | head -n 1)
[ -n "$PRECOMPACT_CHECKPOINT" ] || fail "PreCompact did not publish a durable checkpoint"
PRECOMPACT_EVENT=$(find "$HOME_DIR/data/memory/events" -type f -name '*.json' -exec jq -r 'select(.type == "session-lineage" and .payload.reason == "pre-compact") | .event_id' {} + | head -n 1)
[ -n "$PRECOMPACT_EVENT" ] || fail "PreCompact did not publish its lineage event"
[ ! -e "$HOME_DIR/data/memory/pending/codex/$THREAD_ID.json" ] || fail "PostCompact recovery was not acknowledged after its model continuation"

pass "durable memory: Codex 0.144.4 auto compaction fires both hooks and reaches the model"
