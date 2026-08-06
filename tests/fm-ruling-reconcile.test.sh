#!/usr/bin/env bash
# Tests for reconciling ruling documents against open captain decision holds.
#
# The rule under test is the captain's ruling of 2026-08-06 (option c): a hold
# may be closed on the strength of a ruling only when the ruling names the hold
# identifier VERBATIM and carries an EXPLICIT VERDICT TOKEN. Everything else
# escalates. Each case below drives the eligibility verdict apart deliberately,
# so a classifier that stopped reading either condition fails here rather than
# passing vacuously.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-ruling-reconcile.sh"
HOLD="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-ruling-reconcile)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TASKS_AXI_BIN=$(command -v tasks-axi)

# The reconciler needs only `tasks-axi list`. The two cases that drive
# fm-decision-hold.sh additionally pass through its version floor. Where the
# installed build is below that floor but has every capability the floor exists
# to guarantee, report the floor version and delegate EVERY real command to the
# real binary, so the code path is exercised for real rather than skipped. The
# capability probes below still run against the real build, so a genuinely
# incapable tasks-axi still refuses.
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-tasks-axi-lib.sh"

install_tasks_axi_floor_shim() {  # <home>
  cat > "$1/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\n' "$FM_TASKS_AXI_MIN"; exit 0; fi
exec "$TASKS_AXI_BIN" "\$@"
EOF
  chmod +x "$1/fakebin/tasks-axi"
}

HOLD_MECHANICS_AVAILABLE=1
if ! fm_tasks_axi_compatible >/dev/null 2>&1; then
  SHIM_PROBE=$(fm_test_tmproot fm-ruling-shim-probe)
  mkdir -p "$SHIM_PROBE/fakebin"
  install_tasks_axi_floor_shim "$SHIM_PROBE"
  PATH="$SHIM_PROBE/fakebin:$PATH" fm_tasks_axi_compatible >/dev/null 2>&1 \
    || HOLD_MECHANICS_AVAILABLE=0
fi

# A ruling table whose rows deliberately differ: alpha carries an emphasised
# verdict, beta carries none, and beta sits directly above a row that does carry
# one so a windowed scan would wrongly inherit it.
write_corpus() {  # <home>
  local home=$1
  mkdir -p "$home/data/sample-commission"
  cat > "$home/data/captain-rulings-2026-01-01.md" <<'EOF'
# Captain rulings — 2026-01-01

| ID | Register identity | Ruling |
|---|---|---|
| **A1** | `sample-review-decision-alpha` | **APPROVED** — build it as specified. |
| **A2** | `sample-review-decision-beta` | Consider the tradeoff and report back. |
| **A3** | `sample-review-decision-carol` | **RESOLVED** — recorded and closed. |
EOF
  cat > "$home/data/sample-commission/commission.md" <<'EOF'
# Sample commission

Investigate `sample-review-decision-gamma` and report what you find.
The investigation is **APPROVED** to proceed.
EOF
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  install_tasks_axi_floor_shim "$home"
  write_corpus "$home"
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

add_hold() {  # <home> <hold-id> <title>
  local home=$1 id=$2 title=$3
  tasks_in "$home" add "$id" "$title" --kind captain --repo sample \
    --body "Origin: sample-review" >/dev/null
  tasks_in "$home" hold "$id" --reason "needs the captain" --kind captain >/dev/null
}

run_reconcile() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_RULING_NOW=2026-01-01T00:00:00Z "$RECONCILE" "$@"
}

match_field() {  # <home> <hold-id> <1-based-field>
  awk -F'\t' -v h="$1" -v f="$2" '$1 == h { print $f; exit }' \
    "$3/state/ruling-index/matches.tsv" 2>/dev/null
}

# --- 1. the four grades, driven apart in one corpus -------------------------

