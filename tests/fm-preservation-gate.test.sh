#!/usr/bin/env bash
# Behavior tests for the AgentLab evidence-preservation gate
# (bin/fm-preservation-lib.sh; docs/evidence-preservation-lifecycle.md in
# yagakeerthikiran/agentlab-shared-memory is the canonical contract) and its
# mechanical enforcement in bin/fm-spawn.sh, bin/fm-promote.sh, and
# bin/fm-teardown.sh.
#
# Every case builds a real, minimal AgentLab-shaped git repo with a bare
# origin remote (build_gate_fixture) rather than mocking git, so reachability,
# push state, and the validator are exercised for real.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PRESERVATION_LIB="$ROOT/bin/fm-preservation-lib.sh"
PRESERVATION_RECORD="$ROOT/bin/fm-preservation-record.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SESSION_ID="$ROOT/bin/fm-session-id.sh"
TMP_ROOT=$(fm_test_tmproot fm-preservation-gate)

# build_gate_fixture <dir>: a real AgentLab-shaped repo at <dir>/src with a
# bare origin at <dir>/origin.git, one checkpoint file, and an
# always-passing scripts/validate-checkpoint.mjs, UNLESS the checkpoint's own
# content contains the literal marker FAILME (used to exercise a validator
# failure without a second stub).
build_gate_fixture() {
  local dir=$1
  mkdir -p "$dir/src/scripts" "$dir/src/checkpoints/gate-home/task-x1"
  git init -q -b main "$dir/src"
  cat > "$dir/src/scripts/validate-checkpoint.mjs" <<'EOF'
import fs from 'node:fs';
const content = fs.readFileSync(process.argv[2], 'utf8');
if (content.includes('FAILME')) {
  console.error('validator: FAILME marker present');
  process.exit(1);
}
process.exit(0);
EOF
  printf '# checkpoint\n' > "$dir/src/checkpoints/gate-home/task-x1/001--fixture--final.md"
  git -C "$dir/src" add -A
  git -C "$dir/src" -c user.email=t@t -c user.name=t commit -q -m fixture
  git init -q --bare "$dir/origin.git"
  git -C "$dir/src" remote add origin "$dir/origin.git"
  git -C "$dir/src" push -q origin main
}

# commit_checkpoint <dir> <content> [push=yes|no]: appends <content> to the
# checkpoint file, commits, pushes unless told not to. Echoes the new SHA.
commit_checkpoint() {
  local dir=$1 content=$2 push=${3:-yes}
  printf '%s\n' "$content" >> "$dir/src/checkpoints/gate-home/task-x1/001--fixture--final.md"
  git -C "$dir/src" add -A
  git -C "$dir/src" -c user.email=t@t -c user.name=t commit -q -m "checkpoint update"
  [ "$push" != yes ] || git -C "$dir/src" push -q origin main
  git -C "$dir/src" rev-parse HEAD
}

# write_receipt <state_dir> <id> <kind> <commit> [<app_head>] [<timestamp>]
write_receipt() {
  local state_dir=$1 id=$2 kind=$3 commit=$4 app_head=${5:-} timestamp=${6:-}
  mkdir -p "$state_dir"
  node -e '
    const fs = require("node:fs");
    const [p, id, kind, commit, appHead, ts] = process.argv.slice(1);
    const now = new Date().toISOString();
    fs.appendFileSync(p, JSON.stringify({
      kind, task: id, home: "gate-home", commit,
      path: "checkpoints/gate-home/task-x1/001--fixture--final.md",
      branch: "main", app_branch: "", app_head: appHead || "",
      timestamp: ts || now, recorded_at: now,
    }) + "\n");
  ' "$state_dir/$id.preservation" "$id" "$kind" "$commit" "$app_head" "$timestamp"
}

