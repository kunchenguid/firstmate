#!/usr/bin/env bash
# tests/fm-remote-secondmate-relaunch.test.sh - regression coverage for
# bin/fm-remote-secondmate-relaunch.sh: the parent-side tool an operator runs
# to move a remote secondmate onto a new harness, model, or effort.
#
# Reproduces the observed defect: running
# bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch <id> <harness>
# <model> <effort> relaunches the agent on its host, but that host-local verb
# can only rewrite its own endpoint record. The parent's own state/<id>.meta
# kept naming the runtime the mate used to run. The wrapper drives the same
# host-local relaunch and then republishes this home's own record from the
# identity the host confirmed.
#
# The remote transport is faked at the SSH boundary, exactly as the other
# remote-secondmate suites fake it, rather than exercising a real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP=$(fm_test_tmproot fm-remote-secondmate-relaunch)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"

printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n' \
  > "$HOME_DIR/data/secondmates.md"

reset_meta() {
  fm_write_meta "$HOME_DIR/state/ios.meta" \
    "window=remote:ios" \
    "endpoint_task_id=ios" \
    "worktree=/srv/fm-home" \
    "project=/srv/fm" \
    "harness=pi" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=openai-codex/gpt-5.6-sol" \
    "effort=medium" \
    "home=/srv/fm-home" \
    "projects=alpha" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
}

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..5]);
' "$argv_b64")
IFS=$'\t' read -r cmd action id harness model effort <<EOF
$command_fields
EOF
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
[ "$action" = relaunch ] || exit 94
case "$FM_FAKE_RELAUNCH_MODE" in
  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  confirm-other)
    harness=claude
    model=claude-opus-5-5
    effort=medium
    ;;
esac
# FM_FAKE_DELIVERED: record when the host delivers the replacement, then hold
# the relaunch two seconds.
if [ -n "${FM_FAKE_DELIVERED:-}" ]; then date +%s > "$FM_FAKE_DELIVERED"; sleep 2; fi
printf 'relaunched %s harness=%s from=pi model=%s effort=%s backend=herdr endpoint=fm-remote:w1:p1 worktree=/srv/fm-home\n' \
  "$id" "$harness" "$model" "$effort"
printf 'schema=fm-remote-secondmate-control.v1\n'
printf 'backend=herdr\n'
printf 'target=fm-remote:w1:p1\n'
printf 'herdr_session=fm-remote\n'
printf 'harness=%s\n' "$harness"
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
[ -z "${FM_FAKE_BUSY_GEN:-}" ] || printf 'busy_gen=%s\n' "$FM_FAKE_BUSY_GEN"
SH
chmod +x "$FAKEBIN/fake-ssh"

run_relaunch() {  # <args...>
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" FM_FAKE_BUSY_GEN="${FM_FAKE_BUSY_GEN:-}" \
    "$ROOT/bin/fm-remote-secondmate-relaunch.sh" "$@" 2>&1
}

# --- a successful relaunch republishes the parent's own route record --------
reset_meta
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed"$'\n'"$OUT"
assert_contains "$OUT" "relaunched ios harness=claude" \
  "the wrapper should still print the host's own confirmation line"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed model"
assert_grep 'effort=medium' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed effort"
assert_no_grep 'harness=pi' "$HOME_DIR/state/ios.meta" \
  "the stale runtime should not still be recorded"
assert_no_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "the stale model should not still be recorded"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "unrelated route fields must survive the update"
assert_grep 'window=remote:ios' "$HOME_DIR/state/ios.meta" \
  "unrelated identity fields must survive the update"
pass "a successful remote relaunch republishes the parent's harness, model, and effort"

# --- the parent records what the host confirmed, not what it was asked ------
reset_meta
FM_FAKE_RELAUNCH_MODE=confirm-other
OUT=$(run_relaunch ios default default default); RC=$?
unset FM_FAKE_RELAUNCH_MODE
expect_code 0 "$RC" "a relaunch whose host resolves a different identity should succeed"$'\n'"$OUT"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed model"
assert_no_grep 'harness=default' "$HOME_DIR/state/ios.meta" \
  "the parent record must not keep the unresolved request"
