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
  git -C "$projects/proj" init -q || fail "could not initialize project fixture"
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
  # shellcheck disable=SC2016  # single quotes are deliberate: the placeholders must stay literal
  assert_grep 'needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='"$home/data/promote-dod-no-mistakes/nm-<run>-findings.txt" "$payload" \
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
[captain] Fix the legacy dispatch boundary.
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
  assert_contains "$out" "[captain]" "missing-provenance refusal did not name the replacement marker"
  assert_not_contains "$out" "Captain:" "missing-provenance refusal still prescribes operator address"
  assert_absent "$home/data/$id/launch-brief.md" "unmarked legacy no-mistakes spawn serialized unauthorized intent"
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
[captain] Investigate the fold's session-floor refusal.
[captain] Preserve the existing successful session behavior.

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

# Exercise the serialized input a worker is told to pass to no-mistakes, not
# just the presence of words somewhere in its much larger launch brief.
# No live model or pipeline is needed: spawn publishes this exact input before
# the fixture backend refuses to create an endpoint.
test_authorized_intent_keeps_words_without_composed_address() {
  local rec home proj fakebin id words authorized out status marker n=0
  rec=$(make_home intent-emission)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  id='intent-plain'
  words=$(printf '%s\n' 'Keep the original request intact.' '' "Preserve its provenance, punctuation, and \`literal code\`.")
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "intent brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" "$words" 'This build constraint must not become intent.'
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  assert_present "$home/data/$id/launch-brief.md" "plain intent was not serialized"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit { print }' "$home/data/$id/launch-brief.md")
  [ "$authorized" = "$words" ] || fail "authorized --intent must contain exactly the request, without headings, address, or contract prose: $authorized"

  # The request itself may discuss an address spelling. It is data, not an
  # invitation to scrub the user's words or synthesize a different request.
  words=$(printf '%s\n' "Keep the literal example \`Captain, hello\` in the documentation." \
    "Stop composing Captain:, Captain's words:, Captain's ask:, and Captain's intent: into PR bodies.")
  write_brief "$home" intent-literal no-mistakes
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\nDo not paraphrase.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' "$words" > "$home/data/intent-literal/brief.md"
  out=$(run_spawn "$home" "$fakebin" intent-literal "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "operator-address line" "labels mentioned mid-line were refused as address"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit { print }' "$home/data/intent-literal/launch-brief.md")
  [ "$authorized" = "$words" ] || fail "literal words in the request were scrubbed"

  # A body line that opens with operator address is refused, never rewritten.
  for marker in 'Captain:' "Captain's words:" "Captain's ask:" "Captain's intent:" 'Captain,'; do
    n=$((n + 1))
    id="intent-addressed-$n"
    write_brief "$home" "$id" no-mistakes
    printf '# Task\n## Captain'"'"'s intent\nKeep the original request intact.\n  %s preserve its provenance.\n\n## Firstmate spec\nDo not paraphrase.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
      "$marker" > "$home/data/$id/brief.md"
    out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$marker: addressed intent should be refused"
    assert_contains "$out" "operator-address line:   $marker preserve its provenance." \
      "$marker: refusal did not name the offending line"
    assert_contains "$out" "write the captain's actual words without a Captain label or address" \
      "$marker: refusal did not say what to write instead"
    assert_absent "$home/data/$id/launch-brief.md" "$marker: addressed intent was serialized"
    assert_absent "$home/state/$id.meta" "$marker: addressed intent spawn wrote task metadata"
    assert_grep "  $marker preserve its provenance." "$home/data/$id/brief.md" "$marker: refusal rewrote the brief"
  done

  id='intent-addressed-promote'
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
  write_brief "$home" "$id"
  printf '# Task\n## Captain'"'"'s intent\nCaptain: investigate the refusal.\n\n## Firstmate spec\nReproduce it first.\n' > "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion of addressed intent should be refused"
  assert_contains "$out" "operator-address line: Captain: investigate the refusal." \
    "promotion refusal did not name the offending line"
  assert_absent "$home/data/$id/ship-instructions.md" "promotion published addressed intent"
  assert_grep 'kind=scout' "$home/state/$id.meta" "refused promotion changed the task record"

  # New legacy briefs use neutral provenance. Previously stored labels remain
  # readable without encouraging their use in newly composed pipeline input.
  for marker in '[captain]' 'Captain:' "Captain's words:" "Captain's ask:" "Captain's intent:"; do
    n=$((n + 1))
    id="intent-marked-$n"
    write_brief "$home" "$id" no-mistakes
    printf '# Task\n%s %s\nDo not include this build constraint.\n%s %s\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
      "$marker" 'Keep the original request intact.' "$marker" 'Preserve its provenance.' > "$home/data/$id/brief.md"
    out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
    assert_present "$home/data/$id/launch-brief.md" "$marker: provenance was not accepted"
    authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit { print }' "$home/data/$id/launch-brief.md")
    words=$(printf '%s\n' 'Keep the original request intact.' 'Preserve its provenance.')
    [ "$authorized" = "$words" ] || fail "$marker: legacy intent changed words or included provenance/build prose"
  done
  pass "fm-spawn/fm-promote: authorized intent preserves exact words and refuses operator-address lines"
}

test_spawn_refreshes_legacy_worker_roles() {
  local rec home proj fakebin kind id out brief project_kind first_line role_line supervisor_line
  rec=$(make_home worker-roles)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  # AGENTS.md and its import are instruction inputs, not implementation-source
  # assertions: launching a worker must never rewrite either project's files.
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  for project_kind in firstmate unrelated; do
    if [ "$project_kind" = firstmate ]; then
      cp "$ROOT/AGENTS.md" "$proj/AGENTS.md"
    else
      printf 'Use this project coding standard.\n' > "$proj/AGENTS.md"
    fi
    printf '@AGENTS.md\n' > "$proj/CLAUDE.md"
    cp "$proj/AGENTS.md" "$proj/agents-before"
    for kind in no-mistakes direct-PR local-only scout; do
      id="roles-$project_kind-$kind"
      write_brief "$home" "$id"
      if [ "$kind" = scout ]; then
        out=$(run_spawn "$home" "$fakebin" "$id" "$proj" codex --scout)
      else
        out=$(run_spawn "$home" "$fakebin" "$id" "$proj" codex --mode "$kind" --yolo off)
      fi
      assert_not_contains "$out" 'could not render' "worker role rendering failed"
      brief="$home/data/$id/launch-brief.md"
      assert_present "$brief" "$project_kind $kind did not refresh the legacy launch brief"
      first_line=$(sed -n '1p' "$brief")
      [ "$first_line" = '# Current worker role contract' ] ||
        fail "$project_kind $kind did not put worker identity first"
      assert_grep 'follow this brief instead of that supervisor contract' "$brief" "$project_kind $kind omitted worker authority"
      assert_grep "$home/state/$id.inbox" "$brief" "$project_kind $kind omitted its exact steering inbox"
      assert_grep 'When this task works on Firstmate itself' "$brief" "$project_kind $kind made the exception unconditional"
      assert_grep 'Project instructions still govern the work wherever they do not conflict with this worker identity' "$brief" "$project_kind $kind displaced project guidance"
      ! grep -q '^This section supersedes every earlier brief instruction about your role' "$brief" ||
        fail "$project_kind $kind revoked the brief's own role for a task that is not Firstmate"
      assert_no_grep '# Current worker role contract' "$home/data/$id/brief.md" "spawn rewrote the source brief"
      cmp -s "$proj/agents-before" "$proj/AGENTS.md" || fail "spawn changed project AGENTS.md"
      [ "$(cat "$proj/CLAUDE.md")" = '@AGENTS.md' ] || fail "spawn changed the project import"
    done
  done
  role_line=$(grep -n 'A ship or scout worker launched by Firstmate into a worktree of this repository' "$ROOT/AGENTS.md" | cut -d: -f1)
  supervisor_line=$(grep -n '^You are the first mate\.$' "$ROOT/AGENTS.md" | head -1 | cut -d: -f1)
  [ -n "$role_line" ] && [ "$role_line" -lt "$supervisor_line" ] ||
    fail "Firstmate AGENTS.md does not disambiguate a launched worker before assigning the supervisor identity"
  cmp -s "$ROOT/AGENTS.md" "$home/AGENTS.md" || fail "worker spawn changed the primary contract"
  pass "fm-spawn: every legacy worker receives scoped role instructions without changing project or primary instructions"
}

# The forge binding is orthogonal to the mode and to +yolo, exactly as +yolo is
# orthogonal to the mode: it is read from its own `forge=` token wherever that
# token sits in the annotation, and it is never derived from the mode. It is
# asked for explicitly with --forge, so the default output stays the same two
# words for every project, bound or not, and no existing caller sees a change.
test_project_mode_binds_the_forge_orthogonally() {
  local home out err status label registry expect forge
  home="$TMP_ROOT/forge-binding/home"
  mkdir -p "$home/data"
  while IFS='|' read -r label registry expect forge; do
    [ -n "$label" ] || continue
    printf '%s\n' "$registry" > "$home/data/projects.md"
    out=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>/dev/null)
    [ "$out" = "$expect" ] || fail "$label: expected default output '$expect', got '$out'"
    out=$(FM_HOME="$home" "$PROJECT_MODE" --forge fp 2>/dev/null)
    [ "$out" = "$forge" ] || fail "$label: expected --forge '$forge', got '$out'"
  done <<'ROWS'
no annotation at all|- fp - fixture (added 2026-01-01)|no-mistakes off|none
mode only|- fp [direct-PR] - fixture (added 2026-01-01)|direct-PR off|none
forge beside a mode|- fp [no-mistakes forge=gerrit] - fixture (added 2026-01-01)|no-mistakes off|gerrit
forge as the only token leaves the default mode|- fp [forge=gerrit] - fixture (added 2026-01-01)|no-mistakes off|gerrit
forge before yolo on a direct-PR project|- fp [direct-PR forge=gerrit +yolo] - fixture (added 2026-01-01)|direct-PR off|gerrit
forge under the conditional policy|- fp [no-mistakes-prod-only forge=gerrit] - fixture (added 2026-01-01)|no-mistakes off|gerrit
a project with no forge keeps yolo|- fp [direct-PR +yolo] - fixture (added 2026-01-01)|direct-PR on|none
a keyed token that is not the forge is ignored|- fp [direct-PR owner=me] - fixture (added 2026-01-01)|direct-PR off|none
an unregistered project|- other [direct-PR] - fixture (added 2026-01-01)|no-mistakes off|none
ROWS

  printf '%s\n' '- fp [no-mistakes-prod-only forge=gerrit] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw fp 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] \
    || fail "--raw on a bound project did not keep the two-word annotation (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered forge warned as unknown: $err"

  # A forge describes what a mode publishes, and local-only publishes nothing, so
  # the pair is refused rather than kept as an inert annotation: that mode's
  # landing would fast-forward local main with content the server never saw.
  printf '%s\n' '- fp [local-only forge=gerrit] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  for flag in "" --forge; do
    # shellcheck disable=SC2086 # An empty flag must expand to nothing.
    out=$(FM_HOME="$home" "$PROJECT_MODE" $flag fp 2>/dev/null)
    status=$?
    [ "$status" -eq 3 ] || fail "local-only with a forge did not refuse${flag:+ under $flag} (status $status, got '$out')"
    [ -z "$out" ] || fail "a refused local-only forge still handed the caller a posture: '$out'"
  done
  err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null) || true
  assert_contains "$err" 'local-only publishes nothing' "the refusal did not say why local-only takes no forge"
  pass "fm-project-mode: the forge binds from its own token and is reported only through --forge"
}

