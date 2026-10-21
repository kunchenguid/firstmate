#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-remote-seat-adoption)
FAKEBIN=$(fm_fakebin "$TMP")
REAL_MV=$(command -v mv)
HOST="$TMP/host"
PARENT="$TMP/parent"
HOST_ROOT="$TMP/host-root"
mkdir -p "$HOST_ROOT/state"
mkdir -p "$HOST/state/parent-route" "$HOST/data" "$HOST/config" "$HOST/bin" \
  "$PARENT/state" "$PARENT/data" "$PARENT/config"
printf 'ios\n' > "$HOST/.fm-secondmate-home"
: > "$HOST/AGENTS.md"
printf 'alive\n' > "$TMP/endpoint-state"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_ENDPOINT_LOG"
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n' ;;
  'pane get')
    if [ "$(cat "$FM_TEST_ENDPOINT_STATE")" = absent ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    else
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "$3" "$FM_HOME"
    fi ;;
  'agent get')
    case "$(cat "$FM_TEST_ENDPOINT_STATE")" in
      alive) printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
      absent) printf '{"error":{"code":"pane_not_found"}}\n' ;;
      *) printf '{"error":{"code":"transport_unavailable"}}\n' ;;
    esac ;;
  'pane process-info') printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' "$4" ;;
  *) printf 'unexpected-effect\n' >> "$FM_TEST_EFFECT_LOG"; exit 1 ;;
esac
SH
cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_BINDING_FAIL:-0}" = 1 ] || [ "${FM_TEST_BINDING_CRASH:-0}" = 1 ]; then
  for path in "$@"; do
    case "$path" in
      *.seat-operation.*.tmp.*)
        if [ -f "$path" ] && [ "$(sed -n 's/^phase=//p' "$path")" = existing ]; then
          [ "${FM_TEST_BINDING_CRASH:-0}" != 1 ] || kill -KILL "$PPID"
          exit 1
        fi ;;
    esac
  done
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/mv"
fm_write_meta "$HOST/state/parent-route/ios.meta" \
  kind=secondmate harness=claude backend=herdr window=fm-remote:w1:p1 endpoint_task_id=ios \
  herdr_session=fm-remote herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=w1:p1 \
  "worktree=$HOST" "project=$ROOT" "home=$HOST" spawn_gen=legacy model=pool-model-a

host() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$HOST" FM_ROOT_OVERRIDE="$HOST_ROOT" PATH="$FAKEBIN:$PATH" FM_TEST_REAL_MV="$REAL_MV" \
    FM_TEST_BINDING_FAIL="${FM_TEST_BINDING_FAIL:-0}" FM_TEST_BINDING_CRASH="${FM_TEST_BINDING_CRASH:-0}" \
    FM_TEST_ENDPOINT_STATE="$TMP/endpoint-state" \
    FM_TEST_ENDPOINT_LOG="$TMP/endpoint-log" FM_TEST_EFFECT_LOG="$TMP/effect-log" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@" 2>&1
}

seats() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$PARENT" "$ROOT/bin/fm-fleet-seats.sh" "$@"
}

parent_dispatch() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$PARENT" bash -s -- "$ROOT/bin/fm-fleet-seats.sh" "$1" "$2" <<'SH'
"$1" reserve ios --generation "$2" --kind secondmate --harness claude --model pool-model-a --holder-pid "$$" >/dev/null &&
"$1" dispatch ios --generation "$2" --route-file "$3" >/dev/null
SH
}

payload() {
  jq -cn --arg g "$1" --arg h "$HOST" \
    '{schema:"fm-fleet-seat-holder.v2",task:"ios",incarnations:[{generation:$g,previous_generation:null,
      kind:"secondmate",model:"pool-model-a",lifecycle:"reserved",launch_phase:"dispatching",
      route:{placement:"remote",operation:$g,home:$h}}]}'
}

disposition() { sed -n 's/^seat_disposition=//p' | tail -1; }

OUT=$(FM_TEST_BINDING_FAIL=1 host launch ios claude pool-model-a medium herdr --operation adoption.failed \
  <<< "$(payload adoption.failed)"); RC=$?
DISP=$(printf '%s\n' "$OUT" | disposition)
assert_equals unknown "$(printf '%s\n' "$DISP" | jq -r .disposition)" "failed binding freed an unaccounted live legacy generation"
[ "$RC" -ne 0 ] || fail "failed adoption returned success"
assert_grep 'phase=received' "$HOST/state/parent-route/ios.seat-operation.adoption.failed" "failed binding lost its unresolved receipt: $OUT"
pass "failed existing-generation persistence is unknown and retains its receipt"

