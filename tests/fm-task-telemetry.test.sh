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

test_estimate_keywords_match_words_not_substrings() {
  local home brief
  home=$(make_home estimate-keywords)
  brief="$home/benign.md"
  : > "$brief"
  for _ in $(seq 1 10); do
    printf 'The decision requires the author to be specific about social policy.\n' >> "$brief"
    printf 'Precise authority racing traces deliciously past the pricing sheet.\n' >> "$brief"
  done
  [ "$(run_telemetry "$home" estimate "$brief")" = simple ] \
    || fail "benign prose must not count auth/ci/race inside ordinary words"

  brief="$home/lifecycle.md"
  : > "$brief"
  for _ in $(seq 1 10); do
    printf 'Update the dispatch and teardown migrations before the CI e2e run.\n' >> "$brief"
    printf 'Record auth tokens so the watcher reports schema recovery cleanly.\n' >> "$brief"
  done
  [ "$(run_telemetry "$home" estimate "$brief")" = complex ] \
    || fail "real lifecycle keywords, including plurals, must still count"
  pass "task telemetry keyword scoring matches whole words only"
}

test_estimate_counts_spelled_out_auth_words() {
  local home brief
  home=$(make_home estimate-auth-words)
  # Two keywords (schema, migration) score one point; the auth concept is the
  # third that tips the bucket, so each case isolates whether it counted.
  brief="$home/control.md"
  printf 'Update the schema migration for the author and the authority.\n' > "$brief"
  [ "$(run_telemetry "$home" estimate "$brief")" = simple ] \
    || fail "author/authority must not count as the auth keyword"

  brief="$home/authentication.md"
  printf 'Update the schema migration and the authentication path.\n' > "$brief"
  [ "$(run_telemetry "$home" estimate "$brief")" = intermediate ] \
    || fail "authentication must count as the auth keyword"

  brief="$home/authorization.md"
  printf 'Update the schema migration and the authorization path.\n' > "$brief"
  [ "$(run_telemetry "$home" estimate "$brief")" = intermediate ] \
    || fail "authorization must count as the auth keyword"

  brief="$home/both.md"
  printf 'Update the schema migration with authentication and authorization.\n' > "$brief"
  [ "$(run_telemetry "$home" estimate "$brief")" = intermediate ] \
    || fail "auth spellings must score as one concept, not several keywords"
  pass "task telemetry counts authentication and authorization as the auth keyword"
}

scaffold_brief() {
  local home=$1 id=$2
  shift 2
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" demo-repo "$@" >/dev/null 2>&1 \
    || fail "could not scaffold brief $id"
  printf '%s\n' "$home/data/$id/brief.md"
}

fill_task() {
  local brief=$1 task=$2 tmp
  tmp="$brief.filled"
  awk -v task="$task" '{ gsub(/\{TASK\}/, task); print }' "$brief" > "$tmp"
  printf '%s\n' "$tmp"
}

test_estimate_ignores_scaffold_boilerplate() {
  local home ship scout filled
  home=$(make_home estimate-scaffold)
  ship=$(scaffold_brief "$home" scaffold-ship)
  scout=$(scaffold_brief "$home" scaffold-scout --scout)
  [ "$(run_telemetry "$home" estimate "$ship")" = simple ] \
    || fail "an unfilled ship scaffold must not score from boilerplate alone"
  [ "$(run_telemetry "$home" estimate "$scout")" = simple ] \
    || fail "an unfilled scout scaffold must not score from boilerplate alone"

  filled=$(fill_task "$ship" 'Fix the broken relative link in the README quickstart section.')
  [ "$(run_telemetry "$home" estimate "$filled")" = simple ] \
    || fail "a small filled task should still estimate simple inside a scaffold"

  filled=$(fill_task "$ship" 'Update the watcher so a paused task is rechecked on a long cadence. Add a regression test and keep the existing recovery path intact without touching dispatch or teardown.')
  [ "$(run_telemetry "$home" estimate "$filled")" = intermediate ] \
    || fail "a mid-sized filled task should estimate intermediate inside a scaffold"

  filled=$(fill_task "$ship" 'Add a backend migration with authentication and concurrency safety, a recovery path, dispatch and teardown changes, telemetry for token quota accounting, and no-mistakes CI plus e2e integration coverage across the lifecycle scripts, tests, and configuration docs.')
  [ "$(run_telemetry "$home" estimate "$filled")" = complex ] \
    || fail "a multi-surface filled task should estimate complex inside a scaffold"
  pass "task telemetry estimates scaffold briefs from task content only"
}

