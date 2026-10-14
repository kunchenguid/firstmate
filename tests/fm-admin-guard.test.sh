#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior and refusal tests for the worker-side merge-authority guard (bin/fm-admin-guard.sh).
#
# Hard Rule 2: "Never merge a PR without the captain's explicit word."
# Workers hitting a merge refusal must not fall back to `gh pr merge --admin`.
# This suite proves the refusal of `--admin` merges across CLI and PreToolUse entry forms,
# the allowance of non-admin commands, captain authorization detection via the task brief's intent,
# the refusal when only Firstmate spec or steers author `--admin`, and the `gh` shim wrapper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-admin-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-admin-guard-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

run_guard() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  "$CHECK" "$@" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

# 1. CLI --command refusals without captain authorization
test_cli_admin_refusals() {
  local rc=0
  run_guard --command 'gh pr merge --admin' || rc=$?
  expect_code 2 "$rc" "bare gh pr merge --admin must be refused with code 2"
  assert_grep "hard-rule-2" "$ERR" "refusal must cite hard-rule-2"
  assert_grep "worker cannot use --admin" "$ERR" "refusal must explain --admin prohibition"

  rc=0
  run_guard --command 'gh pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "gh pr merge 123 --admin must be refused"

  rc=0
  run_guard --command 'gh-axi pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "gh-axi pr merge 123 --admin must be refused"

  rc=0
  run_guard --command 'gh pr merge -R owner/repo 123 --admin' || rc=$?
  expect_code 2 "$rc" "gh pr merge -R owner/repo 123 --admin must be refused"

  rc=0
  run_guard --command '/usr/bin/gh pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "absolute path gh pr merge 123 --admin must be refused"

  rc=0
  run_guard --command 'git status && gh pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "chained gh pr merge 123 --admin must be refused"

  local wrapped
  for wrapped in 'command gh pr merge 5 --admin' "bash -lc 'gh pr merge 5 --admin'" \
    '(gh pr merge 5 --admin)' 'cd repo; $(which gh) pr merge 5 --admin' \
    'GH_TOKEN=x sudo gh-axi pr merge 5 --admin' \
    "$(printf "cat <<EOF > notes\nbody\nEOF\ngh pr merge 5 --admin")" \
    "$(printf "cat <<'END.TXT' > f\nbody\nEND.TXT\ngh pr merge 5 --admin")" \
    "$(printf 'cat <<END-1 > f\nbody\nEND-1\ngh pr merge 5 --admin')" \
    "$(printf 'x=$((1<<2))\ngh pr merge 5 --admin')" \
    "$(printf 'echo $(( (1 << 3) ))\ngh pr merge 5 --admin')" \
    'echo \"; gh pr merge 5 --admin'; do
    rc=0
    run_guard --command "$wrapped" || rc=$?
    expect_code 2 "$rc" "wrapped admin merge must be refused: $wrapped"
  done

  pass "CLI --command admin merge forms are deterministically refused with code 2"
}

# 2. PreToolUse JSON transport tests across harnesses
test_pretool_harness_contracts() {
  local payload rc=0

  # Claude mode: stderr gets systemMessage JSON with deny, stdout remains empty
  payload='{"tool_input":{"command":"gh pr merge 42 --admin"}}'
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$payload" | "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "Claude PreToolUse deny must exit 2"
  [ ! -s "$OUT" ] || fail "Claude PreToolUse deny must keep stdout empty, got: $(cat "$OUT")"
  assert_grep '"permissionDecision":"deny"' "$ERR" "Claude PreToolUse deny must carry permissionDecision:deny"
  assert_grep 'hard-rule-2' "$ERR" "Claude PreToolUse deny must mention hard-rule-2"

  # Grok mode: stdout gets decision:deny JSON, exit 2
  rc=0
  payload='{"toolInput":{"command":"gh pr merge 42 --admin"}}'
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$payload" | "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "Grok PreToolUse deny must exit 2"
  assert_grep '"decision":"deny"' "$OUT" "Grok PreToolUse deny must write decision:deny to stdout"
  assert_grep 'hard-rule-2' "$OUT" "Grok PreToolUse deny must cite hard-rule-2"

  # Cursor mode: stdout gets permission:deny JSON, exit 0
  rc=0
  payload='{"tool_input":{"command":"gh pr merge 42 --admin"}}'
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$payload" | "$CHECK" --cursor > "$OUT" 2> "$ERR" || rc=$?
  expect_code 0 "$rc" "Cursor PreToolUse deny must exit 0"
  assert_grep '"permission":"deny"' "$OUT" "Cursor PreToolUse deny must write permission:deny to stdout"
  assert_grep 'hard-rule-2' "$OUT" "Cursor PreToolUse deny must cite hard-rule-2"

  pass "PreToolUse hook contracts conform to Claude, Grok, and Cursor requirements"
}