# run_verify <agentlab_dir> <state_dir> <id> <kind> [<worktree>] [<task_kind>]
# Prints "PASS" or "FAIL: <error>". FM_HOME is pinned to agentlab_dir's parent
# so a scout/secondmate task_kind's data/<id> and status-file freshness checks
# resolve against the fixture, not the real firstmate home.
run_verify() {
  local agentlab_dir=$1 state_dir=$2 id=$3 kind=$4 wt=${5:-} task_kind=${6:-}
  FM_PRESERVATION_AGENTLAB_ROOT="$agentlab_dir/src" FM_HOME="$agentlab_dir" bash -c '
    . "$1"
    if fm_preservation_verify "$2" "$3" "$4" "$5" "$6"; then
      printf "PASS\n"
    else
      printf "FAIL: %s\n" "$FM_PRESERVATION_VERIFY_ERROR"
    fi
  ' _ "$PRESERVATION_LIB" "$state_dir" "$id" "$kind" "$wt" "$task_kind"
}

# --- fm_preservation_verify: the library's own contract ---------------------

test_verify_refuses_without_a_receipt() {
  local dir="$TMP_ROOT/verify-absent" out
  build_gate_fixture "$dir"
  mkdir -p "$dir/state"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*absent*) pass "verify refuses when no receipt is recorded" ;;
    *) fail "expected an absent-receipt refusal, got: $out" ;;
  esac
}

test_verify_refuses_when_commit_not_pushed() {
  local dir="$TMP_ROOT/verify-unpushed" sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "local only, never pushed" no)
  write_receipt "$dir/state" task-x1 final "$sha"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*"not reachable from origin/main"*) pass "verify refuses a commit that is local-only, not pushed" ;;
    *) fail "expected an unpushed-commit refusal, got: $out" ;;
  esac
}

test_verify_refuses_when_commit_absent_from_clone() {
  local dir="$TMP_ROOT/verify-absent-commit" out
  build_gate_fixture "$dir"
  write_receipt "$dir/state" task-x1 final "0000000000000000000000000000000000000f"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*"absent evidence"*) pass "verify refuses a commit the clone has never seen" ;;
    *) fail "expected an absent-commit refusal, got: $out" ;;
  esac
}

test_verify_refuses_when_checkpoint_file_missing_at_commit() {
  local dir="$TMP_ROOT/verify-missing-file" sha out
  build_gate_fixture "$dir"
  git -C "$dir/src" rm -q checkpoints/gate-home/task-x1/001--fixture--final.md
  git -C "$dir/src" -c user.email=t@t -c user.name=t commit -q -m "remove checkpoint"
  git -C "$dir/src" push -q origin main
  sha=$(git -C "$dir/src" rev-parse HEAD)
  write_receipt "$dir/state" task-x1 final "$sha"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*"missing at commit"*) pass "verify refuses when the checkpoint file is absent at its own commit" ;;
    *) fail "expected a missing-file refusal, got: $out" ;;
  esac
}

test_verify_refuses_when_validator_fails() {
  local dir="$TMP_ROOT/verify-validator-fails" sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "FAILME")
  write_receipt "$dir/state" task-x1 final "$sha"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*"validator failures"*) pass "verify refuses when the AgentLab validator fails" ;;
    *) fail "expected a validator-failure refusal, got: $out" ;;
  esac
}

test_verify_refuses_when_clone_is_missing() {
  local dir="$TMP_ROOT/verify-no-clone" out
  mkdir -p "$dir/state"
  write_receipt "$dir/state" task-x1 final "0000000000000000000000000000000000000f"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*"absent; refusing"*) pass "verify refuses rather than skips when the AgentLab clone is missing" ;;
    *) fail "expected a missing-clone refusal, got: $out" ;;
  esac
}