test_estimate_ignores_unknown_scaffold_sections() {
  local home ship marked
  home=$(make_home estimate-new-section)
  ship=$(scaffold_brief "$home" scaffold-new-section)
  marked=$(grep -c 'fm-brief:task-begin' "$ship" || true)
  [ "$marked" = 1 ] || fail "ship scaffold must delimit the firstmate-filled task text"

  # A generated section fm-task-telemetry.sh has never heard of: the markers, not
  # a duplicated heading list, must keep it out of the score.
  {
    printf '\n# Deployment rollout and observability contract\n'
    for _ in $(seq 1 40); do
      printf 'Run the backend migration, watch schema recovery, audit auth and CI e2e dispatch telemetry.\n'
    done
  } >> "$ship"
  [ "$(run_telemetry "$home" estimate "$ship")" = simple ] \
    || fail "a new generated scaffold section must not score as task content"

  ship=$(fill_task "$ship" 'Fix the broken relative link in the README quickstart section.')
  [ "$(run_telemetry "$home" estimate "$ship")" = simple ] \
    || fail "a small filled task must stay simple despite a new generated section"
  pass "task telemetry scores marked task text, not new scaffold sections"
}

test_estimate_survives_unterminated_task_marker() {
  local home ship unterminated filled
  home=$(make_home estimate-unterminated)
  ship=$(scaffold_brief "$home" scaffold-unterminated)

  unterminated="$ship.unterminated"
  grep -Fv '<!-- fm-brief:task-end -->' "$ship" > "$unterminated"
  [ "$(run_telemetry "$home" estimate "$unterminated")" = simple ] \
    || fail "a brief that lost its task-end marker must not score the whole scaffold"

  filled=$(fill_task "$unterminated" 'Fix the broken relative link in the README quickstart section.')
  [ "$(run_telemetry "$home" estimate "$filled")" = simple ] \
    || fail "a small task must stay simple when the task-end marker is missing"

  filled=$(fill_task "$unterminated" 'Add a backend migration with authentication and concurrency safety, a recovery path, dispatch and teardown changes, telemetry for token quota accounting, and no-mistakes CI plus e2e integration coverage across the lifecycle scripts, tests, and configuration docs.')
  [ "$(run_telemetry "$home" estimate "$filled")" = complex ] \
    || fail "real task content must still score when the task-end marker is missing"
  pass "task telemetry falls back safely when a brief loses its task-end marker"
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
  assert_contains "$summary" $'intermediate\tcodex\tgpt-5\tgeneric\t1\t125\t62' \
    "summary did not aggregate token-to-difficulty ratio"
  pass "task telemetry collects sidecar usage and summarizes ratios"
}