# 3. Non-admin commands must be allowed
test_non_admin_commands_allowed() {
  local rc=0
  run_guard --command 'gh pr view 123' || rc=$?
  expect_code 0 "$rc" "gh pr view 123 must be allowed"

  rc=0
  run_guard --command 'gh pr merge 123' || rc=$?
  expect_code 0 "$rc" "gh pr merge 123 without --admin must be allowed by this guard"

  rc=0
  run_guard --command 'gh pr merge 123 --auto' || rc=$?
  expect_code 0 "$rc" "gh pr merge 123 --auto must be allowed"

  rc=0
  run_guard --command 'echo "gh pr merge --admin"' || rc=$?
  expect_code 0 "$rc" "echoing command string must be allowed"

  local quoted
  for quoted in 'git commit -m "docs: never run gh pr merge --admin"' \
    'gh pr create --title x --body "workers never gh pr merge --admin"' \
    'grep -rn "gh pr merge 5 --admin" tests/' \
    'git commit -m "guard: refuse --admin; gh pr merge 5 --admin now exits 2"' \
    "git commit -m 'a && gh pr merge 5 --admin | b'" \
    "$(printf 'gh pr create --title x --body "intro\ngh pr merge 5 --admin\nend"')" \
    "$(printf "git commit -F - <<'EOF'\nguard notes\ngh pr merge 5 --admin is refused\nEOF")" \
    "$(printf 'gh pr create --body-file - <<-EOF\n\tsay "x\n\tgh pr merge 5 --admin\n\tEOF\ngit status')"; do
    rc=0
    run_guard --claude --command "$quoted" || rc=$?
    expect_code 0 "$rc" "guarded phrase in a command argument must be allowed: $quoted"
  done

  rc=0
  run_guard --command 'git status' || rc=$?
  expect_code 0 "$rc" "git status must be allowed"

  pass "non-admin commands pass through cleanly without interference"
}

