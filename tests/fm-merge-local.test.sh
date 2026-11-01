#!/usr/bin/env bash
# Local-only landing must use the durable done head, including across races.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  local name=$1
  CASE="$TMP_ROOT/$name"
  PROJ="$CASE/project"
  WT="$CASE/worker"
  HOME_DIR="$CASE/home"
  META="$HOME_DIR/state/local-task.meta"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/bin/fm-guard.sh"
  chmod +x "$HOME_DIR/bin/fm-guard.sh"
  fm_git_worktree "$PROJ" "$WT" fm/local-task
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m X
  X=$(git -C "$WT" rev-parse HEAD)
  printf 'kind=ship\nmode=local-only\nbranch=fm/local-task\nproject=%s\nworktree=%s\nspawn_gen=fixture-1\n' \
    "$PROJ" "$WT" > "$META"
}

record_done() {
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
    'done [at=1790000000]: ready in branch fm/local-task' \
    "$HOME_DIR/state" local-task "$META"
}

land() {
  local task=local-task
  [ "$#" -eq 0 ] || task=$1
  FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "${MERGE_SCRIPT:-$ROOT/bin/fm-merge-local.sh}" "$task"
}

assert_refused() {
  local out rc=0
  out=$(land 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "landing unexpectedly succeeded: $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'refusal moved main'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'refusal left a dirty checkout'
  [ ! -e "$PROJ/approved.txt" ] || fail 'refusal left approved files behind'
}

test_branch_advance_does_not_change_approval() {
  make_case advanced
  record_done || fail 'done head was not accepted'
  git -C "$WT" commit -q --allow-empty -m Y
  assert_refused
  # Re-reading the old done report must not silently approve Y.
  record_done >/dev/null 2>&1 && fail 'stale done report was rebound to Y'
  git -C "$WT" reset -q --hard "$X"
  land >/dev/null || fail 'approved X did not land'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'landing did not use X'
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'landing did not update the checkout'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'landing left a dirty checkout'
  pass 'branch advance refuses, and restoring the reported X lands exactly X'
}

test_missing_and_malformed_head_refuse() {
  local value
  for value in missing empty abbreviated expression duplicate; do
    make_case "$value"
    case "$value" in
      missing) ;;
      empty) printf 'local_done_head=\n' >> "$META" ;;
      abbreviated) printf 'local_done_head=%s\n' "${X:0:8}" >> "$META" ;;
      expression) printf 'local_done_head=refs/heads/fm/local-task\n' >> "$META" ;;
      duplicate) printf 'local_done_head=%s\nlocal_done_head=%s\n' "$X" "$X" >> "$META" ;;
    esac
    assert_refused
  done
  pass 'missing, malformed and ambiguous done heads refuse without moving main'
}

# A Git shim moves the branch inside the final ref-changing Git invocation.
# It is a scheduling seam only: every Git operation still uses the real binary.
test_change_after_hold_check_refuses() {
  local real_git out rc
  real_git=$(command -v git)
  make_case race-branch
  record_done || fail 'race fixture done was not accepted'
  git -C "$WT" commit -q --allow-empty -m Y
  Y=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" reset -q --hard "$X"
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *' merge --ff-only '*|*' update-ref '*' --stdin')
    "$REAL_GIT" -C "$RACE_PROJ" update-ref refs/heads/fm/local-task "$RACE_Y" || exit $?
    printf 'moved\n' > "$RACE_MARKER"
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$CASE/fakebin/git"
  rc=0
  out=$(PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" RACE_MARKER="$CASE/moved" \
    RACE_PROJ="$PROJ" RACE_Y="$Y" land 2>&1) || rc=$?
  [ -f "$CASE/moved" ] || fail 'branch race was not exercised'
  [ "$(git -C "$PROJ" rev-parse refs/heads/fm/local-task)" = "$Y" ] || fail 'worker branch did not move'
  [ "$rc" -ne 0 ] || fail "branch race unexpectedly landed: $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'branch race moved main'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'branch race left a dirty checkout'
  [ ! -e "$PROJ/approved.txt" ] || fail 'branch race left approved files behind'
  pass 'a branch move inside the final Git invocation refuses without changing main or its checkout'
}

test_diverged_default_refuses() {
  make_case diverged
  record_done || fail 'diverged fixture done was not accepted'
  git -C "$PROJ" commit -q --allow-empty -m diverged
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  assert_refused
  pass 'a diverged default branch refuses without changing main or its checkout'
}

