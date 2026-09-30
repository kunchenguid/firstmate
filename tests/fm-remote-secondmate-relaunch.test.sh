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
  my ($op, $prev) = ("-", "-");
  for (my $i = 0; $i < @args; $i++) {
    $op = $args[$i + 1] if $args[$i] eq "--operation";
    $prev = $args[$i + 1] if $args[$i] eq "--previous";
  }
  print join("\t", (map { defined $_ && $_ ne "" ? $_ : "-" } @args[0..5]), $op, $prev);
' "$argv_b64")
IFS=$'\t' read -r cmd action id harness model effort op prev <<FIELDS
$command_fields
FIELDS
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
[ "$op" != - ] || op=
# disposition <disposition> <startup> <old-stopped> [actual] [requested]
disposition() {
  local actual=${4:-} requested=${5:-$op} prevj=null route=null actualj=null
  [ "$prev" = - ] || prevj="\"$prev\""
  if [ -n "$actual" ]; then
    actualj="\"$actual\""
    route='{"placement":"remote","backend":"herdr","target":"fm-remote:w1:p1","home":"/srv/fm-home","host":null,"remote_root":null,"spawn_gen":null}'
  fi
  printf 'seat_disposition={"schema":"fm-remote-seat-operation.v2","task":"%s","operation":"%s","requested_generation":"%s","actual_generation":%s,"previous_generation":%s,"disposition":"%s","startup_confirmed":%s,"old_stopped":%s,"route":%s,"actual_model":"%s","complete":true}\n' \
    "$id" "$op" "$requested" "$actualj" "$prevj" "$1" "$2" "$3" "$route" "$model"
}
if [ "$action" = disposition ]; then
  # argv: disposition <id> --operation <op>
  op=$model
  model=pool-model-a
  case "$FM_FAKE_DISPOSITION" in
    dead) disposition dead-after-start true false "$op" ;;
    dead-other) disposition dead-after-start true false other-generation other-generation ;;
    unknown) disposition unknown false false ;;
    *) disposition started true false "$op" ;;
  esac
  exit 0
fi
[ "$action" = relaunch ] || exit 94
old_stopped=false
[ "$prev" = - ] || old_stopped=true
case "$FM_FAKE_RELAUNCH_MODE" in
  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  confirmed-failure)
    [ -z "$op" ] || disposition prelaunch false false >&2
    printf 'relaunch_failure=prelaunch\n' >&2
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  launch-failure)
    [ -z "$op" ] || disposition cancelled false "$old_stopped" >&2
    printf 'relaunch_failure=launch\n' >&2
    printf 'error: replacement launch failed; no agent is running\n' >&2
    exit 1
    ;;
  uncertain-failure)
    printf 'error: remote relaunch result is unknown\n' >&2
    exit 255
    ;;
  unmarked-failure)
    printf 'relaunch_failure=prelaunch\n' >&2
    printf 'error: a refusal that carries no operation-bound disposition\n' >&2
    exit 1
    ;;
  wrong-token)
    op=some-other-operation
    disposition prelaunch false false >&2
    exit 1
    ;;
  publication-failure)
    # The host starts the candidate, but the parent cannot publish it: the
    # route block it would republish from never arrives.
    disposition started true "$old_stopped" "$op"
    exit 0
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
if [ -n "$op" ]; then
  printf 'spawn_gen=%s\n' "$op"
  disposition started true "$old_stopped" "$op"
else
  printf 'spawn_gen=host-generation\n'
fi
SH
chmod +x "$FAKEBIN/fake-ssh"

run_relaunch() {  # <args...>
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" FM_FAKE_DISPOSITION="${FM_FAKE_DISPOSITION:-}" \
    "$ROOT/bin/fm-remote-secondmate-relaunch.sh" "$@" 2>&1
}

