#!/usr/bin/env bash
# Closed cleanup-recovery schema and durable close replay.
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

TMP_ROOT=$(fm_test_tmproot fm-cleanup-recovery) \
  || fail "could not allocate cleanup-recovery fixture root"

write_omp_meta() { # <path> <id> <generation> [annotated]
  local path=$1 id=$2 generation=$3 annotated=${4:-0}
  {
    printf 'window=fmtest:w1:p2\n'
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/worktree\n' "$TMP_ROOT"
    printf 'project=%s/project\n' "$TMP_ROOT"
    printf 'harness=omp\n'
    printf 'profile=personal\n'
    printf 'kind=scout\n'
    printf 'tasktmp=\n'
    printf 'model=default\n'
    printf 'effort=default\n'
    printf 'spawn_gen=%s\n' "$generation"
    printf 'backend=herdr\n'
    printf 'herdr_session=fmtest\n'
    printf 'herdr_workspace_id=w1\n'
    printf 'herdr_tab_id=w1:t2\n'
    printf 'herdr_pane_id=w1:p2\n'
    if [ "$annotated" = 1 ]; then
      printf 'cleanup_recovery=omp-delivery\n'
      printf 'delivery_failure=readiness\n'
      printf 'delivery_cleanup=unconfirmed\n'
    fi
  } > "$path"
}

new_state() { # <name>
  CASE_DIR="$TMP_ROOT/$1"
  STATE="$CASE_DIR/state"
  DATA="$CASE_DIR/data"
  ID="recovery-$1"
  GEN="generation-$1"
  mkdir -p "$STATE" "$DATA"
  write_omp_meta "$STATE/$ID.meta" "$ID" "$GEN"
}

test_sidecar_is_private_closed_and_authoritative() {
  new_state authoritative
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 tx-1 \
    || fail "valid scoped Herdr recovery could not be published"
  sidecar="$STATE/$ID.cleanup-recovery"
  [ "$(stat -f %Lp "$sidecar" 2>/dev/null || stat -c %a "$sidecar")" = 600 ] \
    || fail "cleanup-recovery sidecar must be private"
  fm_cleanup_recovery_decode "$STATE" "$STATE/$ID.meta" "$ID" \
    || fail "sidecar fallback was not decoded: $FM_CLEANUP_RECOVERY_ERROR"
  [ "$FM_CLEANUP_RECOVERY_KIND:$FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX" = 'omp-delivery:tx-1' ] \
    || fail "sidecar fallback lost its closed recovery or transaction binding"

  printf 'cleanup_recovery=omp-delivery\ndelivery_failure=readiness\ndelivery_cleanup=confirmed\n' \
    > "$STATE/$ID.status"
  fm_cleanup_recovery_decode "$STATE" "$STATE/$ID.meta" "$ID" \
    || fail "forged status prose interfered with authoritative recovery"
  [ "$FM_CLEANUP_RECOVERY_CLEANUP" = unconfirmed ] \
    || fail "mutable status prose forged cleanup evidence"
  pass "cleanup recovery: a private sidecar is authoritative and status prose is ignored"
}

test_publication_rejects_untrusted_values_before_creating_a_record() {
  new_state injection
  if fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness unconfirmed \
      personal scout "fmtest:w1:p2
forged=yes" fmtest w1 w1:t2 w1:p2 ''; then
    fail "newline-bearing recovery identity was accepted"
  fi
  assert_absent "$STATE/$ID.cleanup-recovery" "rejected recovery input left a published sidecar"
  [ -z "$(find "$STATE" -name ".$ID.cleanup-recovery.*" -print -quit)" ] \
    || fail "rejected recovery input left a staging file"
  pass "cleanup recovery: untrusted fields are rejected before publication"
}

test_publication_does_not_follow_a_precreated_staging_symlink() {
  local sentinel legacy_stage
  new_state staging-symlink
  sentinel="$CASE_DIR/outside"
  legacy_stage="$STATE/.$ID.cleanup-recovery.$$"
  printf 'outside\n' > "$sentinel"
  ln -s "$sentinel" "$legacy_stage"
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 tx-staging \
    || fail "secure recovery publication failed with an unrelated legacy-stage symlink"
  [ "$(cat "$sentinel")" = outside ] || fail "recovery publication followed a precreated staging symlink"
  [ -L "$legacy_stage" ] || fail "recovery publication replaced the unrelated legacy-stage symlink"
  fm_cleanup_recovery_sidecar_validate "$STATE" "$ID" "$GEN" \
    || fail "securely staged recovery record did not validate"
  pass "cleanup recovery: private exclusive staging does not follow precreated symlinks"
}

