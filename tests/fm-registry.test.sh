#!/usr/bin/env bash
# Behavior tests for bin/fm-registry.sh - the helper backing the captain-invocable
# propose-tool and report-problem skills.
#
# The helper's whole job is to append a schema-consistent entry to the right
# tracked registry (CAPABILITIES.md / PROBLEMS.md) AND queue an evaluation in the
# fleet-local queue, so proposals and problems are named and tracked instead of
# hand-written (and drifting) per submission. These cases pin:
#   - propose-tool appends the documented Tool/Replaces/Why better/Notes/Status/
#     Proposed schema to CAPABILITIES.md and a pointer line to the queue.
#   - report-problem appends the documented Problem/Symptom/Impact/Suspected root
#     cause/Candidate fix/tool/Status/Reported schema to PROBLEMS.md and a queue line.
#   - the queue file is created with its header on first use.
#   - duplicate ids in the same timestamp second get a -N suffix (no overwrite).
#   - a punctuation/non-ASCII-only title slugifies to the `entry` fallback.
#   - report-problem without --fix records the documented TBD placeholder.
#   - missing required flags / unknown subcommand fail non-zero with a message.
#   - queue preflight: if data/ cannot be created, the tracked registry is NOT
#     mutated (no recorded entry without a queued evaluation).
# All hermetic over copies of the real registries under a temp FM_ROOT.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REG="$ROOT/bin/fm-registry.sh"
TMP_ROOT=$(fm_test_tmproot fm-registry)

# A fresh sandbox FM_ROOT seeded with copies of the real tracked registries, so
# appends land against the real document structure. Echoes the sandbox path.
make_sandbox() {
  local dir=$1
  mkdir -p "$dir"
  cp "$ROOT/CAPABILITIES.md" "$dir/CAPABILITIES.md"
  cp "$ROOT/PROBLEMS.md" "$dir/PROBLEMS.md"
  printf '%s\n' "$dir"
}

# Run the helper with the sandbox as FM_ROOT/FM_HOME (so the queue lands under
# <sandbox>/data). Caller captures $? for exit-code assertions.
run_registry() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$REG" "$@" 2>&1
}

# --- propose-tool: schema + queue -------------------------------------------

test_propose_tool_records_and_queues() {
  local home out cap queue entry
  home=$(make_sandbox "$TMP_ROOT/propose")
  cap="$home/CAPABILITIES.md"
  queue="$home/data/evaluation-queue.md"

  out=$(run_registry "$home" propose-tool \
    --tool "ripgrep" \
    --replaces "grep for fleet-wide search" \
    --why "much faster on large clones" \
    --notes "install via brew"); status=$?
  expect_code 0 "$status" "propose-tool should succeed"
  assert_contains "$out" "recorded" "propose-tool did not confirm the recording"
  assert_contains "$out" "CAPABILITIES.md" "propose-tool did not name the registry"
  assert_contains "$out" "evaluation-queue.md" "propose-tool did not name the queue"

  # The appended entry carries every documented field, in order, with values.
  entry=$(awk '/^### T-.*ripgrep/{p=1} p{print} p&&/Proposed:/{exit}' "$cap")
  assert_contains "$entry" "### T-" "appended id is not the timestamped T- form"
  assert_contains "$entry" "- **Tool:** ripgrep" "missing Tool field"
  assert_contains "$entry" "- **Replaces:** grep for fleet-wide search" "missing Replaces field"
  assert_contains "$entry" "- **Why better:** much faster on large clones" "missing Why better field"
  assert_contains "$entry" "- **Notes:** install via brew" "missing Notes field"
  assert_contains "$entry" "- **Status:** proposed" "missing/!proposed Status field"
  assert_contains "$entry" "- **Proposed:**" "missing Proposed date field"

  # The queue was created with its header and a pointer line naming the entry.
  assert_present "$queue" "evaluation queue was not created"
  assert_grep "# Evaluation queue (fleet-local)" "$queue" "queue is missing its header"
  assert_grep "evaluate tool proposal" "$queue" "queue is missing the proposal pointer line"
  assert_grep "-> CAPABILITIES.md" "$queue" "queue line does not point at CAPABILITIES.md"
  pass "propose-tool: appends the documented schema to CAPABILITIES.md and queues an evaluation"
}

# --- report-problem: schema + queue + optional --fix default ----------------