OUT=$(FM_TEST_BINDING_CRASH=1 host launch ios claude pool-model-a medium herdr --operation adoption.crashed \
  <<< "$(payload adoption.crashed)"); RC=$?
expect_code 137 "$RC" "crash injection did not kill the owned adoption process: $OUT"
assert_grep 'phase=received' "$HOST/state/parent-route/ios.seat-operation.adoption.crashed" "a crash lost the received receipt"
OUT=$(host launch ios claude pool-model-a medium herdr --operation adoption.crashed \
  <<< "$(payload adoption.crashed)"); RC=$?
[ "$RC" -ne 0 ] || fail "a crashed adoption repeated launch"
assert_equals unknown "$(printf '%s\n' "$OUT" | disposition | jq -r .disposition)" "a crash leaving received became prelaunch"
assert_absent "$TMP/effect-log" "a crash retry changed an endpoint"
pass "an owned-process crash before binding leaves received retries unknown"

mkdir -p "$PARENT/state/fleet-seats"
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$PARENT/config/fleet-seats"
printf -- '- ios - Remote fixture. (host: fixture-host; root: %s; home: %s; scope: test; projects: ; added 2026-10-13)\n' \
  "$ROOT" "$HOST" > "$PARENT/data/secondmates.md"
DIGEST=$(jq -cS . "$PARENT/config/fleet-seats" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
printf '{"schema":"fm-fleet-seats-serve.v2","policy_digest":"%s","epoch":"fixture.1","complete":true,"holders":[]}\n' \
  "$DIGEST" > "$PARENT/state/fleet-seats/remote-ios.cert"
jq -cn --arg h "$HOST" --arg r "$ROOT" \
  '{placement:"remote",backend:"herdr",target:null,home:$h,host:"fixture-host",remote_root:$r,
    spawn_gen:null,operation:"adoption.failed"}' > "$TMP/route"
chmod 0600 "$TMP/route"
parent_dispatch adoption.failed "$TMP/route" || fail "dispatching the parent candidate"
assert_absent "$PARENT/state/ios.meta" "fixture already accounted for the legacy supervisor in metadata"
printf '%s\n' "$DISP" > "$TMP/response"
chmod 0600 "$TMP/response"
OUT=$(seats reconcile-remote ios --generation adoption.failed --response-file "$TMP/response" 2>&1); RC=$?
expect_code 3 "$RC" "parent must retain unresolved adoption: $OUT"
assert_equals reserved "$(seats show ios | jq -r '.incarnations[0].lifecycle')" "parent freed the live legacy supervisor's only candidate"
OUT=$(seats reserve contender --generation contender --harness claude --model pool-model-a --holder-pid "$$" 2>&1); RC=$?
expect_code 4 "$RC" "unresolved adoption allowed another pooled launch: $OUT"
for VERB in launch relaunch; do
  ARGS=("$VERB" ios claude pool-model-a medium)
  [ "$VERB" != launch ] || ARGS+=(herdr)
  OUT=$(host "${ARGS[@]}" --operation adoption.failed <<< "$(payload adoption.failed)"); RC=$?
  [ "$RC" -ne 0 ] || fail "received retry repeated $VERB"
  assert_equals unknown "$(printf '%s\n' "$OUT" | disposition | jq -r .disposition)" "received retry released the candidate"
done
assert_absent "$TMP/effect-log" "received retry changed an endpoint"
pass "received crash and retries retain parent capacity without repeating lifecycle effects"

OLD_PARENT=$PARENT
PARENT="$TMP/parent-success"
mkdir -p "$PARENT/state/fleet-seats" "$PARENT/config" "$PARENT/data"
cp "$OLD_PARENT/config/fleet-seats" "$PARENT/config/fleet-seats"
cp "$OLD_PARENT/data/secondmates.md" "$PARENT/data/secondmates.md"
cp "$OLD_PARENT/state/fleet-seats/remote-ios.cert" "$PARENT/state/fleet-seats/remote-ios.cert"
jq '.operation = "adoption.success"' "$TMP/route" > "$TMP/success-route"
chmod 0600 "$TMP/success-route"
parent_dispatch adoption.success "$TMP/success-route" || fail "dispatching a successful adoption candidate"
OUT=$(host launch ios claude pool-model-a medium herdr --operation adoption.success \
  <<< "$(payload adoption.success)"); RC=$?
