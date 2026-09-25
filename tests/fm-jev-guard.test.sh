#!/usr/bin/env bash
# tests/fm-jev-guard.test.sh - verify Jev dynamic delegation guardrail behavior
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD_SH="$ROOT/bin/fm-jev-guard.sh"
GUARD_PY="$ROOT/bin/fm-jev-guard.py"

[ -x "$GUARD_SH" ] || fail "bin/fm-jev-guard.sh missing or not executable"
[ -x "$GUARD_PY" ] || fail "bin/fm-jev-guard.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-guard-test)
export FM_TEST_PRIMARY=1

# 1. Help flag works
help_out=$("$GUARD_SH" --help 2>&1 || true)
assert_contains "$help_out" "Usage: fm-jev-guard.sh" "shell wrapper emits usage"

# 2. Tier 1 Fast-path whitelist allows benign supervisor commands at 0ms
"$GUARD_SH" --command "bd list" || fail "bd list denied unexpectedly"
"$GUARD_SH" --command "bd create 'investigate failing test shard'" || fail "bd create with inner 'test' denied unexpectedly"
"$GUARD_SH" --command "bin/fm-send.sh gpu-ops 'restart stt service'" || fail "fm-send with inner 'restart' denied unexpectedly"
"$GUARD_SH" --command "bin/fm-wake-drain.sh" || fail "fm-wake-drain denied unexpectedly"
"$GUARD_SH" --command "git status --porcelain" || fail "git status denied unexpectedly"
"$GUARD_SH" --command "cat state/websites.status | grep needs-decision" || fail "cat/grep state denied unexpectedly"

# 3. Fail-open on empty or malformed inputs
printf '' | "$GUARD_SH" || fail "empty stdin failed to allow open"
printf '{bad json' | "$GUARD_SH" || fail "malformed json failed to allow open"
"$GUARD_SH" --command "" || fail "empty command failed to allow open"

# 4. Live classification if TYPESAFE_API_KEY is available
if sudo -n /opt/ra/firstmate/bin/jev-typesafe-run.py -- env | grep -q "TYPESAFE_API_KEY"; then
  # Direct remote SSH must be denied
  set +e
  deny_stderr=$(mktemp)
  deny_stdout=$("$GUARD_SH" --command 'ssh srv-covenant-app "sudo systemctl restart arcs-portal"' 2>"$deny_stderr")
  exit_code=$?
  set -e
  [ "$exit_code" -eq 2 ] || fail "ssh systemctl restart was not denied (exit code $exit_code)"
  assert_contains "$deny_stdout" "require_delegation" "deny stdout contains require_delegation decision"
  stderr_content=$(cat "$deny_stderr")
  rm -f "$deny_stderr"
  assert_contains "$stderr_content" "require_delegation" "deny stderr contains require_delegation code"
  assert_contains "$stderr_content" "svc_ops" "deny stderr identified svc_ops domain"

  # Compound command sneak must be caught and denied
  set +e
  compound_err=$(mktemp)
  "$GUARD_SH" --command 'bin/fm-wake-drain.sh 2>&1 | grep WAKE_ACK; ssh srv "redis-cli ping"' 2>"$compound_err"
  compound_code=$?
  set -e
  [ "$compound_code" -eq 2 ] || fail "compound sneak command was not denied (code $compound_code)"
  compound_msg=$(cat "$compound_err")
  rm -f "$compound_err"
  assert_contains "$compound_msg" "require_delegation" "compound command denied with require_delegation"

  # Claude mode test: stderr gets JSON, stdout stays empty, exit code 2
  set +e
  claude_err=$(mktemp)
  claude_out=$(jq -nc '{"tool_input":{"command":"ssh gpu \"docker ps\""}}' | "$GUARD_SH" --claude 2>"$claude_err")
  claude_code=$?
  set -e
  [ "$claude_code" -eq 2 ] || fail "claude mode failed to exit 2 (got $claude_code)"
  [ -z "$claude_out" ] || fail "claude mode stdout was not empty on deny: $claude_out"
  claude_errmsg=$(cat "$claude_err")
  rm -f "$claude_err"
  assert_contains "$claude_errmsg" '"permissionDecision":"deny"' "claude stderr contains permissionDecision deny"
  assert_contains "$claude_errmsg" "gpu_ops" "claude stderr identified gpu_ops domain"

  # Cursor mode test: exits 0, user_message on stdout
  cursor_out=$(jq -nc '{"tool_input":{"command":"ssh gpu \"docker ps\""}}' | "$GUARD_SH" --cursor)
  assert_contains "$cursor_out" '"permission":"deny"' "cursor stdout contains permission deny"
  assert_contains "$cursor_out" "gpu_ops" "cursor stdout identified gpu_ops"
fi

# 5. Worktree inertia: linked git worktrees must be inert (exit 0)
MOCK_BASE="$TDIR/mock-base"
MOCK_WT="$TDIR/mock-worktree"
fm_git_identity fmtest fmtest@example.invalid
git init -q "$MOCK_BASE"
git -C "$MOCK_BASE" commit -q --allow-empty -m "init base"
git -C "$MOCK_BASE" worktree add -q "$MOCK_WT" -b wt-branch
touch "$MOCK_WT/AGENTS.md"
mkdir -p "$MOCK_WT/bin"
cp "$GUARD_SH" "$MOCK_WT/bin/fm-jev-guard.sh"
cp "$GUARD_PY" "$MOCK_WT/bin/fm-jev-guard.py"

# In the linked worktree, even ssh should exit 0 immediately
wt_out=$(FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$MOCK_WT" "$MOCK_WT/bin/fm-jev-guard.sh" --command "ssh srv 'sudo rm -rf /'" 2>&1) || fail "guard was not inert inside linked worktree"
[ -z "$wt_out" ] || fail "guard emitted output inside linked worktree: $wt_out"

pass "all fm-jev-guard tests passed"
