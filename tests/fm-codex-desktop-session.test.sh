#!/usr/bin/env bash
# Behavior tests for a Codex Desktop primary session owning Firstmate through
# the app-provided thread identity and one live tracked lease process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-desktop-session)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
SYSTEM_PATH=$PATH
REAL_GIT=$(command -v git)
mkdir -p "$HOME_DIR/state"

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' bash ;;
  *"args="*) printf '%s\n' "${FM_TEST_PS_ARGS:-bash /fixture/bin/fm-session-start.sh /fixture/bin/fm-codex-app-task.sh}" ;;
  *"lstart="*) printf '%s\n' "${FM_TEST_PS_START:-Mon Aug 31 10:00:00 2026}" ;;
  *"ppid="*) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/ps"
export PATH="$FAKEBIN:$SYSTEM_PATH"

THREAD_A=019ff1ae-966b-7643-ba01-48811234656e
THREAD_B=019ff1ae-966b-7643-ba01-48811234656f

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

fm_session_lock_record_valid "codex-desktop:$THREAD_A:2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  || fail "canonical Desktop lock record was rejected"
! fm_session_lock_record_valid "codex-desktop:$THREAD_A:2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:" \
  || fail "Desktop lock record with trailing fields was accepted"
! fm_session_lock_record_valid "codex-desktop:$THREAD_A:02:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  || fail "Desktop lock record with a non-canonical pid was accepted"

sleep 300 &
LEASE_A=$!
LEASE_B=
TASK_LEASE=
trap 'kill "$LEASE_A" ${LEASE_B:+"$LEASE_B"} ${TASK_LEASE:+"$TASK_LEASE"} 2>/dev/null || true; wait "$LEASE_A" ${LEASE_B:+"$LEASE_B"} ${TASK_LEASE:+"$TASK_LEASE"} 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT

out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_CODEX_DESKTOP_LEASE_PID="$LEASE_A" \
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-lock.sh" 2>&1) \
  || fail "Codex Desktop primary could not acquire the Firstmate lock: $out"
assert_contains "$out" "lock acquired: Codex Desktop thread $THREAD_A" \
  "lock acquisition did not identify the owning Desktop thread"

record=$(cat "$HOME_DIR/state/.lock")
assert_contains "$record" "codex-desktop:$THREAD_A:" \
  "session lock did not persist the Desktop thread identity"
! FM_TEST_PS_START='Mon Aug 31 10:00:01 2026' \
  fm_session_lock_owner_alive "$record" \
  || fail "a reused Desktop lease pid with a different process identity remained live"
! FM_TEST_PS_ARGS='sleep 300' fm_session_lock_owner_alive "$record" \
  || fail "an unrelated process remained a valid Desktop lease owner"

CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1 \
  || fail "a later shell call from the same Desktop thread did not retain ownership"

status=0
out=$(CODEX_THREAD_ID="$THREAD_B" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_CODEX_DESKTOP_LEASE_PID="$$" \
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
expect_code 1 "$status" "a competing Desktop thread must not acquire a live session's home"
assert_contains "$out" "another live firstmate session holds the lock" \
  "competing Desktop thread refusal did not name the live-owner boundary"

kill "$LEASE_A" 2>/dev/null || true
wait "$LEASE_A" 2>/dev/null || true

sleep 300 &
LEASE_B=$!
out=$(CODEX_THREAD_ID="$THREAD_B" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_CODEX_DESKTOP_LEASE_PID="$LEASE_B" \
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-lock.sh" 2>&1) \
  || fail "a new Desktop thread could not reclaim a dead lease: $out"
assert_contains "$out" "lock acquired: Codex Desktop thread $THREAD_B" \
  "dead-lease recovery did not publish the new Desktop owner"

detected=$(CODEX_THREAD_ID="$THREAD_B" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  PATH="$FAKEBIN:$SYSTEM_PATH" "$ROOT/bin/fm-harness.sh")
[ "$detected" = codex ] \
  || fail "Codex Desktop environment marker resolved harness '$detected', expected codex"

pass "Codex Desktop primary owns one Firstmate home through a live thread-bound lease"

SESSION_HOME="$TMP_ROOT/session-home"
mkdir -p "$SESSION_HOME/data" "$SESSION_HOME/state" "$SESSION_HOME/config"
case "$(uname -s)" in
  Darwin)
    out=$({ sleep 3; printf 'stop\n'; } | script -q /dev/null \
      env CODEX_THREAD_ID="$THREAD_A" \
        CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
        FM_HOME="$SESSION_HOME" FM_ROOT_OVERRIDE="$ROOT" \
        FM_SESSION_START_TIMEOUT=2 \
        "$ROOT/bin/fm-session-start.sh" 2>&1)
    ;;
  *)
    command="env CODEX_THREAD_ID=$THREAD_A CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' FM_HOME='$SESSION_HOME' FM_ROOT_OVERRIDE='$ROOT' FM_SESSION_START_TIMEOUT=2 '$ROOT/bin/fm-session-start.sh'"
    out=$({ sleep 3; printf 'stop\n'; } | script -q -c "$command" /dev/null 2>&1)
    ;;
esac
assert_contains "$out" "lock acquired: Codex Desktop thread $THREAD_A" \
  "session start did not establish its own Desktop lease in a tracked PTY"
assert_contains "$out" "DESKTOP SESSION LEASE" \
  "session start did not keep the Desktop lease active after printing the digest"
