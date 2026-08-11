#!/usr/bin/env bash
# Behavior tests for bin/fm-commitment-register.sh - the typed register of
# recorded-but-not-yet-real commitments, and the pinned decision-file probe.
#
# The cases that carry the weight are the properties the register exists for, and
# each is paired with the control that proves it is not vacuous:
#
#   - RED-CAPABLE. An entry whose commitment is unmet is surfaced and cannot
#     report all-clear; then the probe is SATISFIED and the same entry, byte for
#     byte, retires on its own. A register that only ever says "unmet" enforces
#     nothing, and one that needs a hand edit to go quiet is the defect it
#     replaces - so both directions are driven, and the entry file is checksummed
#     across the transition to prove nothing edited it.
#   - THREE VALUES. could-not-observe is proven distinguishable from BOTH
#     enforced and unenforced, because collapsing it into either is the type error
#     this whole mechanism is built on.
#   - A HAND-WRITTEN STATUS WORD CANNOT SATISFY AN ENTRY. An entry asserting its
#     own state is refused outright, and the refusal is loud rather than a silent
#     drop.
#   - THE FOUR MEASURED FAILURE SHAPES are each expressed as a real entry against
#     the real repository, so the schema is shown to cover them rather than
#     asserted to. Each shape's entry has to probe the thing the shape is ABOUT:
#     a probe that would answer the same whatever the repository said would prove
#     the schema can hold a string, not that it covers the failure. Shape 3 - the
#     derived-state row that went stale while being trusted - reads UNMET here,
#     because the row it names is in fact still stale; its control is the same
#     probe kind over a row that IS owned, which reads SATISFIED.
#   - A VERDICT NEVER CLAIMS MORE THAN THE PROBE OBSERVED. An entry whose recorded
#     commitment has a half no probe reaches declares that half, and cannot retire
#     on the covered half alone.
#   - THE PINNED PROBE BLOCK. Every tier of the 2026-08-10 ruling is driven to its
#     own outcome, including the no-back-fill rule for decisions ruled before it.
#   - THE PROBE-RESULT CACHE NEVER SERVES AN OLD ANSWER AS A CURRENT ONE. It is
#     driven both ways: a served result carries its observation time, and the
#     truth it is standing in for is shown to differ from it.
#
# Probes run against fixture registers through FM_COMMITMENT_DIR, so no case
# depends on what the shipped register currently happens to contain.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-commitment-register-tests)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

REG="$ROOT/bin/fm-commitment-register.sh"
SCHEMA_SRC="$ROOT/commitments/schema.json"

# --- fixtures ---------------------------------------------------------------

# A register directory carrying the real schema, so admissibility is validated
# against the shipped contract rather than a test-local copy of it.
make_register() {  # <name> -> prints dir
  local dir="$TMP_ROOT/$1/commitments"
  mkdir -p "$dir"
  cp "$SCHEMA_SRC" "$dir/schema.json"
  printf '%s\n' "$dir"
}

make_home() {  # <name> -> prints home
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' "$home"
}

# A throwaway CODE ROOT for a case whose probe target the case itself writes.
# Typed probe targets resolve only under the tracked code root, so a case that
# needs to create the owner it probes needs a root it may write into; cases whose
# probes name real repository files keep $ROOT.
make_code_root() {  # <name> -> prints root
  local root="$TMP_ROOT/$1/root"
  mkdir -p "$root"
  printf '%s\n' "$root"
}

# An entry whose probe is a declared owner command: absent by default, so the
# commitment reads unmet until the owner is actually created. The command is a
# path RELATIVE to the code root, as every typed probe target must be.
write_owner_entry() {  # <register-dir> <id> <relative-command>
  cat > "$1/$2.json" <<JSON
{
  "commitment_schema_version": 1,
  "id": "$2",
  "recorded": "the declared owner performs this commitment",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the declared owner exists and answers",
  "assurance": "executable",
  "probe": {"kind": "command_answers", "command": "$3"}
}
JSON
}

# The code root every run_reg call resolves probe targets under. A case that
# writes its own owner shadows it with `local REG_ROOT=$(make_code_root ...)`.
REG_ROOT=$ROOT

run_reg() {  # <register-dir> <home> [args...]
  local dir=$1 home=$2
  shift 2
  FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$REG_ROOT" "$REG" "$@"
}

# --- red-capable, in both directions ----------------------------------------

red_capable_then_retires() {
  local dir home out rc before after owner
  local REG_ROOT
  dir=$(make_register red)
  home=$(make_home red)
  REG_ROOT=$(make_code_root red)
  owner="$REG_ROOT/owner.sh"
  write_owner_entry "$dir" unmet-then-met owner.sh
  before=$(cksum < "$dir/unmet-then-met.json")

  out=$(run_reg "$dir" "$home" --open); rc=$?
  expect_code 3 "$rc" "an unmet commitment must not exit all-clear"
  assert_contains "$out" "COMMITMENT: unmet-then-met UNMET (RULED-NOT-ENFORCED)" \
    "an unmet commitment must be surfaced"
  assert_contains "$out" "is not present and executable" \
    "the surfaced line must carry the evidence, not just a label"

  # Session start must not be able to report a quiet state while it is open.
  out=$(run_reg "$dir" "$home" --open)
  [ -n "$out" ] || fail "session start would have been silent with an open commitment"

  # Now make the commitment real. Nothing edits the entry.
  cat > "$owner" <<'SH'
#!/usr/bin/env bash
printf 'enforced\n'
SH
  chmod +x "$owner"

  out=$(run_reg "$dir" "$home" --open); rc=$?
  expect_code 0 "$rc" "a satisfied commitment must exit all-clear"
  [ -z "$out" ] || fail "a satisfied commitment must retire silently, got: $out"

  after=$(cksum < "$dir/unmet-then-met.json")
  [ "$before" = "$after" ] \
    || fail "the entry retired only because it was edited; it must retire on the probe alone"

  out=$(run_reg "$dir" "$home" --json)
  [ "$(printf '%s' "$out" | jq -r '.entries[0].state')" = SATISFIED ] \
    || fail "the computed state must be SATISFIED"
  [ "$(printf '%s' "$out" | jq -r '.entries[0].state_is_derived')" = true ] \
    || fail "the state must be marked derived"
  pass "an unmet commitment is surfaced, and retires on its probe with no hand edit"
}

# --- three values, pairwise distinguishable ---------------------------------

three_values_are_distinct() {
  local dir home out met unmet unobserved owner
  local REG_ROOT
  dir=$(make_register three)
  home=$(make_home three)
  REG_ROOT=$(make_code_root three)

  owner="$REG_ROOT/answers.sh"
  cat > "$owner" <<'SH'
#!/usr/bin/env bash
printf 'yes\n'
SH
  chmod +x "$owner"
  write_owner_entry "$dir" is-met answers.sh

  write_owner_entry "$dir" is-unmet absent.sh

  # Exits 0 and prints nothing: the empty result set, which is the canonical
  # could-not-observe and must not read as either verdict.
  local silent="$REG_ROOT/silent.sh"
  cat > "$silent" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$silent"
  write_owner_entry "$dir" cannot-observe silent.sh

  out=$(run_reg "$dir" "$home" --json)
  met=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="is-met") | .state')
  unmet=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="is-unmet") | .state')
  unobserved=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="cannot-observe") | .state')

  [ "$met" = SATISFIED ] || fail "an observed-good commitment must be SATISFIED, got $met"
  [ "$unmet" = UNMET ] || fail "an observed-bad commitment must be UNMET, got $unmet"
  [ "$unobserved" = UNOBSERVED ] \
    || fail "an unobservable commitment must be UNOBSERVED, got $unobserved"
  [ "$unobserved" != "$met" ] && [ "$unobserved" != "$unmet" ] \
    || fail "could-not-observe collapsed into one of the two verdicts"

  out=$(run_reg "$dir" "$home" --open)
  assert_contains "$out" "COMMITMENT: cannot-observe COULD-NOT-OBSERVE" \
    "could-not-observe must be surfaced as itself, never as enforced"
  assert_not_contains "$out" "COMMITMENT: is-met" \
    "a satisfied entry must not be surfaced"

  local rc=0
  run_reg "$dir" "$home" --open >/dev/null || rc=$?
  expect_code 4 "$rc" "an unobservable commitment must take the fail-closed exit"
  pass "SATISFIED, UNMET and UNOBSERVED are three distinguishable values"
}

