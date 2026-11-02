#!/usr/bin/env bash
# Exercise the host controller's isolated lab-session selection through its
# public route and retire APIs. The default remote session stays fm-remote;
# only an owned fm-lab-* name may be selected, and every refusal must leave the
# endpoint record and Herdr untouched.
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


cat > "$FAKEBIN/rex" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *whoami*) printf '{"endpoint":"%s"}\n' "$FM_TEST_REX_SERVER" ;;
  *"block call"*) echo 'block not found' >&2; exit 3 ;;
  *) exit 99 ;;
esac
SH
chmod +x "$FAKEBIN/rex"
history="$TMP_ROOT/code/state/remote-secondmate-history"
mkdir -p "$history"
absent_home="$TMP_ROOT/absent"
pending="$history/lab.retirement.rex.g1.pending.json"
jq -n --arg home "$absent_home" '{schema:"fm-remote-retirement-pending.v1",task:"lab",home:$home,generation:"rex.g1",backend:"rex",target:"aaaa:bbbb",rex_server:"recorded-server",phase:"pending",destroyed:false,exit_code:0}' > "$pending"
for server in foreign-server recorded-server; do
  out=$(env FM_HOME="$absent_home" FM_ROOT_OVERRIDE="$TMP_ROOT/code" FM_TEST_REX_SERVER="$server" PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-remote-secondmate-control.sh" retire lab --expect-generation rex.g1 2>&1); rc=$?
  if [ "$server" = foreign-server ]; then
    [ "$rc" -ne 0 ] || fail 'retirement accepted a different Rex server'
    assert_present "$pending" 'refusal lost pending server proof'
  else
    expect_code 0 "$rc" "retirement retry with recorded Rex server: $out"
    assert_absent "$pending" 'successful retry retained pending record'
    assert_equals rex "$(printf '%s\n' "$out" | sed -n 's/^seat_retirement=//p' | jq -r .backend)" 'retry lost Rex backend'
  fi
  assert_absent "$absent_home" 'retirement retry recreated deleted home'
done
pass "Rex retirement retry retains server ownership after home deletion"

for phase in pending completed; do
  proof="$history/lab.retirement.lab.g1.json"
  pending="$history/lab.retirement.lab.g1.pending.json"
  jq -n --arg home "$absent_home" --arg target "$session:w1:p1" \
    '{task:"lab",home:$home,generation:"lab.g1",backend:"herdr",target:$target,destroyed:true,exit_code:0}' > "$proof"
  if [ "$phase" = pending ]; then
    jq '. + {schema:"fm-remote-retirement-pending.v1",phase:"pending",destroyed:false}' "$proof" > "$pending"
    rm "$proof"
  fi
  out=$(env FM_HOME="$absent_home" FM_ROOT_OVERRIDE="$TMP_ROOT/code" PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-remote-secondmate-control.sh" retire lab --expect-generation lab.g1 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$phase evidence accepted the wrong session"
  assert_absent "$FM_TEST_HERDR_LOG" "$phase wrong session accessed Herdr"
  out=$(env FM_HOME="$absent_home" FM_ROOT_OVERRIDE="$TMP_ROOT/code" PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-remote-secondmate-control.sh" retire lab --expect-generation lab.g1 --herdr-session "$session" 2>&1); rc=$?
  if [ "$phase" = completed ]; then
    expect_code 0 "$rc" "lab completion replay refused: $out"
  else
    assert_present "$FM_TEST_HERDR_LOG" "lab pending retry did not reach endpoint reconciliation: $out"
    rm "$FM_TEST_HERDR_LOG" "$pending"
  fi
  assert_absent "$absent_home" "$phase replay recreated the retired home"
done
pass "lab retirement evidence binds pending retries and completion replay to the selected session"
