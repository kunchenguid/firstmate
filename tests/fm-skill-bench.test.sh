#!/usr/bin/env bash
# Hermetic contract tests for bin/fm-skill-bench.sh and bin/fm-skill-mine.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BENCH="$ROOT/bin/fm-skill-bench.sh"
MINER="$ROOT/bin/fm-skill-mine.sh"
FX="$ROOT/tests/fixtures/fm-skill-bench"

assert_present "$BENCH" "fm-skill-bench.sh missing"
assert_present "$MINER" "fm-skill-mine.sh missing"
[ -x "$BENCH" ] || fail "fm-skill-bench.sh must be executable"
[ -x "$MINER" ] || fail "fm-skill-mine.sh must be executable"

bench_tmproot() {
  local dir
  dir=$(fm_test_tmproot fm-skill-bench)
  mkdir -p "$dir/.bench"
  printf '%s\n' "$dir"
}

write_harness_stubs() {
  local stubbin=$1
  mkdir -p "$stubbin"
  cat >"$stubbin/codex" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -C|--skip-git-repo-check|--sandbox) shift; [ "$1" = workspace-write ] && shift || true ;;
    -m) shift 2 ;;
    *) shift ;;
  esac
done
tool=gh
if [ "${FM_SKILL_BENCH_ARM:-}" = B ] || [ "${FM_SKILL_BENCH_ARM:-}" = C ]; then
  tool=gh-axi
fi
PATH="${FM_SKILL_BENCH_RUN_DIR:-.}/fakebin:$PATH" "$tool" pr list >/dev/null 2>&1 || true
printf 'OK\n' >"${out:-/dev/null}"
if [ -n "${FM_SKILL_BENCH_SKILL_NAME:-}" ] && [ -n "${FM_SKILL_BENCH_RUN_DIR:-}" ]; then
  printf '{"custom_tool_call":{"path":"%s/SKILL.md"}}\n' "$FM_SKILL_BENCH_SKILL_NAME" \
    >>"$FM_SKILL_BENCH_RUN_DIR/codex-rollout.jsonl"
fi
printf 'tokens used\n100\n'
exit 0
SH
  cat >"$stubbin/claude" <<'SH'
#!/usr/bin/env bash
tool=gh
if [ "${FM_SKILL_BENCH_ARM:-}" = B ] || [ "${FM_SKILL_BENCH_ARM:-}" = C ]; then
  tool=gh-axi
fi
PATH="${FM_SKILL_BENCH_RUN_DIR:-.}/fakebin:$PATH" "$tool" pr list >/dev/null 2>&1 || true
run_dir=${FM_SKILL_BENCH_RUN_DIR:-.}
if [ -n "${FM_SKILL_BENCH_SKILL_NAME:-}" ]; then
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s"}}]}}\n' \
    "$FM_SKILL_BENCH_SKILL_NAME" >"$run_dir/claude-transcript.jsonl"
fi
printf '{"result":"OK","usage":{"input_tokens":1,"output_tokens":2}}\n'
exit 0
SH
  chmod +x "$stubbin/codex" "$stubbin/claude"
}