# --- a hand-written status word cannot satisfy an entry ---------------------

status_word_cannot_satisfy() {
  local dir home out word
  dir=$(make_register word)
  home=$(make_home word)
  for word in state enforced satisfied applied; do
    cat > "$dir/claims-$word.json" <<JSON
{
  "commitment_schema_version": 1,
  "id": "claims-$word",
  "recorded": "this entry asserts its own answer",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "never, because the entry claims it instead of probing it",
  "assurance": "executable",
  "$word": "SATISFIED",
  "probe": {"kind": "command_answers", "command": "absent.sh"}
}
JSON
  done
  out=$(run_reg "$dir" "$home" --json)
  for word in state enforced satisfied applied; do
    local got
    got=$(printf '%s' "$out" | jq -r --arg id "claims-$word" \
      '.entries[] | select(.id==$id) | .state')
    [ "$got" = UNOBSERVED ] \
      || fail "a hand-written \"$word\" was not refused; the entry reported $got"
  done
  assert_contains "$out" "a status word must not be able to satisfy a commitment" \
    "the refusal must say why"

  out=$(run_reg "$dir" "$home" --open)
  assert_contains "$out" "COMMITMENT: claims-state COULD-NOT-OBSERVE" \
    "a refused entry must be surfaced, never silently dropped"
  pass "an entry carrying a hand-written status word is refused, loudly"
}

no_probe_is_inadmissible() {
  local dir home out got
  dir=$(make_register noprobe)
  home=$(make_home noprobe)
  cat > "$dir/no-probe.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "no-probe",
  "recorded": "a commitment with nothing that could establish it",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "unanswerable",
  "assurance": "executable"
}
JSON
  out=$(run_reg "$dir" "$home" --json)
  got=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="no-probe") | .state')
  [ "$got" = UNOBSERVED ] || fail "an entry with no probe must not be admitted, got $got"
  assert_contains "$out" "requires probe" "the refusal must name the missing probe"
  pass "an entry with no probe is inadmissible and is reported, not dropped"
}

absent_register_is_not_a_pass() {
  local home out rc
  home=$(make_home absentreg)
  out=$(run_reg "$TMP_ROOT/absentreg/nowhere" "$home" --open); rc=$?
  expect_code 4 "$rc" "an unreadable register must never exit all-clear"
  assert_contains "$out" "COMMITMENT: register unreadable" \
    "an unreadable register must say so"
  pass "an absent register is could-not-observe, never a quiet pass"
}

# --- the four measured failure shapes are each expressible -------------------

four_shapes_are_expressible() {
  local dir home out state
  dir=$(make_register shapes)
  home=$(make_home shapes)

  # 1. A ruling recorded and not enforced: the real launch posture, read through
  #    bin/fm-launch-lib.sh's own accessor rather than by grepping for a flag.
  cat > "$dir/shape-ruling.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-ruling",
  "recorded": "no launched agent holds unrestricted permissions",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "every launchable harness enforces permissions",
  "assurance": "executable",
  "probe": {"kind": "launch_permission_enforced"}
}
JSON

  # 2. A guard with no caller: the real task_base_verify_branch, which is called
  #    only from its own tests.
  cat > "$dir/shape-dead-guard.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-dead-guard",
  "recorded": "the base-inversion guard runs in production",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "some runtime caller invokes the guard",
  "assurance": "executable",
  "probe": {"kind": "symbol_called", "symbol": "task_base_verify_branch",
            "defined_in": "bin/fm-task-base-lib.sh"}
}
JSON

  # The negative control for shape 2: a symbol that IS called from bin/. Without
  # it, symbol_called could be a function that always answers "uncalled".
  cat > "$dir/shape-live-guard.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-live-guard",
  "recorded": "the three-valued consumer is reached from production code",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "some runtime caller invokes it",
  "assurance": "executable",
  "probe": {"kind": "symbol_called", "symbol": "fm_verify_case",
            "defined_in": "bin/fm-verify-lib.sh"}
}
JSON

  # 3. A derived-state row that went stale while being trusted: the real
  #    invoking_known_next_stage row, read as a ROW rather than as "the composer
  #    printed something". command_answers would pass here on any exit-0 command
  #    that prints, which is precisely the vacuous shape this entry must not have:
  #    the composer prints a full ledger whether or not this row is current.
  cat > "$dir/shape-stale-row.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-stale-row",
  "recorded": "the compensation ledger carries no pending row whose compensation already has a landed owner",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the ledger's invoking_known_next_stage row is no longer both pending and unowned",
  "assurance": "executable",
  "probe": {"kind": "command_answer_matches", "command": "bin/fm-decision-surface.sh",
            "args": ["owners", "--json"],
            "jq": "[.rows[] | select(.compensation == \"invoking_known_next_stage\")] | length == 1 and (.[0].status != \"pending\" or .[0].owner != null)"}
}
JSON

  # The negative control for shape 3: the SAME probe kind and the SAME command,
  # over a row that IS owned. Without it, command_answer_matches could be a
  # function that always answers "not satisfied".
  cat > "$dir/shape-owned-row.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-owned-row",
  "recorded": "the compensation ledger's counting_workers row names its owner",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the row reports owned with a named owner",
  "assurance": "executable",
  "probe": {"kind": "command_answer_matches", "command": "bin/fm-decision-surface.sh",
            "args": ["owners", "--json"],
            "jq": "[.rows[] | select(.compensation == \"counting_workers\")] | length == 1 and .[0].status == \"owned\" and .[0].owner != null"}
}
JSON

  # The VACUITY control for shape 3, and the reason the shape needs its own probe
  # kind: the same command, run the way a probe that does NOT inspect the row
  # would run it. bin/fm-decision-surface.sh owners --json exits 0 and prints a
  # full ledger whether or not the stale row is current, so command_answers over
  # it reports SATISFIED - the reassuring answer from a check that cannot see the
  # thing it is about, which is failure shape 3 reproduced inside the register.
  cat > "$dir/shape-row-unread.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-row-unread",
  "recorded": "the same commitment as shape-stale-row, probed without reading the row",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "nothing, honestly: this probe only establishes that the composer answered",
  "assurance": "executable",
  "probe": {"kind": "command_answers", "command": "bin/fm-decision-surface.sh",
            "args": ["owners", "--json"]}
}
JSON

  # 4. A dated exception that expired into prose: the deadline modifier, on an
  #    entry that is still unmet well after its date.
  cat > "$dir/shape-expired.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-expired",
  "recorded": "a dated exception whose writes were to be applied by its date",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the owner exists",
  "assurance": "executable",
  "deadline": "2000-01-01",
  "probe": {"kind": "command_answers", "command": "no/such/owner.sh"}
}
JSON

  out=$(run_reg "$dir" "$home" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-ruling") | .state')
  [ "$state" = UNMET ] \
    || fail "the ruled-not-enforced shape must read UNMET against the real launch posture, got $state"
  assert_contains "$out" "launch a worker with permission enforcement disabled" \
    "the ruling shape must name the harnesses it observed"

  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-dead-guard") | .state')
  [ "$state" = UNMET ] || fail "a guard with no runtime caller must read UNMET, got $state"
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-live-guard") | .state')
  [ "$state" = SATISFIED ] \
    || fail "the called-symbol control must read SATISFIED, or symbol_called proves nothing (got $state)"

  # The stale row IS still stale, so the honest verdict is UNMET - and it is that
  # only because the probe read the row. Its control, the same probe kind and the
  # same command over an owned row, must read SATISFIED.
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-stale-row") | .state')
  [ "$state" = UNMET ] \
    || fail "the stale invoking_known_next_stage row must read UNMET; a probe reporting $state is not reading the row"
  assert_contains "$out" "does not satisfy the declared condition" \
    "the stale-row shape must say the answer was read and is not what was committed"
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-owned-row") | .state')
  [ "$state" = SATISFIED ] \
    || fail "the owned-row control must read SATISFIED, or command_answer_matches proves nothing (got $state)"

  # Same commitment, same command, a probe that does not read the row: SATISFIED.
  # That is what makes the UNMET above a property of INSPECTION rather than of the
  # command, and it is the whole reason shape 3 needs command_answer_matches.
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-row-unread") | .state')
  [ "$state" = SATISFIED ] \
    || fail "the vacuity control must read SATISFIED, or the stale-row case does not show that inspection is what decided it (got $state)"
  pass "stale row asserts satisfied only when the probe inspects the row"

  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-expired") | .overdue')
  [ "$state" = true ] || fail "an entry past its deadline must be reported overdue, got $state"
  out=$(run_reg "$dir" "$home" --open)
  assert_contains "$out" "past its 2000-01-01 deadline" \
    "an overdue entry must say so where it is surfaced"
  pass "all four measured failure shapes are expressible, each with its control"
}

