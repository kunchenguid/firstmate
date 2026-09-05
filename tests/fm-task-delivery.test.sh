#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# Promotion is also where a scout's base first acquires a delivery, so a mode that
# opens a pull request is refused while the commit the worktree was CREATED FROM -
# base= in the task record - is unreachable from origin/<default>. That base is the
# only commit a pull request can inherit, because the promoted worker is ordered to
# drop everything above it before branching. So a scout resting on origin's tip
# still promotes while the primary runs ahead with local-only landings, a scout that
# made scratch commits still promotes, a scout parked on a historical commit origin
# still contains still promotes, a base a rewritten-and-force-pushed default branch
# replaced is still caught, and a task record with no base= at all is reported
# rather than silently passed or blanket-refused.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

# Commit the staged index with a fixed identity.
promote_commit() {  # <dir> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

# A project with an origin remote, <pushed> commits origin has received, and
# <landed> further commits that never reach it - exactly what bin/fm-merge-local.sh
# leaves behind on a local-only project. Echoes the case root; the project lives in
# <root>/project and the bare forge in <root>/origin.git.
make_promote_project() {  # <name> <pushed-commits> <landed-commits>
  local name=$1 pushed=$2 landed=$3 root n=0
  root="$TMP_ROOT/$name"
  mkdir -p "$root"
  git init --quiet -b main "$root/project"
  printf 'base\n' > "$root/project/README.md"
  git -C "$root/project" add README.md
  promote_commit "$root/project" initial
  while [ "$n" -lt "$pushed" ]; do
    n=$((n + 1))
    printf 'pushed\n' > "$root/project/pushed-$n.txt"
    git -C "$root/project" add "pushed-$n.txt"
    promote_commit "$root/project" "push $n"
  done
  git clone --quiet --bare "$root/project" "$root/origin.git"
  git -C "$root/project" remote add origin "file://$root/origin.git"
  git -C "$root/project" fetch --quiet origin
  n=0
  while [ "$n" -lt "$landed" ]; do
    n=$((n + 1))
    printf 'landed\n' > "$root/project/landed-$n.txt"
    git -C "$root/project" add "landed-$n.txt"
    promote_commit "$root/project" "land $n"
  done
  printf '%s\n' "$root"
}

# Park a scout's worktree on one specific commit and register it as this task's,
# recording that commit as base= the way bin/fm-spawn.sh does. Pass a sixth
# argument of "no" for a task record that predates the recorded base.
add_scout_at() {  # <home> <id> <project-dir> <worktree> <commit-ish> [record-base]
  local home=$1 id=$2 proj=$3 wt=$4 at=$5 record=${6:-yes}
  mkdir -p "$home/state"
  write_brief "$home" "$id"
  git -C "$proj" worktree add --quiet --detach "$wt" "$at"
  {
    printf 'window=fm-%s\nkind=scout\nworktree=%s\n' "$id" "$wt"
    [ "$record" = no ] || printf 'base=%s\n' "$(git -C "$wt" rev-parse HEAD)"
  } > "$home/state/$id.meta"
}

run_promote() {  # <home> <promote-args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" "$@" 2>&1
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise the delivery contract.\n\n## Firstmate spec\nVerify the selected delivery behavior.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

fill_brief_subsections() {  # <file> <intent> <spec>
  local file=$1 intent=$2 spec=$3 content
  content=$(cat "$file")
  content=${content//'{TASK}'/$intent}
  content=${content//'{FIRSTMATE_SPEC}'/$spec}
  printf '%s\n' "$content" > "$file"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status blocked_data instructions_path
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"
  write_brief "$home" promote-d1

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  blocked_data="$home/data-blocked"
  printf 'not a directory\n' > "$blocked_data"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$blocked_data" \
    "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without writable instruction storage should exit non-zero"
  assert_grep 'kind=scout' "$meta" "failed instruction publication still promoted the task"
  assert_no_grep '^mode=' "$meta" "failed instruction publication recorded a delivery mode"
  assert_no_grep '^yolo=' "$meta" "failed instruction publication recorded a merge posture"

  instructions_path="$home/data/promote-d1/ship-instructions.md"
  mkdir -p "$instructions_path"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion over an instruction directory should exit non-zero"
  assert_contains "$out" "ship instructions path is a directory" \
    "promotion did not explain the invalid instruction destination"
  assert_grep 'kind=scout' "$meta" "invalid instruction destination still promoted the task"
  assert_no_grep '^mode=' "$meta" "invalid instruction destination recorded a delivery mode"
  assert_no_grep '^yolo=' "$meta" "invalid instruction destination recorded a merge posture"
  rmdir "$instructions_path"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

# A symlink at state/<id>.meta is the containment hazard the shared publisher
# refuses: promotion must not rewrite the symlink target in place.
# A scout records no delivery posture, so bin/fm-spawn.sh was free to base its
# worktree on the primary checkout's default branch. Promotion decides the
# delivery, so it re-reads that base: a pull-request mode must not branch from
# commits origin has never seen, or the PR publishes every one of them.
test_promote_refuses_a_pr_delivery_on_unpushed_local_history() {
  local root home meta wt before out status
  root=$(make_promote_project promote-unpushed 0 2)
  home="$root/home"
  wt="$root/wt"
  meta="$home/state/promote-u1.meta"
  add_scout_at "$home" promote-u1 "$root/project" "$wt" main
  before=$(git -C "$wt" rev-parse HEAD)

  out=$(run_promote "$home" promote-u1 --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion into a PR delivery accepted a base origin has never seen"
  assert_contains "$out" "carries 2 commits origin/main does not" \
    "the refusal did not carry the exact count of unpushed commits"
  assert_contains "$out" "opens a pull request against origin" \
    "the refusal did not name the delivery that makes the base unusable"
  assert_grep 'kind=scout' "$meta" "a refused promotion still flipped the task record"
  assert_no_grep '^mode=' "$meta" "a refused promotion recorded a delivery mode"
  [ ! -e "$home/data/promote-u1/ship-instructions.md" ] \
    || fail "a refused promotion still published ship instructions"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$before" ] \
    || fail "promotion moved the scout's worktree while refusing"

  # The same base is fine for a delivery that never pushes, so the refusal is
  # scoped to the delivery rather than to the repository state.
  out=$(run_promote "$home" promote-u1 --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "a local-only promotion should accept the primary's landed base"$'\n'"$out"
  assert_grep 'kind=ship' "$meta" "the local-only promotion did not flip the task record"
  assert_grep 'mode=local-only' "$meta" "the local-only promotion did not record its delivery"
  pass "fm-promote: a pull-request delivery is refused while the base carries unpushed local history"
}

# What a promotion can publish is decided by the base this task was spawned from,
# never by the primary checkout's branch. A scout based on origin's tip carries
# nothing origin lacks, so an unrelated local-only landing moving that branch
# forward must not block it: there would be no correct remedy if it did, because
# pushing would publish work the captain deliberately keeps off origin and
# --mode local-only changes the delivery contract instead of fixing the base.
test_promote_allows_a_pr_delivery_from_a_base_origin_already_has() {
  local root home meta wt forge out status
  root=$(make_promote_project promote-at-origin 0 2)
  home="$root/home"
  wt="$root/wt"
  meta="$home/state/promote-o1.meta"
  forge=$(git -C "$root/project" rev-parse origin/main)
  add_scout_at "$home" promote-o1 "$root/project" "$wt" "$forge"
  [ "$(git -C "$root/project" rev-parse main)" != "$forge" ] \
    || fail "fixture did not leave the primary's branch ahead of the frozen origin tip"

  out=$(run_promote "$home" promote-o1 --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a scout resting on origin's tip was refused over the primary's branch"$'\n'"$out"
  assert_grep 'kind=ship' "$meta" "the promotion did not flip the task record"
  assert_grep 'mode=no-mistakes' "$meta" "the promotion did not record its delivery"
  [ -f "$home/data/promote-o1/ship-instructions.md" ] \
    || fail "the promotion published no ship instructions"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$forge" ] \
    || fail "promotion moved the scout's worktree"
  pass "fm-promote: a base origin already has promotes into a PR delivery however far the primary has run ahead"
}

# A scout parked on a specific historical commit is auditing that base on purpose.
# Origin still contains it, so its branch could publish nothing origin lacks and the
# promotion must go through.
test_promote_allows_a_pr_delivery_from_a_historical_base_origin_contains() {
  local root home meta wt historical out status
  root=$(make_promote_project promote-historical 2 0)
  home="$root/home"
  wt="$root/wt"
  meta="$home/state/promote-h1.meta"
  historical=$(git -C "$root/project" rev-parse 'origin/main~2')
  add_scout_at "$home" promote-h1 "$root/project" "$wt" "$historical"

  out=$(run_promote "$home" promote-h1 --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "a scout auditing a historical base origin contains was refused"$'\n'"$out"
  assert_grep 'kind=ship' "$meta" "the promotion did not flip the task record"
  assert_grep 'mode=direct-PR' "$meta" "the promotion did not record its delivery"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$historical" ] \
    || fail "promotion moved the scout off the historical base it was auditing"
  pass "fm-promote: a historical base origin still contains promotes into a PR delivery"
}

# The mirror case a count taken on a live ref cannot see: rewriting the default
# branch and force-pushing it leaves origin and local identical, so that count reads
# zero while this task's recorded base is still the commit the rewrite replaced.
# Passing it through would publish exactly those commits inside the PR, silently.
test_promote_refuses_a_pr_delivery_on_a_base_the_rewrite_replaced() {
  local root home meta wt initial before out status
  root=$(make_promote_project promote-rewritten 2 0)
  home="$root/home"
  wt="$root/wt"
  meta="$home/state/promote-r1.meta"
  initial=$(git -C "$root/project" rev-parse 'origin/main~2')
  add_scout_at "$home" promote-r1 "$root/project" "$wt" origin/main
  before=$(git -C "$wt" rev-parse HEAD)

  git -C "$root/project" reset --quiet --hard "$initial"
  printf 'rewritten\n' > "$root/project/rewritten.txt"
  git -C "$root/project" add rewritten.txt
  promote_commit "$root/project" "rewrite the published history"
  git -C "$root/project" push --quiet --force origin main
  [ "$(git -C "$root/project" rev-parse main)" = "$(git -C "$root/project" rev-parse origin/main)" ] \
    || fail "fixture did not leave the local and remote default branches identical"
  [ "$(git -C "$root/project" rev-list --count origin/main..main)" = 0 ] \
    || fail "fixture left the primary's branch ahead, so the old count would have caught this case anyway"

  out=$(run_promote "$home" promote-r1 --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted a base the rewrite left behind, which the PR would publish"
  assert_contains "$out" "carries 2 commits origin/main does not" \
    "the refusal did not count the commits the recorded base holds outside origin"
  assert_contains "$out" "opens a pull request against origin" \
    "the refusal did not name the delivery that makes the base unusable"
  assert_grep 'kind=scout' "$meta" "a refused promotion still flipped the task record"
  assert_no_grep '^mode=' "$meta" "a refused promotion recorded a delivery mode"
  [ ! -e "$home/data/promote-r1/ship-instructions.md" ] \
    || fail "a refused promotion still published ship instructions"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$before" ] \
    || fail "promotion moved the scout's worktree while refusing"
  pass "fm-promote: a base a rewritten-and-pushed default branch replaced is refused for a PR delivery"
}

# A scout is told its worktree is a laboratory and that scratch commits are free,
# and the ship instructions promotion itself writes order the promoted worker to
# return to a clean default-branch base and leave those commits behind. Nothing
# above the base can reach the pull request, so the scout that committed while
# reproducing a bug - the one scout actually worth promoting - must go through.
test_promote_allows_a_pr_delivery_after_the_scout_made_scratch_commits() {
  local root home meta wt base out status
  root=$(make_promote_project promote-scratch 1 0)
  home="$root/home"
  wt="$root/wt"
  meta="$home/state/promote-s1.meta"
  base=$(git -C "$root/project" rev-parse origin/main)
  add_scout_at "$home" promote-s1 "$root/project" "$wt" "$base"
  [ "$(git -C "$root/project" rev-parse main)" = "$base" ] \
    || fail "fixture left the primary ahead of origin, so this case would not isolate the scratch commits"
  printf 'reproduction\n' > "$wt/repro.txt"
  git -C "$wt" add repro.txt
  promote_commit "$wt" "reproduce the bug"
  printf 'more scratch\n' > "$wt/scratch.txt"
  git -C "$wt" add scratch.txt
  promote_commit "$wt" "scratch experiment"
  [ "$(git -C "$wt" rev-list --count "origin/main..HEAD")" = 2 ] \
    || fail "fixture did not leave two scratch commits above the recorded base"

  out=$(run_promote "$home" promote-s1 --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a scout was refused over the scratch commits its own brief authorizes"$'\n'"$out"
  assert_grep 'kind=ship' "$meta" "the promotion did not flip the task record"
  assert_grep 'mode=no-mistakes' "$meta" "the promotion did not record its delivery"
  [ -f "$home/data/promote-s1/ship-instructions.md" ] \
    || fail "the promotion published no ship instructions"
  pass "fm-promote: scratch commits above a clean base do not block a PR delivery"
}

# A task spawned before the base was recorded cannot be checked either way. Silently
# passing it would reopen the hazard and blanket-refusing it would strand every such
# task, so promotion proceeds and says so.
test_promote_reports_a_task_with_no_recorded_spawn_base() {
  local root home meta wt out status
  root=$(make_promote_project promote-norecord 0 2)
  home="$root/home"
  wt="$root/wt"
  meta="$home/state/promote-n1.meta"
  add_scout_at "$home" promote-n1 "$root/project" "$wt" main no
  ! grep -q '^base=' "$meta" || fail "the fixture recorded a spawn base it was meant to omit"

  out=$(run_promote "$home" promote-n1 --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "a task with no recorded spawn base was blanket-refused"$'\n'"$out"
  assert_contains "$out" "records no spawn base" \
    "promotion did not report that the base could not be checked"
  assert_contains "$out" "opens a pull request against origin" \
    "the report did not name the delivery whose base went unchecked"
  assert_grep 'kind=ship' "$meta" "the reported promotion did not flip the task record"
  assert_grep 'mode=direct-PR' "$meta" "the reported promotion did not record its delivery"
  pass "fm-promote: a task with no recorded spawn base is reported, not silently passed or refused"
}

test_promote_refuses_a_symlinked_task_record() {
  local home meta target original out status leftover
  home="$TMP_ROOT/promote-symlink/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-sym.meta"
  target="$TMP_ROOT/promote-symlink/foreign-task-record"
  original="$TMP_ROOT/promote-symlink/foreign-task-record.expected"
  printf '%s\n' 'window=fm-promote-sym' 'kind=scout' 'worktree=/tmp/wt' > "$target"
  cp "$target" "$original"
  ln -s "$target" "$meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-sym --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion through a symlink record should refuse"
  assert_contains "$out" "task record" "promotion did not identify the unpublished task record"
  [ -L "$meta" ] || fail "promotion replaced or removed the symlink record"
  cmp -s "$target" "$original" \
    || fail "promotion rewrote the symlink target in place"
  assert_absent "$home/data/promote-sym/ship-instructions.md" \
    "refused promotion published ship instructions"
  leftover=$(find "$home/state" -maxdepth 1 -name '.*.meta.promote.*' -print 2>/dev/null || true)
  [ -z "$leftover" ] || fail "promotion left a staging file after a refused publish: $leftover"
  pass "fm-promote: a symlinked task record is refused and its target is left untouched"
}

# The delivery contract only protects a worker that actually receives it. A promoted
# scout used to get a free-form hint instead of the mode-specific Definition of done,
# so it never saw the ask-user escalation rule or the --yes ban that every briefed
# no-mistakes worker gets. This drives the real promotion path, then runs the delivery command it
# prints against a capturing fm-send.sh, and asserts on the message the worker would
# actually receive - for every supported mode.
test_promotion_delivers_the_real_definition_of_done() {
  local home meta out sendroot payload mode id brief_dod delivered_dod
  home="$TMP_ROOT/promote-dod/home"
  sendroot="$TMP_ROOT/promote-dod/sendroot"
  mkdir -p "$home/state" "$sendroot/bin"
  cat > "$sendroot/bin/fm-send.sh" <<'STUB'
#!/usr/bin/env bash
# Capture the message a promoted worker would receive, instead of steering one.
printf '%s' "$2" > "$FM_TEST_CAPTURE"
STUB
  chmod +x "$sendroot/bin/fm-send.sh"

  for mode in no-mistakes direct-PR local-only; do
    id="promote-dod-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    meta="$home/state/$id.meta"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
    FM_HOME="$home" "$BRIEF" "$id" fixture-project --scout >/dev/null 2>&1 \
      || fail "$mode: scout brief generation should succeed"
    fill_brief_subsections "$home/data/$id/brief.md" \
      "Ship the delivery-contract change." "Preserve the selected delivery mode."
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode "$mode" --yolo off 2>&1) \
      || fail "$mode: promotion should succeed"

    payload="$TMP_ROOT/promote-dod/payload-$id"
    # Run the delivery command promotion printed, so the assertions below are made
    # against the message the worker receives rather than the script's own text.
    ( cd "$sendroot" \
      && FM_TEST_CAPTURE="$payload" \
         eval "$(printf '%s\n' "$out" | sed -n 's/^next: //p' | grep 'fm-send\.sh')" ) \
      || fail "$mode: promotion's delivery command did not run"
    assert_present "$payload" "$mode: promotion delivered no message to the worker"

    grep -qx "Delivery contract: mode=$mode" "$payload" \
      || fail "$mode: promoted worker did not receive the machine-readable delivery contract"
    assert_grep "# Definition of done" "$payload" \
      "$mode: promoted worker did not receive a Definition of done"
    assert_grep "pwd -P" "$payload" \
      "$mode: promoted worker was not told to verify its physical worktree"
    assert_grep "git rev-parse --show-toplevel" "$payload" \
      "$mode: promoted worker was not told to verify its repository root"
    assert_grep "If either does not resolve to the worktree you were launched in, stop and escalate to firstmate" "$payload" \
      "$mode: promoted worker was not told to stop for any wrong worktree"
    assert_grep "git checkout -b fm/$id" "$payload" \
      "$mode: promoted worker was not told to leave the scratch base for its ship branch"
    assert_grep "## Captain's intent" "$payload" \
      "$mode: promoted worker did not receive the Captain's intent subsection"
    assert_grep "## Firstmate spec" "$payload" \
      "$mode: promoted worker did not receive the Firstmate spec subsection"

    # Compare the public outputs of both real generation paths. The promoted
    # payload ends at its Definition of done, as does an ordinary generated
    # brief, so identical suffixes prove both workers receive the same contract.
    rm "$home/data/$id/brief.md"
    FM_HOME="$home" "$BRIEF" "$id" fixture-project --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ordinary ship brief generation should succeed"
    brief_dod="$TMP_ROOT/promote-dod/brief-dod-$id"
    delivered_dod="$TMP_ROOT/promote-dod/delivered-dod-$id"
    awk '/^# Definition of done$/ { emit=1 } emit' "$home/data/$id/brief.md" > "$brief_dod"
    awk '/^# Definition of done$/ { emit=1 } emit' "$payload" > "$delivered_dod"
    cmp -s "$brief_dod" "$delivered_dod" \
      || fail "$mode: promotion and ordinary brief generation delivered different Definitions of done"
  done

  payload="$TMP_ROOT/promote-dod/payload-promote-dod-no-mistakes"
  assert_grep "ask-user findings are never yours to answer: escalate to firstmate" "$payload" \
    "promoted no-mistakes worker did not receive the ask-user escalation rule"
  assert_grep "write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority)" "$payload" \
    "promoted no-mistakes worker did not receive the ask-user-only snapshot contract"
  assert_grep 'needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='"$home/data/promote-dod-no-mistakes/nm-<run>-findings.txt" "$payload" \
    "promoted no-mistakes worker did not receive the structured escalation event"
  assert_grep "NEVER pass \`--yes\` (or \`-y\`)" "$payload" \
    "promoted no-mistakes worker did not receive the --yes prohibition"
  assert_grep "It is banned fleet-wide" "$payload" \
    "promoted no-mistakes worker did not receive the fleet-wide ban wording"

  payload="$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr"
  assert_grep "supersede the scout delivery rules and report-based Definition of done" "$payload" \
    "promoted worker retained the scout delivery contract"
  assert_grep "status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule" "$payload" \
    "promoted worker lost the scout protocols and safety rules that still apply"

  # The faster paths keep their own contracts rather than inheriting the pipeline's.
  assert_grep "Do NOT run /no-mistakes" "$payload" \
    "promoted direct-PR worker lost its no-pipeline contract"
  assert_grep "Do NOT push, do NOT open a PR, do NOT merge" "$TMP_ROOT/promote-dod/payload-promote-dod-local-only" \
    "promoted local-only worker lost its no-remote contract"
  assert_no_grep "no-mistakes axi respond" "$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr" \
    "promoted direct-PR worker received the pipeline gate contract"
  pass "fm-promote: a promoted worker receives the same mode-specific delivery contract a briefed one does"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

# Spawn and promotion refuse leftover Task-subsection placeholders through the
# public brief/spawn/promote path. Filling both subsections lets the spawn
# delivery checks proceed (the fake tmux still fails later).
test_spawn_and_promote_require_filled_task_subsections() {
  local rec home proj fakebin out status id brief meta intent_body spec_body authorized
  rec=$(make_home subsections)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  id=delivery-unfilled-ship
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "unfilled ship brief should still scaffold"
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn of an unfilled ship brief should exit non-zero"
  assert_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "unfilled ship spawn did not name the leftover placeholders"
  assert_contains "$out" "## Captain's intent" \
    "unfilled ship spawn did not name the intent subsection to fill"
  assert_absent "$home/state/$id.meta" "unfilled ship spawn wrote task metadata"

  id=delivery-filled-ship
  FM_HOME="$home" "$BRIEF" "$id" proj --mode direct-PR >/dev/null 2>&1 \
    || fail "filled-ship brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" \
    "Fix replacement of \`{TASK}\` in Herdr briefs." \
    "Keep literal \`{FIRSTMATE_SPEC}\` examples intact."
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "a filled ship brief mentioning placeholder tokens was refused as unfilled"
  assert_not_contains "$out" "must contain nonempty" \
    "a filled ship brief mentioning placeholder tokens failed content validation"

  id=delivery-legacy-fenced-headings
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Preserve this legacy task containing a format example.

```markdown
## Captain's intent
Example intent
## Firstmate spec
Example specification
```

# Definition of done
Delivery contract: mode=direct-PR
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "must contain nonempty" \
    "fenced example headings made a filled legacy Task fail validation"
  assert_not_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "fenced example headings made a filled legacy Task look unfilled"

  id=delivery-legacy-no-mistakes
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Captain: Fix the legacy dispatch boundary.
Do not copy this Firstmate-authored constraint into intent.

# Definition of done
Delivery contract: mode=no-mistakes
Pass the entire Task as --intent.
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "has no provenance-marked captain words" \
    "legacy no-mistakes spawn rejected explicitly marked captain words"
  assert_present "$home/data/$id/launch-brief.md" \
    "marked legacy spawn did not render a current launch contract"
  assert_grep "supersedes every earlier brief instruction about constructing \`--intent\`" \
    "$home/data/$id/launch-brief.md" \
    "marked legacy spawn did not override its stale intent instruction"
  assert_grep "plus any later words the captain actually supplied" \
    "$home/data/$id/launch-brief.md" \
    "marked legacy launch contract excluded later captain clarifications"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit && /^$/ { exit } emit { print }' "$home/data/$id/launch-brief.md")
  assert_contains "$authorized" "Fix the legacy dispatch boundary." \
    "marked legacy launch contract omitted captain words"
  assert_not_contains "$authorized" "Firstmate-authored constraint" \
    "marked legacy launch contract included mixed Task specification"

  id=delivery-migrated-stale-no-mistakes
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the migrated dispatch boundary.

## Firstmate spec
Preserve the existing compatibility path.

# Definition of done
Delivery contract: mode=no-mistakes
Pass the entire Task and every Firstmate requirement as --intent.
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  assert_present "$home/data/$id/launch-brief.md" \
    "migrated subsection brief did not receive the current launch contract"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit && /^$/ { exit } emit { print }' "$home/data/$id/launch-brief.md")
  assert_contains "$authorized" "Fix the migrated dispatch boundary." \
    "migrated launch contract omitted Captain's intent"
  assert_not_contains "$authorized" "Preserve the existing compatibility path." \
    "migrated launch contract included Firstmate spec in intent"
  assert_grep "supersedes every earlier brief instruction about constructing \`--intent\`" \
    "$home/data/$id/launch-brief.md" \
    "migrated launch contract did not supersede its stale mixed-Task DoD"
  assert_grep "plus any later words the captain actually supplied" \
    "$home/data/$id/launch-brief.md" \
    "migrated launch contract excluded later captain clarifications"
  assert_grep "The Definition of done's rule that \`--intent\` must be self-sufficient still governs" \
    "$home/data/$id/launch-brief.md" \
    "migrated launch contract's overlay dropped the self-sufficiency pointer"

  id=delivery-legacy-unmarked-no-mistakes
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Fix the legacy dispatch boundary.
Do not copy this Firstmate-authored constraint into intent.

# Definition of done
Delivery contract: mode=no-mistakes

# Notes
## Captain's intent
Unrelated notes must not become task intent.
## Firstmate spec
Unrelated notes must not satisfy task validation.
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "unmarked legacy no-mistakes spawn should require provenance"
  assert_contains "$out" "has no provenance-marked captain words" \
    "unmarked legacy no-mistakes spawn did not explain the missing intent provenance"
  assert_absent "$home/state/$id.meta" "unmarked legacy no-mistakes spawn wrote task metadata"

  id=delivery-unfilled-scout
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null 2>&1 \
    || fail "unfilled scout brief should still scaffold"
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn of an unfilled scout brief should exit non-zero"
  assert_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "unfilled scout spawn did not name the leftover placeholders"
  assert_absent "$home/state/$id.meta" "unfilled scout spawn wrote task metadata"

  id=delivery-empty-ship
  FM_HOME="$home" "$BRIEF" "$id" proj --mode direct-PR >/dev/null 2>&1 \
    || fail "empty-ship brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" "" ""
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn of empty Task subsections should exit non-zero"
  assert_contains "$out" "must contain nonempty ## Captain's intent and ## Firstmate spec" \
    "empty Task subsections were not rejected semantically"
  assert_absent "$home/state/$id.meta" "empty-subsection spawn wrote task metadata"

  id=promote-unfilled-e1
  meta="$home/state/$id.meta"
  mkdir -p "$home/state"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null 2>&1 \
    || fail "unfilled promote scout brief should scaffold"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion of an unfilled scout brief should exit non-zero"
  assert_contains "$out" "preserve the original ask in ## Captain's intent" \
    "unfilled promotion did not preserve the original captain ask boundary"
  assert_contains "$out" "promotion generates a separate ship-time spec" \
    "unfilled promotion did not distinguish scout and ship Firstmate specs"
  assert_grep 'kind=scout' "$meta" "unfilled promotion still changed the task record"

  id=promote-missing-brief
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without a scout brief should exit non-zero"
  assert_contains "$out" "must contain nonempty" \
    "promotion without a scout brief did not reject missing task content"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "promotion without a scout brief fabricated ship instructions"
  assert_grep 'kind=scout' "$meta" "missing-brief promotion changed the task record"

  id=promote-unmarked-legacy
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Investigate the unmarked legacy failure.
Keep this Firstmate constraint out of captain intent.

# Notes
## Captain's intent
Unrelated notes are not the original ask.
## Firstmate spec
Unrelated notes are not the task specification.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without provenance-marked captain intent should fail"
  assert_contains "$out" "has no provenance-marked Captain's intent" \
    "unmarked legacy promotion did not explain the missing intent provenance"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "unmarked legacy promotion published empty captain intent"
  assert_grep 'kind=scout' "$meta" "unmarked legacy promotion changed the task record"

  id=promote-filled-e2
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null 2>&1 \
    || fail "filled promote scout brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" \
    "Investigate why the identity check is failing." \
    "Ship the identity-check fix without adding a classifier."
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion of a filled scout brief should succeed"
  assert_grep 'kind=ship' "$meta" "filled promotion did not restore ship teardown protection"
  brief="$home/data/$id/ship-instructions.md"
  assert_grep "Investigate why the identity check is failing." "$brief" \
    "promotion did not preserve the original Captain's intent"
  assert_no_grep "Ship the identity-check fix without adding a classifier." "$brief" \
    "promotion reused the scout-time Firstmate spec as ship instructions"
  spec_body=$(awk '$0 == "## Firstmate spec" { emit=1; next } emit && /^# / { exit } emit { print }' "$brief")
  assert_contains "$spec_body" "Verify isolation before anything else" \
    "promotion did not place its ship-time instructions in Firstmate spec"
  assert_no_grep "SCOUT task" "$brief" \
    "promotion copied the scout Setup/Rules contract into Firstmate spec"
  assert_no_grep "# Setup" "$brief" \
    "promotion copied a later brief section into a Task subsection"

  id=promote-nested-spec
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Ship the parser without losing detailed requirements.

## Firstmate spec
Keep this opening requirement.

### Acceptance criteria
Keep this nested requirement too.

```markdown
# This example heading is fenced content.
```

Keep this closing requirement.

# Setup
This scout-only setup must not become the spec.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion with nested and fenced spec content should succeed"
  brief="$home/data/$id/ship-instructions.md"
  assert_grep "Ship the parser without losing detailed requirements." "$brief" \
    "promotion discarded Captain's intent while replacing the scout spec"
  assert_no_grep "### Acceptance criteria" "$brief" \
    "promotion reused nested scout acceptance criteria as ship instructions"
  assert_no_grep "# This example heading is fenced content." "$brief" \
    "promotion reused a fenced scout-spec example as ship instructions"
  assert_no_grep "Keep this closing requirement." "$brief" \
    "promotion reused trailing scout spec as ship instructions"
  assert_no_grep "This scout-only setup must not become the spec." "$brief" \
    "promotion copied the following top-level section into Firstmate spec"

  id=promote-legacy-e3
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Captain's words: Investigate the fold's session-floor refusal.
Captain: Preserve the existing successful session behavior.

Reproduce the refusal before changing code.
Ship the narrow session-floor fix with a regression test.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "promotion of a pre-subsection scout brief should succeed"
  brief="$home/data/$id/ship-instructions.md"
  intent_body=$(awk '$0 == "## Captain'\''s intent" { emit=1; next } emit && /^## / { exit } emit { print }' "$brief")
  spec_body=$(awk '$0 == "## Firstmate spec" { emit=1; next } emit && /^# / { exit } emit { print }' "$brief")
  assert_contains "$intent_body" "Investigate the fold's session-floor refusal." \
    "legacy promotion discarded provenance-marked captain words"
  assert_contains "$intent_body" "Preserve the existing successful session behavior." \
    "legacy promotion truncated multiline provenance-marked captain words"
  assert_not_contains "$intent_body" "Reproduce the refusal" \
    "legacy promotion classified unmarked mixed Task text as captain intent"
  assert_not_contains "$spec_body" "Reproduce the refusal before changing code." \
    "legacy promotion reused the scout-time mixed Task as ship instructions"
  assert_not_contains "$spec_body" "Ship the narrow session-floor fix with a regression test." \
    "legacy promotion reused old build instructions as the ship spec"
  assert_contains "$spec_body" "Verify isolation before anything else" \
    "legacy promotion did not place promotion ship instructions in Firstmate spec"
  assert_not_contains "$spec_body" "This is a SCOUT task" \
    "legacy promotion copied the scout Setup section into Firstmate spec"
  pass "fm-spawn/fm-promote: leftover Task placeholders are refused until both subsections are filled"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_refuses_a_pr_delivery_on_unpushed_local_history
test_promote_allows_a_pr_delivery_from_a_base_origin_already_has
test_promote_allows_a_pr_delivery_from_a_historical_base_origin_contains
test_promote_refuses_a_pr_delivery_on_a_base_the_rewrite_replaced
test_promote_allows_a_pr_delivery_after_the_scout_made_scratch_commits
test_promote_reports_a_task_with_no_recorded_spawn_base
test_promote_refuses_a_symlinked_task_record
test_promotion_delivers_the_real_definition_of_done
test_project_mode_maps_the_conditional_policy
test_spawn_and_promote_require_filled_task_subsections
echo "# all fm-task-delivery tests passed"