expect_lint_rule() {
  local skill_dir=$1 rule=$2
  local out rc
  out=$(FM_SKILL_BENCH_ROOT=/tmp/unused "$BENCH" lint "$skill_dir" 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "lint should reject $skill_dir"
  assert_contains "$out" "$rule" "lint should name rule $rule"
}

test_lint_neutrality_rules() {
  expect_lint_rule "$FX/skills/bad-harness" harness-name
  expect_lint_rule "$FX/skills/bad-slash" slash-command
  expect_lint_rule "$FX/skills/bad-dollar" dollar-invocation
  expect_lint_rule "$FX/skills/bad-home" absolute-home-path
  expect_lint_rule "$FX/skills/bad-role" role-word
  expect_lint_rule "$FX/skills/bad-frontmatter" bad-frontmatter-key
  expect_lint_rule "$FX/skills/bad-description" description-not-situation
  expect_lint_rule "$FX/skills/bad-body-long" body-too-long
  expect_lint_rule "$FX/skills/bad-external-ref" external-reference
  pass "lint rejects each neutrality rule by name"
}

test_lint_accepts_clean() {
  "$BENCH" lint "$FX/skills/clean" >/dev/null
  pass "lint accepts a clean harness-neutral skill"
}

test_run_pass_and_fail_from_calls_log() {
  local home stubbin out
  home=$(bench_tmproot)
  stubbin="$home/stubs"
  write_harness_stubs "$stubbin"
  export FM_SKILL_BENCH_ROOT="$home/.bench"
  export FM_SKILL_BENCH_STUB_BIN="$stubbin"
  export FM_SKILL_BENCH_CASES_DIR="$FX/selftest-cases"
  fm_test_hide_host_commands "$home" codex claude

  out=$(bash "$BENCH" run --candidate "$FX/skills/clean" --cases visible --harness codex --arm B 2>&1)
  assert_contains "$out" "pass-gh" "arm B should mention pass-gh case"
  assert_contains "$out" "pass" "arm B should pass pass-gh"

  out=$(bash "$BENCH" run --candidate "$FX/skills/clean" --cases visible --harness codex --arm A 2>&1)
  assert_contains "$out" "fail-gh" "arm A should exercise fail-gh case"
  assert_contains "$out" "fail" "arm A should fail fail-gh"
  pass "run produces pass and fail from calls.log via harness stubs"
}

test_heldout_case_id_preserved() {
  local home stubbin
  home=$(bench_tmproot)
  stubbin="$home/stubs"
  write_harness_stubs "$stubbin"
  export FM_SKILL_BENCH_ROOT="$home/.bench"
  export FM_SKILL_BENCH_STUB_BIN="$stubbin"
  export FM_SKILL_BENCH_CASES_DIR="$FX/selftest-cases"
  fm_test_hide_host_commands "$home" codex claude

  bash "$BENCH" run --candidate "$FX/skills/clean" --cases heldout --harness codex --arm A >/dev/null
  grep -q $'\tscore-heldout.heldout\t' "$home/.bench/results.tsv" \
    || fail "held-out case id should retain a .heldout suffix"
  pass "run records held-out case ids with a .heldout suffix"
}

write_score_fixture() {
  local home=$1
  cat >"$home/.bench/results.tsv" <<'TSV'
candidate	case	harness	arm	pass	loaded
keep-demo	vis1	codex	A	fail	no
keep-demo	vis1	codex	B	pass	yes
keep-demo	vis2	codex	A	fail	no
keep-demo	vis2	codex	B	pass	yes
keep-demo	vis3	codex	A	pass	no
keep-demo	vis3	codex	B	pass	yes
keep-demo	ho-heldout	codex	A	fail	no
keep-demo	ho-heldout	codex	B	pass	yes
keep-demo	vis1	claude	A	fail	no
keep-demo	vis1	claude	B	pass	yes
keep-demo	vis2	claude	A	fail	no
keep-demo	vis2	claude	B	pass	yes
keep-demo	vis3	claude	A	pass	no
keep-demo	vis3	claude	B	pass	yes
keep-demo	ho-heldout	claude	A	fail	no
keep-demo	ho-heldout	claude	B	pass	yes
TSV
  mkdir -p "$FX/selftest-cases"
  (cd "$ROOT" && sha256sum tests/fixtures/fm-skill-bench/selftest-cases/score-heldout.heldout.case | LC_ALL=C sort) \
    >"$home/.bench/heldout.sha256"
}

test_score_keep_rule() {
  local home out
  home=$(bench_tmproot)
  write_score_fixture "$home"
  export FM_SKILL_BENCH_ROOT="$home/.bench"
  export FM_SKILL_BENCH_CASES_DIR="$FX/selftest-cases"
  out=$(bash "$BENCH" score 2>&1)
  assert_contains "$out" "CANDIDATE keep-demo VERDICT KEEP" "score should KEEP qualifying candidate"
  assert_contains "$out" "HELDOUT_GAIN 2" "score should sum held-out gains across harnesses"
  pass "score computes the keep rule on a hand-written fixture"
}

test_score_requires_both_harnesses() {
  local home out
  home=$(bench_tmproot)
  write_score_fixture "$home"
  # Claude arm B fails every visible case: keep requires +2 on each harness.
  awk -F'\t' -v OFS='\t' '
    $1=="keep-demo" && $3=="claude" && $4=="B" { $5="fail"; $6="no" }
    { print }
  ' "$home/.bench/results.tsv" >"$home/.bench/results.tmp"
  mv "$home/.bench/results.tmp" "$home/.bench/results.tsv"
  export FM_SKILL_BENCH_ROOT="$home/.bench"
  export FM_SKILL_BENCH_CASES_DIR="$FX/selftest-cases"
  out=$(bash "$BENCH" score 2>&1)
  assert_contains "$out" "CANDIDATE keep-demo VERDICT DISCARD" \
    "score should DISCARD when only one harness beats arm A"
  pass "score requires the keep margin on both harnesses"
}

test_score_refuses_bad_heldout_hash() {
  local home out rc
  home=$(bench_tmproot)
  write_score_fixture "$home"
  printf 'deadbeef  tests/fixtures/fm-skill-bench/selftest-cases/score-heldout.heldout.case\n' \
    >"$home/.bench/heldout.sha256"
  export FM_SKILL_BENCH_ROOT="$home/.bench"
  export FM_SKILL_BENCH_CASES_DIR="$FX/selftest-cases"
  out=$(bash "$BENCH" score 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "score should refuse a stale held-out hash"
  assert_contains "$out" "heldout hash mismatch" "score should name hash refusal"
  pass "score refuses when held-out hash does not match"
}

test_claude_loads_requires_skill_tool() {
  local home repo encoded proj out
  home=$(bench_tmproot)
  export HOME="$home/fake-home"
  repo="$home/.bench/dot.repo"
  mkdir -p "$repo"
  encoded=$(printf '%s' "$repo" | tr '/.' '-')
  proj="$HOME/.claude/projects/$encoded"
  mkdir -p "$proj"
  printf '%s\n' '{"attachment":{"type":"skill_listing","content":"- repo-boot-order\n"}}' \
    >"$proj/listing.jsonl"
  out=$(bash "$BENCH" loads --harness claude --dir "$repo" --since 2000-01-01T00:00:00Z)
  printf '%s' "$out" | grep -q repo-boot-order \
    && fail "loads must not treat a skill_listing as an invoke"
  printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"repo-boot-order"}}]}}' \
    >"$proj/invoked.jsonl"
  out=$(bash "$BENCH" loads --harness claude --dir "$repo" --since 2000-01-01T00:00:00Z)
  assert_contains "$out" "repo-boot-order" "loads should report a Skill tool invoke"
  pass "claude loads uses encoded project dir and ignores skill_listing"
}