test_sidecar_wins_over_harness_session_log() {
  local home codex_dir session ledger old_home
  home=$(make_home source-precedence)
  codex_dir="$home/codex/.codex/sessions/2026/07/24"
  mkdir -p "$codex_dir"
  fm_write_meta "$home/state/tokens-prec-a8.meta" \
    "window=fm-tokens-prec-a8" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=medium" \
    "difficulty=simple" \
    "kind=ship"
  : > "$home/state/tokens-prec-a8.spawn-ref"
  printf '{"usage":{"input_tokens":100,"output_tokens":25,"total_tokens":125}}\n' \
    > "$home/state/tokens-prec-a8.usage.json"
  sleep 1
  session="$codex_dir/rollout.jsonl"
  cat > "$session" <<EOF
{"type":"session_meta","payload":{"cwd":"$home/wt"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":8,"total_tokens":48}}}}
EOF

  old_home=$HOME
  HOME="$home/codex"
  export HOME
  run_telemetry "$home" collect tokens-prec-a8 || fail "collect with both sources failed"
  HOME=$old_home
  export HOME
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t100\t25\t125\t1\t125\tgeneric' \
    "the higher-precedence sidecar should win outright, not be summed with the session log"
  pass "task telemetry honors source precedence instead of summing kinds"
}

test_summary_keeps_fallback_rows_out_of_normalized_groups() {
  local home ledger summary
  home=$(make_home summary-fidelity)
  printf '%s\n' \
    'id	recorded_at	kind	difficulty	harness	model	effort	prompt_tokens	completion_tokens	total_tokens	difficulty_points	tokens_per_difficulty_point	source' \
    'a	2026-07-24T00:00:00Z	ship	simple	codex	gpt-5	medium	40	8	48	1	48	codex' \
    'b	2026-07-24T00:00:00Z	ship	simple	codex	gpt-5	medium	900	100	1000	1	1000	codex-generic' \
    > "$home/data/task-telemetry.tsv"
  summary=$(run_telemetry "$home" summary)
  assert_contains "$summary" $'simple\tcodex\tgpt-5\tcodex\t1\t48\t48' \
    "normalized codex rows should stand alone in the summary"
  assert_contains "$summary" $'simple\tcodex\tgpt-5\tcodex-generic\t1\t1000\t1000' \
    "lower-fidelity fallback rows should aggregate separately"
  ledger=$(printf '%s\n' "$summary" | grep -c 'gpt-5' || true)
  [ "$ledger" = 2 ] || fail "fallback and normalized rows must not collapse into one group"
  pass "task telemetry summary never averages fallback rows into harness rows"
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

test_collect_codex_excludes_cached_input() {
  local home codex_dir session ledger old_home
  home=$(make_home codex-cached)
  codex_dir="$home/codex/.codex/sessions/2026/07/24"
  mkdir -p "$codex_dir"
  fm_write_meta "$home/state/tokens-codex-a9.meta" \
    "window=fm-tokens-codex-a9" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=medium" \
    "difficulty=intermediate" \
    "kind=ship"
  : > "$home/state/tokens-codex-a9.spawn-ref"
  sleep 1
  session="$codex_dir/rollout.jsonl"
  # Real Codex rollouts fold the re-read prompt prefix into input_tokens and
  # total_tokens; Claude reports it separately and it is excluded there.
  cat > "$session" <<EOF
{"type":"session_meta","payload":{"cwd":"$home/wt"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":20,"total_tokens":1020}}}}
EOF

  old_home=$HOME
  HOME="$home/codex"
  export HOME
  run_telemetry "$home" collect tokens-codex-a9 \
    || fail "collect from cached-input Codex session failed"
  HOME=$old_home
  export HOME
  assert_grep "usage_prompt_tokens=100" "$home/state/tokens-codex-a9.meta" \
    "codex prompt total should exclude cached_input_tokens"
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t100\t20\t120\t2\t60\tcodex' \
    "codex collector counted the cached prompt prefix in prompt and total"
  pass "task telemetry excludes Codex cached input from prompt totals"
}

test_collect_uses_spawn_ref_after_meta_rewrite() {
  local home codex_dir session meta ledger old_home
  home=$(make_home spawn-ref)
  codex_dir="$home/codex/.codex/sessions/2026/07/24"
  mkdir -p "$codex_dir"
  meta="$home/state/tokens-ref-a3.meta"
  fm_write_meta "$meta" \
    "window=fm-tokens-ref-a3" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=medium" \
    "difficulty=complex" \
    "kind=ship"
  # Spawn drops a stable reference marker at task launch, before any session log.
  : > "$home/state/tokens-ref-a3.spawn-ref"
  sleep 1
  session="$codex_dir/rollout.jsonl"
  cat > "$session" <<EOF
{"type":"session_meta","payload":{"cwd":"$home/wt"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"output_tokens":8,"total_tokens":48}}}}
EOF
  # fm-pr-check rewrites meta on a green PR, bumping its mtime past the session.
  sleep 1
  touch "$meta"

  old_home=$HOME
  HOME="$home/codex"
  export HOME
  run_telemetry "$home" collect tokens-ref-a3 \
    || fail "collect after meta rewrite failed"
  HOME=$old_home
  export HOME
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t40\t8\t48\t3\t16\tcodex' \
    "spawn-ref reference did not survive a later meta rewrite"
  pass "task telemetry discovers logs via spawn-ref despite later meta rewrite"
}

test_collect_claude_excludes_cache_read() {
  local home worktree claude_dir session ledger old_home
  home=$(make_home claude-cache)
  # Mirror a real Firstmate task worktree under a dotted path (.no-mistakes), so
  # the fixture exercises Claude's on-disk encoding of non-slash characters.
  worktree="$home/.no-mistakes/wt"
  mkdir -p "$worktree"
  claude_dir="$home/claude/.claude/projects/$(printf '%s' "$worktree" | sed 's#[^a-zA-Z0-9-]#-#g')"
  mkdir -p "$claude_dir"
  fm_write_meta "$home/state/tokens-claude-a4.meta" \
    "window=fm-tokens-claude-a4" \
    "worktree=$worktree" \
    "project=$home/project" \
    "harness=claude" \
    "model=opus" \
    "effort=high" \
    "difficulty=intermediate" \
    "kind=ship"
  : > "$home/state/tokens-claude-a4.spawn-ref"
  sleep 1
  session="$claude_dir/session.jsonl"
  # Two turns; cache_read grows each turn and must NOT accumulate into the sum.
  cat > "$session" <<'EOF'
{"message":{"id":"m1","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":20}}}
{"message":{"id":"m2","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":110,"output_tokens":30}}}
EOF

  old_home=$HOME
  HOME="$home/claude"
  export HOME
  run_telemetry "$home" collect tokens-claude-a4 \
    || fail "collect from Claude transcript failed"
  HOME=$old_home
  export HOME
  assert_grep "usage_prompt_tokens=115" "$home/state/tokens-claude-a4.meta" \
    "claude prompt sum should exclude growing cache_read re-reads"
  assert_grep "usage_completion_tokens=50" "$home/state/tokens-claude-a4.meta" \
    "claude completion sum should add per-turn output"
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t115\t50\t165\t2\t82\tclaude' \
    "claude collector inflated the prompt total with cache_read"
  pass "task telemetry excludes Claude cache_read from prompt totals"
}

test_generic_fallback_for_harness_log_without_token_events() {
  local home codex_dir session ledger old_home
  home=$(make_home generic-fallback)
  codex_dir="$home/codex/.codex/sessions/2026/07/24"
  mkdir -p "$codex_dir"
  fm_write_meta "$home/state/tokens-fallback-a5.meta" \
    "window=fm-tokens-fallback-a5" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=medium" \
    "difficulty=intermediate" \
    "kind=ship"
  : > "$home/state/tokens-fallback-a5.spawn-ref"
  sleep 1
  session="$codex_dir/rollout.jsonl"
  # Usage-shaped JSON, but no codex token_count events for the harness filter.
  cat > "$session" <<EOF
{"type":"session_meta","payload":{"cwd":"$home/wt"}}
{"type":"other","usage":{"prompt_tokens":70,"completion_tokens":30,"total_tokens":100}}
EOF

  old_home=$HOME
  HOME="$home/codex"
  export HOME
  run_telemetry "$home" collect tokens-fallback-a5 \
    || fail "collect via the generic fallback failed"
  HOME=$old_home
  export HOME
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t70\t30\t100\t2\t50\tcodex-generic' \
    "generic fallback did not run, or wore the plain harness label"
  assert_no_grep "usage_source=unavailable" "$home/state/tokens-fallback-a5.meta" \
    "usage-shaped JSON should not report an unavailable source"
  pass "task telemetry falls back to generic usage parsing"
}

test_generic_fallback_does_not_double_count_sibling_usage() {
  local home codex_dir session ledger old_home
  home=$(make_home generic-siblings)
  codex_dir="$home/codex/.codex/sessions/2026/07/24"
  mkdir -p "$codex_dir"
  fm_write_meta "$home/state/tokens-sib-a6.meta" \
    "window=fm-tokens-sib-a6" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=medium" \
    "difficulty=simple" \
    "kind=ship"
  : > "$home/state/tokens-sib-a6.spawn-ref"
  sleep 1
  session="$codex_dir/rollout.jsonl"
  # A cumulative total beside a per-turn delta, under a payload type the codex
  # parser does not recognize; only the cumulative sibling may be counted.
  cat > "$session" <<EOF
{"type":"session_meta","payload":{"cwd":"$home/wt"}}
{"type":"event_msg","payload":{"type":"turn_summary","info":{"total_token_usage":{"input_tokens":40,"output_tokens":8,"total_tokens":48},"last_token_usage":{"input_tokens":30,"output_tokens":3,"total_tokens":33}}}}
EOF

  old_home=$HOME
  HOME="$home/codex"
  export HOME
  run_telemetry "$home" collect tokens-sib-a6 \
    || fail "collect via the generic fallback failed"
  HOME=$old_home
  export HOME
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t40\t8\t48\t1\t48\tcodex-generic' \
    "generic fallback summed a cumulative total together with its per-turn delta"
  pass "task telemetry generic fallback counts one usage object per record"
}

test_generic_fallback_excludes_cache_read() {
  local home ledger
  home=$(make_home generic-cache)
  fm_write_meta "$home/state/tokens-cache-a7.meta" \
    "window=fm-tokens-cache-a7" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "harness=claude" \
    "model=opus" \
    "effort=high" \
    "difficulty=simple" \
    "kind=ship"
  printf '%s\n' \
    '{"usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":9000,"output_tokens":20}}' \
    > "$home/state/tokens-cache-a7.usage.json"

  run_telemetry "$home" collect tokens-cache-a7 || fail "collect from cache-shaped sidecar failed"
  ledger=$(cat "$home/data/task-telemetry.tsv")
  assert_contains "$ledger" $'\t110\t20\t130\t1\t130\tgeneric' \
    "generic reading inflated the prompt total with cache_read"
  pass "task telemetry generic reading excludes cache_read from prompt totals"
}

test_estimate_simple_and_complex
test_estimate_keywords_match_words_not_substrings
test_estimate_counts_spelled_out_auth_words
test_estimate_ignores_scaffold_boilerplate
test_estimate_ignores_unknown_scaffold_sections
test_estimate_survives_unterminated_task_marker
test_generic_fallback_for_harness_log_without_token_events
test_generic_fallback_does_not_double_count_sibling_usage
test_generic_fallback_excludes_cache_read
test_collect_explicit_usage_sidecar
test_sidecar_wins_over_harness_session_log
test_summary_keeps_fallback_rows_out_of_normalized_groups
test_collect_codex_cumulative_session
test_collect_codex_excludes_cached_input
test_collect_uses_spawn_ref_after_meta_rewrite
test_collect_claude_excludes_cache_read

echo "# all fm-task-telemetry tests passed"
