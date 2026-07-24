#!/usr/bin/env bash
# Tests for task difficulty estimates and post-task token telemetry collection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TELEMETRY="$ROOT/bin/fm-task-telemetry.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-telemetry)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/wt"
  printf '%s\n' "$home"
}

run_telemetry() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$TELEMETRY" "$@"
}

test_estimate_simple_and_complex() {
  local home brief
  home=$(make_home estimate)
  brief="$home/simple.md"
  printf 'Fix a typo in README.\n' > "$brief"
  [ "$(run_telemetry "$home" estimate "$brief")" = simple ] \
    || fail "tiny typo brief should estimate simple"
  brief="$home/complex.md"
  cat > "$brief" <<'EOF'
Implement a backend migration with authentication, concurrency safety, recovery,
dispatch, teardown, no-mistakes CI validation, and telemetry documentation.
This should update lifecycle scripts, tests, and configuration docs.
The work has integration risk and must remain compatible with multiple harnesses.
EOF
  [ "$(run_telemetry "$home" estimate "$brief")" = complex ] \
    || fail "multi-surface lifecycle brief should estimate complex"
  pass "task telemetry estimates simple and complex briefs"
}

test_collect_explicit_usage_sidecar() {
  local home ledger summary
  home=$(make_home sidecar)
  fm_write_meta "$home/state/tokens-a1.meta" \
    "window=fm-tokens-a1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=high" \
    "difficulty=intermediate" \
    "kind=ship"
  printf '{"usage":{"input_tokens":100,"output_tokens":25,"total_tokens":125}}\n' > "$home/state/tokens-a1.usage.json"

  run_telemetry "$home" collect tokens-a1 || fail "collect from explicit sidecar failed"
  assert_grep "usage_prompt_tokens=100" "$home/state/tokens-a1.meta" "meta missing prompt token total"
  assert_grep "usage_completion_tokens=25" "$home/state/tokens-a1.meta" "meta missing completion token total"
  assert_grep "usage_total_tokens=125" "$home/state/tokens-a1.meta" "meta missing total token count"
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'tokens-a1\t' "ledger missing telemetry row"
  assert_contains "$ledger" $'\tintermediate\tcodex\tgpt-5\thigh\t100\t25\t125\t2\t62\tgeneric' \
    "ledger row did not record ratio and source"
  summary=$(run_telemetry "$home" summary)
  assert_contains "$summary" $'intermediate\tcodex\tgpt-5\t1\t125\t62' \
    "summary did not aggregate token-to-difficulty ratio"
  pass "task telemetry collects sidecar usage and summarizes ratios"
}

test_collect_codex_cumulative_session() {
  local home codex_dir session ledger old_home
  home=$(make_home codex-session)
  codex_dir="$home/codex/.codex/sessions/2026/07/24"
  mkdir -p "$codex_dir"
  fm_write_meta "$home/state/tokens-codex-a2.meta" \
    "window=fm-tokens-codex-a2" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=medium" \
    "difficulty=complex" \
    "kind=scout"
  session="$codex_dir/rollout.jsonl"
  cat > "$session" <<EOF
{"type":"session_meta","payload":{"cwd":"$home/wt"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"output_tokens":8,"total_tokens":48}}}}
EOF
  touch -r "$home/state/tokens-codex-a2.meta" "$session"
  sleep 1
  touch "$session"

  old_home=$HOME
  HOME="$home/codex"
  export HOME
  run_telemetry "$home" collect tokens-codex-a2 \
    || fail "collect from Codex session failed"
  HOME=$old_home
  export HOME
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t40\t8\t48\t3\t16\tcodex' \
    "codex collector did not use the last cumulative token_count event"
  pass "task telemetry collects Codex cumulative token_count sessions"
}

test_estimate_simple_and_complex
test_collect_explicit_usage_sidecar
test_collect_codex_cumulative_session

echo "# all fm-task-telemetry tests passed"