if printf '%s\n' "$out" | grep -Fq 'STARTUP TRUNCATED'; then
  TRUNCATED_LINE=$(printf '%s\n' "$out" | sed -n '/STARTUP TRUNCATED/=' | head -1)
  DESKTOP_LEASE_LINE=$(printf '%s\n' "$out" | sed -n '/DESKTOP SESSION LEASE/=' | head -1)
  [ "$DESKTOP_LEASE_LINE" -gt "$TRUNCATED_LINE" ] \
    || fail "the Desktop lease ran inside the bounded digest child"
fi

pass "Codex Desktop session start holds the thread-bound lease in its tracked PTY"

FIRSTMATE_TOP=$(git -C "$ROOT" rev-parse --show-toplevel) \
  || fail "could not resolve the active Firstmate worktree"
ENTRY_OUT=$(cd "$TMP_ROOT" && "$ROOT/bin/fm-desktop-entry.sh" --cwd "$ROOT") \
  || fail "Desktop entry did not resolve from its active tracked code root"
assert_contains "$ENTRY_OUT" 'mode=direct' \
  "Desktop entry did not recognize its active tracked worktree"
assert_contains "$ENTRY_OUT" "firstmate_code=$FIRSTMATE_TOP" \
  "Desktop entry did not report its portable active code root"

pass "Codex Desktop entry resolves the active tracked Firstmate root"

TASK_HOME="$TMP_ROOT/task-home"
TASK_PROJECT="$TMP_ROOT/task-project"
TASK_WORKTREE="$TMP_ROOT/task-worktree"
TASK_ID=desktop-scout
HOST_ID=local-host-123
ROUTE_RECORD="$TASK_HOME/data/$TASK_ID/model-routing.tsv"
mkdir -p "$TASK_HOME/state" "$(dirname "$ROUTE_RECORD")" "$TASK_PROJECT"
git -C "$TASK_PROJECT" init -q -b main
git -C "$TASK_PROJECT" config user.name 'FirstMate Test'
git -C "$TASK_PROJECT" config user.email 'firstmate-test@example.invalid'
printf '%s\n' 'initial' > "$TASK_PROJECT/initial.txt"
git -C "$TASK_PROJECT" add initial.txt
git -C "$TASK_PROJECT" commit -q -m initial
git -C "$TASK_PROJECT" worktree add -q -b desktop-scout-worktree "$TASK_WORKTREE"
FM_HOME="$TASK_HOME" "$ROOT/bin/fm-task-model-route.sh" "$TASK_ID" \
  --ambiguity 0 --ambiguity-evidence explicit \
  --boundary-clarity 0 --boundary-clarity-evidence isolated \
  --risk 0 --risk-evidence low \
  --diagnosis 0 --diagnosis-evidence none \
  --verification 0 --verification-evidence focused \
  --quota-candidate sol-primary gpt-5.6-sol high eligible none 'primary Sol profile has available quota' \
  --resolved-profile sol-primary \
  --resolved-model gpt-5.6-sol --resolved-effort high >/dev/null \
  || fail "could not create the Desktop task model route"
ROUTE_REAL=$(realpath "$ROUTE_RECORD")
ROUTE_HASH=$(shasum -a 256 "$ROUTE_RECORD" | awk '{print $1}')
TASK_GIT_COMMON=$(realpath "$TASK_PROJECT/.git")
sleep 300 &
TASK_LEASE=$!
TASK_LOCK=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_CODEX_DESKTOP_LEASE_PID="$TASK_LEASE" PATH="$FAKEBIN:$SYSTEM_PATH" \
  fm_codex_desktop_new_lock_record) || fail "could not create the Desktop task lease record"
printf '%s\n' "$TASK_LOCK" > "$TASK_HOME/state/.lock"

out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" register "$TASK_ID" \
    --thread "$THREAD_B" \
    --host "$HOST_ID" \
    --project "$TASK_PROJECT" \
    --worktree "$TASK_WORKTREE" \
    --kind scout \
    --model gpt-5.6-sol \
    --effort high \
    --route-record "$ROUTE_RECORD" \
    --session-envelope research \
    --mode direct-PR --yolo off 2>&1) \
  || fail "Codex Desktop task registration failed: $out"
assert_contains "$out" "registered: $TASK_ID -> Codex Desktop task $THREAD_B" \
  "task registration did not report the durable task binding"

META="$TASK_HOME/state/$TASK_ID.meta"
CURRENT="$TASK_HOME/state/$TASK_ID.codex-app-current"
[ -f "$META" ] || fail "Codex Desktop task registration did not create metadata"
[ -f "$TASK_HOME/state/$TASK_ID.status" ] \
  || fail "Codex Desktop task registration did not create the worker return channel"
[ -f "$CURRENT" ] \
  || fail "Codex Desktop task registration did not create the current-state record"
assert_grep "backend=codex-app-host" "$META" \
  "metadata did not identify the host-tool Desktop backend"
assert_grep "window=$THREAD_B" "$META" \
  "metadata did not bind the Desktop task id as its endpoint"
assert_grep "codex_app_thread_id=$THREAD_B" "$META" \
  "metadata did not persist the exact Desktop thread id"
assert_grep "codex_app_host_id=$HOST_ID" "$META" \
  "metadata did not persist the exact Desktop host id"
assert_grep "model_route_record=$ROUTE_REAL" "$META" \
  "metadata did not persist the inspected model route"
assert_grep "model_route_sha256=$ROUTE_HASH" "$META" \
  "metadata did not digest-bind the inspected model route"
