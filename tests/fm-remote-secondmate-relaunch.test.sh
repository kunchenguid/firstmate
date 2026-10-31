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
if [ "$action" = state ]; then
  printf 'probe diagnostic\nalive\n'
  exit 0
fi
[ "$action" = relaunch ] || exit 94
case "$FM_FAKE_RELAUNCH_MODE" in
  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  refuse-preflight)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    printf 'relaunch_refused_before_control=%s\n' "$id"
    exit 1
    ;;
  uncertain)
    printf 'error: remote connection lost\n' >&2
    exit 255
    ;;
  foreign-refusal)
    printf 'relaunch_refused_before_control=another-task\n'
    exit 1
    ;;
  confirm-other)
    harness=claude
    model=claude-opus-5-5
    effort=medium
    ;;
esac
printf 'relaunched %s harness=%s from=pi model=%s effort=%s backend=herdr endpoint=fm-remote:w1:p1 worktree=/srv/fm-home\n' \
  "$id" "$harness" "$model" "$effort"
printf 'schema=fm-remote-secondmate-control.v1\n'
printf 'backend=herdr\n'
printf 'target=fm-remote:w1:p1\n'
printf 'herdr_session=fm-remote\n'
printf 'harness=%s\n' "$harness"
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
SH
chmod +x "$FAKEBIN/fake-ssh"

run_relaunch() {  # <args...>
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" \
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

# --- a refused relaunch leaves the parent's record untouched -----------------
reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-refusal.meta"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a refused host relaunch must not be reported as successful"
assert_contains "$OUT" "unverified remote secondmate harness" \
  "the refusal reason should reach the caller"
cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
  || fail "a refused relaunch must not touch the parent's record"
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

for unpinned_model in - default; do
  reset_meta
  printf 'max=1\nmodel-pattern=.*\n' > "$HOME_DIR/config/sol-cap"
  sed 's|^model=.*|model=default|' "$HOME_DIR/state/ios.meta" > "$TMP/unpinned.meta"
  mv "$TMP/unpinned.meta" "$HOME_DIR/state/ios.meta"
  printf 'occupied\tgpt-6.1-sol\t1\t%s\n' "$$" > "$HOME_DIR/state/sol-sessions.tsv"
  OUT=$(run_relaunch ios codex gpt-6.1-sol default); RC=$?
  expect_code 1 "$RC" "an explicitly pinned switch must respect the full ceiling"
  OUT=$(run_relaunch ios codex "$unpinned_model" default); RC=$?
  expect_code 0 "$RC" "an unpinned switch must bypass the full ceiling: $OUT"
  assert_grep 'model=default' "$HOME_DIR/state/ios.meta" \
    "the unpinned switch must publish the confirmed model"
  assert_equals 1 "$(wc -l < "$HOME_DIR/state/sol-sessions.tsv" | tr -d ' ')" \
    "an unpinned switch must not create occupancy"
done
pass "both unpinned model spellings bypass a full model-pattern ceiling"

echo "ALL TESTS PASSED"

reset_meta
printf 'max=4\nmodels=gpt-6.1-sol\n' > "$HOME_DIR/config/sol-cap"
for i in 1 2 3 4; do printf 'live-%s\tgpt-6.1-sol\t1\t%s\n' "$i" "$$"; done > "$HOME_DIR/state/sol-sessions.tsv"
printf 'ios\tgpt-6.1-sol\t1\t99999999\n' >> "$HOME_DIR/state/sol-sessions.tsv"
OUT=$(run_relaunch ios codex gpt-6.1-sol medium); RC=$?
expect_code 1 "$RC" "a runtime switch bypassed the full parent ceiling"
awk -F'\t' '$1 != "live-4"' "$HOME_DIR/state/sol-sessions.tsv" > "$TMP/registry"
mv "$TMP/registry" "$HOME_DIR/state/sol-sessions.tsv"
OUT=$(run_relaunch ios codex gpt-6.1-sol medium); RC=$?
expect_code 0 "$RC" "an admitted Sol runtime switch failed: $OUT"
assert_equals 0 "$(awk -F'\t' '$1 == "ios" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" "remote switch did not preserve occupancy"
OUT=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim fifth ship codex gpt-6.1-sol "$HOME_DIR/config" "$HOME_DIR/state"); RC=$?
expect_code 1 "$RC" "stale-row replacement left the switched worker uncounted"
OUT=$(run_relaunch ios codex gpt-6.1-sol medium); RC=$?
expect_code 0 "$RC" "an existing live reservation could not be reused: $OUT"
assert_equals 0 "$(awk -F'\t' '$1 == "ios" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" "reused occupancy was not preserved before delivery"
OUT=$(FM_FAKE_RELAUNCH_MODE=refuse run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 1 "$RC" "refused remote replacement unexpectedly succeeded"
assert_equals 0 "$(awk -F'\t' '$1 == "ios" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" "failed runtime switch released occupancy"
# The same refusal over the UNCAPPED worker that held no row: this switch
# created the reservation, so a confirmed pre-control refusal must release it
# rather than block every later capped dispatch. A failure whose phase the
# host does not prove, and a proof naming another task, keep it.
for refusal_mode in refuse-preflight refuse uncertain foreign-refusal; do
  reset_meta
  printf 'max=1\nmodels=gpt-6.1-sol\n' > "$HOME_DIR/config/sol-cap"
  : > "$HOME_DIR/state/sol-sessions.tsv"
  cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-capped-refusal.meta"
  OUT=$(FM_FAKE_RELAUNCH_MODE="$refusal_mode" run_relaunch ios codex gpt-6.1-sol medium); RC=$?
  [ "$RC" -ne 0 ] || fail "a failed uncapped-to-capped switch unexpectedly succeeded: $OUT"
  cmp -s "$TMP/ios-before-capped-refusal.meta" "$HOME_DIR/state/ios.meta" \
    || fail "a failed uncapped-to-capped switch changed the original worker's route"
  if [ "$refusal_mode" = refuse-preflight ]; then
    assert_equals '' "$(awk -F'\t' '$1 == "ios" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" \
      "a confirmed pre-control refusal leaked the reservation the switch created"
    expected_admission=0
  else
    assert_equals 0 "$(awk -F'\t' '$1 == "ios" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" \
      "a delivery that may have started a replacement released its reservation ($refusal_mode)"
    expected_admission=1
  fi
  OUT=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim next ship codex gpt-6.1-sol "$HOME_DIR/config" "$HOME_DIR/state"); RC=$?
  expect_code "$expected_admission" "$RC" "wrong capacity after $refusal_mode: $OUT"