test_malformed_or_conflicting_authority_fails_closed() {
  new_state malformed
  write_omp_meta "$STATE/$ID.meta" "$ID" "$GEN" 1
  printf 'delivery_failure=prompt-delivery\n' >> "$STATE/$ID.meta"
  fm_cleanup_recovery_decode "$STATE" "$STATE/$ID.meta" "$ID" \
    && fail "duplicate recovery companion field was accepted"

  write_omp_meta "$STATE/$ID.meta" "$ID" "$GEN" 1
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness confirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 tx-2 \
    || fail "conflict fixture sidecar could not be published"
  fm_cleanup_recovery_decode "$STATE" "$STATE/$ID.meta" "$ID" \
    && fail "conflicting meta and sidecar cleanup evidence was accepted"
  pass "cleanup recovery: malformed and conflicting authorities fail closed"
}

test_workspace_scope_and_full_endpoint_tuple_are_bound() {
  new_state workspace-scope
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w2:t2 w1:p2 tx-scope \
    && fail "recovery accepted a tab outside its recorded workspace"
  assert_absent "$STATE/$ID.cleanup-recovery" \
    "workspace-mismatched recovery left a sidecar"

  write_omp_meta "$STATE/$ID.meta" "$ID" "$GEN" 1
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 '' \
    || fail "tuple comparison fixture sidecar could not be published"
  sed -i.bak -e 's/^kind=scout$/kind=ship/' "$STATE/$ID.meta"
  rm -f "$STATE/$ID.meta.bak"
  fm_cleanup_recovery_decode "$STATE" "$STATE/$ID.meta" "$ID" \
    && fail "recovery accepted a task-kind mismatch between metadata and sidecar"

  write_omp_meta "$STATE/$ID.meta" "$ID" "$GEN" 1
  sed -i.bak -e 's/^window=fmtest:w1:p2$/window=fmtest:w1:p3/' \
    -e 's/^herdr_pane_id=w1:p2$/herdr_pane_id=w1:p3/' "$STATE/$ID.meta"
  rm -f "$STATE/$ID.meta.bak"
  fm_cleanup_recovery_decode "$STATE" "$STATE/$ID.meta" "$ID" \
    && fail "recovery accepted an endpoint-tuple mismatch between metadata and sidecar"
  pass "cleanup recovery: workspace scopes, task kind, and endpoint tuple are exact"
}

test_failed_backlog_close_replays_sidecar_retirement() {
  new_state replay
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" backlog-transition confirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 tx-replay \
    || fail "replay sidecar could not be published"
  FM_BACKLOG_CLOSE_STAGE_RECOVERY_SIDECAR=1 \
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$GEN" \
    || fail "replay close marker could not be published"
  marker="$STATE/$ID.backlog-close"
  sidecar="$STATE/$ID.cleanup-recovery"

  (
    fm_backlog_done() { return 1; }
    fm_backlog_atomic_transition close-recovery close "$STATE/$ID.meta" "$marker" \
      "$sidecar" "$DATA" "$ID" "$STATE"
  ) && fail "injected backlog completion failure unexpectedly committed"
  assert_absent "$STATE/$ID.meta" "failed close did not land its durable record-removal phase"
  assert_present "$marker" "failed close lost its replay marker"
  assert_present "$sidecar" "failed close orphaned its recovery evidence"

  (
    fm_backlog_row_probe() {
      FM_BACKLOG_ROW_STATE=in_flight
      FM_BACKLOG_ROW_HOLD_KIND=
      return 0
    }
    fm_backlog_done() { return 0; }
    fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA"
  ) || fail "startup-style close replay failed"
  assert_absent "$marker" "successful replay retained its close marker"
  assert_absent "$sidecar" "successful replay retained its cleanup sidecar"
  pass "cleanup recovery: backlog failure replays sidecar retirement atomically"
}