test_verify_refuses_when_validator_script_is_missing() {
  local dir="$TMP_ROOT/verify-no-validator" sha out
  build_gate_fixture "$dir"
  rm -f "$dir/src/scripts/validate-checkpoint.mjs"
  git -C "$dir/src" add -A
  git -C "$dir/src" -c user.email=t@t -c user.name=t commit -q -m "remove validator"
  git -C "$dir/src" push -q origin main
  sha=$(git -C "$dir/src" rev-parse HEAD)
  write_receipt "$dir/state" task-x1 final "$sha"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*"validator missing"*) pass "verify refuses rather than skips when the validator script is missing" ;;
    *) fail "expected a missing-validator refusal, got: $out" ;;
  esac
}

test_verify_passes_with_a_valid_receipt() {
  local dir="$TMP_ROOT/verify-ok" sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "good content")
  write_receipt "$dir/state" task-x1 final "$sha"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  [ "$out" = PASS ] || fail "expected a valid receipt to pass, got: $out"
  pass "verify passes a pushed, validator-clean, reachable receipt"
}

test_verify_refuses_when_app_head_moved() {
  local dir="$TMP_ROOT/verify-stale-head" wt sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "final content")
  wt="$dir/appwt"
  fm_git_init_commit "$wt"
  write_receipt "$dir/state" task-x1 final "$sha" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt")
  case "$out" in
    FAIL:*"is stale"*) pass "verify refuses a final receipt whose app head has moved on" ;;
    *) fail "expected a stale-head refusal, got: $out" ;;
  esac
}

test_verify_passes_when_app_head_matches() {
  local dir="$TMP_ROOT/verify-fresh-head" wt sha head out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "final content")
  wt="$dir/appwt"
  fm_git_init_commit "$wt"
  head=$(git -C "$wt" rev-parse HEAD)
  write_receipt "$dir/state" task-x1 final "$sha" "$head"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt")
  [ "$out" = PASS ] || fail "expected a matching app head to pass, got: $out"
  pass "verify passes a final receipt whose app head matches the current worktree"
}

test_verify_tolerates_a_gone_worktree() {
  local dir="$TMP_ROOT/verify-gone-wt" sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "final content")
  write_receipt "$dir/state" task-x1 final "$sha" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$dir/never-existed")
  [ "$out" = PASS ] || fail "expected a gone worktree to be tolerated (nothing to compare), got: $out"
  pass "verify does not refuse a final checkpoint solely because its worktree is gone"
}

test_verify_only_matches_the_requested_kind_and_task() {
  local dir="$TMP_ROOT/verify-kind-scope" sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "an initial checkpoint")
  write_receipt "$dir/state" task-x1 initial "$sha"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*absent*) pass "verify never lets an initial receipt satisfy a final check" ;;
    *) fail "an initial-kind receipt must not satisfy a final check, got: $out" ;;
  esac
}

test_verify_scout_allows_empty_app_head_when_report_is_fresh() {
  local dir="$TMP_ROOT/verify-scout-fresh" wt sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "scout final content")
  wt="$dir/appwt"
  fm_git_init_commit "$wt"
  mkdir -p "$dir/data/task-x1"
  printf 'report\n' > "$dir/data/task-x1/report.md"
  fm_touch_epoch 1700000000 "$dir/data/task-x1/report.md"
  write_receipt "$dir/state" task-x1 final "$sha" "" "2023-11-15T00:00:00Z"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt" scout)
  [ "$out" = PASS ] || fail "expected an empty app_head with a fresh report to pass for a scout, got: $out"
  pass "verify allows a scout final receipt with an empty app_head when its report predates it"
}

test_verify_scout_refuses_when_report_is_newer_than_the_receipt() {
  local dir="$TMP_ROOT/verify-scout-stale" wt sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "scout final content")
  wt="$dir/appwt"
  fm_git_init_commit "$wt"
  mkdir -p "$dir/data/task-x1"
  printf 'report\n' > "$dir/data/task-x1/report.md"
  fm_touch_epoch 1700000000 "$dir/data/task-x1/report.md"
  write_receipt "$dir/state" task-x1 final "$sha" "" "2020-01-01T00:00:00Z"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt" scout)
  case "$out" in
    FAIL:*"is stale"*) pass "verify refuses a scout final receipt whose report was edited after the checkpoint" ;;
    *) fail "expected a stale-report refusal for a scout, got: $out" ;;
  esac
}

