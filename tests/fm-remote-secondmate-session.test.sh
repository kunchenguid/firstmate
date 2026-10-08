#!/usr/bin/env bash
# Exercise host controller session selection through its route and retire APIs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-session)
REMOTE_HOME="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
META="$REMOTE_HOME/state/parent-route/lab.meta"
mkdir -p "$REMOTE_HOME/state/parent-route" "$REMOTE_HOME/bin"
printf 'lab\n' > "$REMOTE_HOME/.fm-secondmate-home"
printf 'Synthetic controller fixture.\n' > "$REMOTE_HOME/AGENTS.md"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_HERDR_LOG"
exit 99
SH
chmod +x "$FAKEBIN/herdr"
export FM_TEST_HERDR_LOG="$TMP_ROOT/herdr.log"

seed_route() { # <recorded-session> [target-session]
  fm_write_meta "$META" \
    "window=${2:-$1}:w1:p1" "backend=herdr" "endpoint_task_id=lab" \
    "herdr_session=$1" "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" \
    "herdr_pane_id=w1:p1" "worktree=$REMOTE_HOME" "project=$ROOT" "home=$REMOTE_HOME" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "spawn_gen=synthetic.g0"
}

control() {
  env FM_HOME="$REMOTE_HOME" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-remote-secondmate-control.sh" "$@" 2>&1
}

seed_route fm-remote
out=$(control route lab); rc=$?
expect_code 0 "$rc" "unset session retains the ordinary remote route"
assert_contains "$out" 'herdr_session=fm-remote' "default route session"
assert_contains "$out" 'target=fm-remote:w1:p1' "default route target"
pass "unset session retains fm-remote"

session=$(bash "$ROOT/bin/fm-herdr-lab.sh" name remote-controller)
seed_route "$session"
out=$(control route lab --herdr-session "$session"); rc=$?
expect_code 0 "$rc" "helper-named lab route must be accepted"
assert_contains "$out" "herdr_session=$session" "selected lab route session"
assert_contains "$out" "target=$session:w1:p1" "selected lab route target"
pass "helper-named lab route is accepted without endpoint effects"

# Invalid explicit inputs must refuse even when metadata otherwise matches.
# Retirement would access the endpoint and remove records if admitted.
for invalid in default fm-remote fm-lab- fm-lab-bad.name 'fm-lab-bad/name' ''; do
  seed_route "$invalid"
  cp "$META" "$TMP_ROOT/before.meta"
  out=$(control retire lab --herdr-session "$invalid"); rc=$?
  expect_code 1 "$rc" "invalid explicit session must refuse"
  assert_contains "$out" 'invalid remote Herdr lab session' "actionable session refusal"
  cmp -s "$META" "$TMP_ROOT/before.meta" || fail "invalid session changed the endpoint record"
  assert_absent "$FM_TEST_HERDR_LOG" "invalid session accessed Herdr"
done
pass "default, shared, empty and malformed overrides refuse before effects"

seed_route fm-remote
cp "$META" "$TMP_ROOT/before.meta"
out=$(control retire lab --herdr-session "$session"); rc=$?
expect_code 1 "$rc" "lab selection must refuse shared-session metadata"
assert_contains "$out" "expected '$session'" "recorded session mismatch diagnostic"
cmp -s "$META" "$TMP_ROOT/before.meta" || fail "session mismatch changed the endpoint record"
assert_absent "$FM_TEST_HERDR_LOG" "session mismatch accessed Herdr"
pass "lab selection cannot retire a shared-session endpoint"

seed_route "$session" fm-remote
cp "$META" "$TMP_ROOT/before.meta"
out=$(control retire lab --herdr-session "$session"); rc=$?
expect_code 1 "$rc" "lab metadata cannot authorize a shared-session target"
cmp -s "$META" "$TMP_ROOT/before.meta" || fail "target mismatch changed the endpoint record"
assert_absent "$FM_TEST_HERDR_LOG" "target mismatch accessed Herdr"
pass "lab selection refuses targets outside the selected session"