assert_grep $'model\tgpt-5.6-luna' "$ROUTE_RECORD" \
  "quota-aware registration lost the deterministic five-factor result"
assert_grep $'resolved_model\tgpt-5.6-sol' "$ROUTE_RECORD" \
  "quota-aware registration did not retain the resolved Desktop model"
assert_grep $'resolved_profile\tsol-primary' "$ROUTE_RECORD" \
  "quota-aware registration did not retain the selected Desktop profile"
assert_grep "session_envelope=research" "$META" \
  "metadata did not persist the selected session envelope"
assert_grep 'observation_epoch=1' "$META" \
  "metadata did not establish the initial observation epoch"
assert_grep 'mode=direct-PR' "$META" \
  "metadata did not persist bounded direct-PR delivery"
assert_grep 'yolo=off' "$META" \
  "metadata did not persist the actual project yolo posture"
assert_grep "git_common_dir=$TASK_GIT_COMMON" "$META" \
  "metadata did not bind the Desktop worktree to the saved checkout identity"
assert_grep "session_cost_telemetry=unsupported" "$META" \
  "metadata fabricated exact Codex Desktop cost telemetry"
assert_grep "session_context_telemetry=unsupported" "$META" \
  "metadata fabricated exact Codex Desktop context telemetry"
assert_grep "session_compaction_telemetry=unsupported" "$META" \
  "metadata fabricated exact Codex Desktop compaction telemetry"
assert_grep "session_output_telemetry=unsupported" "$META" \
  "metadata fabricated exact Codex Desktop output telemetry"
assert_grep "state=working" "$CURRENT" \
  "newly registered Desktop task did not start in working state"

# shellcheck source=bin/fm-wake-lib.sh
export FM_HOME=$TASK_HOME
export STATE=$TASK_HOME/state
. "$ROOT/bin/fm-wake-lib.sh"
SHARED_META_LOCK=$(fm_meta_lock_path "$META") \
  || fail "could not resolve the shared task metadata lock"
fm_lock_acquire_wait "$SHARED_META_LOCK" \
  || fail "could not hold the shared task metadata lock"
CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$TASK_ID" \
    --thread "$THREAD_B" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state working --detail 'published after shared metadata lock' \
    > "$TMP_ROOT/shared-meta-reconcile.out" 2>&1 &
META_RECONCILE_PID=$!
index=0
while [ "$index" -lt 50 ] && [ ! -e "$TASK_HOME/state/.$TASK_ID.codex-app-mutation-lock" ]; do
  sleep 0.02
  index=$((index + 1))
done
META_LOCKED_DETAIL=$(grep '^detail=' "$CURRENT")
fm_lock_release "$SHARED_META_LOCK"
[ "$META_LOCKED_DETAIL" = 'detail=registered by the Codex Desktop host' ] \
  || fail "Desktop reconciliation crossed a live shared metadata writer lock"
wait "$META_RECONCILE_PID" \
  || fail "Desktop reconciliation did not continue after the shared metadata lock was released"
assert_grep 'detail=published after shared metadata lock' "$CURRENT" \
  "Desktop reconciliation did not publish through the shared metadata boundary"

MUTATION_LOCK="$TASK_HOME/state/.$TASK_ID.codex-app-mutation-lock"
STALE_MUTATION_IDENTITY=$(FM_TEST_PS_START='Mon Aug 31 09:59:59 2026' \
  fm_process_command_identity "$TASK_LEASE" fm-codex-app-task.sh) \
  || fail "could not create a stale task mutation identity"
mkdir "$MUTATION_LOCK"
printf 'codex-app-mutation:%s:%s\n' "$TASK_LEASE" "$STALE_MUTATION_IDENTITY" \
  > "$MUTATION_LOCK/owner"
CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$TASK_ID" \
    --thread "$THREAD_B" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state working --detail 'recovered stale mutation owner' >/dev/null \
  || fail "a reused task mutation pid was treated as the live owner"
[ ! -e "$MUTATION_LOCK" ] \
  || fail "stale task mutation ownership was not retired"

MUTATION_RECOVERY_LOCK="$TASK_HOME/state/.$TASK_ID.codex-app-mutation-recovery.lock"
fm_lock_acquire_wait "$MUTATION_RECOVERY_LOCK" \
  || fail "could not hold task mutation initialization ownership"
mkdir "$MUTATION_LOCK"
CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$TASK_ID" \
    --thread "$THREAD_B" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state working --detail 'recovered serialized lock initialization' \
    > "$TMP_ROOT/mutation-initialization.out" 2>&1 &
MUTATION_RECONCILE_PID=$!
sleep 5.2
kill -0 "$MUTATION_RECONCILE_PID" 2>/dev/null \
  || fail "a competing mutation reclaimed a live ownerless initialization"
[ -d "$MUTATION_LOCK" ] \
  || fail "a competing mutation removed a live ownerless initialization"
fm_lock_release "$MUTATION_RECOVERY_LOCK"
wait "$MUTATION_RECONCILE_PID" \
  || fail "serialized mutation did not continue after initialization ownership was released"
[ ! -e "$MUTATION_LOCK" ] \
  || fail "serialized ownerless mutation lock was not retired"
assert_grep 'detail=recovered serialized lock initialization' "$CURRENT" \
  "serialized mutation did not publish after initialization ownership was released"

