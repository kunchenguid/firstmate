#!/usr/bin/env bash
# Regression tests for the harness-adapters skill split.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/harness-adapters/SKILL.md"
REF_DIR="$ROOT/.agents/skills/harness-adapters"

assert_file_contains() {
  local file=$1 needle=$2 label=$3
  local content
  content=$(<"$file")
  assert_contains "$content" "$needle" "$label"
}

assert_file_not_contains() {
  local file=$1 needle=$2 label=$3
  local content
  content=$(<"$file")
  assert_not_contains "$content" "$needle" "$label"
}

test_core_keeps_only_routing_and_invariants() {
  local runtime
  for runtime in claude codex opencode pi grok; do
    assert_file_contains "$SKILL" "[$runtime.md]($runtime.md)" "core skill omits $runtime reference pointer"
    [ -s "$REF_DIR/$runtime.md" ] || fail "missing $runtime runtime reference"
  done
  assert_file_contains "$SKILL" 'Never dispatch a crewmate or secondmate on an unverified adapter.' \
    "core skill lost the verified-adapter gate"
  assert_file_contains "$SKILL" 'The supported spawn backends are `tmux`, `herdr`, `zellij`, `orca`, and `cmux`.' \
    "core skill lost supported spawn backend list"
  assert_file_contains "$SKILL" '`codex-app` is not an accepted runtime backend' \
    "core skill lost Codex App unsupported boundary"
  assert_file_not_contains "$SKILL" '## claude (VERIFIED)' \
    "core skill still contains the old Claude detail section"
  assert_file_not_contains "$SKILL" '## grok (VERIFIED' \
    "core skill still contains the old Grok detail section"
  pass "harness-adapters core keeps routing, gates, backend boundaries, and reference pointers"
}

test_runtime_references_preserve_load_bearing_facts() {
  assert_file_contains "$REF_DIR/claude.md" 'Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh`' \
    "Claude reference lost Stop-owned watcher behavior"
  assert_file_contains "$REF_DIR/claude.md" '`CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`' \
    "Claude reference lost prompt suggestion suppression"
  assert_file_contains "$REF_DIR/codex.md" '`bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`' \
    "Codex reference lost foreground checkpoint watcher"
  assert_file_contains "$REF_DIR/codex.md" 'A `$<skill>` invocation opens a `$`-autocomplete skill popup' \
    "Codex reference lost skill popup settle quirk"
  assert_file_contains "$REF_DIR/opencode.md" 'Relaunch with `--continue`' \
    "OpenCode reference lost resume path"
  assert_file_contains "$REF_DIR/opencode.md" 'busy plus pending to `empty`' \
    "OpenCode reference lost busy queued Enter regression pointer"
  assert_file_contains "$REF_DIR/pi.md" 'The model arms through `fm_watch_arm_pi`, never a foreground bash arm.' \
    "Pi reference lost primary watcher tool boundary"
  assert_file_contains "$REF_DIR/pi.md" '`PI_CODING_AGENT=true`' \
    "Pi reference lost env marker"
  assert_file_contains "$REF_DIR/grok.md" '`Ctrl+c:cancel`' \
    "Grok reference lost busy signature"
  assert_file_contains "$REF_DIR/grok.md" 'Every `$VAR` reference in a grok hook `command` string must carry an inline `:-default`' \
    "Grok reference lost hook variable safety fact"
  pass "runtime references preserve load-bearing safety and recovery facts"
}

test_core_keeps_conditional_load_instruction() {
  assert_file_contains "$SKILL" 'Load the matching runtime reference below only when that runtime is being selected, spawned, recovered, interrupted, exited, resumed, or verified.' \
    "core skill lost conditional runtime reference load instruction"
  assert_file_contains "$SKILL" 'For stuck recovery, the target window' \
    "core skill lost recorded-harness recovery instruction"
  pass "harness-adapters tells agents when to load runtime references"
}

test_core_keeps_only_routing_and_invariants
test_runtime_references_preserve_load_bearing_facts
test_core_keeps_conditional_load_instruction