test_budget_refuses_at_cap() {
  local home out rc
  home=$(bench_tmproot)
  mkdir -p "$home/.bench"
  printf '0\n' >"$home/.bench/night-runs.count"
  printf '40\n' >"$home/.bench/iter-runs.count"
  export FM_SKILL_BENCH_ROOT="$home/.bench"
  export FM_SKILL_BENCH_STUB_BIN="$home/stubs"
  export FM_SKILL_BENCH_CASES_DIR="$FX/selftest-cases"
  write_harness_stubs "$home/stubs"
  fm_test_hide_host_commands "$home" codex claude
  out=$(bash "$BENCH" run --candidate "$FX/skills/clean" --cases visible --harness codex --arm A 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "run should refuse at iteration budget cap"
  assert_contains "$out" "iteration run cap" "budget refusal should name iteration cap"
  pass "budget refuses when the iteration cap is reached"
}

test_miner_writes_patterns() {
  local home out
  home=$(fm_test_tmproot fm-skill-mine)
  export FM_SKILL_MINE_OUT="$home/mined.md"
  export FM_HOME_DIR="$home/fm-home"
  export HOME="$home/isolated-home"
  export CODEX_HOME="$home/codex-home"
  mkdir -p "$FM_HOME_DIR/data" "$FM_HOME_DIR/state" "$HOME/.claude/projects" "$CODEX_HOME/sessions"
  printf '{"date":"2026-08-28","harness":"codex","outcome":"accept","task":"demo"}\n' \
    >"$FM_HOME_DIR/data/routing-outcomes.jsonl"
  out=$(bash "$MINER" 2>&1)
  assert_contains "$out" "P1 raw-gh" "miner stdout should list P1"
  assert_contains "$out" "P6 accept-by-class" "miner stdout should list P6"
  assert_grep "P1 raw-gh" "$home/mined.md" "mined.md should contain P1"
  pass "miner emits deterministic pattern lines"
}

test_lint_neutrality_rules
test_lint_accepts_clean
test_run_pass_and_fail_from_calls_log
test_heldout_case_id_preserved
test_score_keep_rule
test_score_requires_both_harnesses
test_score_refuses_bad_heldout_hash
test_budget_refuses_at_cap
test_claude_loads_requires_skill_tool
test_miner_writes_patterns

pass "all fm-skill-bench tests passed"