state=$(FM_HOME="$TASK_HOME" "$ROOT/bin/fm-crew-state.sh" "$TASK_ID")
assert_contains "$state" "state: working · source: codex-app-host" \
  "crew-state did not read the Desktop host's authoritative current-state record"

cp "$CURRENT" "$CURRENT.epoch-matched"
sed 's/^observation_epoch=.*/observation_epoch=2/' "$CURRENT" > "$CURRENT.epoch-mismatch"
mv "$CURRENT.epoch-mismatch" "$CURRENT"
state=$(FM_HOME="$TASK_HOME" "$ROOT/bin/fm-crew-state.sh" "$TASK_ID")
assert_contains "$state" "state: unknown · source: none · Codex Desktop current state does not match endpoint metadata" \
  "crew-state accepted current state from a superseded observation epoch"
mv "$CURRENT.epoch-matched" "$CURRENT"

sed 's/^updated_at=.*/updated_at=2000-01-01T00:00:00Z/' "$CURRENT" > "$CURRENT.stale"
mv "$CURRENT.stale" "$CURRENT"
state=$(FM_HOME="$TASK_HOME" FM_CODEX_APP_CURRENT_MAX_AGE=1 \
  "$ROOT/bin/fm-crew-state.sh" "$TASK_ID")
assert_contains "$state" "state: unknown · source: none · stale Codex Desktop working state" \
  "stale Desktop working evidence remained suppressive"

cp "$ROUTE_RECORD" "$ROUTE_RECORD.saved"
printf '%s\n' 'tampered' >> "$ROUTE_RECORD"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$TASK_ID" \
    --thread "$THREAD_B" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state blocked --detail 'must not publish' 2>&1) || status=$?
expect_code 1 "$status" "changed route evidence must invalidate the task binding"
assert_contains "$out" "immutable model route evidence" \
  "changed route evidence refusal did not name the durable binding"
mv "$ROUTE_RECORD.saved" "$ROUTE_RECORD"

CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$TASK_ID" \
    --thread "$THREAD_B" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state blocked --detail 'needs exact captain decision' \
    --event 'blocked: needs exact captain decision' >/dev/null \
  || fail "Codex Desktop task current-state reconciliation failed"
state=$(FM_HOME="$TASK_HOME" "$ROOT/bin/fm-crew-state.sh" "$TASK_ID")
assert_contains "$state" "state: blocked · source: codex-app-host · needs exact captain decision" \
  "crew-state inferred from an event log instead of the reconciled Desktop state"
assert_grep 'blocked: needs exact captain decision' "$TASK_HOME/state/$TASK_ID.status" \
  "verified Desktop host event did not reach the Firstmate return channel"

status=0
printf '%s\n' '# doomed in-worktree report' > "$TASK_WORKTREE/report.md"
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$TASK_ID" \
    --thread "$THREAD_B" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state invented 2>&1) || status=$?
expect_code 2 "$status" "Desktop state reconciliation must reject an unknown state"
assert_contains "$out" "invalid current state 'invented'" \
  "unknown Desktop state refusal did not identify the invalid value"

# Host ownership is metadata-only. It must never become selectable through
# FM_BACKEND/config/backend or fm-spawn's shell dispatcher.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
status=0
out=$(fm_backend_validate codex-app-host 2>&1) || status=$?
expect_code 1 "$status" "codex-app-host must not be a selectable runtime backend"
assert_contains "$out" "unknown backend 'codex-app-host'" \
  "runtime backend refusal did not keep host ownership metadata-only"

status=0
out=$(FM_HOME="$TASK_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-teardown.sh" "$TASK_ID" 2>&1) || status=$?
expect_code 1 "$status" "generic teardown must not destroy a Desktop-host-owned task"
assert_contains "$out" "owned by the Codex Desktop host" \
  "generic teardown refusal did not name the host ownership boundary"
[ -f "$META" ] \
  || fail "generic teardown removed Desktop task metadata before host archival"

pass "Codex Desktop tasks have durable endpoint identity and reconciled current state"

BAD_ID=desktop-invalid-route
BAD_WORKTREE="$TMP_ROOT/task-invalid-worktree"
BAD_ROUTE="$TASK_HOME/data/$BAD_ID/model-routing.tsv"
git -C "$TASK_PROJECT" worktree add -q -b desktop-invalid-worktree "$BAD_WORKTREE"
FM_HOME="$TASK_HOME" "$ROOT/bin/fm-task-model-route.sh" "$BAD_ID" \
  --ambiguity 0 --ambiguity-evidence explicit \
  --boundary-clarity 0 --boundary-clarity-evidence isolated \
  --risk 0 --risk-evidence low \
  --diagnosis 0 --diagnosis-evidence none \
  --verification 0 --verification-evidence focused >/dev/null \
  || fail "could not create the malformed-route fixture"
grep -v $'^verification_quality\t' "$BAD_ROUTE" > "$BAD_ROUTE.incomplete"
mv "$BAD_ROUTE.incomplete" "$BAD_ROUTE"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" register "$BAD_ID" \
    --thread 019ff1ae-966b-7643-ba01-488112346572 --host "$HOST_ID" \
    --project "$TASK_PROJECT" --worktree "$BAD_WORKTREE" --kind scout \
    --model gpt-5.6-luna --effort medium --route-record "$BAD_ROUTE" \
    --session-envelope small --mode local-only --yolo off 2>&1) || status=$?
expect_code 2 "$status" "Desktop registration must reject an incomplete route record"
assert_contains "$out" "complete routing contract" \
  "incomplete route refusal did not identify the shared routing contract"
