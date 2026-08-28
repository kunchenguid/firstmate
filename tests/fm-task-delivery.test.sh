#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across spawn, promotion, local landing, and project-mode resolution.
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
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
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

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
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
  local home meta out status blocked_data instructions_path project worktree origin
  home="$TMP_ROOT/promote/home"
  project="$TMP_ROOT/promote/project"
  worktree="$TMP_ROOT/promote/worktree"
  origin="$TMP_ROOT/promote/origin.git"
  mkdir -p "$home/state"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$worktree" HEAD
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=%s\nproject=%s\n' \
      "$worktree" "$project" > "$meta"
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

# The delivery contract only protects a worker that actually receives it. A promoted
# scout used to get a free-form hint instead of the mode-specific Definition of done,
# so it never saw the ask-user escalation rule or the --yes ban that every briefed
# no-mistakes worker gets. This drives the real promotion path, then runs the delivery command it
# prints against a capturing fm-send.sh, and asserts on the message the worker would
# actually receive - for every supported mode.
test_promotion_delivers_the_real_definition_of_done() {
  local home meta out sendroot payload mode id brief_dod delivered_dod project worktree origin
  home="$TMP_ROOT/promote-dod/home"
  sendroot="$TMP_ROOT/promote-dod/sendroot"
  project="$TMP_ROOT/promote-dod/project"
  worktree="$TMP_ROOT/promote-dod/worktree"
  origin="$TMP_ROOT/promote-dod/origin.git"
  mkdir -p "$home/state" "$sendroot/bin"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$worktree" HEAD
  cat > "$sendroot/bin/fm-send.sh" <<'STUB'
#!/usr/bin/env bash
# Capture the message a promoted worker would receive, instead of steering one.
printf '%s' "$2" > "$FM_TEST_CAPTURE"
STUB
  chmod +x "$sendroot/bin/fm-send.sh"

  for mode in no-mistakes direct-PR local-only; do
    id="promote-dod-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    meta="$home/state/$id.meta"
    printf 'window=fm-%s\nkind=scout\nworktree=%s\nproject=%s\n' \
      "$id" "$worktree" "$project" > "$meta"
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

    # Compare the public outputs of both real generation paths. The promoted
    # payload ends at its Definition of done, as does an ordinary generated
    # brief, so identical suffixes prove both workers receive the same contract.
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

test_promote_requires_origin_for_pr_backed_contracts() {
  local home meta out status project worktree mode
  home="$TMP_ROOT/promote-origin/home"
  project="$TMP_ROOT/promote-origin/project"
  worktree="$TMP_ROOT/promote-origin/worktree"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' '- project [local-only] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$project" worktree add --quiet --detach "$worktree" HEAD
  meta="$home/state/promote-origin-d2.meta"
  printf 'window=fm-promote-origin-d2\nkind=scout\nworktree=%s\nproject=%s\n' \
    "$worktree" "$project" > "$meta"

  for mode in direct-PR no-mistakes; do
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PROMOTE" promote-origin-d2 --mode "$mode" --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode promotion created a PR-backed contract without origin"
    assert_contains "$out" "has no origin remote" \
      "$mode promotion did not name its missing origin"
    assert_grep 'kind=scout' "$meta" "$mode missing-origin refusal changed the scout contract"
  done

  git -C "$project" remote add origin "file://$TMP_ROOT/promote-origin/missing.git"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-origin-d2 --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion created a PR-backed contract with a failing origin"
  assert_contains "$out" "could not fetch origin" \
    "PR-backed promotion did not verify that origin was fetchable"
  assert_grep 'kind=scout' "$meta" "failing-origin refusal changed the scout contract"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-origin-d2 --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "local-only promotion treated a failing configured origin as remote-less"
  assert_contains "$out" "could not fetch origin" \
    "local-only promotion bypassed validation of its configured origin"
  assert_grep 'kind=scout' "$meta" "local-only failing-origin refusal changed the scout contract"

  git clone --quiet --bare "$project" "$TMP_ROOT/promote-origin/unresolved.git"
  git -C "$TMP_ROOT/promote-origin/unresolved.git" symbolic-ref HEAD refs/heads/missing-default
  git -C "$project" remote set-url origin "file://$TMP_ROOT/promote-origin/unresolved.git"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-origin-d2 --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted an origin whose HEAD names no branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "PR-backed promotion did not validate origin's advertised default branch"
  assert_grep 'kind=scout' "$meta" "unresolved-default refusal changed the scout contract"

  git -C "$project" remote remove origin
  git -C "$project" config extensions.worktreeConfig true
  git -C "$project" config --worktree remote.backup.url "file://$TMP_ROOT/promote-origin/backup.git"
  git -C "$project" config --worktree remote.backup.fetch '+refs/heads/*:refs/remotes/backup/*'
  [ "$(git -C "$project" remote)" = backup ] \
    || fail "authoritative-project-only remote fixture was not configured"
  [ -z "$(git -C "$worktree" remote)" ] \
    || fail "authoritative-project-only remote leaked into the task worktree"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-origin-d2 --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "local-only promotion used fallback without proving the project had no remotes"
  assert_contains "$out" "configured remotes but no origin" \
    "local-only promotion did not inspect the authoritative project's remotes"
  assert_grep 'kind=scout' "$meta" "project-remote refusal changed the scout contract"
  git -C "$project" config --worktree --remove-section remote.backup

  printf '%s\n' '- project [no-mistakes] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-origin-d2 --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "no-mistakes project promoted through the remote-less local-only path"
  assert_contains "$out" "registered no-mistakes project 'project' requires a valid origin" \
    "promotion did not gate remote-less fallback on the registered project posture"
  assert_grep 'kind=scout' "$meta" "posture-gated refusal changed the scout contract"

  printf '%s\n' '- project [local-only] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-origin-d2 --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "local-only promotion should not require origin"
  assert_grep 'kind=ship' "$meta" "remote-less local-only promotion did not restore ship protection"
  assert_grep 'mode=local-only' "$meta" "remote-less local-only promotion did not record its contract"
  pass "fm-promote: every configured origin is validated and remote-less fallback proves both repositories"
}

test_local_landing_ignores_stale_remote_tracking_default() {
  local home project worktree meta out initial
  home="$TMP_ROOT/merge-local/home"
  project="$TMP_ROOT/merge-local/project"
  worktree="$TMP_ROOT/merge-local/worktree"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' '- project [local-only] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" branch trunk "$initial"
  git -C "$project" update-ref refs/remotes/origin/trunk "$initial"
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  git -C "$project" worktree add --quiet -b fm/merge-local-e1 "$worktree" main
  printf 'landed locally\n' > "$worktree/local.txt"
  git -C "$worktree" add local.txt
  git -C "$worktree" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-change
  meta="$home/state/merge-local-e1.meta"
  printf 'window=fm-merge-local-e1\nkind=ship\nmode=local-only\nworktree=%s\nproject=%s\n' \
    "$worktree" "$project" > "$meta"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$MERGE_LOCAL" merge-local-e1 2>&1) \
    || fail "remote-less local landing failed: $out"
  assert_contains "$out" "into local main" \
    "local landing selected the stale remote-tracking default"
  assert_grep 'landed locally' "$project/local.txt" \
    "local landing did not fast-forward main"
  [ "$(git -C "$project" rev-parse trunk)" = "$initial" ] \
    || fail "local landing moved stale trunk"
  pass "fm-merge-local: remote-less landing ignores stale remote-tracking defaults"
}

test_local_landing_requires_current_resolved_base() {
  local home project worktree origin updater meta out status initial
  home="$TMP_ROOT/merge-local-current-base/home"
  project="$TMP_ROOT/merge-local-current-base/project"
  worktree="$TMP_ROOT/merge-local-current-base/worktree"
  origin="$TMP_ROOT/merge-local-current-base/origin.git"
  updater="$TMP_ROOT/merge-local-current-base/updater"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' '- project [local-only] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet -b fm/merge-local-e2 "$worktree" main
  printf 'task change\n' > "$worktree/task.txt"
  git -C "$worktree" add task.txt
  git -C "$worktree" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm task-change
  git clone --quiet --bare "$project" "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git -C "$project" remote add origin "file://$origin"
  git clone --quiet "file://$origin" "$updater"
  printf 'upstream change\n' > "$updater/upstream.txt"
  git -C "$updater" add upstream.txt
  git -C "$updater" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm upstream-change
  git -C "$updater" push --quiet origin main
  meta="$home/state/merge-local-e2.meta"
  printf 'window=fm-merge-local-e2\nkind=ship\nmode=local-only\nworktree=%s\nproject=%s\n' \
    "$worktree" "$project" > "$meta"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$MERGE_LOCAL" merge-local-e2 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "local landing should refuse a task behind the resolved origin base"
  assert_contains "$out" "does not contain the current resolved base refs/remotes/origin/main" \
    "local landing did not explain its stale resolved base"
  [ "$(git -C "$project" rev-parse main)" = "$initial" ] \
    || fail "stale-base refusal moved local main"
  [ ! -e "$project/task.txt" ] || fail "stale-base refusal landed the task change"
  pass "fm-merge-local: landing requires the current resolved origin base"
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

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promotion_delivers_the_real_definition_of_done
test_promote_requires_origin_for_pr_backed_contracts
test_local_landing_ignores_stale_remote_tracking_default
test_local_landing_requires_current_resolved_base
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