seed_pool() {  # a primary pool of one whose only remote has a complete, empty certificate
  local digest
  rm -rf "$HOME_DIR/state/fleet-seats"
  mkdir -p "$HOME_DIR/state/fleet-seats"
  printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$HOME_DIR/config/fleet-seats"
  digest=$(jq -cS . "$HOME_DIR/config/fleet-seats" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
  printf '{"schema":"fm-fleet-seats-serve.v2","policy_digest":"%s","epoch":"rtest.1","complete":true,"holders":[]}\n' \
    "$digest" > "$HOME_DIR/state/fleet-seats/remote-ios.cert"
}

seats() {
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_DISPOSITION="${FM_FAKE_DISPOSITION:-}" \
    "$ROOT/bin/fm-fleet-seats.sh" "$@"
}

probe_pool() {  # reserve for another worker, then give the probe back
  local out rc gen
  gen="probe$(date +%s)$RANDOM$RANDOM"
  out=$(seats reserve probe --generation "$gen" --harness pi --model pool-model-a --holder-pid "$$" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || seats release probe --generation "$gen" --reason prelaunch >/dev/null 2>&1
  printf '%s\n' "$out"
  return "$rc"
}

ios_generation() {  # the generation the parent record names
  sed -n 's/^fleet_seat_generation=//p' "$HOME_DIR/state/ios.meta" | tail -1
}

ios_lifecycle() {  # <generation>
  seats show ios | jq -r --arg g "$1" '.incarnations[] | select(.generation == $g) | .lifecycle'
}

ios_candidate() {  # the newest incarnation in the ledger
  seats show ios | jq -r '.incarnations | last | .generation'
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
FM_FAKE_RELAUNCH_MODE='confirm-other'
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
FM_FAKE_RELAUNCH_MODE='refuse'
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
rm -f "$HOME_DIR/state/local1.meta"

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

reset_meta
seed_pool
fm_write_meta "$HOME_DIR/state/busy.meta" "kind=ship" "model=pool-model-a"
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
[ "$RC" -ne 0 ] || fail "a full fleet pool granted a remote supervisor relaunch"
assert_contains "$OUT" "pool shared is full" "a full fleet pool did not refuse before the host call"
assert_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "a refused relaunch changed the parent route"
pass "a full fleet pool refuses a remote supervisor relaunch"

reset_meta
rm -f "$HOME_DIR/state/busy.meta"
seed_pool
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
expect_code 0 "$RC" "a seated remote relaunch should succeed: $OUT"
assert_grep 'model=pool-model-a' "$HOME_DIR/state/ios.meta" \
  "the successful relaunch did not publish its pooled model"
G1=$(ios_generation)
[ -n "$G1" ] || fail "the successful relaunch did not publish its seat generation"
assert_equals confirmed "$(ios_lifecycle "$G1")" "the host's started disposition did not confirm the seat"
OUT=$(probe_pool); RC=$?
expect_code 4 "$RC" "a worker after a successful pooled remote relaunch"
pass "a successful remote relaunch confirms and keeps its fleet seat"

# Same pool at full capacity: the replacement is the same holder, so it needs
# no second seat, and the old generation is released only because the host
# proved it stopped.
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
expect_code 0 "$RC" "an existing pooled supervisor should keep its full-pool seat: $OUT"
G2=$(ios_generation)
[ "$G2" != "$G1" ] || fail "a same-pool relaunch reused the old generation"
assert_equals released "$(ios_lifecycle "$G1")" "the proven-stopped predecessor was not released"
assert_equals confirmed "$(ios_lifecycle "$G2")" "the replacement was not confirmed"
OUT=$(probe_pool); RC=$?
expect_code 4 "$RC" "a worker after a same-model remote relaunch"
pass "a same-pool remote relaunch replaces one seat without dropping the count"

# A token-scoped prelaunch refusal releases only the candidate.
FM_FAKE_RELAUNCH_MODE='confirmed-failure'
OUT=$(run_relaunch ios notaharness pool-model-a medium); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a confirmed host refusal succeeded"
assert_contains "$OUT" "unverified remote secondmate harness" "the confirmed host refusal was lost"
assert_equals released "$(ios_lifecycle "$(ios_candidate)")" "the refused candidate kept its seat"
assert_equals confirmed "$(ios_lifecycle "$G2")" "a prelaunch refusal disturbed the running generation"
assert_equals "$G2" "$(ios_generation)" "a prelaunch refusal changed the parent record"
OUT=$(probe_pool); RC=$?
expect_code 4 "$RC" "a worker while the untouched old supervisor still runs"
pass "a prelaunch refusal releases only its own candidate and keeps the old seat"

# Unmarked, wrong-token, and transport failures never free a candidate.
for mode in unmarked-failure wrong-token uncertain-failure; do
  FM_FAKE_RELAUNCH_MODE=$mode
  OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
  unset FM_FAKE_RELAUNCH_MODE
  [ "$RC" -ne 0 ] || fail "a $mode relaunch was reported as successful"
  CAND=$(ios_candidate)
  assert_equals reserved "$(ios_lifecycle "$CAND")" "a $mode outcome released its candidate"
  OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
  [ "$RC" -ne 0 ] || fail "a new relaunch started beside the unresolved $mode candidate"
  assert_contains "$OUT" "still unresolved" "the unresolved $mode candidate did not block another launch"
  # The host later proves the candidate never ran.
  printf '{"schema":"fm-remote-seat-operation.v2","task":"ios","operation":"%s","requested_generation":"%s","actual_generation":null,"previous_generation":"%s","disposition":"prelaunch","startup_confirmed":false,"old_stopped":false,"route":null,"actual_model":null,"complete":true}\n' \
    "$CAND" "$CAND" "$G2" > "$TMP/resolve.json"
  chmod 0600 "$TMP/resolve.json"
  seats reconcile-remote ios --generation "$CAND" --response-file "$TMP/resolve.json" >/dev/null \
    || fail "the matching host refusal did not resolve the $mode candidate"
done
pass "unmarked, wrong-token, and unknown outcomes keep the candidate counted until its own disposition arrives"

# Old stopped, candidate proven never launched: both terminal, route kept.
FM_FAKE_RELAUNCH_MODE='launch-failure'
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a failed replacement of a pooled supervisor succeeded"
assert_contains "$OUT" "replacement launch failed" "the host's launch failure was lost"
assert_equals released "$(ios_lifecycle "$G2")" "the proven-stopped old generation kept its seat"
assert_equals released "$(ios_lifecycle "$(ios_candidate)")" "the cancelled candidate kept its seat"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "the failed replacement lost its recovery route"
OUT=$(probe_pool); RC=$?
expect_code 0 "$RC" "a worker after the failed replacement: $OUT"
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
expect_code 0 "$RC" "a recovery launch after the failed replacement: $OUT"
OUT=$(probe_pool); RC=$?
expect_code 4 "$RC" "a worker after the supervisor recovered: $OUT"
pass "a failed replacement frees both proven generations and recovery restores the seat"

# Stale existing parent: the host starts B but publication fails, so the
# parent still names the unpooled model A.
reset_meta
seed_pool
FM_FAKE_RELAUNCH_MODE='publication-failure'
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a failed parent publication was reported as successful"
assert_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "the parent record unexpectedly published after its write failed"
B=$(ios_candidate)
assert_equals confirmed "$(ios_lifecycle "$B")" "the started generation was not confirmed despite the stale parent"
OUT=$(probe_pool); RC=$?
expect_code 4 "$RC" "a worker while B runs behind a stale parent record"
# A death report for a different generation never reclaims B.
FM_FAKE_DISPOSITION=dead-other
OUT=$(seats reclaim ios --generation "$B" 2>&1); RC=$?
unset FM_FAKE_DISPOSITION
[ "$RC" -ne 0 ] || fail "another generation's death receipt reclaimed B: $OUT"
assert_equals confirmed "$(ios_lifecycle "$B")" "another generation's death receipt changed B"
# B's own death, reported for its exact operation, reclaims it.
FM_FAKE_DISPOSITION=dead
OUT=$(seats reclaim ios --generation "$B" 2>&1); RC=$?
unset FM_FAKE_DISPOSITION
expect_code 0 "$RC" "B's own death report: $OUT"
assert_equals reclaimed "$(ios_lifecycle "$B")" "B's exact death report did not reclaim it"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" "reclaiming B lost the recovery route"
OUT=$(probe_pool); RC=$?
expect_code 0 "$RC" "a worker after B's death: $OUT"
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
expect_code 0 "$RC" "a retry after B's death should succeed: $OUT"
assert_grep 'model=pool-model-a' "$HOME_DIR/state/ios.meta" \
  "the retry did not publish the confirmed pooled model"
pass "a stale parent record neither hides a started generation nor resurrects it after its exact death"

# A restart whose persistence belonged to an earlier generation touches nothing.
OUT=$(run_relaunch ios claude pool-model-a medium --expect-generation stale-generation); RC=$?
expect_code 6 "$RC" "a stale expected generation: $OUT"
assert_contains "$OUT" "generation-mismatch" "the stale generation refusal was not named"
pass "an expected-generation mismatch refuses before any seat or host effect"

reset_meta
rm -rf "$HOME_DIR/state/fleet-seats"
rm -f "$HOME_DIR/config/fleet-seats"
printf 'remote_spawn_gen=host-old\n' >> "$HOME_DIR/state/ios.meta"
OUT=$(run_relaunch ios claude pool-model-a medium --expect-generation host-old); RC=$?
expect_code 0 "$RC" "generation-matching unpooled remote relaunch: $OUT"
assert_equals host-generation "$(sed -n 's/^remote_spawn_gen=//p' "$HOME_DIR/state/ios.meta")" "unpooled relaunch did not publish its host generation"
OUT=$(run_relaunch ios claude pool-model-a medium --expect-generation host-old); RC=$?
expect_code 6 "$RC" "an old unpooled host generation: $OUT"
pass "remote relaunch publishes and fences its host generation without pools"

# --- host side: token-scoped operation receipts and dispositions --------------
# bin/fm-remote-secondmate-control.sh answers for exactly one operation token
# from its durable receipt and control journal; an absent or foreign receipt
# or a busy episode is unknown, never a refusal.
HOST_HOME="$TMP/host-home"
mkdir -p "$HOST_HOME/state/parent-route" "$HOST_HOME/bin" "$HOST_HOME/data" "$HOST_HOME/config"
printf 'ios\n' > "$HOST_HOME/.fm-secondmate-home"
: > "$HOST_HOME/AGENTS.md"

host_control() {  # <args...>
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$HOST_HOME" "$ROOT/bin/fm-remote-secondmate-control.sh" "$@" 2>&1
}

host_disposition() {  # <operation>: the disposition word the host reports
  host_control disposition ios --operation "$1" | sed -n 's/^seat_disposition=//p' | tail -1 | jq -r '.disposition + " " + (.old_stopped | tostring)'
}

host_receipt() {  # <operation> <verb> <phase> [previous]
  printf 'schema=fm-remote-seat-receipt.v1\noperation=%s\nverb=%s\nrequested_generation=%s\nprevious_generation=%s\nphase=%s\n' \
    "$1" "$2" "$1" "${4:--}" "$3" > "$HOST_HOME/state/parent-route/ios.seat-operation.$1"
}

host_journal() {  # <operation> <phase> [rollback]
  { printf 'v1\ntask=ios\nphase=%s\nseat_operation=%s\n' "$2" "$1"
    [ -z "${3:-}" ] || printf 'rollback=%s\n' "$3"; } > "$HOST_HOME/state/parent-route/ios.control-relaunch"
}

assert_equals "unknown false" "$(host_disposition op1)" "an absent receipt was not unknown"
host_receipt op2 relaunch received
assert_equals "unknown false" "$(host_disposition op1)" "a foreign receipt answered for another operation"
assert_equals "prelaunch false" "$(host_disposition op2)" "an episode that never reached control was not a prelaunch refusal"
host_journal op2 failed:checkpoint instructions-restored
assert_equals "prelaunch false" "$(host_disposition op2)" "a refusal before the stop was not prelaunch"
host_journal op2 failed:exited prior-record-kept
printf 'exit_result=stopped\n' >> "$HOST_HOME/state/parent-route/ios.control-relaunch"
assert_equals "cancelled true" "$(host_disposition op2)" "a stopped predecessor with an unsubmitted candidate was not cancelled"
host_journal op2 failed:stopping
assert_equals "unknown false" "$(host_disposition op2)" "an interrupted stop was not left unknown"
host_receipt op3 launch existing
printf 'actual_generation=s-older\nroute_backend=herdr\nroute_target=fm-remote:w1:p1\nactual_model=pool-model-a\n' \
  >> "$HOST_HOME/state/parent-route/ios.seat-operation.op3"
assert_equals "existing false" "$(host_disposition op3)" "a reused live endpoint was not reported as existing"
# A busy episode may be running this very token: unknown, never a refusal.
bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh" && fm_supervisor_lifecycle_acquire "$2" ios 0 && : > "$3" && exec sleep 600' \
  _ "$ROOT" "$HOST_HOME/state/parent-route" "$TMP/host-episode" &
HOST_BLOCKER=$!
for _ in $(seq 1 50); do [ -e "$TMP/host-episode" ] && break; sleep 0.1; done
assert_equals "unknown false" "$(host_disposition op3)" "a busy host episode was reported as settled"
kill "$HOST_BLOCKER"
wait "$HOST_BLOCKER" 2>/dev/null
pass "the host answers each operation from its own receipt and journal, and uncertainty stays unknown"

# While this home has pools, an unaccounted supervisor relaunch refuses before
# touching anything; an operation-bound home refusal names its operation.
mkdir -p "$HOST_HOME/state/fleet-seats"
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$HOST_HOME/state/fleet-seats/policy.json"
OUT=$(host_control relaunch ios claude pool-model-a medium); RC=$?
[ "$RC" -ne 0 ] || fail "a pooled host relaunch without a parent operation succeeded"
assert_contains "$OUT" "relaunch_failure=prelaunch" "the unaccounted relaunch was not a prelaunch refusal"
assert_contains "$OUT" "parent's seat operation" "the refusal did not name the required path"
printf 'other\n' > "$HOST_HOME/.fm-secondmate-home"
OUT=$(host_control relaunch ios claude pool-model-a medium --operation op9 --previous op3); RC=$?
[ "$RC" -ne 0 ] || fail "a relaunch into a foreign home succeeded"
DISP=$(printf '%s\n' "$OUT" | sed -n 's/^seat_disposition=//p' | tail -1)
assert_equals "op9 prelaunch" "$(printf '%s\n' "$DISP" | jq -r '.operation + " " + .disposition')" \
  "a home validation refusal was not bound to its operation"
printf 'ios\n' > "$HOST_HOME/.fm-secondmate-home"
pass "a pooled host refuses unaccounted relaunches and binds its refusals to the operation"

# The parent wrapper joins the mate's one lifecycle episode: while a recovery
# episode holds it, a manual relaunch neither reserves nor reaches the host.
reset_meta
seed_pool
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-episode.meta"
bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh" && fm_supervisor_lifecycle_acquire "$2" ios 0 && : > "$3" && exec sleep 600' \
  _ "$ROOT" "$HOME_DIR/state" "$TMP/parent-episode" &
PARENT_BLOCKER=$!
for _ in $(seq 1 50); do [ -e "$TMP/parent-episode" ] && break; sleep 0.1; done
OUT=$(run_relaunch ios claude pool-model-a medium); RC=$?
kill "$PARENT_BLOCKER"
wait "$PARENT_BLOCKER" 2>/dev/null
[ "$RC" -ne 0 ] || fail "a manual relaunch ran inside another lifecycle episode"
assert_contains "$OUT" "another lifecycle episode" "the episode refusal was not named"
cmp -s "$TMP/ios-before-episode.meta" "$HOME_DIR/state/ios.meta" || fail "a refused relaunch touched the parent record"
[ -z "$(seats show ios)" ] || fail "a relaunch refused by the episode still reserved a seat"
pass "a manual remote relaunch waits out, then refuses, a running recovery episode"

for n in 1 2 3 4 5; do
  OUT=$(host_control relaunch ios notaharness pool-model-a medium --operation "history$n"); RC=$?
  [ "$RC" -ne 0 ] || fail "unverified harness operation succeeded"
done
assert_present "$HOST_HOME/state/parent-route/ios.seat-operation.history1" "successive operations deleted an older receipt"
OUT=$(host_control relaunch ios claude pool-model-a medium --operation history1); RC=$?
[ "$RC" -ne 0 ] || fail "an old refused token launched again"
DISP=$(printf '%s\n' "$OUT" | sed -n 's/^seat_disposition=//p' | tail -1)
assert_equals prelaunch "$(printf '%s\n' "$DISP" | jq -r .disposition)" "an old receipt did not preserve its refused outcome"
assert_contains "$OUT" "already handled" "a delayed token was treated as fresh"
host_receipt tombstone relaunch dead-after-start
assert_equals "dead-after-start false" "$(host_disposition tombstone)" "a terminal receipt did not replay its recorded outcome"
pass "host receipts survive successive operations and delayed retries never dispatch again"

reset_meta
seed_pool
FM_HOME="$HOME_DIR" SEATS="$ROOT/bin/fm-fleet-seats.sh" bash -c '
  for pair in "old:-" "new:old"; do
    gen=${pair%%:*} prev=${pair#*:}
    "$SEATS" reserve ios --generation "$gen" --previous-generation "$prev" --kind secondmate --harness pi --model pool-model-a --holder-pid "$$" >/dev/null || exit 1
    route="$FM_HOME/state/route-$gen"
    (umask 077 && printf "{\"placement\":\"remote\",\"backend\":\"herdr\",\"target\":null,\"home\":\"/srv/fm-home\",\"host\":\"remote-mac\",\"remote_root\":\"/srv/fm\",\"operation\":\"%s\"}\n" "$gen" > "$route")
    "$SEATS" dispatch ios --generation "$gen" --route-file "$route" >/dev/null || exit 1
  done
' || fail "could not submit the remote predecessor and candidate"
jq -n '{schema:"fm-remote-seat-operation.v2", task:"ios", operation:"new", requested_generation:"new", actual_generation:"new", previous_generation:"old", disposition:"started", startup_confirmed:true, old_stopped:true, old_destroyed:false, route:{placement:"remote",backend:"herdr",target:"fm-remote:w1:p1"},actual_model:"pool-model-a",complete:true}' > "$TMP/predecessor-response"
chmod 0600 "$TMP/predecessor-response"
OUT=$(seats reconcile-remote ios --generation new --response-file "$TMP/predecessor-response" 2>&1); RC=$?
expect_code 3 "$RC" "unconfirmed remote predecessor stop without destruction proof: $OUT"
assert_equals reserved "$(ios_lifecycle old)" "remote old_stopped freed an unconfirmed predecessor"
jq '.old_destroyed=true' "$TMP/predecessor-response" > "$TMP/proven-response"
chmod 0600 "$TMP/proven-response"
seats reconcile-remote ios --generation new --response-file "$TMP/proven-response" >/dev/null || fail "proven remote destruction was refused"
assert_equals released "$(ios_lifecycle old)" "proven remote destruction did not release its predecessor"
pass "remote predecessor release requires startup confirmation or endpoint destruction proof"

echo "ALL TESTS PASSED"