[ ! -e "$TASK_HOME/state/$BAD_ID.meta" ] \
  || fail "incomplete route registration published durable task metadata"

pass "Codex Desktop registration validates the complete shared route record"

status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" register .hidden \
    --thread 019ff1ae-966b-7643-ba01-488112346573 --host "$HOST_ID" \
    --project "$TASK_PROJECT" --worktree "$TASK_WORKTREE" --kind scout \
    --model gpt-5.6-sol --effort high --route-record "$ROUTE_RECORD" \
    --session-envelope small --mode local-only --yolo off 2>&1) || status=$?
expect_code 2 "$status" "Desktop registration must reject a hidden task identity"
assert_contains "$out" "invalid task id '.hidden'" \
  "hidden Desktop task refusal did not use the canonical identity contract"
[ ! -e "$TASK_HOME/state/.hidden.meta" ] \
  || fail "hidden Desktop registration created undiscoverable metadata"

# Desktop archive removes the app-owned worktree. Firstmate must therefore
# expose a fail-closed preflight instead of treating terminal state alone as
# permission to destroy an uncommitted ship artifact.
SCOUT_REPORT="$TASK_HOME/data/$TASK_ID/report.md"
mkdir -p "$(dirname "$SCOUT_REPORT")"
printf '%s\n' '# retained scout report' > "$SCOUT_REPORT"
CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$TASK_ID" \
    --thread "$THREAD_B" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state 'done' --detail 'report retained outside Desktop worktree' >/dev/null \
  || fail "could not make the Desktop scout terminal for archive preflight"

UNRELATED_REPORT="$TMP_ROOT/unrelated-report.md"
printf '%s\n' '# unrelated report' > "$UNRELATED_REPORT"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" archive-preflight "$TASK_ID" \
    --report "$UNRELATED_REPORT" 2>&1) || status=$?
expect_code 1 "$status" "an unrelated external file must not authorize Desktop scout archival"
assert_contains "$out" 'retained scout report must be the canonical task report' \
  "unrelated report refusal did not name the task-bound report contract"

out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" archive-preflight "$TASK_ID" \
    --report "$SCOUT_REPORT" 2>&1) \
  || fail "terminal Desktop scout with a retained external report was not archive-safe: $out"
assert_contains "$out" "archive-safe: $TASK_ID scout report retained" \
  "scout archive preflight did not name the retained deliverable"

SHIP_ID=desktop-ship
SHIP_THREAD=019ff1ae-966b-7643-ba01-488112346570
SHIP_PROJECT="$TMP_ROOT/ship-project"
SHIP_WORKTREE="$TMP_ROOT/ship-worktree"
SHIP_ROUTE="$TASK_HOME/data/$SHIP_ID/model-routing.tsv"
mkdir -p "$SHIP_PROJECT" "$(dirname "$SHIP_ROUTE")"
git -C "$SHIP_PROJECT" init -q -b main
git -C "$SHIP_PROJECT" config user.name 'FirstMate Test'
git -C "$SHIP_PROJECT" config user.email 'firstmate-test@example.invalid'
printf '%s\n' 'initial' > "$SHIP_PROJECT/initial.txt"
git -C "$SHIP_PROJECT" add initial.txt
git -C "$SHIP_PROJECT" commit -q -m initial
git -C "$SHIP_PROJECT" worktree add -q -b desktop-ship-worktree "$SHIP_WORKTREE"
[ -f "$SHIP_WORKTREE/.git" ] \
  || fail "hard-stop fixture is not a standard linked Git worktree"
FM_HOME="$TASK_HOME" "$ROOT/bin/fm-task-model-route.sh" "$SHIP_ID" \
  --ambiguity 0 --ambiguity-evidence explicit \
  --boundary-clarity 0 --boundary-clarity-evidence isolated \
  --risk 0 --risk-evidence low \
  --diagnosis 0 --diagnosis-evidence none \
  --verification 0 --verification-evidence focused \
  --floor architecture >/dev/null \
  || fail "could not create the Desktop ship model route"
TRANSITION_FAILBIN="$TMP_ROOT/transition-failbin"
TRANSITION_FAIL_ONCE="$TMP_ROOT/transition-fail-once"
mkdir -p "$TRANSITION_FAILBIN"
cat > "$TRANSITION_FAILBIN/mv" <<'SH'
#!/usr/bin/env bash
destination=
for destination in "$@"; do :; done
if [ -f "$FM_TEST_FAIL_ONCE" ] && [ "$destination" = "$FM_TEST_FAIL_DEST" ]; then
  rm -f -- "$FM_TEST_FAIL_ONCE"
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$TRANSITION_FAILBIN/mv"
: > "$TRANSITION_FAIL_ONCE"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" FM_TEST_REAL_MV="$(command -v mv)" \
  FM_TEST_FAIL_ONCE="$TRANSITION_FAIL_ONCE" \
  FM_TEST_FAIL_DEST="$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  PATH="$TRANSITION_FAILBIN:$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-codex-app-task.sh" register "$SHIP_ID" \
    --thread "$SHIP_THREAD" --host "$HOST_ID" \
    --project "$SHIP_PROJECT" --worktree "$SHIP_WORKTREE" \
    --kind ship --model gpt-5.6-sol --effort high \
    --route-record "$SHIP_ROUTE" --session-envelope normal \
    --mode direct-PR --yolo on 2>&1) || status=$?