test_verify_secondmate_requires_app_head() {
  local dir="$TMP_ROOT/verify-secondmate-no-head" wt sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "secondmate final content")
  wt="$dir/home"
  fm_git_init_commit "$wt"
  write_receipt "$dir/state" task-x1 final "$sha" ""
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt" secondmate)
  case "$out" in
    FAIL:*"missing app_head"*) pass "verify refuses a secondmate final receipt with no app_head" ;;
    *) fail "expected a missing-app_head refusal for a secondmate, got: $out" ;;
  esac
}

test_verify_secondmate_passes_with_matching_head_and_fresh_backlog() {
  local dir="$TMP_ROOT/verify-secondmate-fresh" wt sha head out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "secondmate final content")
  wt="$dir/home"
  fm_git_init_commit "$wt"
  head=$(git -C "$wt" rev-parse HEAD)
  mkdir -p "$wt/data"
  printf 'backlog\n' > "$wt/data/backlog.md"
  printf 'captain\n' > "$wt/data/captain.md"
  fm_touch_epoch 1700000000 "$wt/data/backlog.md" "$wt/data/captain.md"
  write_receipt "$dir/state" task-x1 final "$sha" "$head" "2023-11-15T00:00:00Z"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt" secondmate)
  [ "$out" = PASS ] || fail "expected a matching head with a fresh backlog/captain to pass, got: $out"
  pass "verify passes a secondmate final receipt whose head and backlog/captain predate it"
}

test_verify_secondmate_refuses_when_backlog_is_newer_than_the_receipt() {
  local dir="$TMP_ROOT/verify-secondmate-stale" wt sha head out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "secondmate final content")
  wt="$dir/home"
  fm_git_init_commit "$wt"
  head=$(git -C "$wt" rev-parse HEAD)
  mkdir -p "$wt/data"
  printf 'backlog\n' > "$wt/data/backlog.md"
  printf 'captain\n' > "$wt/data/captain.md"
  fm_touch_epoch 1700000000 "$wt/data/backlog.md" "$wt/data/captain.md"
  write_receipt "$dir/state" task-x1 final "$sha" "$head" "2020-01-01T00:00:00Z"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt" secondmate)
  case "$out" in
    FAIL:*"is stale"*) pass "verify refuses a secondmate final receipt whose backlog was edited after the checkpoint" ;;
    *) fail "expected a stale-backlog refusal for a secondmate, got: $out" ;;
  esac
}

test_verify_secondmate_refuses_a_head_mismatch() {
  local dir="$TMP_ROOT/verify-secondmate-head-mismatch" wt sha out
  build_gate_fixture "$dir"
  sha=$(commit_checkpoint "$dir" "secondmate final content")
  wt="$dir/home"
  fm_git_init_commit "$wt"
  write_receipt "$dir/state" task-x1 final "$sha" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "2023-11-15T00:00:00Z"
  out=$(run_verify "$dir" "$dir/state" task-x1 final "$wt" secondmate)
  case "$out" in
    FAIL:*"is stale"*) pass "verify refuses a secondmate final receipt whose app head does not match the home's default branch" ;;
    *) fail "expected a head-mismatch refusal for a secondmate, got: $out" ;;
  esac
}

# --- bin/fm-preservation-record.sh: real receipt ingestion ------------------