# --- a verdict never claims more than the probe observed ---------------------

partial_probe_cannot_claim_the_whole_commitment() {
  local dir home out owner state
  local REG_ROOT
  dir=$(make_register partial)
  home=$(make_home partial)
  REG_ROOT=$(make_code_root partial)
  owner="$REG_ROOT/owner.sh"
  cat > "$owner" <<'SH'
#!/usr/bin/env bash
printf 'enforced\n'
SH
  chmod +x "$owner"

  # The control: the SAME passing probe on an entry whose commitment the probe
  # covers entirely. Without it, the case below could pass because the probe
  # failed rather than because the uncovered half withheld the verdict.
  write_owner_entry "$dir" whole-commitment owner.sh

  cat > "$dir/half-commitment.json" <<JSON
{
  "commitment_schema_version": 1,
  "id": "half-commitment",
  "recorded": "two things must both be true, and only one of them has anything to probe",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the declared owner answers AND the second half becomes observable",
  "assurance": "executable",
  "probe": {"kind": "command_answers", "command": "owner.sh"},
  "unobserved_conditions": ["the second half, which has no landed artifact to probe"]
}
JSON

  out=$(run_reg "$dir" "$home" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="whole-commitment") | .state')
  [ "$state" = SATISFIED ] \
    || fail "control: the same probe on a fully covered commitment must be SATISFIED, got $state"
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="half-commitment") | .state')
  [ "$state" = UNOBSERVED ] \
    || fail "a passing probe must not retire a commitment it only half observes, got $state"
  [ "$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="half-commitment") | .unobserved_conditions')" \
    != null ] || fail "the uncovered half must be reported, not merely acted on"

  out=$(run_reg "$dir" "$home" --open)
  assert_contains "$out" "COMMITMENT: half-commitment COULD-NOT-OBSERVE" \
    "a half-observed commitment must keep being surfaced"
  assert_contains "$out" "which no probe here observes" \
    "the surfaced line must name the half nothing observed"
  assert_not_contains "$out" "COMMITMENT: whole-commitment" \
    "the fully covered control must still retire"
  pass "a probe covering half a commitment reports that half, and cannot retire the whole"
}

# --- an unrecorded harness posture is could-not-observe, never an exclusion ---
#
# The register's launch probe reads bin/fm-launch-lib.sh's posture roster, and
# that roster is derived from launch_template's own case arms rather than
# hand-maintained - so an adapter added there arrives at this probe. What matters
# HERE is what the probe does with one whose posture nobody recorded: it must
# report could-not-observe, not quietly leave it out of the answer. Left out, a
# fleet with one unrestricted-but-unlisted harness would read as fully enforced,
# and the commitment would retire while the gap it names was still open.
#
# The fixture is a bin/ of symlinks with one real file: a copy of the launch
# library whose recorded postures all say enforced. The case and its control
# differ by exactly one added case arm.
make_probe_bin() {  # <name> <extra-adapter|""> -> prints bin dir
  local dir="$TMP_ROOT/$1/bin" f
  mkdir -p "$dir"
  for f in fm-commitment-register.sh fm-verify-lib.sh fm-tasks-axi-lib.sh; do
    ln -sf "$ROOT/bin/$f" "$dir/$f"
  done
  if [ -n "$2" ]; then
    # The inserted body only has to exit 0 - the roster accepts a token once
    # launch_template answers for it - and keeping it a fixed literal means an
    # arm carrying a glob or a pipe cannot turn the body into a pipeline whose
    # non-zero status would refuse the very arm the case is about.
    awk -v arm="$2" '{ print }
      /^    kimi\) printf/ { print "    " arm ") printf %s x ;;" }' \
      "$ROOT/bin/fm-launch-lib.sh" > "$dir/fm-launch-lib.sh"
  else
    cp "$ROOT/bin/fm-launch-lib.sh" "$dir/fm-launch-lib.sh"
  fi
  # Every adapter this repo has recorded a posture for reports enforced, so the
  # only thing that can hold the probe back is an adapter it has not.
  cat >> "$dir/fm-launch-lib.sh" <<'SH'
launch_permission_recorded() {
  case "$1" in
    claude|codex|opencode|grok|pi|pi-signed|kimi) printf 'enforced' ;;
    *) return 1 ;;
  esac
}
SH
  printf '%s\n' "$dir"
}

unknown_harness_is_could_not_observe_not_excluded() {
  local dir home out state clean_bin extra_bin
  dir=$(make_register unknownharness)
  home=$(make_home unknownharness)
  cat > "$dir/launch-posture.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "launch-posture",
  "recorded": "no launched agent holds unrestricted permissions",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "every launchable harness enforces permissions",
  "assurance": "executable",
  "probe": {"kind": "launch_permission_enforced"}
}
JSON
  clean_bin=$(make_probe_bin unknownharness-clean "")
  extra_bin=$(make_probe_bin unknownharness-extra frobnicator)

  # The control: with every launchable harness recorded as enforced, the probe
  # passes and the entry retires. This is what the case below must NOT reach.
  out=$(FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$clean_bin/fm-commitment-register.sh" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="launch-posture") | .state')
  [ "$state" = SATISFIED ] \
    || fail "control: with every posture recorded as enforced the probe must pass, got $state ($(printf '%s' "$out" | jq -r '.entries[0].probe_evidence'))"

  # Now one adapter launch_template can launch and nobody recorded a posture for.
  out=$(FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$extra_bin/fm-commitment-register.sh" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="launch-posture") | .state')
  [ "$state" = UNOBSERVED ] \
    || fail "a launchable harness with no recorded posture must make the probe could-not-observe, got $state - an excluded member reads as enforcement nobody verified"
  assert_contains "$out" "frobnicator" \
    "the unobserved harness must be named, not silently dropped from the answer"

  local rc=0
  FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$extra_bin/fm-commitment-register.sh" --open >/dev/null || rc=$?
  expect_code 4 "$rc" "an unrecorded posture must take the fail-closed exit"

  # The same property for an arm the derivation cannot read as a plain literal.
  # An arm carrying an upper-case name or a glob alternation is exactly what a
  # rename or an alias produces, and dropping it would leave nothing unrestricted
  # and nothing unknown once the recorded adapters flip to enforced - a PASS over
  # a harness that is still launchable.
  local odd_bin odd_state
  odd_bin=$(make_probe_bin unknownharness-odd 'Frobnicator|frob-*')
  out=$(FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$odd_bin/fm-commitment-register.sh" --json)
  odd_state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="launch-posture") | .state')
  [ "$odd_state" = UNOBSERVED ] \
    || fail "an arm the roster derivation cannot parse was dropped instead of reading unknown, got $odd_state"
  assert_contains "$out" "Frobnicator" \
    "an unparseable arm must be named in the answer, never silently excluded from it"
  pass "unknown harness member yields could-not-observe, never a silent exclusion"
}

# --- the pinned decision-file probe block ------------------------------------

write_decision() {  # <home> <task> <key> <block-body>
  mkdir -p "$1/data/$2"
  {
    printf '# decision\n\n'
    # shellcheck disable=SC2016  # the backticks are the pinned fence, not a substitution
    printf '```probe\n%s\n```\n' "$4"
  } > "$1/data/$2/decision-$3.md"
}

# The ruling says a `run:` executes FROM THE TASK WORKTREE, so a task without a
# recorded, existing worktree cannot run its probe at all.
give_worktree() {  # <home> <task>
  local wt="$1/wt-$2"
  mkdir -p "$wt"
  printf 'worktree=%s\n' "$wt" > "$1/state/$2.meta"
  printf '%s\n' "$wt"
}

pinned_block_tiers() {
  local dir home out rc gamma_wt err
  dir=$(make_register pinned)
  home=$(make_home pinned)
  err="$TMP_ROOT/pinned-stderr"
  give_worktree "$home" alpha >/dev/null
  give_worktree "$home" beta >/dev/null
  gamma_wt=$(give_worktree "$home" gamma)
  give_worktree "$home" delta >/dev/null

  # executable, criterion met
  write_decision "$home" alpha met 'tier: executable
run: true'
  # executable, criterion NOT met - the measured failure: reported applied, not met
  write_decision "$home" beta notmet 'tier: executable
run: test -f criterion-established'
  # cited-control, naming the test watched to fail first
  printf 'x\n' > "$gamma_wt/marker"
  write_decision "$home" gamma cited 'tier: cited-control
run: test -f marker
control: tests/fm-commitment-register.test.sh'
  # attested - genuinely cannot execute
  write_decision "$home" delta attested 'tier: attested
reason: the criterion is that a comment reads accurately'

  # The gate is consulted from inside the fold on ordinary wake handling, so every
  # tier must ANSWER rather than leak a shell error into a supervisor's output -
  # including the tiers whose task has no status stream to read yet.
  run_reg "$dir" "$home" --closes alpha met >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a met criterion must allow its resolution to close"
  [ ! -s "$err" ] || fail "the closure gate wrote to stderr instead of answering: $(cat "$err")"

  out=$(run_reg "$dir" "$home" --closes beta notmet 2>"$err"); rc=$?
  [ ! -s "$err" ] || fail "the closure gate wrote to stderr instead of answering: $(cat "$err")"
  expect_code 3 "$rc" "an unmet criterion must refuse its resolution"
  assert_contains "$out" "the criterion is not met" "the refusal must say the criterion is not met"

  run_reg "$dir" "$home" --closes gamma cited >/dev/null; rc=$?
  expect_code 0 "$rc" "a cited-control criterion whose test passes must close"

  out=$(run_reg "$dir" "$home" --closes delta attested); rc=$?
  expect_code 0 "$rc" "an attested criterion must be able to close"
  assert_contains "$out" "ATTESTED-NOT-PROBED" \
    "an attested closure must be marked, never silent"

  out=$(run_reg "$dir" "$home" --json)
  local state
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="decision:delta:attested") | .state')
  [ "$state" = UNOBSERVED ] \
    || fail "an attested criterion must never read as verified, got $state"
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="decision:gamma:cited") | .assurance')
  [ "$state" = cited-control ] || fail "the cited-control tier must be reported, got $state"
  pass "every pinned probe tier reaches its own outcome"
}