# The registry keeps its old tolerance: a token the parser does not know is
# ignored, keyed or not, and an unknown mode falls back to the most rigorous
# default with a warning. The one exception is a malformed forge binding - a
# `forge=` value that is empty or outside the closed set - because resolving it
# to "no registered forge" would hand a Gerrit project the pull-request contract.
# Those refuse, naming the token, in both output forms. A key one or two edits
# from `forge` keeps the old result and only warns.
test_project_mode_refuses_only_a_malformed_forge_binding() {
  local home out err status label registry token flag expect
  home="$TMP_ROOT/forge-token/home"
  mkdir -p "$home/data"
  while IFS='|' read -r label registry token; do
    [ -n "$label" ] || continue
    printf '%s\n' "$registry" > "$home/data/projects.md"
    for flag in "" --forge; do
      # shellcheck disable=SC2086 # An empty flag must expand to nothing.
      out=$(FM_HOME="$home" "$PROJECT_MODE" $flag fp 2>/dev/null)
      status=$?
      [ "$status" -eq 3 ] || fail "$label: did not refuse${flag:+ under $flag} (status $status, got '$out')"
      [ -z "$out" ] || fail "$label: a refused binding still handed the caller a posture: '$out'"
    done
    err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null) || true
    assert_contains "$err" "\"$token\"" "$label: the refusal did not name the token it could not read"
    assert_contains "$err" 'forge=gerrit' "$label: the refusal did not name the accepted binding"
  done <<'ROWS'