expect_code 0 "$RC" "successful legacy adoption: $OUT"
DISP=$(printf '%s\n' "$OUT" | disposition)
assert_equals 'existing legacy' "$(printf '%s\n' "$DISP" | jq -r '.disposition + " " + .actual_generation')" "successful adoption lost its actual generation"
printf '%s\n' "$DISP" > "$TMP/response"
OUT=$(seats reconcile-remote ios --generation adoption.success --response-file "$TMP/response" 2>&1); RC=$?
expect_code 0 "$RC" "importing a successfully bound legacy supervisor: $OUT"
assert_equals "fixture-host $ROOT" "$(seats show ios | jq -r '.incarnations[] | select(.generation == "legacy") | .route.host + " " + .route.remote_root')" "host confirmation erased the parent route identity"
assert_equals 'confirmed released' "$(seats show ios | jq -r '(.incarnations[] | select(.generation == "legacy") | .lifecycle) + " " + (.incarnations[] | select(.generation == "adoption.success") | .lifecycle)')" "existing-generation import freed all capacity"
OUT=$(seats reserve contender --generation contender --harness claude --model pool-model-a --holder-pid "$$" 2>&1); RC=$?
expect_code 4 "$RC" "successful adoption failed to count its existing supervisor: $OUT"
pass "successful existing-generation import keeps the legacy supervisor counted"

cp "$HOST/state/parent-route/ios.meta" "$TMP/original-meta"
perl -pi -e 's/^spawn_gen=.*/spawn_gen=newer/' "$HOST/state/parent-route/ios.meta"
assert_equals unknown "$(host disposition ios --operation adoption.success | disposition | jq -r .disposition)" "a stale receipt claimed a newer live generation"
cp "$TMP/original-meta" "$HOST/state/parent-route/ios.meta"
cp "$HOST/state/parent-route/ios.seat-operation.adoption.success" "$TMP/original-receipt"
perl -pi -e 's/^operation=.*/operation=foreign/' "$HOST/state/parent-route/ios.seat-operation.adoption.success"
assert_equals unknown "$(host disposition ios --operation adoption.success | disposition | jq -r .disposition)" "a foreign receipt settled the candidate"
cp "$TMP/original-receipt" "$HOST/state/parent-route/ios.seat-operation.adoption.success"
pass "foreign operations and stale generation evidence stay unknown"

# A captured dispatched request still names the predecessor after its home is
# reused. Both host lifecycle entrypoints must reject it before endpoint effects.
for VERB in launch relaunch; do
  OP="stale.$VERB"
  ARGS=("$VERB" ios claude pool-model-a medium)
  [ "$VERB" != launch ] || ARGS+=(herdr)
  RECORD=$(payload "$OP" | jq '.incarnations[0].previous_generation = "predecessor"')
  OUT=$(host "${ARGS[@]}" --operation "$OP" --previous predecessor <<< "$RECORD"); RC=$?
  expect_code 6 "$RC" "captured stale $VERB reached its successor: $OUT"
  assert_equals unknown "$(printf '%s\n' "$OUT" | disposition | jq -r .disposition)" "a stale predecessor freed its candidate"
  assert_grep 'spawn_gen=legacy' "$HOST/state/parent-route/ios.meta" "a stale predecessor changed the successor"
done
assert_absent "$TMP/effect-log" "a stale predecessor changed an endpoint"
pass "captured stale launch and relaunch operations cannot control a successor"

# Erasing a removable home's receipt cannot erase the host's consumed token.
rm -f "$HOST/state/parent-route/ios.seat-operation.stale.relaunch" \
  "$HOST/state/parent-route/ios.seat-reservation.stale.relaunch"
OUT=$(host relaunch ios claude pool-model-a medium --operation stale.relaunch --previous legacy \
  <<< "$(payload stale.relaunch | jq '.incarnations[0].previous_generation = "legacy"')"); RC=$?
[ "$RC" -ne 0 ] || fail "a consumed operation became fresh after home receipt removal"
assert_contains "$OUT" 'earlier host lifecycle' "lost home receipt did not consult durable history"
assert_absent "$HOST/state/parent-route/ios.seat-operation.stale.relaunch" "a consumed token opened another receipt"
assert_absent "$TMP/effect-log" "a consumed token changed an endpoint"
pass "host operation fences survive removal of home-local receipts"

perl -pi -e 's/^phase=.*/phase=started/' "$HOST/state/parent-route/ios.seat-operation.adoption.success"
cp "$HOST/state/parent-route/ios.seat-operation.adoption.success" "$TMP/started-receipt"
printf 'foreign\n' > "$HOST/.fm-secondmate-home"
for VERB in launch relaunch; do
  ARGS=("$VERB" ios claude pool-model-a medium)
  [ "$VERB" != launch ] || ARGS+=(herdr)
  OUT=$(host "${ARGS[@]}" --operation adoption.success); RC=$?
  [ "$RC" -ne 0 ] || fail "a damaged home accepted $VERB"
  assert_equals unknown "$(printf '%s\n' "$OUT" | disposition | jq -r .disposition)" "home validation demoted a started operation to prelaunch"
  cmp -s "$TMP/started-receipt" "$HOST/state/parent-route/ios.seat-operation.adoption.success" || fail "home validation rewrote the started receipt"