pinned_block_cannot_observe() {
  local dir home out rc
  dir=$(make_register cannotrun)
  home=$(make_home cannotrun)
  # A decision whose task has no recorded worktree: the probe cannot RUN.
  write_decision "$home" orphan key 'tier: executable
run: true'
  out=$(run_reg "$dir" "$home" --closes orphan key); rc=$?
  expect_code 4 "$rc" "a probe that cannot run must refuse the closure as could-not-observe"
  assert_contains "$out" "could not be run from it" "the refusal must say it could not run"

  # And its control: the SAME probe, once the worktree exists, does close.
  give_worktree "$home" orphan >/dev/null
  run_reg "$dir" "$home" --closes orphan key >/dev/null; rc=$?
  expect_code 0 "$rc" "the same probe must close once it can actually run"
  pass "a probe that cannot run is could-not-observe, and its control proves it can pass"
}

pinned_block_malformed_is_refused() {
  local dir home out rc
  dir=$(make_register malformed)
  home=$(make_home malformed)
  give_worktree "$home" epsilon >/dev/null
  write_decision "$home" epsilon nocontrol 'tier: cited-control
run: true'
  out=$(run_reg "$dir" "$home" --closes epsilon nocontrol); rc=$?
  expect_code 4 "$rc" "a cited-control block with no control must not close"
  assert_contains "$out" "declares no control" "the refusal must name the missing control"

  write_decision "$home" epsilon badtier 'tier: probably-fine
run: true'
  out=$(run_reg "$dir" "$home" --closes epsilon badtier); rc=$?
  expect_code 4 "$rc" "an unknown tier must not close"
  pass "a malformed probe block refuses the closure rather than being ignored"
}

# A PATH carrying the tools the register actually uses and no jq.
jqless_path() {
  local dir="$TMP_ROOT/nojq/bin" c p
  mkdir -p "$dir"
  for c in bash sh dirname basename date timeout gtimeout cksum mkdir mv rm tail tr \
           cut head sort ls sed awk grep cat env true false test git uname; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$dir/$c"
  done
  printf '%s\n' "$dir"
}