test_change_during_approval_check_refuses() {
  local mode out rc
  for mode in branch approval; do
    make_case "approval-$mode"
    record_done || fail 'approval race fixture done was not accepted'
    git -C "$WT" commit -q --allow-empty -m Y
    Y=$(git -C "$WT" rev-parse HEAD)
    git -C "$WT" reset -q --hard "$X"
    cp -R "$ROOT/bin" "$CASE/toolbin"
    cat > "$CASE/toolbin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
if [ "$RACE_MODE" = branch ]; then
  git -C "$RACE_PROJ" update-ref refs/heads/fm/local-task "$RACE_Y"
else
  printf 'local_done_head=%s\n' "$RACE_Y" >> "$RACE_META"
fi
exit 3
SH
    rc=0
    out=$(MERGE_SCRIPT="$CASE/toolbin/fm-merge-local.sh" RACE_MODE="$mode" \
      RACE_PROJ="$PROJ" RACE_Y="$Y" RACE_META="$META" land 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "approval race succeeded: $out"
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'approval race moved main'
  done
  pass 'approval and branch changes during the hold read refuse without moving main'
}

test_snapshot_cannot_pin_a_replacement_task() {
  local captured
  make_case stale-snapshot
  captured="$CASE/local-task.meta"
  cp "$META" "$captured"
  printf 'spawn_gen=replacement\n' >> "$META"
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
    'done: ready' "$HOME_DIR/state" local-task "$captured" >/dev/null 2>&1 \
    && fail 'a stale snapshot pinned a replacement task'
  assert_no_grep '^local_done_head=' "$META" 'stale snapshot changed live readiness'
  pass 'captured metadata cannot pin a replacement task generation'
}

test_done_recording_preserves_caller_locks() {
  local caller
  for caller in ledger teardown; do
    make_case "locked-$caller"
    (
      local FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state"
      # shellcheck source=bin/fm-wake-lib.sh
      . "$ROOT/bin/fm-wake-lib.sh"
      local lock control='' owner
      lock=$(fm_meta_lock_path "$META") || exit 1
      if [ "$caller" = teardown ]; then
        control="$HOME_DIR/state/.control-local-task.lock"
        fm_lock_try_acquire "$control" || exit 1
      fi
      fm_lock_try_acquire "$lock" || exit 1
      fm_current_pid owner || exit 1
      trap 'fm_lock_release "$lock"; [ -z "$control" ] || fm_lock_release "$control"' EXIT
      FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
        'done: ready' "$HOME_DIR/state" local-task "$META" meta-locked || exit 1
      [ "$(fm_dod_local_done_head "$META")" = "$X" ] || exit 1
      FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
        'done: ready again' "$HOME_DIR/state" local-task "$META" meta-locked || exit 1
      git -C "$WT" commit -q --allow-empty -m Y || exit 1
      if FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
        'done: changed' "$HOME_DIR/state" local-task "$META" meta-locked >/dev/null; then
        exit 1
      fi
      [ "$(fm_dod_local_done_head "$META")" = "$X" ] || exit 1
      [ "$(cat "$lock/pid")" = "$owner" ] || exit 1
      [ -z "$control" ] || [ "$(cat "$control/pid")" = "$owner" ] || exit 1
    ) || fail "$caller: done recording failed or changed the caller's locks"
  done
  pass 'ledger and teardown record the first done head without reacquiring or releasing caller locks'
}

test_two_tasks_cannot_undo_a_same_tree_landing() {
  local real_git real_sleep other first_pid second_pid first_rc=0 second_rc=0 i project_lock
  make_case same-tree
  record_done || fail 'first task readiness was not accepted'
  other=$(printf 'second task\n' | git -C "$PROJ" commit-tree "$X^{tree}" -p "$BASE")
  git -C "$PROJ" update-ref refs/heads/fm/other-task "$other"
  printf 'kind=ship\nmode=local-only\nbranch=fm/other-task\nproject=%s\nspawn_gen=fixture-2\nlocal_done_head=%s\n' \
    "$PROJ" "$other" > "$HOME_DIR/state/other-task.meta"
  [ "$other" != "$X" ] || fail 'same-tree commits were not distinct'
  [ "$(git -C "$PROJ" rev-parse "$other^{tree}")" = "$(git -C "$PROJ" rev-parse "$X^{tree}")" ] \
    || fail 'the two approved commits have different trees'
  real_git=$(command -v git)
  real_sleep=$(command -v sleep)
  project_lock="$(git -C "$PROJ" rev-parse --absolute-git-dir)/fm-local-landing.lock"
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/git" <<'SH'
#!/usr/bin/env bash
wait_for() {
  local i=0
  while [ ! -f "$RACE_DIR/$1" ] && [ "$i" -lt 600 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$RACE_DIR/$1" ]
}
case "$*" in
  *' read-tree -m -u '*)
    if [ ! -f "$RACE_DIR/$RACE_ROLE.staged" ]; then
      : > "$RACE_DIR/$RACE_ROLE.ready"
      if [ "$RACE_ROLE" = first ]; then
        wait_for release-first || exit 90
      else
        wait_for first.staged || exit 91
      fi
      "$REAL_GIT" "$@" || exit $?
      : > "$RACE_DIR/$RACE_ROLE.staged"
      exit 0
    fi
    ;;
  *' update-ref '*' --stdin')
    if [ "$RACE_ROLE" = first ]; then
      if [ -f "$RACE_DIR/second.ready" ]; then
        wait_for second.staged || exit 92
      fi
    else
      wait_for first.updated || exit 93
    fi
    "$REAL_GIT" "$@" || exit $?
    : > "$RACE_DIR/$RACE_ROLE.updated"
    exit 0
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  cat > "$CASE/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$RACE_ROLE" = second ] && [ -d "$RACE_PROJECT_LOCK" ] \
  && [ -d "$RACE_CONTROL_LOCK" ] && [ ! -f "$RACE_DIR/second.ready" ]; then
  : > "$RACE_DIR/second.waiting"