test_record_accepts_a_pre_worktree_receipt_with_no_app_head() {
  local dir="$TMP_ROOT/record-no-app-head" out status
  mkdir -p "$dir/state"
  out=$(printf '%s' '{"kind":"initial","task":"task-x1","commit":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","path":"checkpoints/gate-home/task-x1/001--fixture--initial.md","timestamp":"2026-09-17T00:00:00Z"}' \
    | FM_STATE_OVERRIDE="$dir/state" "$PRESERVATION_RECORD" task-x1 --home gate-home 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "fm-preservation-record.sh should accept an app_head-less initial receipt (rc=$status): $out"
  assert_grep '"app_head":""' "$dir/state/task-x1.preservation" \
    "an app_head-less receipt was not recorded with an empty app_head"
  pass "fm-preservation-record.sh records a pre-worktree initial receipt that omits app_head"
}

# --- captain waiver ----------------------------------------------------------

test_waiver_records_words_and_lets_verify_stay_refused() {
  local dir="$TMP_ROOT/waiver" out
  mkdir -p "$dir/state"
  bash -c '. "$1"; fm_preservation_record_waiver "$2" task-x1 "ship it now, captain says so"' \
    _ "$PRESERVATION_LIB" "$dir/state"
  assert_grep '"kind":"waiver"' "$dir/state/task-x1.preservation" "waiver was not recorded in the receipt log"
  assert_grep 'ship it now, captain says so' "$dir/state/task-x1.preservation" "waiver did not record the captain's exact words"
  assert_grep 'preservation gate waived by captain: ship it now, captain says so' "$dir/state/task-x1.status" \
    "waiver did not append an auditable status line"
  out=$(run_verify "$dir" "$dir/state" task-x1 final)
  case "$out" in
    FAIL:*absent*) pass "a waiver record is auditable but never itself satisfies verify" ;;
    *) fail "a waiver must never make verify pass on its own, got: $out" ;;
  esac
}

# --- fm-teardown.sh integration ----------------------------------------------

# make_teardown_case <name>: a real project + worktree + fork remote so the
# task's own landed-work check passes, leaving the preservation gate as the
# only thing standing between teardown and success. Echoes "<case_dir>|<wt>".
make_teardown_case() {
  local name=$1 case_dir wt
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$case_dir/fakebin"
  fm_test_fake_exit0 "$case_dir/fakebin" tmux treehouse no-mistakes gh gh-axi 2>/dev/null \
    || fm_fake_exit0 "$case_dir/fakebin" tmux treehouse no-mistakes gh gh-axi
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  wt="$case_dir/wt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$wt" "project=$case_dir/project" \
    "kind=ship" "mode=local-only" "spawn_gen=preservation-gate-fixture"
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$wt"
}

run_gate_teardown() {  # <case_dir> [extra args...]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@" 2>&1
}

test_teardown_refuses_without_a_final_receipt() {
  local rec case_dir wt out status
  rec=$(make_teardown_case teardown-no-receipt)
  IFS='|' read -r case_dir wt <<EOF
$rec
EOF
  out=$(run_gate_teardown "$case_dir")
  status=$?
  [ "$status" -ne 0 ] || fail "teardown should refuse without a preservation receipt"
  assert_contains "$out" "REFUSED: preservation" "teardown's refusal did not name the preservation gate"
  pass "teardown refuses cleanup without a final AgentLab checkpoint"
}

test_teardown_force_does_not_bypass_preservation() {
  local rec case_dir wt out status
  rec=$(make_teardown_case teardown-force-no-bypass)
  IFS='|' read -r case_dir wt <<EOF
$rec
EOF
  out=$(run_gate_teardown "$case_dir" --force)
  status=$?
  [ "$status" -ne 0 ] || fail "--force must not bypass the preservation gate"
  assert_contains "$out" "REFUSED: preservation" "--force bypassed the preservation refusal"
  pass "--force authorizes discarding unlanded work only, never skipping preservation"
}

