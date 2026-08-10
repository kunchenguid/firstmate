#!/usr/bin/env bash
# Behavior tests for the agent-justification record written at the spawn
# chokepoint (bin/fm-reasoning-lib.sh, bin/fm-spawn.sh, bin/fm-promote.sh).
#
# Every dispatch has to answer why an agent turn was necessary, in a vocabulary
# closed enough to count. These tests pin the three properties that make the
# record worth having rather than worth ignoring:
#
#   1. The enum is CLOSED. An unknown code is refused with a stable token, so a
#      reason can never degrade into free text nothing can measure.
#   2. TOOLING_GAP is COUNTED SEPARATELY and never as justified reasoning, and a
#      TOOLING_GAP dispatch is only recordable alongside OPEN repair work. Without
#      that, a broken reader is laundered into a permanently "necessary" agent turn.
#   3. The derivable fields MATCH THEIR SOURCES. The floor comes verbatim from
#      config/crew-dispatch.json and the escalation policy from the delivery
#      contract, so the record cannot claim a band or an authority the config and
#      the contract never granted.
#
# Refusal cases stop before any endpoint exists and a fake `tmux` that exits
# non-zero backstops them, so nothing is created. Record cases run a real spawn
# against a real git worktree and a fake tmux, and then read the meta.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-reasoning-required)

# Floors and a default route copied into a home's dispatch config, so the
# "matches its config source" cases assert against a real file rather than a
# constant baked into the test.
write_dispatch_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "rules": [
    { "when": "implementation", "use": { "harness": "codex" }, "route": "R3-MED", "floor": "F-IMPL-MED" }
  ],
  "default": { "harness": "codex", "route": "R2-GEN", "floor": "F-GEN" },
  "_floors": { "F-UTIL": {}, "F-IMPL-MED": {}, "F-GEN": {} }
}
JSON
}

# The same home, with `default` written as the profile ARRAY that
# docs/configuration.md documents and docs/examples/crew-dispatch.json ships.
# One default route, several interchangeable profiles.
write_dispatch_config_array_default() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_floors": { "F-UTIL": {}, "F-IMPL-MED": {}, "F-GEN": {} },
  "rules": [
    { "when": "implementation", "use": { "harness": "codex" }, "floor": "F-IMPL-MED" }
  ],
  "default": [
    { "harness": "codex", "model": "gpt-5.5", "effort": "medium", "floor": "F-GEN" },
    { "harness": "pi", "model": "anthropic/claude-sonnet-5", "effort": "medium", "floor": "F-GEN" }
  ]
}
JSON
}

# A home with a fake tmux that refuses, so a spawn that clears the justification
# checks still creates nothing. Echoes "<home>|<project-dir>|<fakebin>".
make_refusal_home() {  # <name>
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
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

# One open and one already-closed backlog item, so the TOOLING_GAP certification
# can be driven apart: filed-and-open must pass where closed and absent must not.
write_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] fleet-view-exits-nonzero - The fleet view reader exits 1 (repo: firstmate) (kind: ship)

## Done
- [x] already-repaired-reader - A reader that was already fixed (repo: firstmate) (kind: ship)
MD
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

# --- 1. the enum is closed --------------------------------------------------

# A dispatch that names no reason, or names one outside the vocabulary, is
# refused with a stable token and writes no task metadata. The negative control
# is the last row: the SAME spawn with an in-enum code must get past this gate,
# so the refusals above are proven to come from the reason code rather than from
# some unrelated check further up.
test_reason_code_is_required_and_closed() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_refusal_home closed-enum)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "closed-enum-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "closed-enum-$n" "$proj" claude \
      --mode no-mistakes --yolo off $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not carry its stable token"
    assert_absent "$home/state/closed-enum-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