test_report_problem_records_and_queues() {
  local home out prob queue entry
  home=$(make_sandbox "$TMP_ROOT/report")
  prob="$home/PROBLEMS.md"
  queue="$home/data/evaluation-queue.md"

  out=$(run_registry "$home" report-problem \
    --problem "Steers get dropped mid-turn" \
    --symptom "a sent line never reaches the crewmate" \
    --impact "wasted turns re-sending" \
    --cause "send raced the busy signature" \
    --fix "settle before send"); status=$?
  expect_code 0 "$status" "report-problem should succeed"
  assert_contains "$out" "PROBLEMS.md" "report-problem did not name the registry"

  entry=$(awk '/^### P-.*Steers/{p=1} p{print} p&&/Reported:/{exit}' "$prob")
  assert_contains "$entry" "### P-" "appended id is not the timestamped P- form"
  assert_contains "$entry" "- **Problem:** Steers get dropped mid-turn" "missing Problem field"
  assert_contains "$entry" "- **Symptom:** a sent line never reaches the crewmate" "missing Symptom field"
  assert_contains "$entry" "- **Impact:** wasted turns re-sending" "missing Impact field"
  assert_contains "$entry" "- **Suspected root cause:** send raced the busy signature" "missing Suspected root cause field"
  assert_contains "$entry" "- **Candidate fix / tool:** settle before send" "missing Candidate fix / tool field"
  assert_contains "$entry" "- **Status:** reported" "missing/!reported Status field"
  assert_contains "$entry" "- **Reported:**" "missing Reported date field"

  assert_grep "evaluate problem" "$queue" "queue is missing the problem pointer line"
  assert_grep "-> PROBLEMS.md" "$queue" "queue line does not point at PROBLEMS.md"

  # Optional --fix omitted -> the documented TBD placeholder, not an empty field.
  out=$(run_registry "$home" report-problem \
    --problem "No-fix case" \
    --symptom "s" --impact "i" --cause "c"); status=$?
  expect_code 0 "$status" "report-problem without --fix should still succeed"
  entry=$(awk '/^### P-.*No-fix case/{p=1} p{print} p&&/Reported:/{exit}' "$prob")
  assert_contains "$entry" "- **Candidate fix / tool:** TBD - to be evaluated" \
    "omitted --fix did not record the TBD placeholder"
  pass "report-problem: appends the documented schema (and TBD default) to PROBLEMS.md and queues an evaluation"
}

# --- id collision: same-second submissions never overwrite ------------------

test_unique_id_suffix() {
  local home cap n
  home=$(make_sandbox "$TMP_ROOT/collide")
  cap="$home/CAPABILITIES.md"
  run_registry "$home" propose-tool --tool "dupe" --replaces "x" --why "y" >/dev/null
  run_registry "$home" propose-tool --tool "dupe" --replaces "x" --why "y" >/dev/null
  # Two distinct headings for the same tool, the second carrying a -N suffix.
  n=$(grep -cE '^### T-[0-9]{8}-[0-9]{6}-dupe(-[0-9]+)? - dupe$' "$cap")
  [ "$n" -ge 2 ] || fail "expected >=2 distinct dupe ids, got $n"
  assert_grep "-dupe-2 - dupe" "$cap" "collision did not produce a -2 suffixed id"
  pass "propose-tool: a colliding id is suffixed -N instead of overwriting"
}

# --- slug fallback: a title with no slug characters -------------------------

test_slug_fallback() {
  local home prob
  home=$(make_sandbox "$TMP_ROOT/slug")
  prob="$home/PROBLEMS.md"
  run_registry "$home" report-problem --problem "??? !!!" --symptom s --impact i --cause c >/dev/null
  assert_grep "-entry - ??? !!!" "$prob" "punctuation-only title did not fall back to the 'entry' slug"
  assert_no_grep "-- - ??? !!!" "$prob" "fallback id has a malformed empty slug"
  pass "fm-registry: a no-slug title gets the stable 'entry' id fallback"
}

# --- input validation -------------------------------------------------------

test_validation() {
  local home out
  home=$(make_sandbox "$TMP_ROOT/validate")

  out=$(run_registry "$home" propose-tool --tool "only-tool"); status=$?
  expect_code 1 "$status" "missing required flag should fail"
  assert_contains "$out" "missing required --replaces" "missing-flag error did not name the field"

  out=$(run_registry "$home" frobnicate); status=$?
  expect_code 1 "$status" "unknown subcommand should fail"
  assert_contains "$out" "unknown subcommand" "unknown subcommand lacked an error"

  out=$(run_registry "$home" report-problem --bogus x); status=$?
  expect_code 1 "$status" "unknown flag should fail"
  assert_contains "$out" "unknown flag" "unknown flag lacked an error"
  pass "fm-registry: missing flags, unknown subcommand, and unknown flags fail non-zero with a message"
}

# --- preflight: no registry mutation when the queue cannot be created --------

test_queue_preflight_guards_registry() {
  local home cap before after out
  home=$(make_sandbox "$TMP_ROOT/preflight")
  cap="$home/CAPABILITIES.md"
  before=$(grep -c '^### T-' "$cap")
  # Force the queue dir uncreatable by rooting it under a regular file, so
  # ensure_queue's mkdir -p fails before any registry append happens.
  printf 'i am a file\n' > "$home/blocker"
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_DATA_OVERRIDE="$home/blocker/data" \
    "$REG" propose-tool --tool "should-not-land" --replaces x --why y 2>&1); status=$?
  expect_code 1 "$status" "an uncreatable queue dir should fail the run"
  after=$(grep -c '^### T-' "$cap")
  [ "$before" = "$after" ] || fail "tracked registry was mutated despite the queue failing ($before -> $after)"
  assert_no_grep "should-not-land" "$cap" "an entry leaked into the registry without a queued evaluation"
  pass "fm-registry: a failed queue preflight leaves the tracked registry untouched"
}

test_propose_tool_records_and_queues
test_report_problem_records_and_queues
test_unique_id_suffix
test_slug_fallback
test_validation
test_queue_preflight_guards_registry
