#!/usr/bin/env bash
# Tests for bin/fm-jules-check.sh: the watcher-poll arm for Jules coding-agent
# sessions, analogous to fm-pr-check.sh for PR merge polls.
#
# Matrix:
#   (a) first arm appends jules_session= to meta
#   (b) second arm is idempotent — no duplicate jules_session= line
#   (c) generated check.sh invokes jules-axi watch with --state-file
#   (d) check.sh prints nothing when jules-axi produces no output (silence contract)
#   (e) check.sh echoes the transition line when jules-axi prints one
#   (f) check.sh exits 0 even when jules-axi is not on PATH
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

JULES_CHECK="$ROOT/bin/fm-jules-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-jules-check-tests)

# Build a fresh sandbox with a state dir and a pre-existing task meta.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

arm_jules_check() {
  local case_dir=$1 session=$2
  PATH="$case_dir/fakebin:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$JULES_CHECK" task-x1 "$session"
}

# --- (a) first arm appends jules_session= to meta ---

test_first_arm_appends_jules_session() {
  local case_dir
  case_dir=$(make_case first-arm)

  arm_jules_check "$case_dir" "sesh-abc123" >/dev/null 2>&1

  assert_grep 'jules_session=sesh-abc123' "$case_dir/state/task-x1.meta" \
    "first-arm: meta should contain jules_session=sesh-abc123"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "first-arm: check.sh should be created"
  pass "fm-jules-check appends jules_session= to meta on first arm"
}

# --- (b) second arm is idempotent ---

test_second_arm_idempotent() {
  local case_dir
  case_dir=$(make_case idempotent)

  arm_jules_check "$case_dir" "sesh-abc123" >/dev/null 2>&1
  arm_jules_check "$case_dir" "sesh-abc123" >/dev/null 2>&1

  # Should appear exactly once
  local count
  count=$(grep -c 'jules_session=sesh-abc123' "$case_dir/state/task-x1.meta")
  [ "$count" -eq 1 ] || fail "idempotent: jules_session= appears $count times, expected 1"
  pass "fm-jules-check is idempotent — no duplicate jules_session= lines"
}

# --- (c) generated check.sh invokes jules-axi watch with --state-file ---

test_check_sh_invokes_jules_axi_watch() {
  local case_dir
  case_dir=$(make_case check-invocation)

  arm_jules_check "$case_dir" "sesh-def456" >/dev/null 2>&1

  local check_sh="$case_dir/state/task-x1.check.sh"
  assert_present "$check_sh" "check-invocation: check.sh should exist"

  # Verify it references jules-axi watch
  local body
  body=$(cat "$check_sh")
  assert_contains "$body" 'jules-axi watch' \
    "check-invocation: check.sh should call jules-axi watch"

  # Verify --state-file points under STATE
  assert_contains "$body" '--state-file' \
    "check-invocation: check.sh should pass --state-file"

  assert_contains "$body" 'jules.state' \
    "check-invocation: state-file should end with .jules.state"
  pass "generated check.sh invokes jules-axi watch with --state-file"
}

# --- (d) check.sh prints nothing when jules-axi produces no output ---

test_check_sh_silent_on_no_output() {
  local case_dir fakebin out
  case_dir=$(make_case silence)
  fakebin="$case_dir/fakebin"

  # Stub jules-axi: exit 0, no output
  cat > "$fakebin/jules-axi" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$fakebin/jules-axi"

  arm_jules_check "$case_dir" "sesh-silent" >/dev/null 2>&1

  out=$(PATH="$fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh" 2>&1)
  [ -z "$out" ] || fail "silence: check.sh should print nothing when jules-axi is silent, got: $out"
  pass "check.sh prints nothing when jules-axi watch produces no output"
}

# --- (e) check.sh echoes the transition line when jules-axi prints one ---

test_check_sh_echoes_transition() {
  local case_dir fakebin out
  case_dir=$(make_case transition)
  fakebin="$case_dir/fakebin"

  # Stub jules-axi: prints a state transition line
  cat > "$fakebin/jules-axi" <<'STUB'
#!/usr/bin/env bash
echo "state: building"
STUB
  chmod +x "$fakebin/jules-axi"

  arm_jules_check "$case_dir" "sesh-trans" >/dev/null 2>&1

  out=$(PATH="$fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh" 2>&1)
  assert_contains "$out" 'state: building' \
    "transition: check.sh should echo the transition line from jules-axi"
  pass "check.sh echoes the state transition line from jules-axi watch"
}

# --- (f) check.sh exits 0 even when jules-axi is not on PATH ---

test_check_sh_exits_zero_without_jules_axi() {
  local case_dir out rc
  case_dir=$(make_case no-jules-axi)

  arm_jules_check "$case_dir" "sesh-no-axi" >/dev/null 2>&1

  set +e
  out=$(PATH="$case_dir/fakebin" bash "$case_dir/state/task-x1.check.sh" 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "no-jules-axi: check.sh should exit 0, got $rc"
  [ -z "$out" ] || fail "no-jules-axi: check.sh should produce no output, got: $out"
  pass "check.sh exits 0 silently when jules-axi is not on PATH"
}

test_first_arm_appends_jules_session
test_second_arm_idempotent
test_check_sh_invokes_jules_axi_watch
test_check_sh_silent_on_no_output
test_check_sh_echoes_transition
test_check_sh_exits_zero_without_jules_axi