test_marker_removal_failure_after_retirement_is_replay_safe() {
  local marker sidecar
  new_state marker-retirement
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" backlog-transition confirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 tx-marker \
    || fail "marker-retirement sidecar could not be published"
  FM_BACKLOG_CLOSE_STAGE_RECOVERY_SIDECAR=1 \
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$GEN" \
    || fail "marker-retirement close marker could not be published"
  marker="$STATE/$ID.backlog-close"
  sidecar="$STATE/$ID.cleanup-recovery"

  (
    fm_backlog_done() { return 0; }
    rm() {
      local last
      for last in "$@"; do :; done
      [ "$last" != "$marker" ] || return 1
      command rm "$@"
    }
    fm_backlog_atomic_transition close-recovery close "$STATE/$ID.meta" "$marker" \
      "$sidecar" "$DATA" "$ID" "$STATE"
  ) && fail "injected final marker removal unexpectedly succeeded"
  assert_absent "$STATE/$ID.meta" "completed recovery close retained task metadata"
  assert_absent "$sidecar" "completed recovery close retained its retired sidecar"
  assert_grep 'cleanup_recovery_retired=1' "$marker" \
    "completed recovery close did not commit its replay phase: $(cat "$marker" 2>/dev/null || true)"

  fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA" \
    || fail "completed recovery replay rejected its already-retired sidecar"
  assert_absent "$marker" "completed recovery replay retained its marker"
  pass "cleanup recovery: marker-removal failure after sidecar retirement replays safely"
}

test_stale_generation_retires_sidecar_before_marker() {
  local marker sidecar
  new_state stale-order
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" backlog-transition confirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 tx-stale \
    || fail "stale-order sidecar could not be published"
  FM_BACKLOG_CLOSE_STAGE_RECOVERY_SIDECAR=1 \
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$GEN" \
    || fail "stale-order marker could not be published"
  marker="$STATE/$ID.backlog-close"
  sidecar="$STATE/$ID.cleanup-recovery"
  write_omp_meta "$STATE/$ID.meta" "$ID" "$GEN-new"

  (
    rm() {
      local last
      for last in "$@"; do :; done
      [ "$last" != "$sidecar" ] || return 1
      command rm "$@"
    }
    fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA"
  ) && fail "stale replay ignored an injected sidecar retirement failure"
  assert_present "$sidecar" "stale replay lost sidecar after failed retirement"
  assert_present "$marker" "stale replay cleared marker before sidecar retirement"
  assert_grep 'cleanup_recovery_retired=1' "$marker" \
    "stale replay did not durably commit retirement before unlink"

  (
    rm() {
      local last
      for last in "$@"; do :; done
      [ "$last" != "$marker" ] || return 1
      command rm "$@"
    }
    fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA"
  ) && fail "stale replay ignored an injected marker retirement failure"
  assert_absent "$sidecar" "stale replay did not retire sidecar before marker"
  assert_present "$marker" "stale replay lost its marker after marker unlink failure"
  assert_grep "spawn_gen=$GEN-new" "$STATE/$ID.meta" \
    "stale replay mutated the newer task generation"

  fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA" \
    || fail "stale replay could not finish after ordered retirement failures"
  assert_absent "$marker" "stale replay retained its final marker"
  pass "cleanup recovery: stale generations retire sidecar before marker and preserve newer metadata"
}

test_fresh_recovery_retires_sidecar_before_annotated_meta() {
  local meta sidecar log
  new_state fresh-retirement
  meta="$STATE/$ID.meta"
  sidecar="$STATE/$ID.cleanup-recovery"
  log="$CASE_DIR/removal-order"
  write_omp_meta "$meta" "$ID" "$GEN" 1
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 '' \
    || fail "fresh-retirement sidecar could not be published"

  (
    fm_backlog_atomic_transition() {
      [ "$1" = remove ] || return 1
      printf '%s\n' "$2" >> "$log"
      [ "$2" != "$meta" ] || return 1
      command rm -f -- "$2"
    }
    fm_cleanup_recovery_retire_fresh_task "$STATE" "$meta" "$ID"
  ) && fail "injected fresh metadata retirement failure unexpectedly succeeded"
  [ "$(sed -n '1p' "$log")" = "$sidecar" ] \
    || fail "fresh recovery did not retire its sidecar first"
  [ "$(sed -n '2p' "$log")" = "$meta" ] \
    || fail "fresh recovery did not attempt annotated metadata second"
  assert_absent "$sidecar" "fresh recovery retained sidecar after successful first phase"
  assert_present "$meta" "fresh recovery lost annotated metadata after injected failure"
  fm_cleanup_recovery_retire_fresh_task "$STATE" "$meta" "$ID" \
    || fail "fresh recovery could not resume from its annotated metadata"
  assert_absent "$meta" "fresh recovery retained metadata after replay"
  pass "cleanup recovery: fresh retirement removes sidecar before annotated metadata"
}