test_teardown_proceeds_with_a_valid_final_receipt() {
  local rec case_dir wt agentlab sha head out status
  rec=$(make_teardown_case teardown-valid-receipt)
  IFS='|' read -r case_dir wt <<EOF
$rec
EOF
  agentlab="$case_dir/agentlab"
  build_gate_fixture "$agentlab"
  sha=$(commit_checkpoint "$agentlab" "final for teardown")
  head=$(git -C "$wt" rev-parse HEAD)
  write_receipt "$case_dir/state" task-x1 final "$sha" "$head"
  out=$(FM_PRESERVATION_AGENTLAB_ROOT="$agentlab/src" run_gate_teardown "$case_dir")
  status=$?
  assert_not_contains "$out" "REFUSED: preservation" "a valid final receipt was refused: $out"
  [ "$status" -eq 0 ] || fail "teardown should succeed with a valid final receipt (rc=$status): $out"
  pass "teardown proceeds once a valid, fresh final checkpoint is on record"
}

test_teardown_waiver_records_words_and_proceeds() {
  local rec case_dir wt out status
  rec=$(make_teardown_case teardown-waiver)
  IFS='|' read -r case_dir wt <<EOF
$rec
EOF
  out=$(run_gate_teardown "$case_dir" --preservation-waived-by-captain "captain says ship without a checkpoint this once")
  status=$?
  [ "$status" -eq 0 ] || fail "a captain waiver should let teardown proceed (rc=$status): $out"
  assert_grep '"kind":"waiver"' "$case_dir/state/task-x1.preservation" "the waiver was not recorded in the receipt log"
  assert_grep 'captain says ship without a checkpoint this once' "$case_dir/state/task-x1.preservation" \
    "the waiver did not record the captain's verbatim words"
  pass "--preservation-waived-by-captain records an auditable waiver and proceeds"
}

# --- fm-spawn.sh integration --------------------------------------------------

write_min_brief() {  # <home> <id> [mode]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf '# Task\n## Captain'"'"'s intent\nExercise the preservation gate.\n\n## Firstmate spec\nn/a.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

make_spawn_home() {  # <name> -> echoes "<home>|<proj>|<fakebin>"
  local name=$1 home proj fakebin
  home="$TMP_ROOT/$name/home"
  proj="$TMP_ROOT/$name/proj"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fakebin"
  fm_git_init_commit "$proj"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$home|$proj|$fakebin"
}

test_spawn_ship_refuses_without_initial_receipt() {
  local rec home proj fakebin id out status
  rec=$(make_spawn_home spawn-no-receipt)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  id=gate-spawn-a
  write_min_brief "$home" "$id" no-mistakes
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn should refuse without an initial receipt"
  assert_contains "$out" "REFUSED: preservation initial checkpoint absent" \
    "spawn's refusal did not name the missing initial checkpoint"
  pass "a ship spawn refuses before any endpoint exists without a verified initial checkpoint"
}

test_spawn_ship_proceeds_past_the_gate_with_a_valid_initial_receipt() {
  local rec home proj fakebin id agentlab sha out
  rec=$(make_spawn_home spawn-with-receipt)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  id=gate-spawn-b
  write_min_brief "$home" "$id" no-mistakes
  agentlab="$home/agentlab"
  build_gate_fixture "$agentlab"
  sha=$(commit_checkpoint "$agentlab" "initial for spawn")
  write_receipt "$home/state" "$id" initial "$sha"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PRESERVATION_AGENTLAB_ROOT="$agentlab/src" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  assert_not_contains "$out" "REFUSED: preservation" "a valid initial receipt was refused: $out"
  pass "a ship spawn clears the preservation gate once a valid initial checkpoint is on record"
}

test_spawn_scout_is_exempt_from_the_initial_receipt() {
  local rec home proj fakebin id out
  rec=$(make_spawn_home spawn-scout-exempt)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  id=gate-spawn-scout
  write_min_brief "$home" "$id"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --scout 2>&1)
  assert_not_contains "$out" "REFUSED: preservation" "a scout spawn must never require an initial checkpoint: $out"
  pass "a scout spawn is exempt from the initial-receipt gate"
}

# --- fm-promote.sh integration ------------------------------------------------

