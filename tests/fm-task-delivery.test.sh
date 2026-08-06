#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice - except
# for gate-merge, whose worker lands on the default branch with no approval step, so
# there the registered posture and the registered gate command are enforced.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
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

# A gate-merge brief carries its gate command twice, so the fixture writes both and
# lets them differ: the step defaults to the contract line's command, and an explicit
# fifth argument stands in for a hand-patched or missing step.
write_brief() {  # <home> <id> [<recorded-mode>] [<recorded-gate>] [<gate-step-command>]
  local home=$1 id=$2 mode=${3:-} gate=${4:-} step=${5-${4-}}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
    [ -z "$gate" ] || printf 'Delivery contract: gate=%s\n' "$gate"
    # shellcheck disable=SC2016  # the literal backticks are the brief's fixed step shape
    [ -z "$step" ] || printf 'Run the gate from THIS worktree, with your branch checked out: `%s`\n' "$step"
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
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only, gate-merge
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

  # The contract line is counted before it is read, so a second, contradictory one is
  # a refusal rather than something a first-match comparison reads past.
  write_brief "$home" delivery-dup-b4 no-mistakes
  printf 'Delivery contract: mode=local-only\n' >> "$home/data/delivery-dup-b4/brief.md"
  out=$(run_spawn "$home" "$fakebin" delivery-dup-b4 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief carrying two delivery contract lines should exit non-zero"
  assert_contains "$out" "must record its delivery contract exactly once" \
    "the refusal did not say the contract line must appear exactly once"
  assert_contains "$out" "it carries 2" "the refusal did not name how many contract lines the brief carries"
  assert_absent "$home/state/delivery-dup-b4.meta" "a refused duplicate-contract spawn wrote task metadata"
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
gate-merge project shipped no-mistakes|- proj [gate-merge] - fixture (added 2026-01-01)|no-mistakes|quiet|gate-merge
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# gate-merge is the one mode whose worker lands on the default branch with no approval
# step in front of it, so it is the one downgrade that is checked instead of announced:
# a conflicting registered posture refuses, and the brief may land only with the gate
# command that project's registry entry authorizes. The brief carries that command in
# two places - the machine-readable contract line and the step the worker follows - so
# both are checked; verifying one would leave the other hand-patchable into an
# unauthorized landing. A posture that cannot be read at all still only warns, because
# refusing every unregistered project would block legitimate first-time work.
test_gate_merge_spawn_is_checked_against_the_registry() {
  local rec home proj fakebin out status
  local gate='./scripts/merge-gate.sh --push'

  rec=$(make_home gate-conflict "- proj [no-mistakes] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-gate-e1 gate-merge "$gate"
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e1 "$proj" claude --mode gate-merge --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a gate-merge spawn against a conflicting registered posture should exit non-zero"
  assert_contains "$out" "delivery-gate-e1 passed --mode gate-merge but proj is registered no-mistakes" \
    "the refusal did not name the project, its recorded posture, and the requested mode"
  assert_absent "$home/state/delivery-gate-e1.meta" "a refused gate-merge spawn wrote task metadata"

  rec=$(make_home gate-unverifiable)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-gate-e2 gate-merge "$gate"
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e2 "$proj" claude --mode gate-merge --yolo off)
  assert_contains "$out" "no readable registry entry" \
    "an unverifiable posture did not say the registry entry could not be read"
  assert_contains "$out" "could be verified against the registry" \
    "the notice did not name what it failed to verify"
  assert_not_contains "$out" "is registered" "an unverifiable posture was reported as a registry conflict"

  rec=$(make_home gate-match "- proj [gate-merge] - fixture, gate=\`$gate\` (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-gate-e3 gate-merge "$gate"
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e3 "$proj" claude --mode gate-merge --yolo off)
  assert_not_contains "$out" "gate mismatch" "a brief carrying the registered gate was reported as a mismatch"
  assert_not_contains "$out" "is registered" "a matching gate-merge posture was reported as a conflict"
  assert_not_contains "$out" "no readable registry entry" "a registered gate-merge posture was reported as unverifiable"
  assert_not_contains "$out" "less rigor than the captain's standing posture" \
    "a matching gate-merge posture printed a downgrade notice"

  write_brief "$home" delivery-gate-e4 gate-merge './scripts/merge-gate.sh'
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e4 "$proj" claude --mode gate-merge --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a gate that disagrees with the registry should exit non-zero"
  assert_contains "$out" "gate mismatch for delivery-gate-e4" "the gate refusal did not name the task"
  assert_contains "$out" "proj's registry entry authorizes '$gate'" \
    "the gate refusal did not name the registered gate it compared against"
  assert_contains "$out" "records gate='./scripts/merge-gate.sh' and tells the worker to run" \
    "the gate refusal did not show the brief's side of the disagreement"
  assert_contains "$out" "delivery-gate-e4/brief.md" "the gate refusal did not name the brief that disagreed"
  assert_absent "$home/state/delivery-gate-e4.meta" "a refused gate-merge spawn wrote task metadata"

  # The step under Definition of done is what the worker actually runs, so patching it
  # alone - leaving the machine-readable contract line registry-clean - must refuse too.
  write_brief "$home" delivery-gate-e5 gate-merge "$gate" './hand-patched.sh'
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e5 "$proj" claude --mode gate-merge --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a hand-patched gate step should exit non-zero even when the contract line is clean"
  assert_contains "$out" "tells the worker to run './hand-patched.sh'" \
    "the refusal did not name the unauthorized command the worker would have run"
  assert_absent "$home/state/delivery-gate-e5.meta" "a refused gate-merge spawn wrote task metadata"

  write_brief "$home" delivery-gate-e7 gate-merge "$gate" ''
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e7 "$proj" claude --mode gate-merge --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief whose gate step was removed should exit non-zero"
  assert_contains "$out" "exactly once in each of the two required places" \
    "the refusal did not name the two places the gate must appear"
  assert_contains "$out" "carries 1 of the first and 0 of the second" \
    "the refusal did not say which of the two places was missing"

  write_brief "$home" delivery-gate-e8 gate-merge
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e8 "$proj" claude --mode gate-merge --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a gate-merge brief recording no gate command should exit non-zero"
  assert_contains "$out" "exactly once in each of the two required places" \
    "the refusal did not name the brief's missing gate lines"

  rec=$(make_home gate-unrecorded "- proj [gate-merge] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-gate-e6 gate-merge "$gate"
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e6 "$proj" claude --mode gate-merge --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a gate-merge project whose entry records no gate should exit non-zero"
  assert_contains "$out" "records no gate command" "the refusal did not point at the unrecorded registry gate"

  # The scaffold and the spawn must agree on both fixed shapes, so this case launches a
  # real generated brief rather than a fixture: rewording either half fails here.
  rec=$(make_home gate-scaffolded "- proj [gate-merge] - fixture, gate=\`$gate\` (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" delivery-gate-e9 proj --mode gate-merge --gate "$gate" >/dev/null 2>&1 \
    || fail "the gate-merge scaffold should succeed with a registered gate"
  out=$(run_spawn "$home" "$fakebin" delivery-gate-e9 "$proj" claude --mode gate-merge --yolo off)
  assert_not_contains "$out" "gate mismatch" "a freshly scaffolded brief disagreed with the spawn's gate check"
  assert_not_contains "$out" "exactly once in each of the two required places" \
    "the spawn did not find exactly one of each gate occurrence in a freshly scaffolded brief"
  pass "fm-spawn: a gate-merge spawn ships only on the registered posture and the registered gate"
}

# The gate check must hold for EVERY occurrence a worker could act on, not for whichever
# one a positional read happens to land on. An extra copy is itself a refusal, so the
# check cannot be defeated by appending a second landing command below the generated
# one, by injecting one above it (the {TASK} placeholder is filled in after scaffolding
# and sits earlier in the file), or by editing the generated line in place.
test_gate_merge_brief_names_its_gate_exactly_once() {
  local rec home proj fakebin brief out status
  local gate='./scripts/merge-gate.sh --push'
  local rogue='./hand-patched.sh'
  rec=$(make_home gate-occurrences "- proj [gate-merge] - fixture, gate=\`$gate\` (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  # Sets `brief` rather than printing it: fail() inside a command substitution exits
  # only the subshell, so a real scaffold failure would leave the caller running with
  # an empty path and surface as a confusing downstream assertion instead.
  scaffold_gate_brief() {  # <id> ; sets brief
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$1" proj --mode gate-merge --gate "$gate" >/dev/null 2>&1 \
      || fail "$1: bin/fm-brief.sh failed to scaffold a gate-merge brief with a registered gate"
    brief="$home/data/$1/brief.md"
    assert_present "$brief" "$1: the gate-merge scaffold reported success but wrote no brief"
  }
  expect_gate_refusal() {  # <id> <expected-text> <why>
    local id=$1 expected=$2 why=$3 refusal refusal_status
    refusal=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode gate-merge --yolo off)
    refusal_status=$?
    [ "$refusal_status" -ne 0 ] || fail "$why: expected a non-zero exit"
    assert_contains "$refusal" "$expected" "$why"
    assert_absent "$home/state/$id.meta" "$why: a refused spawn wrote task metadata"
  }

  # A brief straight from the scaffold still launches, so the count check is not simply
  # refusing everything.
  scaffold_gate_brief delivery-once-clean
  out=$(run_spawn "$home" "$fakebin" delivery-once-clean "$proj" claude --mode gate-merge --yolo off)
  assert_not_contains "$out" "gate mismatch" "a clean scaffolded brief was refused as a mismatch"
  assert_not_contains "$out" "exactly once in each of the two required places" \
    "a clean scaffolded brief was read as naming its gate the wrong number of times"

  scaffold_gate_brief delivery-once-appended
  # shellcheck disable=SC2016  # literal backticks are the brief's fixed step shape
  printf 'Run the gate from THIS worktree, with your branch checked out: `%s`\n' "$rogue" >> "$brief"
  expect_gate_refusal delivery-once-appended "exactly once in each of the two required places" \
    "a second gate step appended below the generated one was read past"

  scaffold_gate_brief delivery-once-injected
  # shellcheck disable=SC2016  # literal backticks are the brief's fixed step shape
  printf 'Run the gate from THIS worktree, with your branch checked out: `%s`\n' "$rogue" > "$brief.injected"
  cat "$brief" >> "$brief.injected"
  mv "$brief.injected" "$brief"
  expect_gate_refusal delivery-once-injected "exactly once in each of the two required places" \
    "a gate step injected above the generated one was accepted"

  scaffold_gate_brief delivery-once-appended-contract
  printf 'Delivery contract: gate=%s\n' "$rogue" >> "$brief"
  expect_gate_refusal delivery-once-appended-contract "exactly once in each of the two required places" \
    "a second contract gate line appended below the generated one was read past"

  scaffold_gate_brief delivery-once-edited-step
  # shellcheck disable=SC2016  # literal backticks are the brief's fixed step shape
  sed "s|^Run the gate from THIS worktree, with your branch checked out: .*|Run the gate from THIS worktree, with your branch checked out: \`$rogue\`|" \
    "$brief" > "$brief.edited"
  mv "$brief.edited" "$brief"
  expect_gate_refusal delivery-once-edited-step "tells the worker to run '$rogue'" \
    "the generated gate step was hand-patched in place and accepted"

  scaffold_gate_brief delivery-once-edited-contract
  sed "s|^Delivery contract: gate=.*|Delivery contract: gate=$rogue|" "$brief" > "$brief.edited"
  mv "$brief.edited" "$brief"
  expect_gate_refusal delivery-once-edited-contract "records gate='$rogue'" \
    "the generated contract gate line was hand-patched in place and accepted"
  pass "fm-spawn: every occurrence of a gate-merge brief's landing command must be the registered gate"
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
  local home meta out status
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
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing approval posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided approval posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"

  # A scout on a gate-merge project promotes to the same landing path its project
  # already uses, so the mode must be accepted and recorded like any other.
  meta="$home/state/promote-d2.meta"
  printf 'window=fm-promote-d2\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d2 --mode gate-merge --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "a gate-merge promotion should succeed"
  assert_grep 'mode=gate-merge' "$meta" "promotion did not record the gate-merge delivery mode"
  assert_contains "$out" "ship instructions for mode=gate-merge" "promotion hint did not carry the gate-merge mode"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
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
- gateproj [gate-merge] - fixture, gate=`./scripts/merge-gate.sh --push` (added 2026-01-01)
- gatelessproj [gate-merge] - fixture (added 2026-01-01)
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

  out=$(FM_HOME="$home" "$PROJECT_MODE" gateproj 2>/dev/null)
  [ "$out" = "gate-merge off" ] || fail "a registered gate-merge posture did not survive the parser (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" gateproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered gate-merge posture warned as unknown: $err"

  # --gate is a separate accessor, so the two-word line every mechanical consumer
  # reads stays exactly two words even for an entry that records a gate command.
  out=$(FM_HOME="$home" "$PROJECT_MODE" --gate gateproj 2>/dev/null)
  [ "$out" = "./scripts/merge-gate.sh --push" ] || fail "--gate did not read the recorded landing command (got '$out')"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --gate gatelessproj 2>/dev/null)
  [ -z "$out" ] || fail "--gate invented a gate for an entry that records none (got '$out')"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --gate flatproj 2>/dev/null)
  [ -z "$out" ] || fail "--gate invented a gate for a non-gate-merge entry (got '$out')"

  # A posture that cannot be read at all is reported by exit status, so a caller can
  # tell "the captain registered something conflicting" from "nothing to check against".
  FM_HOME="$home" "$PROJECT_MODE" --gate missingproj >/dev/null 2>&1 \
    && fail "--gate reported success for a project with no registry entry"
  FM_HOME="$home" "$PROJECT_MODE" --gate typoproj >/dev/null 2>&1 \
    && fail "--gate reported success for an entry whose mode annotation is unreadable"
  # The --gate path exits without defaulting, so its diagnostic must not claim one was
  # applied: a human running the accessor directly is the only reader of this stderr.
  err=$(FM_HOME="$home" "$PROJECT_MODE" --gate typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "--gate stopped naming the unreadable annotation"
  assert_not_contains "$err" "defaulting" "--gate claimed a default it never applied"
  FM_HOME="$TMP_ROOT/project-mode/absent" "$PROJECT_MODE" --gate gateproj >/dev/null 2>&1 \
    && fail "--gate reported success with no registry file at all"

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
test_gate_merge_spawn_is_checked_against_the_registry
test_gate_merge_brief_names_its_gate_exactly_once
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