# --closes reads a decision file's pinned probe block, which is line-oriented text
# parsed in shell. Gating it on jq would stall the whole fleet's decision
# lifecycle on a tool the operation never calls: no `resolved` event could close
# anywhere, for want of something that would not have been used.
closes_reaches_a_verdict_without_jq() {
  local dir home path rc out
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    printf 'skip: no timeout tool, so no probe can be bounded here\n'
    return 0
  fi
  dir=$(make_register nojq)
  home=$(make_home nojq)
  give_worktree "$home" jqtask >/dev/null
  path=$(jqless_path)
  [ -z "$(PATH="$path" bash -c 'command -v jq')" ] \
    || fail "the fixture PATH still reaches jq, so this case proves nothing"

  write_decision "$home" jqtask crit 'tier: executable
run: false'
  out=$(PATH="$path" FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$REG" --closes jqtask crit); rc=$?
  expect_code 3 "$rc" "an unmet criterion must reach its verdict where jq is unavailable"
  assert_contains "$out" "the criterion is not met" \
    "the refusal must be the probe's answer, not a missing-dependency report"

  write_decision "$home" jqtask crit 'tier: executable
run: true'
  PATH="$path" FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$REG" --closes jqtask crit >/dev/null; rc=$?
  expect_code 0 "$rc" "a met criterion must close where jq is unavailable"

  # The control: the reports that DO read JSON entries still fail closed on it,
  # so this is a scoped dependency and not a dropped one.
  out=$(PATH="$path" FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$REG" --open); rc=$?
  expect_code 4 "$rc" "a report that reads JSON entries must still fail closed without jq"
  assert_contains "$out" "jq is required" "that report must say what it needed"
  pass "a closure gate that reads no JSON is not gated on jq, and the reports that do still are"
}

no_backfill_for_older_decisions() {
  local dir home out rc
  dir=$(make_register nobackfill)
  home=$(make_home nobackfill)
  mkdir -p "$home/data/zeta"
  printf '# an older ruling, written before the probe format existed\n' \
    > "$home/data/zeta/decision-legacy.md"

  out=$(run_reg "$dir" "$home" --closes zeta legacy); rc=$?
  expect_code 0 "$rc" "a decision with no registered probe must close exactly as it always did"
  [ -z "$out" ] || fail "a decision with no registered probe must say nothing, got: $out"

  out=$(run_reg "$dir" "$home" --json)
  assert_not_contains "$out" "decision:zeta:legacy" \
    "a decision with no probe block must not be given an invented one"

  # A key with no decision file at all is the same answer.
  run_reg "$dir" "$home" --closes zeta never-ruled >/dev/null; rc=$?
  expect_code 0 "$rc" "an unruled key must close normally"

  # But an existing decision file that cannot be READ is a different answer: it
  # may carry a probe nobody can see, so it must not be waved through as if no
  # probe were registered. Skipped as root, which can read it regardless.
  if [ "$(id -u)" -ne 0 ]; then
    local err
    chmod 000 "$home/data/zeta/decision-legacy.md"
    err="$TMP_ROOT/nobackfill-stderr"
    out=$(run_reg "$dir" "$home" --closes zeta legacy 2>"$err"); rc=$?
    chmod 644 "$home/data/zeta/decision-legacy.md"
    expect_code 4 "$rc" "an unreadable decision file must not be read as no probe registered"
    assert_contains "$out" "cannot be read" "the refusal must say the file could not be read"
    # The gate is consulted from inside the fold on ordinary wake handling, so it
    # must answer rather than leaking a shell error into a supervisor's output.
    [ ! -s "$err" ] \
      || fail "the closure gate wrote to stderr instead of answering: $(cat "$err")"
  fi
  pass "decisions ruled before the format are not back-filled and fold as before"
}

# --- the probe-result cache never serves an old answer as a current one -------
#
# --closes runs inside the open-decision fold, which recomputes from the whole
# status stream on every wake drain, every fleet snapshot and every decision-hold
# read - so an uncached probe re-runs a test for the remaining life of a status
# file. The cache bounds that, and the rule it may not break is that a stored
# result never reads as a fresh one. Both halves are driven: a served result says
# when it was observed, and the truth it stands in for is shown to differ.
cached_probe_result_never_reads_as_current() {
  local dir home out rc wt
  dir=$(make_register cache)
  home=$(make_home cache)
  wt=$(give_worktree "$home" cachetask)
  printf 'needs-decision [key=crit]: the ruled finding\n' > "$home/state/cachetask.status"
  write_decision "$home" cachetask crit 'tier: executable
run: test -f criterion-established'

  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 3 "$rc" "an unmet criterion must refuse its resolution"
  assert_not_contains "$out" "freshness bound" \
    "the first read must run the probe, not serve one"

  # Satisfy the criterion, recording nothing on the task. The stored result is
  # still inside its bound, so it is served - and it says so rather than passing
  # itself off as an answer about now.
  : > "$wt/criterion-established"
  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 3 "$rc" "a result inside its freshness bound is served"
  assert_contains "$out" "freshness bound" \
    "a served result must carry its observation time, never read as a current one"

  # And what it is standing in for is genuinely different: with the cache off,
  # the same call answers now, and answers the other way.
  out=$(FM_COMMITMENT_PROBE_CACHE_TTL=0 run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 0 "$rc" \
    "with the cache disabled the same call must reach the current answer, or the case above proved nothing"

  # A status append must NOT invalidate. The open-decision fold is DRIVEN by
  # status appends, so keying on them would miss on the one append where the
  # cache is supposed to help and hit only on idle tasks - and it would say
  # nothing about the worktree, where the answer actually lives.
  printf 'resolved [key=crit]: fix applied\n' >> "$home/state/cachetask.status"
  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 3 "$rc" \
    "a status append invalidated the stored result; the fold is driven by those appends, so that key helps only idle tasks"

  # The worktree head IS in the key: a new commit is the ordinary way a criterion
  # becomes met, so a verdict recorded before it is inapplicable rather than old.
  git -C "$wt" init -q
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'the commit that fixes the criterion'
  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 0 "$rc" "a moved worktree head must invalidate the stored result, not be answered from before it"

  # So are the decision file's own bytes: a rewritten criterion is a different
  # question, and the previous question's answer is not an answer to it.
  : > "$wt/criterion-established.v2"
  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 0 "$rc" "control: the criterion is met right now, so the rewrite below changes what is asked"
  write_decision "$home" cachetask crit 'tier: executable
run: test -f criterion-never-established'
  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 3 "$rc" "a rewritten decision file must invalidate the stored result rather than answering the old question"
  pass "a cached probe result carries its observation time and is invalidated by what it depends on"
}

# The provenance has to reach the path that CONSUMES the result. render_closes
# prints when an acceptance rests on a stored observation rather than on one made
# just now, and if bin/fm-classify-lib.sh captured that and dropped it on rc 0 the
# guarantee would exist only for a human running --closes by hand: the fold would
# close the decision with no sign the verdict was not observed now.
cached_result_carries_observation_time_on_the_accept_path() {
  local home err out wt
  home=$(make_home acceptnote)
  wt=$(give_worktree "$home" accepttask)
  : > "$wt/criterion-established"
  write_decision "$home" accepttask crit 'tier: executable
run: test -f criterion-established'
  printf 'needs-decision [key=crit]: the ruled finding\n' > "$home/state/accepttask.status"

  # Observe once, so the next fold is served from the store rather than running.
  run_reg "$TMP_ROOT/acceptnote/unused" "$home" --closes accepttask crit >/dev/null 2>&1

  err="$TMP_ROOT/acceptnote-stderr"
  printf 'resolved [key=crit]: fix applied\n' >> "$home/state/accepttask.status"
  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/accepttask.status" 2>"$err"
  )
  [ -z "$out" ] || fail "a passing criterion must still close the decision, got: $out"
  assert_contains "$(cat "$err")" "freshness bound" \
    "the accept path discarded the observation time; the fold closed the decision with no sign the verdict was not observed now"
  assert_contains "$(cat "$err")" "[key=crit]" \
    "the disclosure must say which decision it is about"

  # The control: a probe observed JUST NOW discloses nothing, because there is
  # nothing about it to disclose - otherwise the case above would pass on noise.
  rm -rf "$home/state/commitment-probe-cache"
  : > "$err"
  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/accepttask.status" 2>"$err"
  )
  [ -z "$out" ] || fail "control: a passing criterion must still close the decision, got: $out"
  [ ! -s "$err" ] || fail "a probe observed just now must disclose nothing: $(cat "$err")"

  # And the attested acceptance is disclosed for the same reason: the ruling
  # requires attested be marked and visible, never silently read as verified, and
  # on this path it would otherwise close indistinguishably from a passed probe.
  give_worktree "$home" attesttask >/dev/null
  write_decision "$home" attesttask crit 'tier: attested
reason: the criterion is that a comment reads accurately'
  printf 'needs-decision [key=crit]: the ruled finding\n' > "$home/state/attesttask.status"
  printf 'resolved [key=crit]: fix applied\n' >> "$home/state/attesttask.status"
  : > "$err"
  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/attesttask.status" 2>"$err"
  )
  [ -z "$out" ] || fail "an attested criterion must still close the decision, got: $out"
  assert_contains "$(cat "$err")" "ATTESTED-NOT-PROBED" \
    "an attested closure must not be indistinguishable from a passed probe on the fold's own path"
  pass "cached result carries observation time on the accept path"
}

# --- the fold keeps a refused resolution open --------------------------------

fold_keeps_refused_resolution_open() {
  local home out wt
  home=$(make_home fold)
  wt=$(give_worktree "$home" task1)
  git -C "$wt" init -q
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'before the fix'
  write_decision "$home" task1 crit 'tier: executable
run: test -f criterion-established'

  printf 'needs-decision [key=crit]: the ruled finding\n' > "$home/state/task1.status"
  printf 'resolved [key=crit]: fix applied\n' >> "$home/state/task1.status"

  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/task1.status"
  )
  assert_contains "$out" "crit" \
    "a resolution whose registered probe fails must keep the decision open"
  assert_contains "$out" "the criterion is not met" \
    "the still-open decision must carry why the resolution was not accepted"

  # The control: satisfy the criterion, and the SAME status stream closes. The
  # commit that establishes the criterion is what invalidates the earlier
  # observation - the worktree head is in the cache key precisely because that is
  # how a criterion becomes met. Without a change to something the answer depends
  # on the fold may serve the previous answer, and when it does it says so rather
  # than claiming to have looked just now.
  : > "$wt/criterion-established"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'the commit that establishes the criterion'
  printf 'resolved [key=crit]: criterion established\n' >> "$home/state/task1.status"
  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/task1.status"
  )
  [ -z "$out" ] || fail "once the probe passes, the resolution must close the decision, got: $out"

  # And a key with no registered probe is unaffected: the fold behaves as before.
  printf 'needs-decision [key=plain]: an ordinary decision\n' > "$home/state/task2.status"
  printf 'resolved [key=plain]: decided\n' >> "$home/state/task2.status"
  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/task2.status"
  )
  [ -z "$out" ] || fail "a decision with no registered probe must still close, got: $out"
  pass "the open-decision fold refuses a resolution its registered probe does not support"
}

# The gate's cost contract, driven rather than asserted. The fold runs over every
# status file on every wake drain, and a decision file EXISTING is the common
# case: every decision ruled before 2026-08-10 has one and none of them carries a
# probe block, and the ruling forbids back-filling them. If existence were the
# fence, that common case would spend an interpreter subprocess per legacy
# decision per drain, to be told there is nothing to evaluate.
fold_spends_no_subprocess_on_a_decision_without_a_probe() {
  local home log stub out
  home=$(make_home fence)
  mkdir -p "$TMP_ROOT/fence-gate" "$home/data/legacy"
  log="$TMP_ROOT/fence-gate/spawned"
  stub="$TMP_ROOT/fence-gate/stub.sh"
  cat > "$stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exit 0
SH
  chmod +x "$stub"
  printf '# an older ruling, written before the probe format existed\n' \
    > "$home/data/legacy/decision-old.md"
  printf 'needs-decision [key=old]: an older ruling\n' > "$home/state/legacy.status"
  printf 'resolved [key=old]: decided\n' >> "$home/state/legacy.status"

  out=$(
    FM_HOME="$home" FM_CLASSIFY_COMMITMENT_BIN="$stub" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/legacy.status"
  )
  [ -z "$out" ] || fail "a decision with no probe block must close exactly as it always did, got: $out"
  [ ! -e "$log" ] \
    || fail "the fold spent an interpreter subprocess on a decision file carrying no probe block: $(cat "$log")"

  # The control: the same fold, the same file, once it does carry a probe block.
  # Without it, the fence could be refusing to consult the interpreter at all.
  write_decision "$home" legacy old 'tier: executable
run: true'
  out=$(
    FM_HOME="$home" FM_CLASSIFY_COMMITMENT_BIN="$stub" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/legacy.status"
  )
  [ -s "$log" ] \
    || fail "the fence swallowed a decision file that does carry a probe block, so no probe would ever gate a closure"
  pass "only a decision that actually carries a probe block costs a subprocess"
}