test_promote_refuses_without_initial_receipt() {
  local home id out status
  home="$TMP_ROOT/promote-no-receipt/home"
  mkdir -p "$home/state" "$home/data"
  id=gate-promote-a
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "kind=scout"
  write_min_brief "$home" "$id"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion should refuse without an initial receipt"
  assert_contains "$out" "REFUSED: preservation initial checkpoint absent" \
    "promotion's refusal did not name the missing initial checkpoint"
  assert_grep 'kind=scout' "$home/state/$id.meta" "refused promotion still changed the task record"
  pass "promotion refuses to flip kind=ship without a verified initial checkpoint"
}

test_promote_proceeds_with_a_valid_initial_receipt() {
  local home id agentlab sha out status
  home="$TMP_ROOT/promote-with-receipt/home"
  mkdir -p "$home/state" "$home/data"
  id=gate-promote-b
  fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "kind=scout"
  write_min_brief "$home" "$id"
  agentlab="$home/agentlab"
  build_gate_fixture "$agentlab"
  sha=$(commit_checkpoint "$agentlab" "initial for promotion")
  write_receipt "$home/state" "$id" initial "$sha"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PRESERVATION_AGENTLAB_ROOT="$agentlab/src" \
    "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "promotion should succeed with a valid initial receipt (rc=$status): $out"
  assert_grep 'kind=ship' "$home/state/$id.meta" "promotion did not flip kind=ship after clearing the gate"
  pass "promotion proceeds once a valid initial checkpoint is on record"
}

# --- bin/fm-brief.sh scaffold --------------------------------------------------

test_brief_scaffolds_carry_the_evidence_preservation_section() {
  local home id
  home="$TMP_ROOT/brief-ship/home"
  mkdir -p "$home/data"
  id=gate-brief-ship
  FM_HOME="$home" "$BRIEF" "$id" someproj --mode no-mistakes >/dev/null \
    || fail "ship brief scaffold failed"
  assert_grep '# Evidence preservation' "$home/data/$id/brief.md" \
    "ship brief is missing the Evidence preservation section"
  assert_grep 'yagakeerthikiran/agentlab-shared-memory' "$home/data/$id/brief.md" \
    "ship brief does not point at the canonical AgentLab contract"
  assert_grep 'Crew Claude session ID' "$home/data/$id/brief.md" \
    "ship brief is missing the crew identification block fields"
  assert_grep 'fm-preservation-record.sh' "$home/data/$id/brief.md" \
    "ship brief does not give the exact receipt-recording command"
  assert_grep 'not a valid AgentLab handoff' "$home/data/$id/brief.md" \
    "ship brief is missing the captain's mandated handoff sentence"

  home="$TMP_ROOT/brief-scout/home"
  mkdir -p "$home/data"
  id=gate-brief-scout
  FM_HOME="$home" "$BRIEF" "$id" someproj --scout >/dev/null \
    || fail "scout brief scaffold failed"
  assert_grep '# Evidence preservation' "$home/data/$id/brief.md" \
    "scout brief is missing the Evidence preservation section"
  assert_grep 'becomes the initial checkpoint only if firstmate promotes' "$home/data/$id/brief.md" \
    "scout brief does not explain its exemption at spawn and requirement at promotion"
  pass "ship and scout brief scaffolds carry the Evidence preservation section and identity fields"
}

# --- bin/fm-session-id.sh -----------------------------------------------------

test_session_id_returns_the_env_session_id_when_present() {
  local out
  out=$(env CLAUDE_CODE_SESSION_ID=11111111-1111-1111-1111-111111111111 "$SESSION_ID" 2>&1)
  assert_contains "$out" "session_id=11111111-1111-1111-1111-111111111111" \
    "fm-session-id.sh did not report the ambient CLAUDE_CODE_SESSION_ID"
  assert_contains "$out" "resume_url=https://claude.ai/code/session_11111111-1111-1111-1111-111111111111" \
    "fm-session-id.sh did not derive the matching resume URL"
  pass "fm-session-id.sh reports the ambient session id and resume URL"
}