pass "a remote relaunch records the identity the host confirmed"

# --- a confirmed relaunch arms the replacement's spawn start check ----------
# The host-local relaunch arms nothing (no watcher scans its route state), so
# the parent records the replacement's busy generation and arms its own record,
# the same '<epoch> <generation or -> <harness>' bin/fm-watch.sh judges.
reset_meta
printf 'remote_busy_gen=g1000.1.1\n' >> "$HOME_DIR/state/ios.meta"
rm -f "$HOME_DIR/state/ios.start-pending"
before=$(date +%s)
FM_FAKE_BUSY_GEN=g1793600000.42.7
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
unset FM_FAKE_BUSY_GEN
expect_code 0 "$RC" "a confirmed remote relaunch should succeed"$'\n'"$OUT"
assert_grep 'remote_busy_gen=g1793600000.42.7' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the replacement's busy generation"
assert_no_grep 'remote_busy_gen=g1000.1.1' "$HOME_DIR/state/ios.meta" \
  "the previous launch's busy generation should be replaced"
read -r rec_epoch rec_gen rec_harness _ < "$HOME_DIR/state/ios.start-pending" \
  || fail "a confirmed remote relaunch armed no start check"
[ "$rec_gen $rec_harness" = "g1793600000.42.7 claude" ] \
  || fail "the armed start check does not describe the replacement: $(cat "$HOME_DIR/state/ios.start-pending")"
[ "$rec_epoch" -ge "$before" ] && [ "$rec_epoch" -le "$(date +%s)" ] \
  || fail "the armed start check is not bounded by the relaunch: $rec_epoch"
pass "a confirmed remote relaunch records the replacement's generation and arms its start check"

reset_meta
rm -f "$HOME_DIR/state/ios.start-pending"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch without a busy generation should succeed"$'\n'"$OUT"
assert_no_grep 'remote_busy_gen=' "$HOME_DIR/state/ios.meta" \
  "a host with no busy generation should leave none recorded"
[ "$(cut -d' ' -f2- "$HOME_DIR/state/ios.start-pending")" = "- claude" ] \
  || fail "a replacement without a busy generation should be armed with '-'"
pass "a replacement whose host reports no busy generation is armed with '-'"

reset_meta
printf '1 - pi\n' > "$HOME_DIR/state/ios.start-pending"
OUT=$(run_relaunch ios kimi - -); RC=$?
expect_code 0 "$RC" "a confirmed kimi relaunch should succeed"$'\n'"$OUT"
assert_absent "$HOME_DIR/state/ios.start-pending" \
  "kimi proves its start in its own gate, so no start check should stay armed"
pass "a kimi replacement is not armed, and an older record is removed"

# --- the relaunch takes its start-check boundary before the host delivers ----
reset_meta
rm -f "$HOME_DIR/state/ios.start-pending"
export FM_FAKE_DELIVERED="$TMP/delivered"
rm -f "$FM_FAKE_DELIVERED"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
unset FM_FAKE_DELIVERED
expect_code 0 "$RC" "a slow confirmed remote relaunch should succeed"$'\n'"$OUT"
read -r rec_epoch _ < "$HOME_DIR/state/ios.start-pending" || fail "the slow relaunch armed no start check"
[ "$rec_epoch" -le "$(cat "$TMP/delivered")" ] \
  || fail "the start-check boundary $rec_epoch was taken after the host delivered at $(cat "$TMP/delivered")"
pass "a remote relaunch takes its start-check boundary before the host delivers the replacement"

# --- a start check that cannot be written fails the relaunch -----------------
reset_meta
printf '1 - pi\n' > "$HOME_DIR/state/ios.start-pending"
FAILMV=$(fm_fakebin "$TMP/failmv")
cat > "$FAILMV/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in *.start-pending) echo "mv: injected failure" >&2; exit 1 ;; esac
exec /bin/mv "$@"
SH
chmod +x "$FAILMV/mv"
OUT=$(PATH="$FAILMV:$PATH" run_relaunch ios claude claude-opus-5-5 medium); RC=$?
[ "$RC" -ne 0 ] || fail "a relaunch whose start check could not be armed reported success"$'\n'"$OUT"
assert_contains "$OUT" "relaunched ios, but its start check could not be armed" \
  "the failed arm should say the replacement runs unchecked"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the running replacement's identity should still be recorded"
