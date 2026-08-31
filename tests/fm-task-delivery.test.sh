#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
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
    write_brief "$home" "delivery-required-$n" direct-PR
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode direct-PR|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of direct-PR, local-only
unknown yolo|--mode direct-PR --yolo maybe|--yolo must be on or off
retired mode|--mode no-mistakes-prod-only --yolo off|no-mistakes is retired
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

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode direct-PR --yolo off)
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
  write_brief "$home" delivery-mismatch-b1 local-only
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=local-only but this spawn passed --mode direct-PR" \
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
# unregistered project resolves to the same direct-PR standing default
# (AGENTS.md section 7), so a local-only downgrade there is announced too.
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
direct-PR project shipped local-only|- proj [direct-PR] - fixture (added 2026-01-01)|local-only|notice|direct-PR
direct-PR project shipped direct-PR|- proj [direct-PR] - fixture (added 2026-01-01)|direct-PR|quiet|direct-PR
local-only project shipped direct-PR|- proj [local-only] - fixture (added 2026-01-01)|direct-PR|quiet|local-only
unregistered project defaults direct-PR|- other [direct-PR] - fixture (added 2026-01-01)|local-only|notice|direct-PR
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
  assert_contains "$out" "no-mistakes is retired" "promote did not refuse the retired mode"

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
# scout used to get a free-form hint instead of the mode-specific Definition of done.
# This drives the real promotion path, then runs the delivery command it prints
# against a capturing fm-send.sh, and asserts on the message the worker would
# actually receive for every active mode.
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

  for mode in direct-PR local-only; do
    id="promote-dod-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    meta="$home/state/$id.meta"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
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

  payload="$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr"
  assert_grep "supersede the scout delivery rules and report-based Definition of done" "$payload" \
    "promoted worker retained the scout delivery contract"
  assert_grep "status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule" "$payload" \
    "promoted worker lost the scout protocols and safety rules that still apply"

  # Each active path keeps its own delivery contract.
  assert_grep "Do NOT run /no-mistakes" "$payload" \
    "promoted direct-PR worker lost its no-pipeline contract"
  assert_grep "Do NOT push, do NOT open a PR, do NOT merge" "$TMP_ROOT/promote-dod/payload-promote-dod-local-only" \
    "promoted local-only worker lost its no-remote contract"
  assert_no_grep "no-mistakes axi respond" "$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr" \
    "promoted direct-PR worker received the pipeline gate contract"
  pass "fm-promote: a promoted worker receives the same mode-specific delivery contract a briefed one does"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# legacy annotations, maps them to direct-PR for active callers, and exposes the
# raw annotation for migration inventory.
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
  [ "$out" = "direct-PR off" ] || fail "conditional policy did not map to direct-PR (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  assert_contains "$err" "inactive migration compatibility" "legacy mapping did not carry its compatibility warning"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "direct-PR on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "a typo'd mode no longer falls back to direct-PR"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: legacy annotations are labeled, mapped for active callers, and readable raw"
}

# The migration retires no-mistakes as an active task mode without making old
# registries unreadable. New task entrypoints refuse it; the registry parser
# maps both legacy spellings to direct-PR and labels the compatibility warning.
test_no_mistakes_is_inactive_compatibility_only() {
  local rec home proj fakebin out status
  rec=$(make_home retired-mode "- proj [no-mistakes] - legacy fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" retired-mode-e1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" retired-mode-e1 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "retired no-mistakes task mode should exit non-zero"
  assert_contains "$out" "no-mistakes is retired; use direct-PR" \
    "retired task mode refusal did not name the active replacement"

  out=$(FM_HOME="$home" "$PROJECT_MODE" proj 2>"$home/legacy.err")
  [ "$out" = "direct-PR off" ] \
    || fail "legacy registry mode did not map to direct-PR (got '$out')"
  assert_grep "inactive migration compatibility" "$home/legacy.err" \
    "legacy registry mapping was not explicitly labeled inactive compatibility"
  pass "no-mistakes is refused for active tasks and retained only as labeled registry compatibility"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_refuses_a_symlinked_task_record
test_promotion_delivers_the_real_definition_of_done
test_project_mode_maps_the_conditional_policy
test_no_mistakes_is_inactive_compatibility_only
echo "# all fm-task-delivery tests passed"