test_session_id_reports_unavailable_with_a_reason() {
  local dir out status
  dir="$TMP_ROOT/session-id-unavailable"
  mkdir -p "$dir/home"
  out=$(env -u CLAUDE_CODE_SESSION_ID FM_CLAUDE_PROJECTS_DIR="$dir/no-such-projects-dir" \
    "$SESSION_ID" "$dir/home" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-session-id.sh should exit non-zero when unavailable"
  assert_contains "$out" "session_id=UNAVAILABLE" "missing session id was not reported as UNAVAILABLE"
  assert_contains "$out" "reason=" "an UNAVAILABLE session id was not given a reason"
  pass "fm-session-id.sh reports UNAVAILABLE with a reason rather than a false id"
}

test_session_id_finds_the_newest_transcript_when_env_is_absent() {
  local dir projdir slug out
  dir="$TMP_ROOT/session-id-newest"
  mkdir -p "$dir/home"
  slug=$(printf '%s' "$dir/home" | sed 's/[\/.]/-/g')
  projdir="$dir/claude-projects/$slug"
  mkdir -p "$projdir"
  printf 'old\n' > "$projdir/00000000-0000-0000-0000-000000000001.jsonl"
  fm_touch_epoch 1000000000 "$projdir/00000000-0000-0000-0000-000000000001.jsonl"
  printf 'new\n' > "$projdir/00000000-0000-0000-0000-000000000002.jsonl"
  fm_touch_epoch 2000000000 "$projdir/00000000-0000-0000-0000-000000000002.jsonl"
  out=$(env -u CLAUDE_CODE_SESSION_ID FM_CLAUDE_PROJECTS_DIR="$dir/claude-projects" \
    "$SESSION_ID" "$dir/home" 2>&1)
  assert_contains "$out" "session_id=00000000-0000-0000-0000-000000000002" \
    "fm-session-id.sh did not pick the newest transcript file"
  pass "fm-session-id.sh falls back to the newest transcript file for the home"
}

test_verify_refuses_without_a_receipt
test_verify_refuses_when_commit_not_pushed
test_verify_refuses_when_commit_absent_from_clone
test_verify_refuses_when_checkpoint_file_missing_at_commit
test_verify_refuses_when_validator_fails
test_verify_refuses_when_clone_is_missing
test_verify_refuses_when_validator_script_is_missing
test_verify_passes_with_a_valid_receipt
test_verify_refuses_when_app_head_moved
test_verify_passes_when_app_head_matches
test_verify_tolerates_a_gone_worktree
test_verify_only_matches_the_requested_kind_and_task
test_verify_scout_allows_empty_app_head_when_report_is_fresh
test_verify_scout_refuses_when_report_is_newer_than_the_receipt
test_verify_secondmate_requires_app_head
test_verify_secondmate_passes_with_matching_head_and_fresh_backlog
test_verify_secondmate_refuses_when_backlog_is_newer_than_the_receipt
test_verify_secondmate_refuses_a_head_mismatch
test_record_accepts_a_pre_worktree_receipt_with_no_app_head
test_waiver_records_words_and_lets_verify_stay_refused
test_teardown_refuses_without_a_final_receipt
test_teardown_force_does_not_bypass_preservation
test_teardown_proceeds_with_a_valid_final_receipt
test_teardown_waiver_records_words_and_proceeds
test_spawn_ship_refuses_without_initial_receipt
test_spawn_ship_proceeds_past_the_gate_with_a_valid_initial_receipt
test_spawn_scout_is_exempt_from_the_initial_receipt
test_promote_refuses_without_initial_receipt
test_promote_proceeds_with_a_valid_initial_receipt
test_brief_scaffolds_carry_the_evidence_preservation_section
test_session_id_returns_the_env_session_id_when_present
test_session_id_reports_unavailable_with_a_reason
test_session_id_finds_the_newest_transcript_when_env_is_absent
echo "# all fm-preservation-gate tests passed"