done
printf 'ios\n' > "$HOST/.fm-secondmate-home"
printf 'absent\n' > "$TMP/endpoint-state"
DISP=$(host disposition ios --operation adoption.success | disposition)
assert_equals dead-after-start "$(printf '%s\n' "$DISP" | jq -r .disposition)" "proven endpoint absence did not settle the started generation"
printf '%s\n' "$DISP" > "$TMP/response"
seats reconcile-remote ios --generation legacy --response-file "$TMP/response" >/dev/null || fail "parent did not reclaim the proven absent legacy generation"
assert_equals reclaimed "$(seats show ios | jq -r '.incarnations[] | select(.generation == "legacy") | .lifecycle')" "proven absence retained the legacy seat"
assert_absent "$TMP/effect-log" "adoption or disposition repeated lifecycle effects"
assert_absent "$HOST/state/parent-route/.secondmate-liveness-ios.lock" "host lifecycle ownership survived the command"
pass "damaged-home retries preserve started receipts and proven absence reclaims the exact generation"

HOST="$TMP/fresh-home"
mkdir -p "$HOST/state/parent-route" "$HOST/data" "$HOST/config" "$HOST/bin"
printf 'ios\n' > "$HOST/.fm-secondmate-home"
: > "$HOST/AGENTS.md"
printf 'foreign\n' > "$HOST/.fm-secondmate-home"
OUT=$(host launch ios claude pool-model-a medium herdr --operation fresh.refusal); RC=$?
[ "$RC" -ne 0 ] || fail "a fresh invalid launch succeeded"
assert_equals prelaunch "$(printf '%s\n' "$OUT" | disposition | jq -r .disposition)" "a verified fresh refusal was no longer prelaunch"
assert_absent "$HOST/state/parent-route/ios.seat-operation.fresh.refusal" "a fresh home refusal opened an operation"
pass "verified fresh refusals remain prelaunch before opening a receipt"

# The persisted host retirement record is a public retry contract: replay does
# not depend on the retired home, nor act on a successor now using that path.
for RETIRE_RC in 0 4; do
  RETIRE_GEN="retired.$RETIRE_RC"
  jq -cn --arg h "$HOST" --arg g "$RETIRE_GEN" --argjson rc "$RETIRE_RC" \
    '{task:"ios",generation:$g,home:$h,backend:"herdr",target:"fm-remote:w1:p1",destroyed:true,exit_code:$rc}' \
    > "$HOST_ROOT/state/remote-secondmate-history/ios.retirement.$RETIRE_GEN.json"
  [ "$RETIRE_RC" != 0 ] || mv "$HOST" "$TMP/retired-home"
  OUT=$(host retire ios --force --expect-generation "$RETIRE_GEN"); RC=$?
  expect_code "$RETIRE_RC" "$RC" "retirement retry lost its original exit: $OUT"
  assert_equals "$RETIRE_GEN" "$(printf '%s\n' "$OUT" | sed -n 's/^seat_retirement=//p' | jq -r .generation)" "retirement retry lost its generation"
  if [ "$RETIRE_RC" = 0 ]; then
    assert_absent "$HOST" "retirement replay recreated a deleted home"
    mv "$TMP/retired-home" "$HOST"
  fi
  assert_equals foreign "$(cat "$HOST/.fm-secondmate-home")" "retirement replay changed a reused home"
done
assert_absent "$TMP/effect-log" "retirement replay changed a live endpoint"
OUT=$(host retire ios --force --expect-generation unrelated); RC=$?
[ "$RC" -ne 0 ] || fail "retirement evidence replayed for an unrelated generation"
cp "$HOST_ROOT/state/remote-secondmate-history/ios.retirement.retired.0.json" "$TMP/retirement-proof"
for DAMAGE in '.home = "/unrelated"' '.target = "foreign:pane"' '.backend = "tmux"' '.destroyed = false'; do
  jq "$DAMAGE" "$TMP/retirement-proof" > "$HOST_ROOT/state/remote-secondmate-history/ios.retirement.retired.0.json"
  OUT=$(host retire ios --force --expect-generation retired.0); RC=$?
  [ "$RC" -ne 0 ] || fail "retirement replay accepted foreign destruction evidence ($DAMAGE)"
done
pass "retirement retries preserve exact generation and clean/residue exits without touching reused homes"