no reason code at all||FM_SPAWN_REASON_CODE_REQUIRED
a code outside the enum|--reason-code BECAUSE_I_SAID_SO|FM_SPAWN_REASON_CODE_UNKNOWN
a plausible-looking invention|--reason-code HARD_PROBLEM|FM_SPAWN_REASON_CODE_UNKNOWN
free text|--reason-code "the router was unclear"|FM_SPAWN_REASON_CODE_UNKNOWN
lowercase spelling of a real code|--reason-code synthesis|FM_SPAWN_REASON_CODE_UNKNOWN
ROWS

  # Negative control: the identical spawn with an in-enum code must clear the
  # justification gate and fail later, at the refusing tmux, instead.
  write_brief "$home" closed-enum-control no-mistakes
  out=$(run_spawn "$home" "$fakebin" closed-enum-control "$proj" claude \
    --mode no-mistakes --yolo off --reason-code SYNTHESIS)
  assert_not_contains "$out" "FM_SPAWN_REASON_CODE" \
    "an in-enum code was still refused by the closed-enum gate"
  pass "fm-spawn: the reason code is required and its vocabulary is closed"
}

# Every code the library publishes must be accepted AND land in the record. This
# asserts the recorded value positively rather than the absence of a refusal: an
# implementation that writes nothing at all would satisfy "was not refused".
test_every_published_code_is_recorded() {
  local rec home proj wt fakebin code out n=0 codes
  rec=$(make_record_case published-codes)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  codes=$(. "$ROOT/bin/fm-reasoning-lib.sh"; printf '%s\n' "$FM_REASON_CODES")
  while IFS= read -r code; do
    [ -n "$code" ] || continue
    n=$((n + 1))
    write_brief "$home" "published-$n" no-mistakes
    if [ "$code" = TOOLING_GAP ]; then
      out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" "published-$n" "$proj" codex \
        --mode no-mistakes --yolo off --reason-code "$code" \
        --tooling-gap-item fleet-view-exits-nonzero)
    else
      out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" "published-$n" "$proj" codex \
        --mode no-mistakes --yolo off --reason-code "$code")
    fi
    expect_code 0 "$?" "published code $code was refused: $out"
    assert_grep "reason_code=$code" "$home/state/published-$n.meta" \
      "published code $code did not reach the record"
  done <<EOF
$codes
EOF
  [ "$n" -ge 9 ] || fail "expected at least the nine published codes, saw $n"
  pass "fm-spawn: every code the closed enum publishes is accepted and recorded"
}

# --- 2. TOOLING_GAP is not a reasoning code ---------------------------------

# A broken reader is not legitimate reasoning demand. The turn it forced is only
# recordable next to OPEN repair work, so an absent item, a merely-claimed item
# and an already-closed item are all refused.
test_tooling_gap_requires_open_filed_work() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_refusal_home tooling-gap)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_backlog "$home"
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "tooling-gap-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "tooling-gap-$n" "$proj" claude \
      --mode no-mistakes --yolo off --reason-code TOOLING_GAP $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not carry its stable token"
    assert_absent "$home/state/tooling-gap-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