# The one fail-open hole left in a gate whose whole job is to fail closed: with a
# probe registered and no interpreter to evaluate it, accepting the resolution
# would read an unevaluated criterion as met. Refusing wedges nothing - the
# decision simply keeps showing, carrying the reason.
fold_refuses_a_registered_probe_it_cannot_evaluate() {
  local home out
  home=$(make_home nointerp)
  give_worktree "$home" task9 >/dev/null
  write_decision "$home" task9 crit 'tier: executable
run: true'
  printf 'needs-decision [key=crit]: the ruled finding\n' > "$home/state/task9.status"
  printf 'resolved [key=crit]: fix applied\n' >> "$home/state/task9.status"

  # The control first: with the interpreter present, this exact probe closes.
  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/task9.status"
  )
  [ -z "$out" ] || fail "control: a passing probe must close this decision, got: $out"

  out=$(
    FM_HOME="$home" FM_CLASSIFY_COMMITMENT_BIN="$TMP_ROOT/nointerp/no-such-register.sh" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/task9.status"
  )
  assert_contains "$out" "crit" \
    "with no interpreter for a registered probe, the resolution must not be accepted"
  assert_contains "$out" "not available to evaluate it" \
    "the still-open decision must say why the criterion could not be evaluated"
  pass "a registered probe with no interpreter refuses the closure rather than being waved through"
}

# --- session start executes no probe -----------------------------------------
#
# Read precisely: no probe of the kind that is a TRUST decision. Two kinds live
# here and they are not the same question. The register's own typed probes are a
# closed, audited, 10s-bounded set this repository owns, so running one is a cost.
# A decision file's `run:` is arbitrary text from whoever authored a ruling,
# executed by bash -c inside a task worktree, so running one is a trust decision -
# and the chain that reaches it is real: bin/fm-session-start.sh runs
# bin/fm-admission.sh, which runs bin/fm-fleet-snapshot.sh, which folds every
# task's open decisions, which reaches the closure gate.
#
# This case drives the register end of that chain: with the guard on, no `run:`
# executes, and - the half that matters more - nothing is ACCEPTED either, neither
# from a run nor from a stored verdict. Each half is paired with the control that
# shows the probe really would have run and really would have closed the key.
# tests/fm-session-start.test.sh drives the whole composed chain against the real
# script, including that typed probes still run there.
session_start_executes_no_probe() {
  local dir home out rc wt marker
  dir=$(make_register noexec)
  home=$(make_home noexec)
  mkdir -p "$TMP_ROOT/noexec"

  marker="$TMP_ROOT/noexec/decision-ran"
  wt=$(give_worktree "$home" noexectask)
  write_decision "$home" noexectask crit "tier: executable
run: : > $marker"
  printf 'needs-decision [key=crit]: the ruled finding\n' > "$home/state/noexectask.status"
  printf 'resolved [key=crit]: fix applied\n' >> "$home/state/noexectask.status"

  # Control: allowed to run, this `run:` executes and the key closes.
  out=$(
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/noexectask.status" 2>/dev/null
  )
  [ -e "$marker" ] || fail "control: the decision probe never ran, so the case below would prove nothing"
  [ -z "$out" ] || fail "control: a passing decision probe must close the key, got: $out"

  rm -f "$marker"
  rm -rf "$home/state/commitment-probe-cache"
  out=$(
    FM_HOME="$home" FM_COMMITMENT_NO_DECISION_RUN=1 bash -c '
      . "$1/bin/fm-classify-lib.sh"
      status_open_decisions "$2"
    ' _ "$ROOT" "$home/state/noexectask.status" 2>/dev/null
  )
  [ ! -e "$marker" ] \
    || fail "session start ran a decision file's run: inside a task worktree"
  assert_contains "$out" "crit" \
    "not running must not mean accepting: the resolution must stay open, never be silently closed"
  assert_contains "$out" "executes no decision-file run command" \
    "the still-open decision must say the probe was not run"

  # And no stored verdict stands in for one either: a cached PASS would close the
  # key on an observation this session did not make, which is the accepting half
  # of the same failure.
  run_reg "$dir" "$home" --closes noexectask crit >/dev/null 2>&1
  rm -f "$marker"
  out=$(FM_COMMITMENT_NO_DECISION_RUN=1 run_reg "$dir" "$home" --closes noexectask crit); rc=$?
  expect_code 4 "$rc" "a stored verdict must not close a key session start did not observe"
  [ ! -e "$marker" ] || fail "the cache lookup ran the probe"
  pass "session start executes no probe that is a trust decision, and not running is never accepting"
}

# The distinction the guard rests on, driven rather than asserted: the SAME
# invocation must run the typed probe and refuse the decision-file `run:`. A guard
# that answered both would be the over-broad fix, and one that answered neither
# would be the original hazard.
session_start_runs_typed_probes_and_never_a_decision_run() {
  local dir home out rc typed_ran decision_ran wt
  local REG_ROOT
  dir=$(make_register bothkinds)
  home=$(make_home bothkinds)
  REG_ROOT=$(make_code_root bothkinds)
  typed_ran="$TMP_ROOT/bothkinds/typed-ran"
  decision_ran="$TMP_ROOT/bothkinds/decision-ran"
  cat > "$REG_ROOT/owner.sh" <<SH
#!/usr/bin/env bash
: > "$typed_ran"
printf 'enforced\n'
SH
  chmod +x "$REG_ROOT/owner.sh"
  write_owner_entry "$dir" typed-entry owner.sh

  wt=$(give_worktree "$home" bothtask)
  write_decision "$home" bothtask crit "tier: executable
run: : > $decision_ran"

  out=$(FM_COMMITMENT_NO_DECISION_RUN=1 run_reg "$dir" "$home" --json); rc=$?
  [ -e "$typed_ran" ] \
    || fail "the guard suppressed a typed probe; it is a closed audited set and a cost decision, not a trust one"
  [ ! -e "$decision_ran" ] \
    || fail "the guard let a ruling author's run: execute inside a task worktree"
  [ "$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="typed-entry") | .state')" = SATISFIED ] \
    || fail "a typed probe that passes must still reach SATISFIED under the guard"
  [ "$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="decision:bothtask:crit") | .state')" = UNOBSERVED ] \
    || fail "a decision-file criterion whose run: was not executed must read could-not-observe"
  expect_code 4 "$rc" "an unrun decision criterion must still take the fail-closed exit"

  # And the two are separable in the other direction too: without the guard the
  # same call runs both, so the case above is about the guard rather than about a
  # decision probe that never runs anywhere.
  rm -f "$typed_ran" "$decision_ran"
  rm -rf "$home/state/commitment-probe-cache"
  run_reg "$dir" "$home" --json >/dev/null
  [ -e "$typed_ran" ] && [ -e "$decision_ran" ] \
    || fail "control: an unguarded call must run both kinds, or the separation above proves nothing"
  pass "session start runs typed probes and never a decision-file run command"
}