[ -z "$(ls "$HOME_DIR/state/ios.start-pending.tmp."* 2>/dev/null)" ] || fail "a failed arm left its temp record"
pass "a remote relaunch whose start check cannot be armed fails with a clear error"

# --- spawn ownership prevents a concurrent remote relaunch -------------------
reset_meta
printf '123 - pi\n' > "$HOME_DIR/state/ios.start-pending"
SPAWN_LOCK="$HOME_DIR/state/.spawn-ios.lock"
fm_lock_try_acquire "$SPAWN_LOCK" || fail "could not acquire spawn lock fixture"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
fm_lock_release "$SPAWN_LOCK" || fail "could not release spawn lock fixture"
[ "$RC" -ne 0 ] || fail "a relaunch must refuse while spawn owns the task lock"
assert_contains "$OUT" "a spawn is still creating task ios" "the lock refusal should be actionable"
[ "$(cat "$HOME_DIR/state/ios.start-pending")" = '123 - pi' ] \
  || fail "a refused relaunch changed the existing start check"
pass "a remote relaunch refuses without changing state while spawn owns the task lock"

# --- a refused relaunch leaves the parent's record untouched -----------------
reset_meta
rm -f "$HOME_DIR/state/ios.start-pending"
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-refusal.meta"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a refused host relaunch must not be reported as successful"
assert_contains "$OUT" "unverified remote secondmate harness" \
  "the refusal reason should reach the caller"
cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
  || fail "a refused relaunch must not touch the parent's record"
assert_absent "$HOME_DIR/state/ios.start-pending" "a refused relaunch must not arm a start check"
pass "a refused remote relaunch leaves the parent's record untouched"

# --- a local (non-remote) secondmate is refused, not silently mishandled ----
fm_write_meta "$HOME_DIR/state/local1.meta" \
  "window=firstmate:fm-local1" "endpoint_task_id=local1" \
  "worktree=/srv/local1" "project=/srv/local1" "harness=codex" \
  "kind=secondmate" "mode=secondmate" "yolo=off" "home=/srv/local1"
OUT=$(run_relaunch local1 claude - -); RC=$?
[ "$RC" -ne 0 ] || fail "a local secondmate must not be accepted by the remote relaunch tool"
assert_contains "$OUT" "not a remotely placed secondmate" \
  "the refusal should explain the tool this task needs instead"
pass "a local secondmate is refused by the remote relaunch tool"

# --- a relaunch keeps an already-armed PR poll authenticating ---------------
# fm-pr-check.sh now refuses to arm a poll on a kind=secondmate record, but a
# record armed before that refusal can still carry the block until the
# watcher retires it. fm-pr-check.sh wrote pr= (and, when a forge head was
# readable, pr_head=) as the LAST lines of the record, and
# fm_pr_metadata_identity_parse treats any other key appearing after pr= as
# invalid, so this wrapper must not append its harness=/model=/effort= lines
# after that identity block. The fixture is seeded the way such a record was
# really written: pr= appended last to the meta, then the poll artifacts
# published through the same fm_pr_poll_prepare/fm_pr_poll_publish_prepared
# pair fm-pr-check.sh uses, since the refused entry point cannot arm it.
reset_meta
printf 'pr=https://github.com/example/repo/pull/1\n' >> "$HOME_DIR/state/ios.meta" \
  || fail "could not write the pr= identity for the relaunch-ordering test"
fm_pr_poll_prepare "$HOME_DIR/state" ios github \
  https://github.com/example/repo/pull/1 github.com example/repo 1 \
  "$ROOT/bin/fm-pr-poll.sh" \
  || fail "could not prepare the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_publish_prepared \
  || fail "could not publish the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "PR poll fixture did not authenticate before the relaunch"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed with an armed PR poll"$'\n'"$OUT"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "a remote relaunch broke PR poll authentication by writing harness/model/effort after pr="
pass "a remote relaunch keeps an already-armed PR poll authenticating"

echo "ALL TESTS PASSED"
