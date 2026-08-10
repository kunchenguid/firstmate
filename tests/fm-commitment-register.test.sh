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

# An entry whose probe is a declared owner command: absent by default, so the
# commitment reads unmet until the owner is actually created.
write_owner_entry() {  # <register-dir> <id> <command-path>
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

run_reg() {  # <register-dir> <home> [args...]
  local dir=$1 home=$2
  shift 2
  FM_COMMITMENT_DIR="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$REG" "$@"
}

# --- red-capable, in both directions ----------------------------------------

red_capable_then_retires() {
  local dir home out rc before after owner
  dir=$(make_register red)
  home=$(make_home red)
  owner="$TMP_ROOT/red/owner.sh"
  write_owner_entry "$dir" unmet-then-met "$owner"
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
  dir=$(make_register three)
  home=$(make_home three)

  owner="$TMP_ROOT/three/answers.sh"
  cat > "$owner" <<'SH'
#!/usr/bin/env bash
printf 'yes\n'
SH
  chmod +x "$owner"
  write_owner_entry "$dir" is-met "$owner"

  write_owner_entry "$dir" is-unmet "$TMP_ROOT/three/absent.sh"

  # Exits 0 and prints nothing: the empty result set, which is the canonical
  # could-not-observe and must not read as either verdict.
  local silent="$TMP_ROOT/three/silent.sh"
  cat > "$silent" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$silent"
  write_owner_entry "$dir" cannot-observe "$silent"

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
  "probe": {"kind": "command_answers", "command": "$TMP_ROOT/word/absent.sh"}
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
  dir=$(make_register partial)
  home=$(make_home partial)
  owner="$TMP_ROOT/partial/owner.sh"
  mkdir -p "$TMP_ROOT/partial"
  cat > "$owner" <<'SH'
#!/usr/bin/env bash
printf 'enforced\n'
SH
  chmod +x "$owner"

  # The control: the SAME passing probe on an entry whose commitment the probe
  # covers entirely. Without it, the case below could pass because the probe
  # failed rather than because the uncovered half withheld the verdict.
  write_owner_entry "$dir" whole-commitment "$owner"

  cat > "$dir/half-commitment.json" <<JSON
{
  "commitment_schema_version": 1,
  "id": "half-commitment",
  "recorded": "two things must both be true, and only one of them has anything to probe",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the declared owner answers AND the second half becomes observable",
  "assurance": "executable",
  "probe": {"kind": "command_answers", "command": "$owner"},
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
    awk -v arm="$2" '{ print }
      /^    kimi\) printf/ { print "    " arm ") printf %s " arm " ;;" }' \
      "$ROOT/bin/fm-launch-lib.sh" > "$dir/fm-launch-lib.sh"
  else
    cp "$ROOT/bin/fm-launch-lib.sh" "$dir/fm-launch-lib.sh"
  fi
  # Every adapter this repo has recorded a posture for reports enforced, so the
  # only thing that can hold the probe back is an adapter it has not.
  cat >> "$dir/fm-launch-lib.sh" <<'SH'
launch_permission_recorded() {
  case "$1" in
    frobnicator) return 1 ;;
    *) printf 'enforced' ;;
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
  pass "a harness with no recorded posture is could-not-observe, never left out of the answer"
}

# --- the pinned decision-file probe block ------------------------------------

write_decision() {  # <home> <task> <key> <block-body>
  mkdir -p "$1/data/$2"
  {
    printf '# decision\n\n'
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
  local dir home out rc
  dir=$(make_register cache)
  home=$(make_home cache)
  give_worktree "$home" cachetask >/dev/null
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
  : > "$home/wt-cachetask/criterion-established"
  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 3 "$rc" "a result inside its freshness bound is served"
  assert_contains "$out" "freshness bound" \
    "a served result must carry its observation time, never read as a current one"

  # And what it is standing in for is genuinely different: with the cache off,
  # the same call answers now, and answers the other way.
  out=$(FM_COMMITMENT_PROBE_CACHE_TTL=0 run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 0 "$rc" \
    "with the cache disabled the same call must reach the current answer, or the case above proved nothing"

  # Recorded progress on the task invalidates the stored result rather than being
  # answered from before it.
  printf 'resolved [key=crit]: fix applied\n' >> "$home/state/cachetask.status"
  out=$(run_reg "$dir" "$home" --closes cachetask crit); rc=$?
  expect_code 0 "$rc" "a status event on the task must invalidate the stored result"
  pass "a cached probe result carries its observation time and is invalidated by progress"
}

# --- the fold keeps a refused resolution open --------------------------------

fold_keeps_refused_resolution_open() {
  local home out
  home=$(make_home fold)
  give_worktree "$home" task1 >/dev/null
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
  # worker recording that it re-resolved is what invalidates the earlier
  # observation; without a new event the fold may serve the previous answer, and
  # when it does it says so rather than claiming to have looked just now.
  : > "$home/wt-task1/criterion-established"
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
fold_keeps_refused_resolution_open
fold_spends_no_subprocess_on_a_decision_without_a_probe
fold_refuses_a_registered_probe_it_cannot_evaluate