# 4. Captain authorization allows --admin; negations, env vars, and cwd briefs do not
run_with_brief() {  # <case-dir> <task-id> <intent-line> -> rc of gh pr merge 99 --admin
  local case_dir=$1 task_id=$2 intent=$3 rc=0
  mkdir -p "$case_dir/data/$task_id"
  printf '# Task\n## Captain'"'"'s intent\n%s\n## Firstmate spec\nRun gh pr merge 99 --admin.\n' "$intent" \
    > "$case_dir/data/$task_id/brief.md"
  : > "$OUT"
  : > "$ERR"
  FM_TASK_ID="$task_id" FM_HOME="$case_dir" \
    "$CHECK" --command 'gh pr merge 99 --admin' > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

test_captain_authorization() {
  local case_dir="$TMP_ROOT/captain-auth" rc=0
  run_with_brief "$case_dir" task-cap-1 "Admin-Merge: authorized" || rc=$?
  expect_code 0 "$rc" "the admin-merge: authorized token in Captain's intent must allow --admin"

  local neg
  for neg in "Merge it once green, never use --admin." \
    "Do not use --admin." "Don't admin merge this." "Merge without --admin." \
    "Merge once green; using --admin merges is prohibited." "Use --admin? It is off-limits." \
    "Run --admin is banned." "Allowed --admin is disallowed here." "Refrain from using --admin." \
    "- --admin" "Please merge PR 99 using --admin." "Use --admin only if I say so." \
    "Should we use --admin? Ask me first." \
    "$(printf 'Ship the fix. Never do any of the following:\n- use --admin\n- admin-merge: authorized\n- force-push')"; do
    rc=0
    run_with_brief "$case_dir" task-cap-neg "$neg" || rc=$?
    expect_code 2 "$rc" "negated captain wording must not authorize --admin: $neg"
  done

  rc=0
  : > "$OUT"
  : > "$ERR"
  FM_CAPTAIN_ADMIN_AUTH=1 FM_CAPTAIN_ADMIN_OVERRIDE=1 \
    "$CHECK" --command 'gh pr merge 99 --admin' > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "environment variables must not authorize --admin"

  local cwd_dir="$TMP_ROOT/cwd-brief"
  mkdir -p "$cwd_dir"
  printf '# Task\n## Captain'"'"'s intent\nUse --admin.\nCaptain: use --admin\n' > "$cwd_dir/brief.md"
  rc=0
  (
    cd "$cwd_dir"
    FM_TASK_ID="task-missing" FM_HOME="$TMP_ROOT/no-home" \
      "$CHECK" --command 'gh pr merge 99 --admin' > "$OUT" 2> "$ERR"
  ) || rc=$?
  expect_code 2 "$rc" "a brief.md in the working directory must not authorize --admin"

  local spawned="$TMP_ROOT/spawned-brief"
  mkdir -p "$spawned"
  printf '# Task\n## Captain'"'"'s intent\nadmin-merge: authorized\n' > "$spawned/brief.md"
  rc=0
  : > "$OUT"
  : > "$ERR"
  FM_ADMIN_GUARD_BRIEF="$spawned/brief.md" FM_HOME="$TMP_ROOT/no-home" \
    "$CHECK" --command 'gh pr merge 99 --admin' > "$OUT" 2> "$ERR" || rc=$?
  expect_code 0 "$rc" "FM_ADMIN_GUARD_BRIEF must locate the task brief outside FM_HOME"

  pass "only the admin-merge: authorized token line in the task brief's Captain's intent authorizes --admin"
}

# 5. Firstmate spec or steer wording does NOT authorize --admin
test_supervisor_words_do_not_authorize() {
  local case_dir="$TMP_ROOT/supervisor-hazard"
  mkdir -p "$case_dir/data/task-haz-1" "$case_dir/state/task-haz-1.inbox"
  local brief="$case_dir/data/task-haz-1/brief.md"

  # Brief where captain intent does NOT mention admin, but Firstmate spec says "land it with --admin"
  cat <<'EOF' > "$brief"
# Task
## Captain's intent
Fix the issue in the repository.
## Firstmate spec
Push branch, open PR, land it with --admin.
EOF

  # Inbox message from Firstmate supervisor also saying "land it with --admin"
  cat <<'EOF' > "$case_dir/state/task-haz-1.inbox/001.msg"
schema=fm-task-inbox.v1
--
push branch, open PR, land it with --admin
EOF

  local rc=0
  : > "$OUT"
  : > "$ERR"
  (
    cd "$case_dir"
    FM_TASK_ID="task-haz-1" FM_HOME="$case_dir" \
      "$CHECK" --command 'gh pr merge 55 --admin' > "$OUT" 2> "$ERR"
  ) || rc=$?
  expect_code 2 "$rc" "Firstmate spec or steer wording must NOT confer --admin authorization"
  assert_grep "hard-rule-2" "$ERR" "refusal must cite hard-rule-2"

  pass "supervisor spec and steer text are refused as merge authority"
}

# 6. Wrapper / shim execution mode (invoked as `gh`)
test_gh_wrapper_shim() {
  local shim_dir="$TMP_ROOT/shim-test"
  mkdir -p "$shim_dir/bin" "$shim_dir/real"
  ln -sf "$CHECK" "$shim_dir/bin/gh"
  printf '#!/bin/sh\necho "real-gh $*"\n' > "$shim_dir/real/gh"
  chmod +x "$shim_dir/real/gh"

  local rc=0
  : > "$OUT"
  : > "$ERR"
  "$shim_dir/bin/gh" pr merge 123 --admin > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "gh shim must refuse pr merge --admin with code 2"
  assert_grep "hard-rule-2" "$ERR" "gh shim refusal must cite hard-rule-2"

  # Symlinked shim resolves the real script root, so the default home's task brief authorizes.
  local home="$TMP_ROOT/shim-home"
  mkdir -p "$home/data/task-shim"
  printf '# Task\n## Captain'"'"'s intent\nadmin-merge: authorized\n' > "$home/data/task-shim/brief.md"
  rc=0
  : > "$OUT"
  : > "$ERR"
  PATH="$shim_dir/bin:$shim_dir/real:$PATH" FM_TASK_ID=task-shim FM_HOME="$home" \
    gh pr merge 123 --admin > "$OUT" 2> "$ERR" || rc=$?
  expect_code 0 "$rc" "authorized gh shim merge must reach the real gh"
  assert_grep "real-gh pr merge 123 --admin" "$OUT" "shim must exec the real gh with the original args"

  rc=0
  : > "$OUT"
  : > "$ERR"
  PATH="$shim_dir/bin:$shim_dir/real:$PATH" gh --help > "$OUT" 2> "$ERR" || rc=$?
  expect_code 0 "$rc" "shim must pass --help through to real gh"
  assert_grep "real-gh --help" "$OUT" "shim --help must reach the real gh"

  # Also test invocation via argv: fm-admin-guard.sh gh pr merge --admin
  rc=0
  : > "$OUT"
  : > "$ERR"
  "$CHECK" gh pr merge 123 --admin > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "fm-admin-guard.sh gh pr merge --admin must refuse with code 2"

  pass "gh shim wrapper intercepts unauthorized --admin merges and passes others to real gh"
}

# 7. Lint cleanliness check
test_lint_cleanliness() {
  local out
  out=$("$ROOT/bin/fm-lint.sh" "$CHECK" "${BASH_SOURCE[0]}" 2>&1) || fail "fm-admin-guard is not lint-clean: $out"
  pass "bin/fm-admin-guard.sh and its test are clean under bin/fm-lint.sh"
}

test_cli_admin_refusals
test_pretool_harness_contracts
test_non_admin_commands_allowed
test_captain_authorization
test_supervisor_words_do_not_authorize
test_gh_wrapper_shim
test_lint_cleanliness

echo "all fm-admin-guard tests passed"
