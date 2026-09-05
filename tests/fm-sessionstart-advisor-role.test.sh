#!/usr/bin/env bash
# Behavior tests for the FM_SESSION_ROLE=advisor launch-time marker
# (bin/fm-sessionstart-run.sh, bin/fm-primary-scope-lib.sh's
# fm_session_role_is_advisor). docs/configuration.md "Advisor session role"
# owns the full contract; see the 2026-09-04 review finding G1, where an
# advisor session launched in the primary checkout acquired the home's session
# lock after the real firstmate session had crashed.
#
# bin/fm-session-start.sh is a stub here, not the real digest: these tests pin
# fm-sessionstart-run.sh's OWN routing decision (advisor vs ordinary), which is
# what changed. The real digest's lock/bootstrap/drain mechanics are covered
# end to end by tests/fm-sessionstart-nudge.test.sh and
# tests/fm-turnend-guard.test.sh (the latter also covers the guard's
# independent foreign-lock-owner defer for when a foreign session has already
# taken the lock).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-advisor-role)
fm_git_identity fmtest fmtest@example.invalid

# Deliberately bare PATH: fast, hermetic, and irrelevant here since the
# advisor path never reaches a tool probe.
RUN_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

CLAUDE_SESSIONSTART_CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$ROOT/.claude/settings.json")
[ -n "$CLAUDE_SESSIONSTART_CMD" ] || fail "tracked .claude/settings.json SessionStart command is missing"
CODEX_SESSIONSTART_CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$ROOT/.codex/hooks.json")
[ -n "$CODEX_SESSIONSTART_CMD" ] || fail "tracked .codex/hooks.json SessionStart command is missing"

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

# A throwaway primary checkout carrying the REAL fm-sessionstart-run.sh and its
# sourced dependencies, plus a STUBBED fm-session-start.sh that records whether
# it ran. If the advisor short-circuit ever regressed, the stub still exists
# and would be reached, so these tests fail loudly instead of passing by
# accident on a missing script.
install_run_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-sessionstart-run.sh" "$dir/bin/fm-sessionstart-run.sh"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$dir/bin/fm-sessionstart-nudge.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$dir/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
# Mirrors the real script's own FM_ROOT/FM_HOME self-resolution (never relies
# on an inherited FM_HOME), so this stub behaves correctly under the tracked
# Claude entry point too, which sets only CLAUDE_PROJECT_DIR.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
: > "$state/session-start-invoked"
printf 'SESSION START - stub digest\n'
SH
  chmod +x "$dir/bin/"*.sh
  printf '%s\n' "$dir"
}

mark_codex_hook_root() {
  local dir=$1
  mkdir -p "$dir/.codex"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"fm-sessionstart-run.sh"}]}]}}\n' > "$dir/.codex/hooks.json"
}

run_direct() {  # <dir> [env-assignment...]
  local dir=$1
  shift
  printf '{"source":"startup"}' | env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u GROK_HOOK_EVENT \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" PATH="$RUN_PATH" "$@" \
    "$dir/bin/fm-sessionstart-run.sh"
}

# The tracked Claude entry execs "$CLAUDE_PROJECT_DIR"/bin/fm-sessionstart-run.sh
# directly, so pointing CLAUDE_PROJECT_DIR at the fixture is enough; the script
# resolves its own FM_ROOT/FM_HOME from its own location with no override
# needed, exactly as the real registration does.
run_claude_entry() {  # <dir> <payload> [env-assignment...]
  local dir=$1 payload=$2
  shift 2
  printf '%s' "$payload" | env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u GROK_HOOK_EVENT \
    CLAUDE_PROJECT_DIR="$dir" PATH="$RUN_PATH" "$@" bash -c "$CLAUDE_SESSIONSTART_CMD"
}

# The tracked Codex entry resolves its own root as `pwd -P`, so it must
# actually run from inside the fixture directory.
run_codex_entry() {  # <dir> <payload> [env-assignment...]
  local dir=$1 payload=$2
  shift 2
  printf '%s' "$payload" | env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u GROK_HOOK_EVENT \
    PATH="$RUN_PATH" "$@" bash -c "cd \"$dir\" && $CODEX_SESSIONSTART_CMD"
}

# --- direct invocation: bin/fm-sessionstart-run.sh --------------------------

test_ordinary_primary_reaches_digest_directly() {
  local dir out status=0
  dir=$(install_run_fixture "$TMP_ROOT/direct-primary")
  out=$(run_direct "$dir") || status=$?
  expect_code 0 "$status" "ordinary primary session-open"
  assert_contains "$out" "SESSION START - stub digest" "ordinary primary session did not reach the digest"
  assert_not_contains "$out" "ADVISOR" "ordinary primary session wrongly took the advisor path"
  assert_present "$dir/state/session-start-invoked" "ordinary primary session did not invoke the digest"
  pass "fm-sessionstart-run: an ordinary primary session (FM_SESSION_ROLE unset) reaches the digest unaffected"
}