test_eligibility_separates_ruling_commission_and_silence() {
  local home elig
  home=$(make_home grades)
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  add_hold "$home" sample-review-decision-gamma "Gamma decision"
  add_hold "$home" sample-review-decision-delta "Delta decision"
  run_reconcile "$home" scan >/dev/null || fail "scan failed"

  elig=$(match_field sample-review-decision-alpha 7 "$home")
  [ "$elig" = closable-if-graded-rules ] \
    || fail "a hold named in a ruling beside an explicit verdict must be eligible, got: $elig"

  # A hold named only in a COMMISSION is never eligible, however decisive the
  # commission's own language sounds - that document says **APPROVED** too.
  elig=$(match_field sample-review-decision-gamma 7 "$home")
  [ "$elig" = escalate ] \
    || fail "a hold named in a commission must escalate, got: $elig"
  [ "$(match_field sample-review-decision-gamma 4 "$home")" = commission ] \
    || fail "the commission document must be classified commission"

  # An unmatched hold is REPORTED open, never dropped.
  [ "$(match_field sample-review-decision-delta 2 "$home")" = none ] \
    || fail "an unmatched hold must be reported with ruling_file=none"
  [ "$(match_field sample-review-decision-delta 7 "$home")" = escalate ] \
    || fail "an unmatched hold must escalate"
  run_reconcile "$home" propose | grep -qF 'sample-review-decision-delta,none' \
    || fail "an unmatched hold must appear in the grading envelope"

  pass "eligibility separates ruling, commission, and durable-source silence"
}

# --- 2. the mutation control: red before, green after -----------------------
#
# Removes ONE row's verdict token and asserts the eligibility flips. Run in this
# order the check is proven able to reject: the same assertion that holds before
# the mutation must fail after it.

test_removing_a_verdict_token_flips_eligibility() {
  local home before after
  home=$(make_home mutation)
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  run_reconcile "$home" scan >/dev/null || fail "scan failed"
  before=$(match_field sample-review-decision-alpha 7 "$home")
  [ "$before" = closable-if-graded-rules ] \
    || fail "control precondition: alpha must start eligible, got: $before"

  # The verdict token, and only the verdict token, is removed.
  sed -i 's/| \*\*APPROVED\*\* — build it as specified. |/| Build it as specified. |/' \
    "$home/data/captain-rulings-2026-01-01.md"
  run_reconcile "$home" scan >/dev/null || fail "rescan failed"
  after=$(match_field sample-review-decision-alpha 7 "$home")
  [ "$after" = escalate ] \
    || fail "removing the verdict token must flip eligibility to escalate, got: $after"
  [ "$(match_field sample-review-decision-alpha 5 "$home")" = none ] \
    || fail "verdict_token must read none once the token is gone"

  pass "removing a ruling row's verdict token flips its eligibility"
}

# --- 3. a table row never inherits a neighbour's verdict --------------------
#
# Regression for a measured defect: a windowed verdict scan attributed row B1's
# **RESOLVED** to row A4 six lines above it. beta has no verdict of its own and
# sits directly above carol, which has one.

test_table_row_does_not_inherit_the_next_rows_verdict() {
  local home
  home=$(make_home bleed)
  add_hold "$home" sample-review-decision-beta "Beta decision"
  add_hold "$home" sample-review-decision-carol "Carol decision"
  run_reconcile "$home" scan >/dev/null || fail "scan failed"

  [ "$(match_field sample-review-decision-carol 5 "$home")" = '**RESOLVED**' ] \
    || fail "control precondition: carol must carry its own verdict token"
  [ "$(match_field sample-review-decision-beta 5 "$home")" = none ] \
    || fail "beta must not inherit the verdict of the row below it"
  [ "$(match_field sample-review-decision-beta 7 "$home")" = escalate ] \
    || fail "a row with no verdict of its own must escalate"

  pass "a table row never inherits an adjacent row's verdict"
}

# --- 4. no_delta costs no extraction ----------------------------------------

