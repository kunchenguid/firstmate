#!/usr/bin/env bash
# Strict fm-fleet-snapshot.v1 projection for provisional OMP task records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$ROOT/bin/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-cleanup-recovery-lib.sh
. "$ROOT/bin/fm-cleanup-recovery-lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-snapshot) \
  || fail "could not allocate OMP snapshot fixture root"
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
ID=omp-snapshot
GEN=generation-snapshot
mkdir -p "$STATE" "$DATA" "$HOME_DIR/config" "$HOME_DIR/projects/worktree"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
esac
exit 0
SH
fm_fake_exit0 "$FAKEBIN" no-mistakes
chmod +x "$FAKEBIN/herdr"

write_meta() {
  fm_write_meta "$STATE/$ID.meta" \
    'window=fmtest:w1:p2' "endpoint_task_id=$ID" \
    "worktree=$HOME_DIR/projects/worktree" 'project=project' 'harness=omp' \
    'profile=personal' 'kind=scout' 'mode=scout' 'tasktmp=' 'model=default' \
    'effort=default' "spawn_gen=$GEN" 'backend=herdr' 'herdr_session=fmtest' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2'
}

snapshot() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$SNAPSHOT" --json
}

test_profile_capabilities_and_recovery_projection() {
  local out
  write_meta
  out=$(snapshot) || fail "OMP snapshot without recovery failed: $out"
  printf '%s' "$out" | jq -e '
    .tasks == [(.tasks[0])]
      and .tasks[0].id == "omp-snapshot"
      and .tasks[0].harness == "omp"
      and .tasks[0].profile == "personal"
      and .tasks[0].capabilities == {
        interrupt_cancellation_ack:false,
        interrupt_cancellation_evidence:"unavailable"
      }
      and .tasks[0].recovery == null
  ' >/dev/null || fail "OMP snapshot profile/capability contract changed: $out"

  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" prompt-delivery unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 '' \
    || fail "snapshot recovery fixture could not be published"
  printf 'cleanup_recovery=omp-delivery\ndelivery_failure=readiness\ndelivery_cleanup=confirmed\n' \
    > "$STATE/$ID.status"
  out=$(snapshot) || fail "OMP recovery snapshot failed: $out"
  printf '%s' "$out" | jq -e '
    .tasks[0].recovery == {
      kind:"omp-delivery",
      failure:"prompt-delivery",
      cleanup:"unconfirmed"
    }
  ' >/dev/null || fail "snapshot trusted mutable status over the recovery sidecar: $out"
  pass "OMP snapshot: profile, capability, and authoritative recovery are strict"
}

test_mixed_omp_then_orca_recovery_does_not_leak_fields() {
  local orca_id=zz-orca-recovery out
  write_meta
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" prompt-delivery unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 '' \
    || fail "mixed snapshot OMP recovery fixture could not be published"
  fm_write_meta "$STATE/$orca_id.meta" \
    'window=fmtest:w1:p3' "endpoint_task_id=$orca_id" \
    "worktree=$HOME_DIR/projects/worktree" 'project=project' 'harness=claude' \
    'kind=ship' 'mode=no-mistakes' 'tasktmp=' 'model=default' 'effort=default' \
    'spawn_gen=generation-orca' 'backend=herdr' 'herdr_session=fmtest' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t3' 'herdr_pane_id=w1:p3' \
    'cleanup_recovery=orca'

  out=$(snapshot) || fail "mixed OMP/Orca snapshot failed: $out"
  printf '%s' "$out" | jq -e \
    --arg omp "$ID" --arg orca "$orca_id" '
      (.tasks | map(select(.id == $omp or .id == $orca)) | map({id,recovery})) == [
        {id:$omp,recovery:{kind:"omp-delivery",failure:"prompt-delivery",cleanup:"unconfirmed"}},
        {id:$orca,recovery:{kind:"orca",failure:null,cleanup:null}}
      ]
    ' >/dev/null || fail "Orca row inherited OMP recovery fields: $out"
  rm -f -- "$STATE/$orca_id.meta"
  pass "OMP snapshot: mixed OMP then Orca recovery rows do not share decoder state"
}

test_unsafe_task_record_is_refused_before_decoding() {
  local outside out rc=0
  rm -f "$STATE/$ID.cleanup-recovery" "$STATE/$ID.meta"
  outside="$TMP_ROOT/outside.meta"
  write_meta
  mv "$STATE/$ID.meta" "$outside"
  ln -s "$outside" "$STATE/$ID.meta"
  out=$(snapshot 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "snapshot accepted a symlink task record"
  assert_contains "$out" "unsafe task record" "snapshot refusal did not identify record validation"
  pass "OMP snapshot: unsafe metadata is refused before field decoding"
}

test_unsafe_state_directory_is_refused() {
  local unsafe real_state out rc=0
  rm -f "$STATE/$ID.meta"
  real_state="$TMP_ROOT/real-state"
  mv "$STATE" "$real_state"
  ln -s "$real_state" "$STATE"
  out=$(snapshot 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "snapshot accepted a symlink state directory"
  assert_contains "$out" "unsafe state directory" "snapshot refusal did not identify state validation"
  pass "OMP snapshot: unsafe state directories fail closed"
}

test_empty_home_projects_an_empty_task_array() {
  local empty_home out
  empty_home="$TMP_ROOT/empty-home"
  mkdir -p "$empty_home/data" "$empty_home/config"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$empty_home" "$SNAPSHOT" --json) \
    || fail "empty-home snapshot failed: $out"
  printf '%s' "$out" | jq -e '.tasks == []' >/dev/null \
    || fail "empty Firstmate state did not project tasks as []: $out"
  pass "OMP snapshot: an empty Firstmate state emits an empty task array"
}

test_profile_capabilities_and_recovery_projection
test_mixed_omp_then_orca_recovery_does_not_leak_fields
test_unsafe_task_record_is_refused_before_decoding
test_empty_home_projects_an_empty_task_array
test_unsafe_state_directory_is_refused