test_advisor_role_never_reaches_digest_or_lock() {
  local dir out status=0
  dir=$(install_run_fixture "$TMP_ROOT/direct-advisor")
  out=$(run_direct "$dir" FM_SESSION_ROLE=advisor) || status=$?
  expect_code 0 "$status" "advisor session-open"
  assert_contains "$out" "FM_SESSION_ROLE=advisor" "advisor session did not identify its role"
  assert_not_contains "$out" "SESSION START - stub digest" "advisor session ran the digest"
  assert_absent "$dir/state/session-start-invoked" "advisor session invoked the digest"
  assert_absent "$dir/state/.lock" "advisor session acquired the primary session lock"
  pass "fm-sessionstart-run: FM_SESSION_ROLE=advisor takes the read-only path before any lock, bootstrap, or drain"
}

test_advisor_role_leaves_crashed_owner_lock_untouched() {
  local dir out status=0 dead before after
  dir=$(install_run_fixture "$TMP_ROOT/direct-crashed-owner")
  dead=$(nonexistent_pid)
  printf '%s\n' "$dead" > "$dir/state/.lock"
  before=$(cat "$dir/state/.lock")
  out=$(run_direct "$dir" FM_SESSION_ROLE=advisor) || status=$?
  expect_code 0 "$status" "advisor session-open with a crashed previous owner"
  after=$(cat "$dir/state/.lock")
  [ "$before" = "$after" ] || fail "advisor session rewrote a crashed previous owner's lock: was $before, now $after"
  assert_contains "$out" "FM_SESSION_ROLE=advisor" "advisor session did not identify its role"
  assert_absent "$dir/state/session-start-invoked" "advisor session invoked the digest despite a crashed previous owner"
  pass "fm-sessionstart-run: FM_SESSION_ROLE=advisor never claims a lock left behind by a crashed previous owner (2026-09-04 review finding G1)"
}

# --- tracked hook entry points: both adapters --------------------------------

test_ordinary_primary_under_claude_hook_entry() {
  local dir out status=0
  dir=$(install_run_fixture "$TMP_ROOT/claude-entry-primary")
  out=$(run_claude_entry "$dir" '{"source":"startup"}') || status=$?
  expect_code 0 "$status" "ordinary session via the tracked Claude SessionStart entry"
  assert_contains "$out" "SESSION START - stub digest" "Claude entry point did not reach the digest for an ordinary session"
  assert_not_contains "$out" "ADVISOR" "Claude entry point wrongly took the advisor path for an ordinary session"
  pass "fm-sessionstart-run: the tracked Claude SessionStart entry runs the digest unaffected when FM_SESSION_ROLE is unset"
}

test_advisor_role_under_claude_hook_entry() {
  local dir out status=0
  dir=$(install_run_fixture "$TMP_ROOT/claude-entry-advisor")
  out=$(run_claude_entry "$dir" '{"source":"startup"}' FM_SESSION_ROLE=advisor) || status=$?
  expect_code 0 "$status" "advisor session via the tracked Claude SessionStart entry"
  assert_contains "$out" "FM_SESSION_ROLE=advisor" "Claude entry point did not take the advisor path"
  assert_absent "$dir/state/session-start-invoked" "Claude entry point ran the digest for an advisor session"
  assert_absent "$dir/state/.lock" "Claude entry point let an advisor session acquire the lock"
  pass "fm-sessionstart-run: the tracked Claude SessionStart entry honors FM_SESSION_ROLE=advisor"
}

test_ordinary_primary_under_codex_hook_entry() {
  local dir out status=0
  dir=$(install_run_fixture "$TMP_ROOT/codex-entry-primary")
  mark_codex_hook_root "$dir"
  out=$(run_codex_entry "$dir" '{"source":"startup"}') || status=$?
  expect_code 0 "$status" "ordinary session via the tracked Codex SessionStart entry"
  assert_contains "$out" "SESSION START - stub digest" "Codex entry point did not reach the digest for an ordinary session"
  assert_not_contains "$out" "ADVISOR" "Codex entry point wrongly took the advisor path for an ordinary session"
  pass "fm-sessionstart-run: the tracked Codex SessionStart entry runs the digest unaffected when FM_SESSION_ROLE is unset"
}

test_advisor_role_under_codex_hook_entry() {
  local dir out status=0
  dir=$(install_run_fixture "$TMP_ROOT/codex-entry-advisor")
  mark_codex_hook_root "$dir"
  out=$(run_codex_entry "$dir" '{"source":"startup"}' FM_SESSION_ROLE=advisor) || status=$?
  expect_code 0 "$status" "advisor session via the tracked Codex SessionStart entry"
  assert_contains "$out" "FM_SESSION_ROLE=advisor" "Codex entry point did not take the advisor path"
  assert_absent "$dir/state/session-start-invoked" "Codex entry point ran the digest for an advisor session"
  assert_absent "$dir/state/.lock" "Codex entry point let an advisor session acquire the lock"
  pass "fm-sessionstart-run: the tracked Codex SessionStart entry honors FM_SESSION_ROLE=advisor"
}

test_ordinary_primary_reaches_digest_directly
test_advisor_role_never_reaches_digest_or_lock
test_advisor_role_leaves_crashed_owner_lock_untouched
test_ordinary_primary_under_claude_hook_entry
test_advisor_role_under_claude_hook_entry
test_ordinary_primary_under_codex_hook_entry
test_advisor_role_under_codex_hook_entry