expect_code 1 "$status" "interrupted Desktop registration must remain retryable"
[ -f "$TASK_HOME/state/$SHIP_ID.codex-app-transition" ] \
  || fail "interrupted Desktop registration left no recovery journal"
[ -f "$TASK_HOME/state/$SHIP_ID.meta" ] \
  || fail "registration interruption fixture did not publish its first artifact"
[ ! -e "$TASK_HOME/state/$SHIP_ID.codex-app-current" ] \
  || fail "registration interruption fixture unexpectedly published current state"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$SHIP_ID" \
    --thread "$SHIP_THREAD" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state 'done' --detail 'must wait for registration recovery' 2>&1) || status=$?
expect_code 1 "$status" "a sibling mutation must not cross interrupted registration"
assert_contains "$out" 'interrupted register mutation' \
  "registration recovery refusal did not name its active mutation"
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" register "$SHIP_ID" \
    --thread "$SHIP_THREAD" --host "$HOST_ID" \
    --project "$SHIP_PROJECT" --worktree "$SHIP_WORKTREE" \
    --kind ship --model gpt-5.6-sol --effort high \
    --route-record "$SHIP_ROUTE" --session-envelope normal \
    --mode direct-PR --yolo on 2>&1) \
  || fail "could not recover Desktop ship registration: $out"
[ ! -e "$TASK_HOME/state/$SHIP_ID.codex-app-transition" ] \
  || fail "recovered Desktop registration retained its journal"
assert_grep 'yolo=on' "$TASK_HOME/state/$SHIP_ID.meta" \
  "Desktop ship metadata did not retain the enabled project yolo posture"

# A hard envelope boundary commits staged intended work only, writes a structured
# handoff outside the app-owned worktree, and pauses the old endpoint. A fresh
# Desktop task can resume only from that exact checkpoint and handoff.
printf '%s\n' 'checkpointed work' > "$SHIP_WORKTREE/checkpoint.txt"
git -C "$SHIP_WORKTREE" add checkpoint.txt
printf '%s\n' 'leave unstaged' > "$SHIP_WORKTREE/unstaged.txt"
SHIP_HANDOFF="$TASK_HOME/data/$SHIP_ID/session-handoff-1.md"
mkdir -p "$TMP_ROOT/fail-git"
cat > "$TMP_ROOT/fail-git/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" commit "*)
    "$FM_TEST_REAL_GIT" "$@" || exit $?
    exit 1
    ;;
esac
exec "$FM_TEST_REAL_GIT" "$@"
SH
chmod +x "$TMP_ROOT/fail-git/git"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" FM_TEST_REAL_GIT="$REAL_GIT" \
  PATH="$TMP_ROOT/fail-git:$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-codex-app-task.sh" hard-stop "$SHIP_ID" \
    --reason 'session envelope hard boundary' --handoff "$SHIP_HANDOFF" 2>&1) \
  || status=$?
expect_code 1 "$status" "an interrupted checkpoint publication must remain retryable"
[ -f "$TASK_HOME/state/$SHIP_ID.hard-stop-journal" ] \
  || fail "interrupted hard stop left no recovery journal"
[ ! -e "$SHIP_HANDOFF" ] \
  || fail "interrupted checkpoint fixture unexpectedly published the handoff"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$SHIP_ID" \
    --thread "$SHIP_THREAD" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state 'done' --detail 'must wait for hard-stop recovery' 2>&1) || status=$?
expect_code 1 "$status" "a sibling mutation must not cross interrupted hard stop"
assert_contains "$out" 'interrupted hard-stop mutation' \
  "hard-stop recovery refusal did not name its active mutation"
: > "$TRANSITION_FAIL_ONCE"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" FM_TEST_REAL_MV="$(command -v mv)" \
  FM_TEST_FAIL_ONCE="$TRANSITION_FAIL_ONCE" \
  FM_TEST_FAIL_DEST="$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  PATH="$TRANSITION_FAILBIN:$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-codex-app-task.sh" hard-stop "$SHIP_ID" \
    --reason 'session envelope hard boundary' --handoff "$SHIP_HANDOFF" 2>&1) \
  || status=$?
expect_code 1 "$status" "interrupted hard-stop publication must remain retryable"
[ -f "$TASK_HOME/state/$SHIP_ID.hard-stop-journal" ] \
  || fail "interrupted hard-stop state publication retired its recovery journal"
SHIP_HANDOFF_REAL=$(realpath "$SHIP_HANDOFF")
assert_grep "session_handoff=$SHIP_HANDOFF_REAL" "$TASK_HOME/state/$SHIP_ID.meta" \
  "hard-stop interruption fixture did not publish its first task record: $out"
assert_grep 'state=working' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "hard-stop interruption fixture unexpectedly published paused state"
cp "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "$TASK_HOME/state/$SHIP_ID.codex-app-current.preimage"
sed 's/^state=.*/state=done/' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  > "$TASK_HOME/state/$SHIP_ID.codex-app-current.newer"
mv "$TASK_HOME/state/$SHIP_ID.codex-app-current.newer" \
  "$TASK_HOME/state/$SHIP_ID.codex-app-current"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" hard-stop "$SHIP_ID" \
    --reason 'session envelope hard boundary' --handoff "$SHIP_HANDOFF" 2>&1) \
  || status=$?