fi
exec "$REAL_SLEEP" "$@"
SH
  chmod +x "$CASE/fakebin/git" "$CASE/fakebin/sleep"
  (
    first_pid='' second_pid=''
    trap ': > "$CASE/release-first"; [ -z "$first_pid" ] || { kill "$first_pid" 2>/dev/null || true; wait "$first_pid" 2>/dev/null || true; }; [ -z "$second_pid" ] || { kill "$second_pid" 2>/dev/null || true; wait "$second_pid" 2>/dev/null || true; }' EXIT
    PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" REAL_SLEEP="$real_sleep" RACE_DIR="$CASE" RACE_ROLE=first \
      RACE_PROJECT_LOCK="$project_lock" RACE_CONTROL_LOCK="$HOME_DIR/state/.control-other-task.lock" \
      land > "$CASE/first.out" 2>&1 &
    # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
    first_pid=$!
    i=0
    while [ ! -f "$CASE/first.ready" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    [ -f "$CASE/first.ready" ] || fail 'first landing never reached its checkout update'
    PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" REAL_SLEEP="$real_sleep" RACE_DIR="$CASE" RACE_ROLE=second \
      RACE_PROJECT_LOCK="$project_lock" RACE_CONTROL_LOCK="$HOME_DIR/state/.control-other-task.lock" \
      land other-task > "$CASE/second.out" 2>&1 &
    # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
    second_pid=$!
    i=0
    while [ "$i" -lt 300 ]; do
      [ ! -f "$CASE/second.ready" ] || break
      if [ -f "$CASE/second.waiting" ]; then
        [ -d "$project_lock" ] || fail 'the contended project lock disappeared'
        kill -0 "$second_pid" 2>/dev/null || fail 'second landing exited before contending'
        break
      fi
      sleep 0.1
      i=$((i + 1))
    done
    [ "$i" -lt 300 ] || fail 'second landing neither prepared nor contended for the checkout'
    : > "$CASE/release-first"
    wait "$first_pid" || first_rc=$?
    wait "$second_pid" || second_rc=$?
    first_pid='' second_pid=''
    [ "$first_rc" -eq 0 ] || fail "first landing failed: $(cat "$CASE/first.out")"
    [ "$second_rc" -ne 0 ] || fail "second landing unexpectedly succeeded: $(cat "$CASE/second.out")"
    [ -f "$CASE/first.updated" ] || fail 'the first ref transaction did not run'
    if [ -f "$CASE/second.ready" ]; then
      [ -f "$CASE/second.staged" ] || fail 'the competing checkout was never staged'
    fi
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'the competing task moved the landed head'
    [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'the competing task reverted the landed files'
    [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'the competing task dirtied the landed checkout'
  ) || fail 'two-task same-tree landing corrupted the first result'
  pass 'two approved tasks with the same tree cannot roll back a successful landing'
}

enter_away() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --spend 2 --words 'keep going while I sleep' >/dev/null \
    || fail 'away entry failed'
}

# Away parity: the away posture never approves less than the standing authority
# the captain already granted, so a yolo-on local-only task lands while away
# exactly as it does attended, for main and for the relocated supervision
# branch alike, while a task whose posture needs the captain's word for each
# landing still waits for the captain's return.
test_away_landing_matches_standing_authority() {
  local out rc actor
  for actor in main branch; do
    make_case "away-yolo-on-$actor"
    printf 'yolo=on\n' >> "$META"
    record_done || fail 'away yolo-on readiness was not accepted'
    enter_away
    rc=0
    if [ "$actor" = branch ]; then
      out=$(FM_SUPERVISION_ACTOR=branch land 2>&1) || rc=$?
    else
      out=$(land 2>&1) || rc=$?
    fi
    [ "$rc" -eq 0 ] || fail "a yolo-on local-only landing by $actor refused while away (rc=$rc): $out"
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail "the away landing by $actor did not land X"
    [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail "the away landing by $actor did not update the checkout"
  done
  assert_contains "$out" 'main is parked' 'the relocated branch landing did not announce itself'

  for actor in main branch; do
    make_case "away-yolo-off-$actor"
    printf 'yolo=off\n' >> "$META"
    record_done || fail 'away yolo-off readiness was not accepted'
    enter_away
    rc=0
    if [ "$actor" = branch ]; then
      out=$(FM_SUPERVISION_ACTOR=branch land 2>&1) || rc=$?
    else
      out=$(land 2>&1) || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "a yolo-off local-only landing by $actor proceeded while away: $out"
    assert_contains "$out" "waits for the captain's word" "the yolo-off refusal by $actor did not name the captain"
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail "a yolo-off away refusal by $actor moved main"
    [ ! -e "$PROJ/approved.txt" ] || fail "a yolo-off away refusal by $actor left approved files behind"
  done

  # A task record that predates recorded yolo carries no standing grant.
  make_case away-yolo-missing
  record_done || fail 'away no-yolo readiness was not accepted'
  enter_away
  out=$(land 2>&1) && fail "a task with no recorded yolo landed while away: $out"
  assert_contains "$out" "waits for the captain's word" 'the missing-yolo refusal did not name the captain'

  # Attended, the branch still never lands, and main lands as before.
  make_case attended-branch
  printf 'yolo=on\n' >> "$META"
  record_done || fail 'attended readiness was not accepted'
  rc=0
  out=$(FM_SUPERVISION_ACTOR=branch land 2>&1) || rc=$?
  [ "$rc" -eq 6 ] || fail "an attended branch landing was not refused at the role partition (rc=$rc): $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'an attended branch refusal moved main'
  land >/dev/null 2>&1 || fail 'an attended main landing refused'

  # Quiet mode is a present captain: a yolo-off landing the captain approved
  # in chat still proceeds, because quiet records hold nothing for a return.
  make_case quiet-yolo-off
  printf 'yolo=off\n' >> "$META"
  record_done || fail 'quiet readiness was not accepted'
  FM_AFK_MODE=quiet FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'quiet please' >/dev/null || fail 'quiet entry failed'
  land >/dev/null 2>&1 || fail 'a quiet-mode main landing refused'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'the quiet-mode landing did not land X'
  pass 'while away a yolo-on local-only task lands for main and the branch, and a task whose posture needs the captain waits'
}

land_with_override() {
  FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "$ROOT/bin/fm-merge-local.sh" local-task --attended-override
}

# Away never approves less than the captain already authorized: a yolo-off
# landing the captain named lands for main with --attended-override, exactly as
# fm-pr-merge.sh's attended override carries an explicit captain instruction.
# The supervision branch cannot hear the captain, so it is refused the override,
# and without it a yolo-off landing still waits.
test_away_attended_override_lands_only_for_main() {
  local out rc
  make_case away-override-main
  printf 'yolo=off\n' >> "$META"
  record_done || fail 'override readiness was not accepted'
  enter_away
  out=$(land 2>&1) && fail "a yolo-off landing with no override proceeded while away: $out"
  assert_contains "$out" "waits for the captain's word" 'the no-override refusal did not name the captain'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'the no-override refusal moved main'
  out=$(land_with_override 2>&1) || fail "main's away landing with the captain's override refused: $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail "main's override landing did not land X"
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail "main's override landing did not update the checkout"

  make_case away-override-branch
  printf 'yolo=off\n' >> "$META"
  record_done || fail 'branch override readiness was not accepted'
  enter_away
  rc=0
  out=$(FM_SUPERVISION_ACTOR=branch land_with_override 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the supervision branch landed with --attended-override: $out"
  assert_contains "$out" 'cannot hear' 'the branch override refusal did not say why'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'the branch override refusal moved main'
  [ ! -e "$PROJ/approved.txt" ] || fail 'the branch override refusal left approved files behind'

  make_case override-bad-arg
  record_done || fail 'bad-arg readiness was not accepted'
  rc=0
  out=$(FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "$ROOT/bin/fm-merge-local.sh" local-task --attended-override=yes 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown second argument was not refused as invalid (rc=$rc): $out"
  pass 'while away main lands a captain-named yolo-off task with --attended-override, the branch never may, and no override still waits'
}

fm_test_run test_two_tasks_cannot_undo_a_same_tree_landing test_branch_advance_does_not_change_approval \
  test_away_landing_matches_standing_authority test_away_attended_override_lands_only_for_main \
  test_missing_and_malformed_head_refuse test_change_after_hold_check_refuses \
  test_diverged_default_refuses test_change_during_approval_check_refuses \
  test_snapshot_cannot_pin_a_replacement_task test_done_recording_preserves_caller_locks