test_no_delta_reaches_the_terminal_without_extracting() {
  local home out
  home=$(make_home nodelta)
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  run_reconcile "$home" scan >/dev/null || fail "first scan failed"

  # Sentinel is created AFTER the first scan, so anything the second scan
  # rewrites is newer than it.
  touch "$home/sentinel"
  out=$(run_reconcile "$home" scan) || fail "second scan failed"
  printf '%s\n' "$out" | grep -qxF 'verdict=no_delta' \
    || fail "an unchanged corpus and hold set must reach no_delta, got: $out"
  printf '%s\n' "$out" | grep -qxF 'extracted=0' \
    || fail "no_delta must extract nothing, got: $out"
  [ -z "$(find "$home/state/ruling-index/matches.tsv" -newer "$home/sentinel" 2>/dev/null)" ] \
    || fail "no_delta must not rewrite the index"

  # A single new hold is a delta, so the terminal is not simply always taken.
  add_hold "$home" sample-review-decision-delta "Delta decision"
  out=$(run_reconcile "$home" scan) || fail "third scan failed"
  printf '%s\n' "$out" | grep -qxF 'verdict=delta' \
    || fail "control: a new open hold must force a rescan, got: $out"

  pass "no_delta is reached without extraction and still yields to a real change"
}

# --- 5. the empty-set law ---------------------------------------------------

test_unreadable_ruling_document_refuses_the_run() {
  local home out rc=0
  home=$(make_home unreadable)
  add_hold "$home" sample-review-decision-delta "Delta decision"
  run_reconcile "$home" scan >/dev/null || fail "baseline scan failed"

  # A ruling-class path this script will not read. Symlinked rather than
  # chmod-ed so the case is real for a root test runner too.
  rm -f "$home/data/captain-rulings-2026-01-01.md"
  ln -s /dev/null "$home/data/captain-rulings-2026-01-01.md"
  out=$(run_reconcile "$home" scan 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "an unreadable ruling document must exit 3, got rc=$rc"
  printf '%s\n' "$out" | grep -qF 'verdict=NO_RULING_READ' \
    || fail "an unreadable ruling document must yield NO_RULING_READ, got: $out"
  # `grep -qv` would pass on any multi-line output and prove nothing; the
  # absence must be asserted over the whole output.
  ! printf '%s\n' "$out" | grep -qF 'unruled' \
    || fail "an unread ruling must never be reported as unruled, got: $out"

  pass "an unreadable ruling document yields NO_RULING_READ, never unruled"
}

# --- 6. closure authority ---------------------------------------------------

test_closure_test_enforces_both_conditions() {
  local home out line
  home=$(make_home closure)

  line=$(grep -nF 'sample-review-decision-alpha' "$home/data/captain-rulings-2026-01-01.md" | cut -d: -f1)
  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha \
    --ruling captain-rulings-2026-01-01.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'closure=permitted' \
    || fail "control precondition: a verbatim identifier beside a verdict must be permitted, got: $out"

  # Same row, same verdict, a grade that is not `rules`. The agent's grade is a
  # separate condition and cannot be skipped.
  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha \
    --ruling captain-rulings-2026-01-01.md --line "$line" --grade cites)
  printf '%s\n' "$out" | grep -qxF 'closure=escalate' \
    || fail "a grade of cites must escalate, got: $out"

  # A commission, graded `rules` by an agent that overreached. Condition 1 is
  # not satisfied by a commission and no grade can substitute for it.
  line=$(grep -nF 'sample-review-decision-gamma' "$home/data/sample-commission/commission.md" | cut -d: -f1)
  out=$(run_reconcile "$home" closure-test sample-review-decision-gamma \
    --ruling sample-commission/commission.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'closure=escalate' \
    || fail "a commission graded rules must still escalate, got: $out"
  printf '%s\n' "$out" | grep -qxF 'reason=not-a-ruling-document' \
    || fail "the refusal must name the commission as the reason, got: $out"

  # A line that does not name the identifier verbatim.
  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha \
    --ruling captain-rulings-2026-01-01.md --line 1 --grade rules)
  printf '%s\n' "$out" | grep -qxF 'reason=identifier-not-verbatim-on-cited-line' \
    || fail "a cited line that does not name the hold must escalate, got: $out"

  pass "closure requires a ruling, a verbatim identifier, a verdict token, and a rules grade"
}