expect_code 1 "$status" "hard-stop retry must preserve a newer current state"
assert_grep 'state=done' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "hard-stop retry overwrote a newer current state"
mv "$TASK_HOME/state/$SHIP_ID.codex-app-current.preimage" \
  "$TASK_HOME/state/$SHIP_ID.codex-app-current"
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" hard-stop "$SHIP_ID" \
    --reason 'session envelope hard boundary' --handoff "$SHIP_HANDOFF" 2>&1) \
  || fail "Desktop envelope hard stop failed: $out"
SHIP_CHECKPOINT=$(git -C "$SHIP_WORKTREE" rev-parse HEAD)
assert_contains "$out" "checkpoint=$SHIP_CHECKPOINT" \
  "hard stop did not report the exact checkpoint commit"
assert_grep "checkpoint_sha: $SHIP_CHECKPOINT" "$SHIP_HANDOFF" \
  "structured handoff did not bind the exact checkpoint"
assert_grep 'reason: session envelope hard boundary' "$SHIP_HANDOFF" \
  "structured handoff did not record the hard-stop reason"
assert_grep 'session_cost_telemetry: unsupported' "$SHIP_HANDOFF" \
  "structured handoff fabricated exact cost telemetry"
[ -f "$SHIP_WORKTREE/unstaged.txt" ] \
  || fail "hard stop discarded an unstaged task artifact"
git -C "$SHIP_WORKTREE" ls-files --error-unmatch checkpoint.txt >/dev/null 2>&1 \
  || fail "hard stop did not commit staged intended work"
if git -C "$SHIP_WORKTREE" ls-files --error-unmatch unstaged.txt >/dev/null 2>&1; then
  fail "hard stop committed an unstaged artifact"
fi
assert_grep 'state=paused' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "hard stop did not pause the old Desktop endpoint"
assert_grep 'observation_epoch=2' "$TASK_HOME/state/$SHIP_ID.meta" \
  "hard stop did not advance the durable observation epoch"
assert_grep 'observation_epoch=2' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "hard stop current state did not bind the advanced observation epoch"
HARD_STOP_RECEIPT="$TASK_HOME/state/$SHIP_ID.codex-app-hard-stop-receipt"
assert_grep "request_sha256=" "$HARD_STOP_RECEIPT" \
  "hard stop did not retain a request-bound completion receipt"
assert_grep "checkpoint=$SHIP_CHECKPOINT" "$HARD_STOP_RECEIPT" \
  "hard-stop completion receipt omitted the exact checkpoint"
assert_grep 'observation_epoch=2' "$HARD_STOP_RECEIPT" \
  "hard-stop completion receipt omitted the advanced observation epoch"
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" hard-stop "$SHIP_ID" \
    --reason 'session envelope hard boundary' --handoff "$SHIP_HANDOFF" 2>&1) \
  || fail "completed hard-stop retry was not receipt-idempotent: $out"
assert_contains "$out" "checkpoint=$SHIP_CHECKPOINT" \
  "completed hard-stop retry did not recover its exact receipt"

status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$SHIP_ID" \
    --thread "$SHIP_THREAD" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state working --detail 'old endpoint reported working after hard stop' 2>&1) \
  || status=$?
expect_code 1 "$status" "a stopped endpoint observation must not cross hard stop"
assert_contains "$out" 'generation, and observation epoch binding' \
  "stopped endpoint refusal did not name the advanced observation epoch"
assert_grep 'state=paused' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "a stopped endpoint observation overwrote the hard-stop boundary"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" resume "$SHIP_ID" \
    --thread "$SHIP_THREAD" --host "$HOST_ID" \
    --checkpoint "$SHIP_CHECKPOINT" --handoff "$SHIP_HANDOFF" 2>&1) \
  || status=$?
expect_code 1 "$status" "old Desktop thread must never satisfy resume idempotence"
assert_grep 'session_generation=1' "$TASK_HOME/state/$SHIP_ID.meta" \
  "reused old Desktop thread advanced the session generation"

SHIP_THREAD_2=019ff1ae-966b-7643-ba01-488112346571
: > "$TRANSITION_FAIL_ONCE"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" FM_TEST_REAL_MV="$(command -v mv)" \
  FM_TEST_FAIL_ONCE="$TRANSITION_FAIL_ONCE" \
  FM_TEST_FAIL_DEST="$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  PATH="$TRANSITION_FAILBIN:$FAKEBIN:$SYSTEM_PATH" \
  "$ROOT/bin/fm-codex-app-task.sh" resume "$SHIP_ID" \
    --thread "$SHIP_THREAD_2" --host "$HOST_ID" \
    --checkpoint "$SHIP_CHECKPOINT" --handoff "$SHIP_HANDOFF" 2>&1) \
  || status=$?
expect_code 1 "$status" "interrupted Desktop resume must remain retryable"
[ -f "$TASK_HOME/state/$SHIP_ID.codex-app-transition" ] \
  || fail "interrupted Desktop resume left no recovery journal"
assert_grep "codex_app_thread_id=$SHIP_THREAD_2" "$TASK_HOME/state/$SHIP_ID.meta" \
  "resume interruption fixture did not publish its first artifact"
assert_grep 'state=paused' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "resume interruption fixture unexpectedly published current state"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$SHIP_ID" \
    --thread "$SHIP_THREAD_2" --host "$HOST_ID" --generation 2 --epoch 3 \
    --state 'done' --detail 'must wait for resume recovery' \
    --event 'done: must wait for resume recovery' 2>&1) || status=$?