an unknown forge value|- fp [no-mistakes forge=gitlab] - fixture (added 2026-01-01)|gitlab
a misspelled forge value|- fp [no-mistakes forge=gerit] - fixture (added 2026-01-01)|gerit
an empty forge value|- fp [no-mistakes +yolo forge=] - fixture (added 2026-01-01)|forge=
ROWS

  while IFS='|' read -r label registry; do
    [ -n "$label" ] || continue
    printf '%s\n' "$registry" > "$home/data/projects.md"
    out=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>/dev/null) \
      || fail "$label: a token the parser never read became a refusal"
    [ "$out" = "no-mistakes off" ] || fail "$label: expected the old tolerant 'no-mistakes off', got '$out'"
    out=$(FM_HOME="$home" "$PROJECT_MODE" --forge fp 2>/dev/null) \
      || fail "$label: --forge refused a token the parser never read"
    [ "$out" = none ] || fail "$label: an ignored token bound a forge ('$out')"
  done <<'ROWS'
an unknown token beside the mode|- fp [no-mistakes +tomorrow] - fixture (added 2026-01-01)
the forge key with a space|- fp [no-mistakes forge gerrit] - fixture (added 2026-01-01)
a bare forge value in the mode slot|- fp [gerrit] - fixture (added 2026-01-01)
a keyed token in the mode slot|- fp [owner=me] - fixture (added 2026-01-01)
an annotation the line never closes|- fp [no-mistakes - fixture (added 2026-01-01)
ROWS
  printf '%s\n' '- fp [gerrit] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a forge value in the mode slot stopped warning as an unknown mode"
  printf '%s\n' '- fp [owner=me] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null)
  assert_contains "$err" 'unknown mode "owner=me"' "a keyed token in the mode slot stopped warning as an unknown mode"
  printf '%s\n' '- fp [direct-PR owner=me] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a keyed token that is not near the forge key warned: $err"

  # A near miss of the forge key keeps the old stdout and exit status; only
  # stderr gains one warning that names the token and the right spelling.
  while IFS='|' read -r label registry token expect; do
    [ -n "$label" ] || continue
    printf '%s\n' "$registry" > "$home/data/projects.md"
    out=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>/dev/null) \
      || fail "$label: a near-miss key became a refusal"
    [ "$out" = "$expect" ] || fail "$label: expected '$expect', got '$out'"
    out=$(FM_HOME="$home" "$PROJECT_MODE" --forge fp 2>/dev/null) \
      || fail "$label: --forge refused a near-miss key"
    [ "$out" = none ] || fail "$label: a near-miss key bound a forge ('$out')"
    err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null)
    [ "$(printf '%s\n' "$err" | grep -c .)" -eq 1 ] || fail "$label: expected one warning line, got: $err"
    assert_contains "$err" "\"$token\"" "$label: the warning did not name the token"
    assert_contains "$err" 'forge=gerrit' "$label: the warning did not name the forge=gerrit spelling"
  done <<'ROWS'
