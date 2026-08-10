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
#     asserted to.
#   - THE PINNED PROBE BLOCK. Every tier of the 2026-08-10 ruling is driven to its
#     own outcome, including the no-back-fill rule for decisions ruled before it.
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

  # 3. A derived-state row that went stale: expressed as its replacement's owner
  #    answering, so the row's truth is computed rather than hand-maintained.
  cat > "$dir/shape-stale-row.json" <<'JSON'
{
  "commitment_schema_version": 1,
  "id": "shape-stale-row",
  "recorded": "the compensation ledger's pending row has a landed owner",
  "authority": "tests/fm-commitment-register.test.sh",
  "unmet_state": "RULED-NOT-ENFORCED",
  "satisfied_when": "the replacement owner answers",
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

  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-stale-row") | .state')
  [ "$state" = SATISFIED ] \
    || fail "a landed owner must make the stale-row shape SATISFIED, got $state"

  state=$(printf '%s' "$out" | jq -r '.entries[] | select(.id=="shape-expired") | .overdue')
  [ "$state" = true ] || fail "an entry past its deadline must be reported overdue, got $state"
  out=$(run_reg "$dir" "$home" --open)
  assert_contains "$out" "past its 2000-01-01 deadline" \
    "an overdue entry must say so where it is surfaced"
  pass "all four measured failure shapes are expressible, each with its control"
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
  local dir home out rc gamma_wt
  dir=$(make_register pinned)
  home=$(make_home pinned)
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

  run_reg "$dir" "$home" --closes alpha met >/dev/null; rc=$?
  expect_code 0 "$rc" "a met criterion must allow its resolution to close"

  out=$(run_reg "$dir" "$home" --closes beta notmet); rc=$?
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

  # The control: satisfy the criterion, and the SAME status stream closes.
  : > "$home/wt-task1/criterion-established"
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

red_capable_then_retires
three_values_are_distinct
status_word_cannot_satisfy
no_probe_is_inadmissible
absent_register_is_not_a_pass
four_shapes_are_expressible
pinned_block_tiers
pinned_block_cannot_observe
pinned_block_malformed_is_refused
no_backfill_for_older_decisions
fold_keeps_refused_resolution_open