expect_code 1 "$status" "a sibling mutation must not cross interrupted resume"
assert_contains "$out" 'interrupted resume mutation' \
  "resume recovery refusal did not name its active mutation"
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" resume "$SHIP_ID" \
    --thread "$SHIP_THREAD_2" --host "$HOST_ID" \
    --checkpoint "$SHIP_CHECKPOINT" --handoff "$SHIP_HANDOFF" 2>&1) \
  || fail "fresh Desktop session could not resume the checkpoint: $out"
[ ! -e "$TASK_HOME/state/$SHIP_ID.codex-app-transition" ] \
  || fail "recovered Desktop resume retained its journal"
assert_contains "$out" "generation=2" \
  "resume did not report the fresh session generation"
assert_grep "codex_app_thread_id=$SHIP_THREAD_2" "$TASK_HOME/state/$SHIP_ID.meta" \
  "resume did not bind the fresh Desktop task"
assert_grep 'session_generation=2' "$TASK_HOME/state/$SHIP_ID.meta" \
  "resume did not advance the session generation"
assert_grep 'observation_epoch=3' "$TASK_HOME/state/$SHIP_ID.meta" \
  "resume did not advance the observation epoch"
assert_grep 'state=working' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "resume retry did not complete its journaled current state"
status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$SHIP_ID" \
    --thread "$SHIP_THREAD" --host "$HOST_ID" --generation 1 --epoch 1 \
    --state 'done' --detail 'delayed old endpoint result' 2>&1) || status=$?
expect_code 1 "$status" "a delayed pre-resume endpoint result must be refused"
assert_contains "$out" 'does not match its current thread, host, generation, and observation epoch binding' \
  "delayed endpoint refusal did not name the exact current binding"
assert_grep 'state=working' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "delayed old endpoint result mutated the resumed task state"
CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$SHIP_ID" \
    --thread "$SHIP_THREAD_2" --host "$HOST_ID" --generation 2 --epoch 3 \
    --state 'done' --detail 'new endpoint completed after resume recovery' \
    --event 'done: new endpoint completed after resume recovery' >/dev/null \
  || fail "could not publish a newer reconciled state after resume recovery"
[ "$(grep -cFx 'done: new endpoint completed during resume recovery' \
  "$TASK_HOME/state/$SHIP_ID.status")" = 0 ] \
  || fail "a refused sibling mutation published a status event"
[ "$(grep -cFx 'done: new endpoint completed after resume recovery' \
  "$TASK_HOME/state/$SHIP_ID.status")" = 1 ] \
  || fail "post-recovery reconciliation lost or duplicated its status event"
RESUME_RECEIPT="$TASK_HOME/state/$SHIP_ID.codex-app-resume-receipt"
assert_grep "old_thread_id=$SHIP_THREAD" "$RESUME_RECEIPT" \
  "resume receipt omitted the previous Desktop thread"
assert_grep "new_thread_id=$SHIP_THREAD_2" "$RESUME_RECEIPT" \
  "resume receipt omitted the fresh Desktop thread"
assert_grep 'old_generation=1' "$RESUME_RECEIPT" \
  "resume receipt omitted the previous session generation"
assert_grep 'new_generation=2' "$RESUME_RECEIPT" \
  "resume receipt omitted the fresh session generation"
assert_grep 'old_observation_epoch=2' "$RESUME_RECEIPT" \
  "resume receipt omitted the stopped observation epoch"
assert_grep 'new_observation_epoch=3' "$RESUME_RECEIPT" \
  "resume receipt omitted the fresh observation epoch"
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" resume "$SHIP_ID" \
    --thread "$SHIP_THREAD_2" --host "$HOST_ID" \
    --checkpoint "$SHIP_CHECKPOINT" --handoff "$SHIP_HANDOFF" 2>&1) \
  || fail "receipt-bound Desktop resume retry was not idempotent: $out"
assert_contains "$out" 'generation=2' \
  "receipt-bound Desktop resume retry did not preserve its generation"
assert_grep 'state=done' "$TASK_HOME/state/$SHIP_ID.codex-app-current" \
  "idempotent Desktop resume retry changed newer reconciled state"

printf '%s\n' 'uncommitted ship artifact' > "$SHIP_WORKTREE/result.txt"
CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" reconcile "$SHIP_ID" \
    --thread "$SHIP_THREAD_2" --host "$HOST_ID" --generation 2 --epoch 3 \
    --state 'done' --detail 'uncommitted artifact retained' >/dev/null \
  || fail "could not make the Desktop ship terminal for archive preflight"

status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" archive-preflight "$SHIP_ID" 2>&1) \
  || status=$?
expect_code 1 "$status" \
  "terminal state alone must not make a Desktop ship worktree archive-safe"
assert_contains "$out" "archive would delete the retained ship worktree" \
  "ship archive refusal did not name the destructive Desktop boundary"
[ -f "$SHIP_WORKTREE/result.txt" ] \
  || fail "archive preflight itself removed the ship artifact"

status=0
out=$(CODEX_THREAD_ID="$THREAD_A" \
  CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' \
  FM_HOME="$TASK_HOME" \
  "$ROOT/bin/fm-codex-app-task.sh" archive-preflight "$TASK_ID" \
    --report "$TASK_WORKTREE/report.md" 2>&1) || status=$?
expect_code 1 "$status" \
  "a scout report inside the Desktop worktree must not authorize archival"
assert_contains "$out" "report is inside the Desktop worktree" \
  "scout archive refusal did not identify the report-loss risk"

pass "Codex Desktop archive preflight preserves ship artifacts and requires external scout reports"