test_sidecar_only_fresh_recovery_is_annotated_before_retirement() {
  local meta sidecar log
  new_state sidecar-only-retirement
  meta="$STATE/$ID.meta"
  sidecar="$STATE/$ID.cleanup-recovery"
  log="$CASE_DIR/transition-order"
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$GEN" readiness unconfirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 '' \
    || fail "sidecar-only fresh recovery could not be published"

  (
    fm_backlog_atomic_transition() {
      printf '%s %s\n' "$1" "$2" >> "$log"
      case "$1" in
        publish) fm_backlog_record_publish "$2" "$3" "$4" "$5" ;;
        remove) return 1 ;;
        *) return 2 ;;
      esac
    }
    fm_cleanup_recovery_retire_fresh_task "$STATE" "$meta" "$ID"
  ) && fail "sidecar-only retirement ignored an injected post-annotation failure"
  assert_grep "publish " "$log" \
    "sidecar-only retirement did not publish an annotation first"
  [ "$(sed -n '2p' "$log")" = "remove $sidecar" ] \
    || fail "sidecar-only retirement did not defer sidecar removal until after annotation"
  assert_present "$sidecar" "sidecar-only retirement lost its authority after injected failure"
  assert_grep 'cleanup_recovery=omp-delivery' "$meta" \
    "sidecar-only retirement did not leave independently recoverable metadata"
  fm_cleanup_recovery_decode "$STATE" "$meta" "$ID" \
    || fail "annotated retry state did not validate: $FM_CLEANUP_RECOVERY_ERROR"

  fm_cleanup_recovery_retire_fresh_task "$STATE" "$meta" "$ID" \
    || fail "sidecar-only fresh recovery could not resume after annotation"
  assert_absent "$sidecar" "sidecar-only fresh recovery retained its sidecar after retry"
  assert_absent "$meta" "sidecar-only fresh recovery retained its metadata after retry"
  pass "cleanup recovery: sidecar-only fresh retirement journals metadata before unlink"
}

assert_replay_refusal_is_zero_mutation() { # <label>
  local label=$1 marker="$STATE/$ID.backlog-close" meta="$STATE/$ID.meta"
  cp "$marker" "$CASE_DIR/$label.marker.before"
  cp "$meta" "$CASE_DIR/$label.meta.before"
  fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA" \
    && fail "$label recovery replay unexpectedly succeeded"
  cmp -s "$marker" "$CASE_DIR/$label.marker.before" \
    || fail "$label recovery replay mutated its close marker"
  cmp -s "$meta" "$CASE_DIR/$label.meta.before" \
    || fail "$label recovery replay mutated task metadata"
}

test_replay_authenticates_recovery_before_any_mutation() {
  local marker sidecar other_gen

  new_state replay-missing
  FM_BACKLOG_CLOSE_STAGE_RECOVERY_SIDECAR=1 \
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$GEN" \
    || fail "missing-sidecar close marker could not be written"
  assert_replay_refusal_is_zero_mutation missing

  new_state replay-malformed
  FM_BACKLOG_CLOSE_STAGE_RECOVERY_SIDECAR=1 \
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$GEN" \
    || fail "malformed-sidecar close marker could not be written"
  sidecar="$STATE/$ID.cleanup-recovery"
  (umask 077; printf 'not-a-recovery-record\n' > "$sidecar")
  assert_replay_refusal_is_zero_mutation malformed

  new_state replay-generation
  FM_BACKLOG_CLOSE_STAGE_RECOVERY_SIDECAR=1 \
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$GEN" \
    || fail "generation-mismatch close marker could not be written"
  other_gen="$GEN-other"
  fm_cleanup_recovery_publish_omp "$STATE" "$ID" "$other_gen" backlog-transition confirmed \
    personal scout fmtest:w1:p2 fmtest w1 w1:t2 w1:p2 tx-generation \
    || fail "generation-mismatch recovery sidecar could not be written"
  assert_replay_refusal_is_zero_mutation generation-mismatch

  pass "cleanup recovery: close replay authenticates its companion before mutation"
}

test_sidecar_is_private_closed_and_authoritative
test_publication_rejects_untrusted_values_before_creating_a_record
test_publication_does_not_follow_a_precreated_staging_symlink
test_malformed_or_conflicting_authority_fails_closed
test_workspace_scope_and_full_endpoint_tuple_are_bound
test_failed_backlog_close_replays_sidecar_retirement
test_marker_removal_failure_after_retirement_is_replay_safe
test_stale_generation_retires_sidecar_before_marker
test_fresh_recovery_retires_sidecar_before_annotated_meta
test_sidecar_only_fresh_recovery_is_annotated_before_retirement
test_replay_authenticates_recovery_before_any_mutation