# The captain's criterion, on the surface session start actually reads. A register
# that keeps printing after its commitment became real is the hand-maintained list
# it was built to replace, so the entry must go quiet under the guard too - and
# the entry file must be byte-identical across the transition.
typed_probe_pass_retires_the_entry_under_the_guard() {
  local dir home out rc owner before after
  local REG_ROOT
  dir=$(make_register retireguard)
  home=$(make_home retireguard)
  REG_ROOT=$(make_code_root retireguard)
  owner="$REG_ROOT/owner.sh"
  write_owner_entry "$dir" becomes-real owner.sh
  before=$(cksum < "$dir/becomes-real.json")

  out=$(FM_COMMITMENT_NO_DECISION_RUN=1 run_reg "$dir" "$home" --open); rc=$?
  expect_code 3 "$rc" "an unmet commitment must not exit all-clear, guard or no guard"
  assert_contains "$out" "COMMITMENT: becomes-real UNMET" \
    "an unmet commitment must be surfaced under the guard, with the verdict its probe reached"

  cat > "$owner" <<'SH'
#!/usr/bin/env bash
printf 'enforced\n'
SH
  chmod +x "$owner"

  out=$(FM_COMMITMENT_NO_DECISION_RUN=1 run_reg "$dir" "$home" --open); rc=$?
  expect_code 0 "$rc" "a satisfied commitment must exit all-clear under the guard"
  [ -z "$out" ] || fail "a commitment that became real must stop printing, guard or no guard, got: $out"
  after=$(cksum < "$dir/becomes-real.json")
  [ "$before" = "$after" ] \
    || fail "the entry retired only because it was edited; it must retire on the probe alone"
  pass "an entry whose typed probe passes retires without a hand edit"
}

# --- the two probe bounds, and a timeout that says so ------------------------

decision_probe_bound_matches_the_documented_value() {
  local coded documented entry_coded entry_documented
  coded=$(sed -n 's/^DECISION_PROBE_TIMEOUT_DEFAULT=\([0-9][0-9]*\)$/\1/p' "$REG" | head -1)
  entry_coded=$(grep -m1 '^PROBE_TIMEOUT=' "$REG" | tr -dc '0-9')
  documented=$(jq -r '.probe_bounds.decision_file_probe_seconds' "$SCHEMA_SRC")
  entry_documented=$(jq -r '.probe_bounds.register_entry_probe_seconds' "$SCHEMA_SRC")

  [ -n "$coded" ] || fail "the decision-probe bound could not be read out of $REG"
  [ -n "$entry_coded" ] || fail "the entry-probe bound could not be read out of $REG"
  [ "$coded" = "$documented" ] \
    || fail "the code bounds a decision-file probe at ${coded}s and commitments/schema.json documents ${documented}s; prose claiming what the code does not do is the failure this register is about"
  [ "$entry_coded" = "$entry_documented" ] \
    || fail "the code bounds a register-entry probe at ${entry_coded}s and commitments/schema.json documents ${entry_documented}s"

  # Both numbers are stated wherever either is, with the reason and the
  # derivation, so the next person changing one can see what they are trading.
  local header
  header=$(awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$REG")
  assert_contains "$header" "THE TWO PROBE BOUNDS" \
    "the script header must state both bounds, not just set them"
  assert_contains "$header" "runs in 7.8s" \
    "the header must record the measurement the larger bound was derived from"
  assert_contains "$(jq -r '.probe_bounds.derivation' "$SCHEMA_SRC")" "7.8s" \
    "commitments/schema.json must record the same derivation as the header"
  pass "decision-file probe bound matches the documented value"
}

timed_out_probe_is_reported_as_a_timeout() {
  local dir home out rc timeout_out unreachable_out
  dir=$(make_register timeout)
  home=$(make_home timeout)
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || {
    printf 'ok - a timed-out probe is reported as a timeout, distinct from other could-not-observe (skipped: no bounding tool)\n'
    return 0
  }
  give_worktree "$home" slowtask >/dev/null
  write_decision "$home" slowtask crit 'tier: executable
run: sleep 30'
  printf 'needs-decision [key=crit]: the ruled finding\n' > "$home/state/slowtask.status"

  timeout_out=$(FM_COMMITMENT_DECISION_PROBE_TIMEOUT=1 FM_COMMITMENT_PROBE_CACHE_TTL=0 \
    run_reg "$dir" "$home" --closes slowtask crit); rc=$?
  expect_code 4 "$rc" "a probe stopped at its bound is could-not-observe, never a pass"
  assert_contains "$timeout_out" "TIMEOUT" \
    "a timed-out probe must say so plainly, or a key that never closes reads as an ordinary open item"
  assert_contains "$timeout_out" "1s bound" \
    "the timeout must name the bound it was stopped at, so someone can fix the probe"

  # The control: a DIFFERENT could-not-observe cause must not read the same way,
  # or "distinct" would be a claim rather than an observation.
  write_decision "$home" orphantask crit 'tier: executable
run: true'
  unreachable_out=$(run_reg "$dir" "$home" --closes orphantask crit); rc=$?
  expect_code 4 "$rc" "control: an unrunnable probe is also could-not-observe"
  assert_not_contains "$unreachable_out" "TIMEOUT" \
    "every could-not-observe cause reads as a timeout, so the timeout is not distinguishable"
  pass "a timed-out probe is reported as a timeout, distinct from other could-not-observe"
}

# --- a typed probe may only run what this repository can audit ---------------
#
# The permission to run typed probes at session start rests on them being a
# closed set this repository owns. That is true of the KINDS and false of the
# TARGETS unless this holds: command, test and defined_in come out of the entry's
# own JSON, and entries also arrive from the gitignored $FM_HOME/data/commitments/
# overlay, so one unreviewed file could otherwise name any absolute executable
# and have it run on every session's critical path.
#
# Each refusal is paired with the control that shows the SAME probe, the SAME
# executable, named from inside the code root, does run and does pass - so the
# case is about where the target is, not about a probe that never runs.
typed_probe_target_outside_the_code_root_is_refused() {
  local dir home out state outside
  local REG_ROOT
  dir=$(make_register outsideroot)
  home=$(make_home outsideroot)
  REG_ROOT=$(make_code_root outsideroot)
  outside="$TMP_ROOT/outsideroot/outside-the-root"
  mkdir -p "$outside"
  cat > "$outside/owner.sh" <<'SH'
#!/usr/bin/env bash
printf 'enforced\n'
SH
  chmod +x "$outside/owner.sh"

  # The control: the same script, reached from inside the code root, passes.
  cp "$outside/owner.sh" "$REG_ROOT/owner.sh"
  write_owner_entry "$dir" in-root owner.sh
  out=$(run_reg "$dir" "$home" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="in-root") | .state')
  [ "$state" = SATISFIED ] \
    || fail "control: an in-root target must run and pass, or the refusals below prove nothing (got $state)"
  rm -f "$dir/in-root.json"

  # Upward traversal out of the root.
  write_owner_entry "$dir" traversal ../outside-the-root/owner.sh
  # A symlink inside the root pointing at the same script outside it.
  ln -sf "$outside/owner.sh" "$REG_ROOT/linked-owner.sh"
  write_owner_entry "$dir" symlinked linked-owner.sh
  # A directory symlink, so the escape is in the path rather than the leaf.
  ln -sfn "$outside" "$REG_ROOT/linked-dir"
  write_owner_entry "$dir" symlinked-dir linked-dir/owner.sh
  # The other two path-bearing fields, so this is a property of TARGETS rather
  # than of one probe kind.
  cat > "$dir/outside-test.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "outside-test",
  "recorded": "a named test establishes this commitment",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the named test passes",
  "assurance": "executable",
  "probe": {"kind": "test_passes", "test": "../outside-the-root/owner.sh"}
}
JSON
  cat > "$dir/outside-defined-in.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "outside-defined-in",
  "recorded": "the guard runs in production",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "some runtime caller invokes it",
  "assurance": "executable",
  "probe": {"kind": "symbol_called", "symbol": "lonely_guard",
            "defined_in": "../outside-the-root/owner.sh"}
}
JSON

  out=$(run_reg "$dir" "$home" --json)
  local id
  for id in traversal symlinked symlinked-dir outside-test outside-defined-in; do
    state=$(printf '%s' "$out" | jq -r --arg i "$id" '.entries[] | select(.id==$i) | .state')
    [ "$state" = UNOBSERVED ] \
      || fail "$id names a target outside the tracked code root and reached $state instead of being refused"
  done
  assert_contains "$out" "inadmissible probe target" \
    "a refused target must be reported as an inadmissible entry, never silently skipped"
  assert_contains "$out" "outside the tracked code root" \
    "the refusal must say the target leaves the code root"
  assert_contains "$out" "is a symlink" \
    "the refusal must name a symlinked target as the reason it cannot be audited"
  pass "a typed probe target outside the tracked code root is refused"
}