no work item named at all||FM_SPAWN_TOOLING_GAP_ITEM_REQUIRED
an item that was never filed|--tooling-gap-item no-such-repair|FM_SPAWN_TOOLING_GAP_ITEM_UNFILED
an item that is already closed|--tooling-gap-item already-repaired-reader|FM_SPAWN_TOOLING_GAP_ITEM_UNFILED
a prefix of a real item|--tooling-gap-item fleet-view|FM_SPAWN_TOOLING_GAP_ITEM_UNFILED
ROWS

  # The item id is data, never match syntax. An id built from regex
  # metacharacters names no filed repair, so it is refused exactly like any
  # other unfiled id rather than matching the backlog by construction: a bare
  # alternation that certifies against any non-empty backlog would clear this
  # gate with no repair work filed at all.
  local injected
  for injected in '|' '(' ')' '+' '?' '.*' 'fleet-view|' '.*|x'; do
    n=$((n + 1))
    write_brief "$home" "tooling-gap-$n" no-mistakes
    out=$(run_spawn "$home" "$fakebin" "tooling-gap-$n" "$proj" claude \
      --mode no-mistakes --yolo off --reason-code TOOLING_GAP \
      --tooling-gap-item "$injected")
    status=$?
    [ "$status" -ne 0 ] || fail "the item id '$injected' certified as filed open work"
    assert_contains "$out" FM_SPAWN_TOOLING_GAP_ITEM_UNFILED \
      "the item id '$injected' did not refuse with its stable token"
    assert_absent "$home/state/tooling-gap-$n.meta" \
      "the item id '$injected' let a refused spawn write task metadata"
  done

  # Negative control: the same dispatch naming the OPEN item must clear the gate.
  write_brief "$home" tooling-gap-control no-mistakes
  out=$(run_spawn "$home" "$fakebin" tooling-gap-control "$proj" claude \
    --mode no-mistakes --yolo off --reason-code TOOLING_GAP \
    --tooling-gap-item fleet-view-exits-nonzero)
  assert_not_contains "$out" FM_SPAWN_TOOLING_GAP_ITEM \
    "a TOOLING_GAP dispatch naming genuinely open repair work was still refused"

  # And the flag is meaningless without the code, so it is refused rather than
  # silently recorded on a dispatch that claims real reasoning.
  write_brief "$home" tooling-gap-misuse no-mistakes
  out=$(run_spawn "$home" "$fakebin" tooling-gap-misuse "$proj" claude \
    --mode no-mistakes --yolo off --reason-code SYNTHESIS \
    --tooling-gap-item fleet-view-exits-nonzero)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-TOOLING_GAP dispatch accepted --tooling-gap-item"
  assert_contains "$out" FM_SPAWN_TOOLING_GAP_ITEM_REFUSED \
    "misusing --tooling-gap-item did not carry its stable token"
  pass "fm-spawn: a TOOLING_GAP dispatch is only recordable alongside open filed work"
}

# --- 3. the derivable fields match their sources ----------------------------

test_capability_floor_matches_its_config_source() {
  local rec home proj fakebin out status
  rec=$(make_refusal_home floor-source)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_dispatch_config "$home"

  write_brief "$home" floor-undefined no-mistakes
  out=$(run_spawn "$home" "$fakebin" floor-undefined "$proj" claude \
    --mode no-mistakes --yolo off --reason-code SYNTHESIS --capability-floor F-INVENTED)
  status=$?
  [ "$status" -ne 0 ] || fail "a floor absent from the dispatch config was accepted"
  assert_contains "$out" FM_SPAWN_CAPABILITY_FLOOR_UNKNOWN \
    "an undefined floor did not carry its stable token"

  # Negative control: a floor the SAME config defines must clear the gate.
  write_brief "$home" floor-defined no-mistakes
  out=$(run_spawn "$home" "$fakebin" floor-defined "$proj" claude \
    --mode no-mistakes --yolo off --reason-code SYNTHESIS --capability-floor F-IMPL-MED)
  assert_not_contains "$out" FM_SPAWN_CAPABILITY_FLOOR_UNKNOWN \
    "a floor defined by the dispatch config was still refused"

  # A home with no dispatch profiles has no vocabulary to match against, so an
  # explicit floor is refused rather than recorded unchecked.
  local bare_rec bare_home bare_proj bare_fakebin
  bare_rec=$(make_refusal_home floor-unconfigured)
  IFS='|' read -r bare_home bare_proj bare_fakebin <<EOF
$bare_rec
EOF
  write_brief "$bare_home" floor-nodispatch no-mistakes
  out=$(run_spawn "$bare_home" "$bare_fakebin" floor-nodispatch "$bare_proj" claude \
    --mode no-mistakes --yolo off --reason-code SYNTHESIS --capability-floor F-IMPL-MED)
  status=$?
  [ "$status" -ne 0 ] || fail "an unconfigured home accepted an unverifiable floor"
  assert_contains "$out" FM_SPAWN_CAPABILITY_FLOOR_UNKNOWN \
    "an unverifiable floor did not carry its stable token"

  # A dispatch config that exists but cannot be read is unverifiable, not empty:
  # the floor has to fail closed rather than be recorded against nothing.
  printf '{ "rules": [ this is not json\n' > "$home/config/crew-dispatch.json"
  write_brief "$home" floor-unreadable no-mistakes
  out=$(run_spawn "$home" "$fakebin" floor-unreadable "$proj" claude \
    --mode no-mistakes --yolo off --reason-code SYNTHESIS --capability-floor F-IMPL-MED)
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable dispatch config still recorded a floor"
  assert_contains "$out" FM_SPAWN_CAPABILITY_FLOOR_UNVERIFIABLE \
    "an unreadable dispatch config did not carry its stable token"
  assert_absent "$home/state/floor-unreadable.meta" \
    "a spawn with an uncheckable floor wrote task metadata"
  pass "fm-spawn: a recorded capability floor matches the dispatch config that defines it"
}