a dropped character in the key|- fp [no-mistakes forg=gerrit] - fixture (added 2026-01-01)|forg=gerrit|no-mistakes off
a swapped pair in the key|- fp [direct-PR froge=gerrit +yolo] - fixture (added 2026-01-01)|froge=gerrit|direct-PR on
a transposed key|- fp [no-mistakes frge=gerrit] - fixture (added 2026-01-01)|frge=gerrit|no-mistakes off
a capitalized key|- fp [no-mistakes Forge=gerrit] - fixture (added 2026-01-01)|Forge=gerrit|no-mistakes off
ROWS
  pass "fm-project-mode: only a malformed forge binding refuses; every other token keeps its old tolerance"
}

# Yolo is inactive for the Gerrit forge on the captain's decision of 2026-09-15,
# because a Code-Review+2 is a positive attributed claim that a named human
# approved. Every path that could carry merge authority to such a project must
# say so out loud: the registry parser reports yolo=off with the reason instead of
# the registered +yolo, and a spawn or promotion asked for it outright refuses.
test_forge_gerrit_refuses_yolo() {
  local home out err rec proj fakebin status meta
  home="$TMP_ROOT/forge-yolo/home"
  mkdir -p "$home/data"
  printf '%s\n' '- fp [no-mistakes +yolo forge=gerrit] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  out=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>/dev/null)
  [ "$out" = "no-mistakes off" ] \
    || fail "a registered +yolo survived the gerrit forge (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" fp 2>&1 >/dev/null)
  assert_contains "$err" "refused" "the dropped yolo posture was a silent no-op"
  assert_contains "$err" "attributed claim that a named human approved" \
    "the refusal did not carry the reason yolo is inactive for this forge"

  rec=$(make_home forge-yolo-spawn "- proj [no-mistakes forge=gerrit] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  FM_HOME="$home" "$BRIEF" forge-yolo-s1 proj --mode no-mistakes --forge gerrit >/dev/null \
    || fail "a gerrit ship brief should scaffold"
  fill_brief_subsections "$home/data/forge-yolo-s1/brief.md" \
    "Run the review loop on the Gerrit project." "Ship the review pass."
  out=$(run_spawn "$home" "$fakebin" forge-yolo-s1 "$proj" claude --mode no-mistakes --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn with --yolo on launched on a gerrit-forge project"
  assert_contains "$out" "--yolo on is refused" "the spawn refusal did not name the refused flag"
  assert_contains "$out" "attributed claim that a named human approved" \
    "the spawn refusal did not carry the captain's reason"
  assert_absent "$home/state/forge-yolo-s1.meta" "the refused spawn still recorded a task"

  meta="$home/state/forge-yolo-p1.meta"
  printf 'window=fm-forge-yolo-p1\nkind=scout\nworktree=/tmp/wt\nproject=%s\n' "$proj" > "$meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" forge-yolo-p1 --mode no-mistakes --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a promotion with --yolo on was accepted for the gerrit-forge project"
  assert_contains "$out" "--yolo on is refused" "the promotion refusal did not name the refused flag"
  grep -qx 'kind=scout' "$meta" || fail "the refused promotion still flipped the task record"
  pass "forge=gerrit: yolo is refused with its reason, never silently dropped"
}

# The point of binding the forge is that it changes what no-mistakes MEANS for the
# worker. The brief must carry the per-run skip vocabulary, must keep every step
# that does the reviewing, must require custody recovery before the worker may
# report ready, and must end at a ready branch instead of a PR with green checks -
# while the forge-independent half of the pipeline contract is unchanged.
test_forge_gerrit_changes_what_no_mistakes_means() {
  local home brief plain
  home="$TMP_ROOT/forge-dod/home"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$BRIEF" forge-dod-g1 review-server-project --mode no-mistakes --forge gerrit >/dev/null \
    || fail "a gerrit no-mistakes brief should scaffold"
  brief="$home/data/forge-dod-g1/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes forge=gerrit shape=squash" "$brief" \
    || fail "the brief did not record the machine-readable forge in its delivery contract"

  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Pass `--skip push,pr,ci` on every `no-mistakes axi run` for this task' "$brief" \
    "the worker was not given the skip vocabulary the forge requires"
  assert_grep 'skip nothing else' "$brief" "nothing stopped the worker skipping the review itself"
  assert_grep 'branch_sync.next_action' "$brief" \
    "the worker was not told where to read whether custody must be recovered"
  assert_grep 'recover_custody' "$brief" "the worker was not told which state requires recovery"
  assert_grep 'no-mistakes axi sync --recover' "$brief" \
    "the worker was not given the recovery command"
  assert_grep 'You may not publish until you have closed that gap' "$brief" \
    "custody recovery was offered as advice rather than required before publishing"
  assert_grep 'how the UNFIXED code reaches review' "$brief" \
    "the brief did not say what skipping the recovery actually ships"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Run `gerrit-axi publish --squash --json`' "$brief" \
    "the worker was not told to publish through the forge tool"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Never pass `--stack`' "$brief" "the worker was not kept off an unwatchable stack"
  assert_grep 'done [at=<epoch>]: PR {change url} published for review' "$brief" \
    "the gerrit contract did not end at a published change"
  assert_grep 'note [at=<epoch>]: pipeline changes: {finding} - {fix it made}' "$brief" \
    "the gerrit worker was not told to report each pipeline fix the squash hides"
  assert_grep 'pipeline changes: none' "$brief" \
    "the gerrit worker was not told what to report when the pipeline fixed nothing"
  assert_no_grep 'done [at=<epoch>]: PR {url} checks green' "$brief" \
    "the gerrit contract still demands a PR with green checks this forge cannot produce"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Never run `gerrit-axi submit`, never vote or review a change by any path' "$brief" \
    "the gerrit worker was not kept from submitting or voting"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Run `no-mistakes doctor`' "$brief" \
    "the gerrit worker lost the pipeline initialization step no-mistakes still needs"

  # The forge changes the contract's head and tail only: how the pipeline is
  # driven, what --intent may carry, and the two firstmate-specific rules are the
  # same text a GitHub-forge worker receives.
  assert_grep 'ask-user findings are never yours to answer: escalate to firstmate' "$brief" \
    "the gerrit worker lost the ask-user escalation rule"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'NEVER pass `--yes` (or `-y`)' "$brief" "the gerrit worker lost the --yes ban"
  FM_HOME="$home" "$BRIEF" forge-dod-n1 other-project --mode no-mistakes >/dev/null \
    || fail "a default-forge no-mistakes brief should scaffold"
  plain="$home/data/forge-dod-n1/brief.md"
  awk '/^You drive no-mistakes by responding to its gates/ { emit = 1 }
       emit { print }
       emit && /hard rule violation\.$/ { exit }' "$brief" > "$TMP_ROOT/forge-dod/gerrit-middle"
  awk '/^You drive no-mistakes by responding to its gates/ { emit = 1 }
       emit { print }
       emit && /hard rule violation\.$/ { exit }' "$plain" > "$TMP_ROOT/forge-dod/plain-middle"
  [ -s "$TMP_ROOT/forge-dod/gerrit-middle" ] || fail "the gerrit brief carries no pipeline-driving section to compare"
  # Only the two statements about a green PR differ: the ci step is skipped on
  # this forge, so there is no checks-passed return to wait for.
  grep -q "reports the green PR" "$TMP_ROOT/forge-dod/plain-middle" \
    || fail "the default contract lost the green-PR return statement the comparison removes"
  assert_no_grep "checks-passed" "$TMP_ROOT/forge-dod/gerrit-middle" \
    "the gerrit worker was told to wait for a checks-passed return its skipped ci step never gives"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  grep -v "reports the green PR" "$TMP_ROOT/forge-dod/plain-middle" \
    | sed 's/; once checks are green it returns `checks-passed` immediately, and if it refuses/; if it refuses/' \
    > "$TMP_ROOT/forge-dod/plain-middle-no-pr"
  cmp -s "$TMP_ROOT/forge-dod/gerrit-middle" "$TMP_ROOT/forge-dod/plain-middle-no-pr" \
    || fail "the forge changed the forge-independent half of the pipeline contract"
  pass "forge=gerrit: no-mistakes runs with its forge steps skipped, recovers its fixes, then publishes one change"
}

# A registered forge is the captain's binding, so the spawn refuses a brief that
# disagrees with it in either direction: a Gerrit project launched on a brief that
# does not carry the forge would tell the worker to open a pull request and report
# green checks on a server that has neither, and a Gerrit brief on an unbound
# project would publish to a forge the project is not. Both publishing modes
# compose with the forge; local-only, which publishes nothing, cannot carry it.
test_spawn_requires_the_brief_to_carry_the_registered_forge() {
  local rec home proj fakebin out status
  rec=$(make_home forge-agree-gerrit "- proj [no-mistakes forge=gerrit] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" forge-agree-a1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" forge-agree-a1 "$proj" claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a gerrit project launched on a brief that records no forge"
  assert_contains "$out" "forge mismatch for forge-agree-a1" "the refusal did not name the drift it caught"
  assert_contains "$out" "remove $home/data/forge-agree-a1/brief.md" \
    "the refusal did not name the authored brief the re-scaffold must replace"
  assert_not_contains "$out" "remove $home/data/forge-agree-a1/launch-brief.md" \
    "the refusal named the generated launch brief instead of the authored one"
  assert_contains "$out" "fm-brief.sh forge-agree-a1 proj --mode no-mistakes --forge gerrit" \
    "the refusal did not print a re-scaffold command that can actually run"
  assert_contains "$out" "Captain's intent" \
    "the refusal did not say to preserve the filled subsections the re-scaffold discards"
  assert_absent "$home/state/forge-agree-a1.meta" "the refused spawn still recorded a task"

  FM_HOME="$home" "$BRIEF" forge-agree-a2 proj --mode direct-PR --forge gerrit >/dev/null \
    || fail "a gerrit direct-PR brief should scaffold"
  fill_brief_subsections "$home/data/forge-agree-a2/brief.md" "Publish the change." "Ship it."
  out=$(run_spawn "$home" "$fakebin" forge-agree-a2 "$proj" claude --mode direct-PR --yolo off 2>&1)
  assert_not_contains "$out" "forge mismatch" "a gerrit direct-PR brief was reported as drift"
  assert_not_contains "$out" "cannot ship" "direct-PR was refused on the forge it publishes to"

  FM_HOME="$home" "$BRIEF" forge-agree-a3 proj --mode no-mistakes --forge gerrit >/dev/null \
    || fail "a gerrit ship brief should scaffold"
  fill_brief_subsections "$home/data/forge-agree-a3/brief.md" "Run the review loop." "Ship it."
  out=$(run_spawn "$home" "$fakebin" forge-agree-a3 "$proj" claude --mode no-mistakes --yolo off 2>&1)
  assert_not_contains "$out" "forge mismatch" "an agreeing brief and registry were reported as drift"

  # local-only publishes nothing and cannot carry the forge, so a bound project
  # has no local-only brief that agrees with its registry: landing one would
  # fast-forward local main with content the review server never saw.
  FM_HOME="$home" "$BRIEF" forge-agree-a4 proj --mode local-only >/dev/null \
    || fail "a local-only ship brief should scaffold without a forge"
  fill_brief_subsections "$home/data/forge-agree-a4/brief.md" "Land it locally." "Stop at a ready branch."
  out=$(run_spawn "$home" "$fakebin" forge-agree-a4 "$proj" claude --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a local-only launch on a gerrit-bound project was accepted"
  assert_contains "$out" "forge mismatch for forge-agree-a4" "the local-only refusal did not name the drift"
  assert_absent "$home/state/forge-agree-a4.meta" "the refused local-only spawn still recorded a task"

  # The other direction is refused too: a brief that publishes to Gerrit on a
  # project the captain never bound would send the worker to a forge it is not.
  rec=$(make_home forge-agree-unbound "- proj [no-mistakes] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  FM_HOME="$home" "$BRIEF" forge-agree-a5 proj --mode no-mistakes --forge gerrit >/dev/null \
    || fail "a gerrit ship brief should scaffold"
  fill_brief_subsections "$home/data/forge-agree-a5/brief.md" "Run the review loop." "Ship it."
  out=$(run_spawn "$home" "$fakebin" forge-agree-a5 "$proj" claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a gerrit brief launched on a project with no registered forge"
  assert_contains "$out" "forge mismatch for forge-agree-a5" "the unbound-project refusal did not name the drift"
  assert_contains "$out" "fm-brief.sh forge-agree-a5 proj --mode no-mistakes" \
    "the refusal did not print the unbound re-scaffold command"
  assert_absent "$home/state/forge-agree-a5.meta" "the refused spawn still recorded a task"

  pass "fm-spawn: a registered forge must reach the worker's brief"
}

# The registry is hand-edited markdown, so a one-character typo in the forge token
# is the likeliest way it goes wrong. Such an entry must stop the spawn with the
# parser's own reason in front of the operator: resolving it to "no registered
# forge" would drop every guard at once - yolo, the direct-PR refusal, and the
# brief agreement - and launch a worker onto a review server with the
# pull-request contract.
test_spawn_refuses_a_registry_forge_it_cannot_read() {
  local rec home proj fakebin out status
  rec=$(make_home forge-typo "- proj [no-mistakes forge=gerit] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" forge-typo-a1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" forge-typo-a1 "$proj" claude --mode no-mistakes --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn launched on a registry entry whose forge token does not resolve"
  assert_contains "$out" 'unknown forge "gerit"' \
    "the parser's refusal never reached the operator running the spawn"
  assert_contains "$out" "does not resolve to a delivery posture" \
    "the spawn did not say why it refused to launch"
  assert_absent "$home/state/forge-typo-a1.meta" "the refused spawn still recorded a task"
  pass "fm-spawn: a registry forge token the parser refuses stops the launch, reason included"
}

# Promotion renders the same single owner an ordinary brief does, so a promoted
# worker on a bound forge must receive that forge's contract rather than the PR
# one. Promotion decides the mode and yolo itself, but the forge is the project's
# binding, so promotion takes it from the registry with no flag to remember, and
# refuses a flag that contradicts it.
test_promotion_carries_the_forge_binding() {
  local home sendroot meta out payload id
  home="$TMP_ROOT/forge-promote/home"
  sendroot="$TMP_ROOT/forge-promote/sendroot"
  mkdir -p "$home/state" "$home/data" "$home/projects/proj" "$sendroot/bin"
  printf '%s\n' '- proj [no-mistakes forge=gerrit] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  cat > "$sendroot/bin/fm-send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$2" > "$FM_TEST_CAPTURE"
STUB
  chmod +x "$sendroot/bin/fm-send.sh"

  id="forge-promote-g1"
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nproject=%s\n' "$id" "$home/projects/proj" > "$meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null 2>&1 \
    || fail "scout brief generation should succeed"
  fill_brief_subsections "$home/data/$id/brief.md" \
    "Fix what the investigation found on the Gerrit project." "Carry over only the fix."

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode no-mistakes --yolo off 2>&1) \
    || fail "promotion should take the registered forge with no flag to remember"
  payload="$TMP_ROOT/forge-promote/payload"
  ( cd "$sendroot" \
    && FM_TEST_CAPTURE="$payload" \
       eval "$(printf '%s\n' "$out" | sed -n 's/^next: //p' | grep 'fm-send\.sh')" ) \
    || fail "promotion's delivery command did not run"
  assert_present "$payload" "promotion delivered no message to the worker"
  grep -qx "Delivery contract: mode=no-mistakes forge=gerrit shape=squash" "$payload" \
    || fail "the promoted worker did not receive the forge in its delivery contract"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Pass `--skip push,pr,ci` on every `no-mistakes axi run` for this task' "$payload" \
    "the promoted worker was not given the skip vocabulary the forge requires"
  assert_grep 'You may not publish until you have closed that gap' "$payload" \
    "the promoted worker was not required to recover custody before publishing"
  assert_no_grep 'done [at=<epoch>]: PR {url} checks green' "$payload" \
    "the promoted worker was still told to report a PR with green checks"

  # Both real generation paths must end in the same contract, as they do for every
  # mode: a promoted worker is never handed a weaker one than a briefed worker.
  rm "$home/data/$id/brief.md"
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes --forge gerrit >/dev/null 2>&1 \
    || fail "ordinary gerrit ship brief generation should succeed"
  awk '/^# Definition of done$/ { emit=1 } emit' "$home/data/$id/brief.md" > "$TMP_ROOT/forge-promote/brief-dod"
  awk '/^# Definition of done$/ { emit=1 } emit' "$payload" > "$TMP_ROOT/forge-promote/delivered-dod"
  cmp -s "$TMP_ROOT/forge-promote/brief-dod" "$TMP_ROOT/forge-promote/delivered-dod" \
    || fail "promotion and ordinary brief generation delivered different gerrit contracts"
  pass "fm-promote: a promoted worker receives the project's registered forge contract with no flag to remember"
}

# direct-PR composes with the forge: the mode still means "publish without the
# pipeline", and on Gerrit publishing is one gerrit-axi call rather than a push
# plus a pull request. The worker reports the published change, never submits or
# votes, and is kept to the one squashed shape the merge watch can follow.
test_forge_gerrit_direct_pr_publishes_one_change() {
  local home brief out status
  home="$TMP_ROOT/forge-direct/home"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$BRIEF" forge-direct-g1 review-server-project --mode direct-PR --forge gerrit >/dev/null \
    || fail "a gerrit direct-PR brief should scaffold"
  brief="$home/data/forge-direct-g1/brief.md"
  grep -qx "Delivery contract: mode=direct-PR forge=gerrit shape=squash" "$brief" \
    || fail "the brief did not record the forge and shape in its delivery contract"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Run `gerrit-axi publish --squash --json`' "$brief" \
    "the direct-PR worker was not told to publish through the forge tool"
  assert_grep 'done [at=<epoch>]: PR {change url} published for review' "$brief" \
    "the direct-PR contract did not end at a published change"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_no_grep 'open a PR with `gh-axi`' "$brief" \
    "the gerrit direct-PR worker was still told to open a pull request"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_no_grep 'Pass `--skip push,pr,ci`' "$brief" \
    "the direct-PR worker was given pipeline vocabulary for a pipeline it never runs"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'Never run `gerrit-axi submit`' "$brief" "the direct-PR worker was not kept from submitting"
  assert_grep 'Do NOT run /no-mistakes.' "$brief" "the direct-PR worker was not kept off the pipeline"
  assert_no_grep 'pipeline changes:' "$brief" \
    "the direct-PR worker was asked to report pipeline fixes from a pipeline it never runs"

  # A stack is several changes and the merge watch follows one, so the shape is
  # refused with that reason until pinned-membership watching exists.
  out=$(FM_HOME="$home" "$BRIEF" forge-direct-g2 review-server-project --mode direct-PR --forge gerrit --shape stack 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a stack-shaped gerrit brief scaffolded"
  assert_contains "$out" "--shape stack is refused" "the stack refusal did not name the refused shape"
  assert_contains "$out" "pinned when its watch is armed" "the stack refusal did not carry its reason"
  assert_absent "$home/data/forge-direct-g2/brief.md" "the refused stack brief was still written"
  out=$(FM_HOME="$home" "$BRIEF" forge-direct-g3 review-server-project --mode direct-PR --shape squash 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a shape was accepted without a forge that publishes changes"
  out=$(FM_HOME="$home" "$BRIEF" forge-direct-g4 review-server-project --mode local-only --forge gerrit 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a local-only brief accepted a forge"
  assert_contains "$out" "cannot ship mode=local-only" "the local-only refusal did not name the mode"
  pass "forge=gerrit: direct-PR publishes one squashed change and a stack is refused with its reason"
}

test_authorized_intent_keeps_words_without_composed_address
test_spawn_refreshes_legacy_worker_roles
test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_refuses_a_symlinked_task_record
test_promotion_delivers_the_real_definition_of_done
test_project_mode_maps_the_conditional_policy
test_project_mode_binds_the_forge_orthogonally
test_project_mode_refuses_only_a_malformed_forge_binding
test_forge_gerrit_refuses_yolo
test_forge_gerrit_changes_what_no_mistakes_means
test_forge_gerrit_direct_pr_publishes_one_change
test_spawn_requires_the_brief_to_carry_the_registered_forge
test_spawn_refuses_a_registry_forge_it_cannot_read
test_promotion_carries_the_forge_binding
test_spawn_and_promote_require_filled_task_subsections
echo "# all fm-task-delivery tests passed"