# --- 7. resolve verifies the provenance it records --------------------------

test_resolve_refuses_unverified_ruling_provenance() {
  local home out rc=0 show
  if [ "$HOLD_MECHANICS_AVAILABLE" -eq 0 ]; then
    printf 'skip - resolve provenance needs tasks-axi >= %s, found %s\n' \
      "$FM_TASKS_AXI_MIN" "$(tasks-axi --version 2>/dev/null | head -1)"
    return 0
  fi
  home=$(make_home provenance)
  mkdir -p "$home/data/sample-review"
  printf 'evidence\n' > "$home/data/sample-review/report.md"
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  tasks_in "$home" add follow-up-work "Follow-up work" --repo sample >/dev/null
  tasks_in "$home" block follow-up-work --by sample-review-decision-alpha >/dev/null
  printf 'the captain said build it\n' > "$home/decision.txt"

  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$HOLD" resolve sample-review alpha \
    --decision-file "$home/decision.txt" --routed-to follow-up-work \
    --from-ruling sample-commission/commission.md:3 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve must refuse a provenance that fails the closure test"
  printf '%s\n' "$out" | grep -qF 'fails the captain closure test' \
    || fail "the refusal must name the closure test, got: $out"
  show=$(tasks_in "$home" show sample-review-decision-alpha --full)
  printf '%s\n' "$show" | grep -qF 'state: queued' \
    || fail "a refused provenance must leave the hold open"

  # The same resolve with a provenance that PASSES the test records it.
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$HOLD" resolve sample-review alpha \
    --decision-file "$home/decision.txt" --routed-to follow-up-work \
    --from-ruling captain-rulings-2026-01-01.md:5 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "control: a verified provenance must be accepted, got: $out"
  show=$(tasks_in "$home" show sample-review-decision-alpha --full)
  printf '%s\n' "$show" | grep -qF 'Ruling provenance: captain-rulings-2026-01-01.md:5' \
    || fail "an accepted provenance must be recorded on the hold"
  printf '%s\n' "$show" | grep -qF 'state: done' \
    || fail "a verified resolve must still close the hold"

  pass "resolve verifies ruling provenance instead of stamping it"
}

# --- 8. the retired self-report ---------------------------------------------

test_hold_body_carries_no_self_reported_state() {
  local home show
  if [ "$HOLD_MECHANICS_AVAILABLE" -eq 0 ]; then
    printf 'skip - hold creation needs tasks-axi >= %s, found %s\n' \
      "$FM_TASKS_AXI_MIN" "$(tasks-axi --version 2>/dev/null | head -1)"
    return 0
  fi
  home=$(make_home selfreport)
  mkdir -p "$home/data/sample-review"
  printf 'evidence\n' > "$home/data/sample-review/report.md"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$HOLD" hold sample-review alpha \
    --title "Alpha decision" --reason "needs the captain" >/dev/null \
    || fail "hold creation failed"
  show=$(tasks_in "$home" show sample-review-decision-alpha --full)
  ! printf '%s\n' "$show" | grep -qF 'awaiting captain decision' \
    || fail "a hold must not self-report its state in its body, got: $show"
  # The structured fields remain the single state owner.
  printf '%s\n' "$show" | grep -qF 'held: yes' \
    || fail "the structured held field must still report the hold as active"
  printf '%s\n' "$show" | grep -qF 'hold_kind: captain' \
    || fail "the structured hold_kind field must still report the captain"

  pass "hold state is owned by the structured fields, not by body prose"
}

test_eligibility_separates_ruling_commission_and_silence
test_removing_a_verdict_token_flips_eligibility
test_table_row_does_not_inherit_the_next_rows_verdict
test_no_delta_reaches_the_terminal_without_extracting
test_unreadable_ruling_document_refuses_the_run
test_closure_test_enforces_both_conditions
test_resolve_refuses_unverified_ruling_provenance
test_hold_body_carries_no_self_reported_state