# --- the record itself ------------------------------------------------------

# A real spawn against a real worktree, so the fields can be read back off the
# meta rather than inferred from a refusal. Echoes "<home>|<project>|<worktree>|<fakebin>".
make_record_case() {  # <name>
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  cat > "$fakebin/tmux" <<'SH'
#!/bin/sh
case "$1" in
  display-message) printf '%s\n' "$FM_FAKE_PANE_PATH" ;;
  new-window|new-session) printf 'fm-fake:1\n' ;;
  list-panes|list-windows) printf 'fm-fake:1\n' ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  write_dispatch_config "$home"
  write_backlog "$home"
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

run_record_spawn() {  # <home> <project> <worktree> <fakebin> <spawn-args...>
  local home=$1 proj=$2 wt=$3 fakebin=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Completion criterion (a): every new task-dispatch record carries all four
# fields, and the two derived ones follow their sources rather than a caller.
test_every_task_dispatch_record_carries_the_fields() {
  local rec home proj wt fakebin out status meta gated_policy local_policy
  rec=$(make_record_case record-fields)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  write_brief "$home" record-ship no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" record-ship "$proj" codex \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --capability-floor F-IMPL-MED)
  status=$?
  expect_code 0 "$status" "ship spawn should succeed: $out"
  meta="$home/state/record-ship.meta"
  assert_grep "reasoning_required=yes" "$meta" "ship record is missing reasoning_required"
  assert_grep "reason_code=NL_RULE_CLASSIFICATION" "$meta" "ship record is missing reason_code"
  assert_grep "capability_floor=F-IMPL-MED" "$meta" "ship record is missing capability_floor"
  assert_grep "escalation_policy=captain-approves-gates" "$meta" \
    "a yolo=off ship must record that the captain owns its gates"

  # yolo flips ONLY the escalation policy, from the same reason code.
  write_brief "$home" record-yolo no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" record-yolo "$proj" codex \
    --mode no-mistakes --yolo on --reason-code NL_RULE_CLASSIFICATION)
  expect_code 0 "$?" "yolo=on ship spawn should succeed: $out"
  assert_grep "escalation_policy=firstmate-routine-gates" "$home/state/record-yolo.meta" \
    "a yolo=on ship must record firstmate's routine gate authority"
  # An omitted floor falls back to the dispatch config's own default route floor.
  assert_grep "capability_floor=F-GEN" "$home/state/record-yolo.meta" \
    "an omitted floor did not fall back to the configured default route floor"

  # The delivery mode is the other half of the contract this field is derived
  # from. A local-only ship lands through the guarded fast-forward path and
  # never reaches a PR merge gate, so recording the gated ship's posture for it
  # would claim an authority boundary the task never arrives at.
  write_brief "$home" record-local local-only
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" record-local "$proj" codex \
    --mode local-only --yolo off --reason-code UNFAMILIAR_CODE)
  expect_code 0 "$?" "local-only ship spawn should succeed: $out"
  assert_grep "escalation_policy=captain-approves-local-merge" "$home/state/record-local.meta" \
    "a local-only ship must record the local merge approval the captain actually owns"
  gated_policy=$(grep '^escalation_policy=' "$meta")
  local_policy=$(grep '^escalation_policy=' "$home/state/record-local.meta")
  [ "$gated_policy" != "$local_policy" ] || fail \
    "a local-only yolo=off ship recorded the same policy as a no-mistakes yolo=off ship ($gated_policy)"

  # A scout holds no merge authority at all, and that is derived, not passed.
  write_brief "$home" record-scout
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" record-scout "$proj" codex \
    --scout --reason-code MULTIPLE_PLAUSIBLE_ROOT_CAUSES)
  expect_code 0 "$?" "scout spawn should succeed: $out"
  assert_grep "escalation_policy=report-only" "$home/state/record-scout.meta" \
    "a scout must record that it holds no merge authority"
  assert_grep "reasoning_required=yes" "$home/state/record-scout.meta" \
    "scout record is missing reasoning_required"
  pass "fm-spawn: every task-dispatch record carries all four fields, derived from their sources"
}

# TOOLING_GAP must be readable as a separate category, never as justified
# reasoning, and the record must name the repair it was admitted against.
test_tooling_gap_is_never_recorded_as_justified_reasoning() {
  local rec home proj wt fakebin out meta
  rec=$(make_record_case record-gap)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  write_brief "$home" gap-record no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" gap-record "$proj" codex \
    --mode no-mistakes --yolo off --reason-code TOOLING_GAP \
    --tooling-gap-item fleet-view-exits-nonzero)
  expect_code 0 "$?" "TOOLING_GAP spawn with open filed work should succeed: $out"
  meta="$home/state/gap-record.meta"
  assert_grep "reason_code=TOOLING_GAP" "$meta" "the gap record lost its reason code"
  assert_grep "reasoning_required=no" "$meta" \
    "TOOLING_GAP was recorded as reasoning the turn actually required"
  assert_grep "tooling_gap_item=fleet-view-exits-nonzero" "$meta" \
    "the gap record does not name the repair work it was admitted against"

  # Negative control: a genuine reasoning code on an otherwise identical spawn
  # records the opposite, so reasoning_required is proven to track the code.
  write_brief "$home" gap-control no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" gap-control "$proj" codex \
    --mode no-mistakes --yolo off --reason-code SEMANTIC_REVIEW)
  expect_code 0 "$?" "control spawn should succeed: $out"
  assert_grep "reasoning_required=yes" "$home/state/gap-control.meta" \
    "a genuine reasoning code did not record reasoning as required"
  assert_no_grep "tooling_gap_item=" "$home/state/gap-control.meta" \
    "a non-gap dispatch recorded a tooling gap item"
  pass "fm-spawn: TOOLING_GAP is counted separately and never as justified reasoning"
}

# The array form of `default` is the shape docs/configuration.md documents and
# docs/examples/crew-dispatch.json ships, so a home that copied the example must
# be readable here. A floor read that only understands the object form refuses
# EVERY ship and scout dispatch in such a home, including one that named no
# floor at all.
test_an_array_form_default_route_resolves_its_floor() {
  local rec home proj wt fakebin out status
  rec=$(make_record_case array-default)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  write_dispatch_config_array_default "$home"

  write_brief "$home" array-omitted no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" array-omitted "$proj" codex \
    --mode no-mistakes --yolo off --reason-code UNFAMILIAR_CODE)
  expect_code 0 "$?" "an array-form default refused a dispatch that named no floor: $out"
  assert_grep "capability_floor=F-GEN" "$home/state/array-omitted.meta" \
    "an omitted floor did not fall back to the array-form default route's floor"

  # A floor the same array-form config defines is accepted.
  write_brief "$home" array-explicit no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" array-explicit "$proj" codex \
    --mode no-mistakes --yolo off --reason-code UNFAMILIAR_CODE --capability-floor F-IMPL-MED)
  expect_code 0 "$?" "an array-form config refused a floor it defines: $out"
  assert_grep "capability_floor=F-IMPL-MED" "$home/state/array-explicit.meta" \
    "an explicit floor did not reach the record under an array-form default"

  # Negative control: the array form is read rather than waved through, so a
  # floor it never defines is still refused.
  write_brief "$home" array-invented no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" array-invented "$proj" codex \
    --mode no-mistakes --yolo off --reason-code UNFAMILIAR_CODE --capability-floor F-INVENTED)
  status=$?
  [ "$status" -ne 0 ] || fail "an array-form config accepted a floor it never defines"
  assert_contains "$out" FM_SPAWN_CAPABILITY_FLOOR_UNKNOWN \
    "an undefined floor under an array-form default lost its stable token"
  assert_absent "$home/state/array-invented.meta" \
    "a refused floor under an array-form default still wrote task metadata"

  # The shipped example is what a new home copies into config/, so the file the
  # docs hand out has to be readable by the code that reads it.
  #
  # Its `_scheduling` block is dropped for this case only. The example also
  # opts a home into admission control, and an enabled admission policy bands
  # an invocation that does not hold the home's session lock to `hard` - which
  # every test invocation is, and which fm-spawn now honors at the chokepoint.
  # That behavior is covered directly in tests/fm-route-enforcement.test.sh;
  # what THIS case is about is the example's floor vocabulary being readable.
  jq 'del(._scheduling)' "$ROOT/docs/examples/crew-dispatch.json" > "$home/config/crew-dispatch.json"
  write_brief "$home" array-shipped no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" array-shipped "$proj" codex \
    --mode no-mistakes --yolo off --reason-code UNFAMILIAR_CODE)
  expect_code 0 "$?" "the shipped example dispatch config refused an ordinary spawn: $out"
  assert_grep "capability_floor=" "$home/state/array-shipped.meta" \
    "a home running the shipped example recorded no capability floor at all"
  assert_no_grep "capability_floor=unconfigured" "$home/state/array-shipped.meta" \
    "the shipped example defines floors but the record still read as unconfigured"
  pass "fm-spawn: an array-form default route resolves its floor instead of refusing every dispatch"
}

# Each justification field is one line of state/<id>.meta, a file teardown,
# supervision and backend resolution read as authority. A value carrying a
# newline would append forged key lines to it, so it is refused before the
# record is written rather than trimmed afterwards.
test_a_justification_value_can_never_forge_a_meta_line() {
  local rec home proj wt fakebin out status
  rec=$(make_record_case meta-line)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  write_brief "$home" forged-floor no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" forged-floor "$proj" codex \
    --mode no-mistakes --yolo off --reason-code SYNTHESIS \
    --capability-floor "$(printf 'F-GEN\nkind=secondmate')")
  status=$?
  [ "$status" -ne 0 ] || fail "a newline-bearing --capability-floor was accepted"
  assert_contains "$out" FM_SPAWN_JUSTIFICATION_VALUE_MALFORMED \
    "a newline-bearing floor did not refuse with its stable token"
  assert_absent "$home/state/forged-floor.meta" \
    "a newline-bearing floor still wrote task metadata, forging a kind= line into it"

  write_brief "$home" forged-item no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" forged-item "$proj" codex \
    --mode no-mistakes --yolo off --reason-code TOOLING_GAP \
    --tooling-gap-item "$(printf 'fleet-view-exits-nonzero\nkind=secondmate')")
  status=$?
  [ "$status" -ne 0 ] || fail "a newline-bearing --tooling-gap-item was accepted"
  assert_contains "$out" FM_SPAWN_JUSTIFICATION_VALUE_MALFORMED \
    "a newline-bearing gap item did not refuse with its stable token"
  assert_absent "$home/state/forged-item.meta" \
    "a newline-bearing gap item still wrote task metadata, forging a kind= line into it"

  # Negative control: the same fields carrying ordinary single-line values are
  # recorded, so the refusals above come from the newline and nothing else.
  write_brief "$home" single-line no-mistakes
  out=$(run_record_spawn "$home" "$proj" "$wt" "$fakebin" single-line "$proj" codex \
    --mode no-mistakes --yolo off --reason-code TOOLING_GAP \
    --capability-floor F-GEN --tooling-gap-item fleet-view-exits-nonzero)
  expect_code 0 "$?" "single-line justification values were refused: $out"
  assert_grep "capability_floor=F-GEN" "$home/state/single-line.meta" \
    "a single-line floor did not reach the record"
  pass "fm-spawn: a justification value can never forge a second line of the record"
}

# A --secondmate spawn provisions a standing home rather than dispatching a
# task, so it carries no justification record and refuses the flags outright -
# an absent field reads as unknown, never as justified reasoning.
test_secondmate_provisioning_carries_no_justification_record() {
  local rec home proj fakebin out status
  rec=$(make_refusal_home secondmate-scope)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  mkdir -p "$proj/.fm-secondmate-home"
  out=$(run_spawn "$home" "$fakebin" second-a "$proj" --secondmate --reason-code SYNTHESIS)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn accepted a task-dispatch reason code"
  assert_contains "$out" FM_SPAWN_REASON_CODE_REFUSED \
    "the secondmate refusal did not carry its stable token"

  out=$(run_spawn "$home" "$fakebin" second-b "$proj" --secondmate --capability-floor F-GEN)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn accepted a dispatch capability floor"
  assert_contains "$out" FM_SPAWN_REASON_CODE_REFUSED \
    "the secondmate floor refusal did not carry its stable token"
  pass "fm-spawn: secondmate provisioning is out of scope for the justification record"
}

# --- promotion --------------------------------------------------------------

# escalation_policy is derived, so promotion has to recompute it. Leaving the
# scout's report-only posture on a task that can now reach a merge gate would
# make the record claim an authority boundary that no longer holds.
test_promotion_recomputes_the_derived_escalation_policy() {
  local home meta out
  home="$TMP_ROOT/promotion/home"
  mkdir -p "$home/state"
  meta="$home/state/promoted.meta"
  cat > "$meta" <<'META'
window=fm-fake:1
kind=scout
reasoning_required=yes
reason_code=MULTIPLE_PLAUSIBLE_ROOT_CAUSES
capability_floor=F-GEN
escalation_policy=report-only
META

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promoted --mode no-mistakes --yolo on 2>&1)
  expect_code 0 "$?" "promotion should succeed: $out"
  assert_no_grep "escalation_policy=report-only" "$meta" \
    "promotion left the scout's report-only posture on a ship task"
  assert_grep "escalation_policy=firstmate-routine-gates" "$meta" \
    "promotion did not recompute the escalation policy from the new contract"
  # The reason the agent turn was necessary did not change, so it is preserved.
  assert_grep "reason_code=MULTIPLE_PLAUSIBLE_ROOT_CAUSES" "$meta" \
    "promotion dropped the recorded reason code"

  # The recomputation reads the whole new contract, not just yolo: promoting the
  # same scout into local-only work records the local merge approval instead of
  # the gated ship's posture.
  local local_meta
  local_meta="$home/state/promoted-local.meta"
  cat > "$local_meta" <<'META'
window=fm-fake:1
kind=scout
reasoning_required=yes
reason_code=MULTIPLE_PLAUSIBLE_ROOT_CAUSES
capability_floor=F-GEN
escalation_policy=report-only
META
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promoted-local --mode local-only --yolo off 2>&1)
  expect_code 0 "$?" "local-only promotion should succeed: $out"
  assert_grep "escalation_policy=captain-approves-local-merge" "$local_meta" \
    "promotion into local-only work did not recompute the policy from the new mode"
  pass "fm-promote: promotion recomputes the derived escalation policy"
}

test_reason_code_is_required_and_closed
test_every_published_code_is_recorded
test_tooling_gap_requires_open_filed_work
test_capability_floor_matches_its_config_source
test_every_task_dispatch_record_carries_the_fields
test_tooling_gap_is_never_recorded_as_justified_reasoning
test_an_array_form_default_route_resolves_its_floor
test_a_justification_value_can_never_forge_a_meta_line
test_secondmate_provisioning_carries_no_justification_record
test_promotion_recomputes_the_derived_escalation_policy