done
pass "only a confirmed pre-control refusal releases the reservation a switch created"
REAL_MV=$(command -v mv)
export REAL_MV
cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [[ "$last" = */ios.meta ]]; then
  [ "${FM_TEST_PUBLISH_FAIL:-0}" = 0 ] || exit 1
  if [ -n "${FM_TEST_PUBLISH_PAUSE:-}" ]; then
    touch "$FM_TEST_PUBLISH_PAUSE.ready"
    while [ ! -e "$FM_TEST_PUBLISH_PAUSE.release" ]; do sleep 0.02; done
  fi
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$FAKEBIN/mv"
OUT=$(PATH="$FAKEBIN:$PATH" FM_TEST_PUBLISH_FAIL=1 run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 1 "$RC" "failed metadata publication unexpectedly succeeded"
assert_equals 0 "$(awk -F'\t' '$1 == "ios" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" "publication failure released occupancy"
PATH="$FAKEBIN:$PATH" FM_TEST_PUBLISH_PAUSE="$TMP/publication" run_relaunch ios claude claude-opus-5-5 medium > "$TMP/switch.out" &
switch_pid=$!
for ((i=0; i<200; i++)); do
  [ ! -e "$TMP/publication.ready" ] || break
  sleep 0.02
done
[ -e "$TMP/publication.ready" ] || fail "model publication did not reach the barrier"
(
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim concurrent ship codex gpt-6.1-sol "$HOME_DIR/config" "$HOME_DIR/state" > "$TMP/admission.out"
  printf '%s\n' "$?" > "$TMP/admission.done"
) &
admission_pid=$!
sleep 0.1
[ ! -e "$TMP/admission.done" ] || fail "admission crossed the model-publication boundary"
touch "$TMP/publication.release"
wait "$switch_pid"; RC=$?
OUT=$(cat "$TMP/switch.out")
expect_code 0 "$RC" "reverse runtime switch failed: $OUT"
wait "$admission_pid"
assert_equals 0 "$(cat "$TMP/admission.done")" "post-publication admission restored stale Sol occupancy"
assert_equals '' "$(awk -F'\t' '$1 == "ios" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" "confirmed non-Sol replacement retained occupancy"
pass "remote runtime switches enforce parent admission and retain uncertain occupancy"

cat > "$FAKEBIN/rex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --autostart=false ]; then
  echo 'error: could not connect to the rex server' >&2
  exit 4
fi
if [ "${1:-}" = whoami ]; then
  if [ "$FM_TEST_REX_MODE" = foreign ]; then
    printf '{"endpoint":"unix:///other.sock"}\n'
  else
    printf '{"endpoint":"unix:///recorded.sock"}\n'
  fi
  exit 0
fi
if [ "$FM_TEST_REX_MODE" = gone ]; then
  echo 'error: block not found' >&2
  exit 3
fi
echo 'error: could not connect to the rex server' >&2
exit 4
SH
chmod +x "$FAKEBIN/rex"
for entry in relaunch standalone; do
  for rex_mode in unknown foreign gone; do
    reset_meta
    printf 'max=1\nmodels=gpt-6.1-sol\n' > "$HOME_DIR/config/sol-cap"
    fm_write_meta "$HOME_DIR/state/stopped-rex.meta" "backend=rex" \
      "window=aaaaaaaa:bbbbbbbb" "rex_server=unix:///recorded.sock" "model=gpt-6.1-sol"
    printf 'stopped-rex\tgpt-6.1-sol\t1\t-2\n' > "$HOME_DIR/state/sol-sessions.tsv"
    if [ "$entry" = relaunch ]; then
      OUT=$(REX_BIN_DIR="$FAKEBIN" FM_TEST_REX_MODE="$rex_mode" run_relaunch ios codex gpt-6.1-sol medium); RC=$?
    else
      OUT=$(FM_HOME="$HOME_DIR" REX_BIN_DIR="$FAKEBIN" FM_TEST_REX_MODE="$rex_mode" \
        bash "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim fresh ship codex gpt-6.1-sol "$HOME_DIR/config" "$HOME_DIR/state"); RC=$?
    fi
    if [ "$rex_mode" = gone ]; then
      expect_code 0 "$RC" "$entry did not recover stopped Rex capacity: $OUT"
      assert_equals -1 "$(awk -F '\t' '$1 == "stopped-rex" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" "$entry forgot the Rex stop proof"
    else
      expect_code 1 "$RC" "$entry admitted against unproven Rex absence: $OUT"
      assert_equals -2 "$(awk -F '\t' '$1 == "stopped-rex" {print $4}' "$HOME_DIR/state/sol-sessions.tsv")" "$entry released unproven Rex occupancy"
    fi
  done
  rm -f "$HOME_DIR/state/stopped-rex.meta"
done
pass "remote relaunch and standalone admission recover only proven Rex absence"