absolute_path_target_is_refused_verbatim() {
  local dir home out state absolute
  local REG_ROOT
  dir=$(make_register absroot)
  home=$(make_home absroot)
  REG_ROOT=$(make_code_root absroot)
  absolute="$REG_ROOT/owner.sh"
  cat > "$absolute" <<'SH'
#!/usr/bin/env bash
printf 'enforced\n'
SH
  chmod +x "$absolute"

  # The control comes first and is the whole point: this exact file, named
  # relative to the code root, runs and passes. So the refusal below is about the
  # path being absolute, not about the file.
  write_owner_entry "$dir" relative owner.sh
  out=$(run_reg "$dir" "$home" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="relative") | .state')
  [ "$state" = SATISFIED ] \
    || fail "control: the same file named relatively must run and pass (got $state)"
  rm -f "$dir/relative.json"

  # An absolute path that resolves INSIDE the code root is still refused: taking
  # one verbatim is the behaviour being removed, and admitting the convenient
  # cases back is how it returns.
  write_owner_entry "$dir" absolute-inside "$absolute"
  write_owner_entry "$dir" absolute-outside /bin/echo
  out=$(run_reg "$dir" "$home" --json)
  for state in absolute-inside absolute-outside; do
    [ "$(printf '%s' "$out" | jq -r --arg i "$state" '.entries[] | select(.id==$i) | .state')" = UNOBSERVED ] \
      || fail "$state was not refused; an absolute path must never be taken verbatim"
  done
  assert_contains "$out" "is an absolute path" \
    "the refusal must say the target is absolute"
  assert_contains "$out" "never taken verbatim" \
    "the refusal must say why an absolute path is not simply resolved"
  pass "an absolute path target is refused verbatim"
}

# --- the declared-uncovered half is the one field that can withhold ----------
#
# unobserved_conditions is the only field that can WITHHOLD satisfaction, so a
# malformed one is the one malformation that lets a passing probe retire a
# half-observed commitment. Read with jq's join over a bare string or an array of
# objects, it produces nothing, and nothing reads as "no half was declared".
malformed_unobserved_conditions_is_inadmissible() {
  local dir home out owner shape state err
  local REG_ROOT
  dir=$(make_register malformedhalf)
  home=$(make_home malformedhalf)
  REG_ROOT=$(make_code_root malformedhalf)
  owner="$REG_ROOT/owner.sh"
  cat > "$owner" <<'SH'
#!/usr/bin/env bash
printf 'enforced\n'
SH
  chmod +x "$owner"

  for shape in '"the second half"' '[{"half": "the second"}]' '[null]' '[]' '[""]'; do
    cat > "$dir/half.json" <<JSON
{
  "commitment_schema_version": 1,
  "id": "half",
  "recorded": "two things must both be true",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "both halves hold",
  "assurance": "executable",
  "probe": {"kind": "command_answers", "command": "owner.sh"},
  "unobserved_conditions": $shape
}
JSON
    err="$TMP_ROOT/malformedhalf/stderr"
    out=$(run_reg "$dir" "$home" --json 2>"$err")
    state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="half") | .state')
    [ "$state" = UNOBSERVED ] \
      || fail "unobserved_conditions $shape let a passing probe reach $state on a partial answer"
    assert_contains "$out" "unobserved_conditions must be a non-empty array" \
      "the refusal must name the malformed field"
    [ ! -s "$err" ] \
      || fail "a malformed unobserved_conditions leaked jq's complaint to the caller: $(cat "$err")"
  done

  # The control: the same entry, the same passing probe, with a well-formed
  # declaration - still UNOBSERVED, but for the reason the field exists, and a
  # well-formed entry must not be refused as malformed.
  cat > "$dir/half.json" <<JSON
{
  "commitment_schema_version": 1,
  "id": "half",
  "recorded": "two things must both be true",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "both halves hold",
  "assurance": "executable",
  "probe": {"kind": "command_answers", "command": "owner.sh"},
  "unobserved_conditions": ["the second half, which has no landed artifact to probe"]
}
JSON
  out=$(run_reg "$dir" "$home" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="half") | .state')
  [ "$state" = UNOBSERVED ] || fail "control: a declared uncovered half must still withhold SATISFIED, got $state"
  assert_not_contains "$out" "unobserved_conditions must be a non-empty array" \
    "a well-formed declaration must not be refused as malformed"
  pass "a malformed unobserved_conditions makes the entry inadmissible rather than skipping the guard"
}

# --- a textual mention is not a runtime caller -------------------------------
#
# This entry class IS "a guard with no runtime caller at all", so a probe that
# counts any occurrence lets a comment retire the entry while the guard still
# guards nothing - the register reproducing its own defect.
symbol_called_does_not_count_a_mention() {
  local dir home out state bin
  dir=$(make_register mention)
  home=$(make_home mention)
  bin="$TMP_ROOT/mention/root/bin"
  mkdir -p "$bin"
  cat > "$bin/fm-guard-lib.sh" <<'SH'
#!/usr/bin/env bash
lonely_guard() { return 0; }
SH
  cat > "$bin/fm-mentions-only.sh" <<'SH'
#!/usr/bin/env bash
# lonely_guard should be wired in here one day.
usage() { printf 'see lonely_guard for the rule this enforces\n'; }
usage
SH
  cat > "$dir/guard.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "guard",
  "recorded": "the guard runs in production",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "some runtime caller invokes it",
  "assurance": "executable",
  "probe": {"kind": "symbol_called", "symbol": "lonely_guard",
            "defined_in": "bin/fm-guard-lib.sh"}
}
JSON

  out=$(FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/mention/root" \
    "$REG" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="guard") | .state')
  [ "$state" = UNMET ] \
    || fail "a comment and a usage string retired the entry; a mention is not a runtime caller (got $state)"

  # The control: a real call in the same file, and the same probe passes. Without
  # it, this probe could simply be one that never finds a caller.
  cat > "$bin/fm-mentions-only.sh" <<'SH'
#!/usr/bin/env bash
# lonely_guard should be wired in here one day.
if lonely_guard "$@"; then
  printf 'guarded\n'
fi
SH
  out=$(FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/mention/root" \
    "$REG" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="guard") | .state')
  [ "$state" = SATISFIED ] \
    || fail "control: a real call must satisfy the entry, or the case above proves nothing (got $state)"

  # A declared name goes into that call-shaped regex, so one carrying a regex
  # metacharacter is refused rather than matching more than it names. "." is the
  # one that reads as an ordinary character: bash permits it in a function name,
  # and interpolated it matches ANY character, so fm.verify would report SATISFIED
  # on a caller of fm_verify.
  cat > "$bin/fm-lonely-guard.sh" <<'SH'
#!/usr/bin/env bash
lonely_guard "$@"
SH
  cat > "$dir/guard.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "guard",
  "recorded": "the guard runs in production",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "some runtime caller invokes it",
  "assurance": "executable",
  "probe": {"kind": "symbol_called", "symbol": "lonely.guard",
            "defined_in": "bin/fm-guard-lib.sh"}
}
JSON
  out=$(FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/mention/root" \
    "$REG" --json)
  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="guard") | .state')
  [ "$state" = UNOBSERVED ] \
    || fail "a symbol carrying a regex metacharacter matched a call to a different function and reported $state"
  assert_contains "$out" "not a plain shell function name" \
    "the refusal must say the declared name is not one a call can be told from a pattern"
  pass "a mention in a comment or a usage string is not a runtime caller"
}

red_capable_then_retires
three_values_are_distinct
status_word_cannot_satisfy
no_probe_is_inadmissible
absent_register_is_not_a_pass
four_shapes_are_expressible
partial_probe_cannot_claim_the_whole_commitment
unknown_harness_is_could_not_observe_not_excluded
pinned_block_tiers
pinned_block_cannot_observe
pinned_block_malformed_is_refused
no_backfill_for_older_decisions
closes_reaches_a_verdict_without_jq
cached_probe_result_never_reads_as_current
cached_result_carries_observation_time_on_the_accept_path
session_start_executes_no_probe
session_start_runs_typed_probes_and_never_a_decision_run
typed_probe_pass_retires_the_entry_under_the_guard
decision_probe_bound_matches_the_documented_value
timed_out_probe_is_reported_as_a_timeout
typed_probe_target_outside_the_code_root_is_refused
absolute_path_target_is_refused_verbatim
malformed_unobserved_conditions_is_inadmissible
symbol_called_does_not_count_a_mention
fold_keeps_refused_resolution_open
fold_spends_no_subprocess_on_a_decision_without_a_probe
fold_refuses_a_registered_probe_it_cannot_evaluate
