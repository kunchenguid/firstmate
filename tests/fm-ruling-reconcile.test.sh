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
#
# Three further rows exist only to be REFUSED, and each names a hold no other
# row names. `alpha-two` is a longer identifier that contains `alpha`, so a
# substring test would let alpha be closed on alpha-two's verdict. `delta-two`
# and `epsilon` carry emphasised English words that merely contain a verdict
# token, so an unanchored token test would accept an ordinary noun as the
# captain's explicit verdict.
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
| **A4** | `sample-review-decision-alpha-two` | **APPROVED** — a different decision. |
| **A5** | `sample-review-decision-delta-two` | The **Runtime** owns work identity. |
| **A6** | `sample-review-decision-epsilon` | That shape is **acceptable** for now. |
EOF
  cat > "$home/data/sample-commission/commission.md" <<'EOF'
# Sample commission

Investigate `sample-review-decision-gamma` and report what you find.
The investigation is **APPROVED** to proceed.
EOF
  # A commission whose NAME contains `ruling-`. Class is decided structurally,
  # and the commission suffix is decisive, so this must never become a ruling.
  cat > "$home/data/cfvc-remediation-ruling-commission.md" <<'EOF'
# A commission named like a ruling

Investigate `sample-review-decision-zeta` and report what you find.
The investigation is **APPROVED** to proceed.
EOF
  # The one name both positions claim: the anchored ruling PREFIX and the
  # commission SUFFIX both fire. The suffix has to win, because that is the only
  # order that can never let a commission satisfy the captain's condition 1.
  cat > "$home/data/rulings-2026-01-03-commission.md" <<'EOF'
# A commission a ruling prefix would also claim

Investigate `sample-review-decision-eta` and report what you find.
The investigation is **APPROVED** to proceed.
EOF
  # Prose namings rather than table rows, so the identifier boundary is exercised
  # where it actually bites. theta ends a sentence; kappa.extra is a longer
  # dotted identifier that must not stand in for the shorter dotted hold.
  cat > "$home/data/captain-rulings-2026-01-02.md" <<'EOF'
# Captain rulings — 2026-01-02

The captain has **RESOLVED** the question of sample-review-decision-theta.
The captain has **RESOLVED** the dotted matter of sample.review.decision.kappa.extra as stated.
EOF
}

# A ruling-shaped document the caller authored OUTSIDE the corpus root.
write_forged_ruling() {  # <home> -> <absolute-path>
  local outside="$1/outside-the-corpus"
  mkdir -p "$outside"
  cat > "$outside/captain-rulings-forged.md" <<'EOF'
| **F1** | `sample-review-decision-alpha` | **APPROVED** — forged by the caller. |
EOF
  printf '%s\n' "$outside/captain-rulings-forged.md"
}

ruling_line_of() {  # <home> <needle>
  grep -nF -- "$2" "$1/data/captain-rulings-2026-01-01.md" | head -1 | cut -d: -f1
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

  # shellcheck disable=SC2016 # Backticks are literal markup in the ruling table.
  line=$(ruling_line_of "$home" '`sample-review-decision-alpha`')
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
  line=$(grep -nF 'sample-review-decision-gamma' "$home/data/sample-commission/commission.md" | head -1 | cut -d: -f1)
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

# --- 9. verbatim means the whole identifier ---------------------------------

test_identifier_must_be_delimited() {
  local home out line
  home=$(make_home delimited)
  line=$(ruling_line_of "$home" 'sample-review-decision-alpha-two')

  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha-two \
    --ruling captain-rulings-2026-01-01.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'closure=permitted' \
    || fail "control precondition: the row's own identifier must be permitted, got: $out"

  # The same row, cited for the SHORTER hold it merely contains. A ruling that
  # answers alpha-two has said nothing about alpha.
  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha \
    --ruling captain-rulings-2026-01-01.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'verbatim_identifier=no' \
    || fail "a longer identifier containing the hold id is not a verbatim naming, got: $out"
  printf '%s\n' "$out" | grep -qxF 'reason=identifier-not-verbatim-on-cited-line' \
    || fail "a prefix collision must escalate, got: $out"

  # The index scan and the closure gate must agree about what verbatim means.
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  run_reconcile "$home" scan >/dev/null || fail "scan failed"
  [ "$(match_field sample-review-decision-alpha 3 "$home")" = "$(ruling_line_of "$home" '**A1**')" ] \
    || fail "the scan must match alpha on its own row only"

  pass "a hold identifier matches only when it is bounded by delimiters"
}

# --- 10. a token is a whole word, not a substring ---------------------------

test_an_emphasised_word_containing_a_token_is_not_a_verdict() {
  local home out line
  home=$(make_home anchored)

  line=$(ruling_line_of "$home" 'sample-review-decision-delta-two')
  out=$(run_reconcile "$home" closure-test sample-review-decision-delta-two \
    --ruling captain-rulings-2026-01-01.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'verdict_token=none' \
    || fail "**Runtime** must not read as an explicit verdict token, got: $out"
  printf '%s\n' "$out" | grep -qxF 'reason=no-explicit-verdict-token' \
    || fail "an emphasised noun must escalate, got: $out"

  line=$(ruling_line_of "$home" 'sample-review-decision-epsilon')
  out=$(run_reconcile "$home" closure-test sample-review-decision-epsilon \
    --ruling captain-rulings-2026-01-01.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'verdict_token=none' \
    || fail "**acceptable** must not read as an explicit verdict token, got: $out"

  # Control: a whole-word token on the same table still qualifies, so the check
  # is not passing by refusing everything.
  line=$(ruling_line_of "$home" 'sample-review-decision-carol')
  out=$(run_reconcile "$home" closure-test sample-review-decision-carol \
    --ruling captain-rulings-2026-01-01.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'closure=permitted' \
    || fail "control: a whole-word verdict token must still be permitted, got: $out"

  pass "an emphasised word merely containing a token is not an explicit verdict"
}

# --- 11. the closure gate is confined to the corpus -------------------------

test_closure_test_refuses_a_ruling_outside_the_corpus() {
  local home out forged
  home=$(make_home containment)
  forged=$(write_forged_ruling "$home")

  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha \
    --ruling "$forged" --line 1 --grade rules)
  printf '%s\n' "$out" | grep -qxF 'closure=escalate' \
    || fail "an out-of-corpus ruling must escalate, got: $out"
  printf '%s\n' "$out" | grep -qxF 'reason=ruling-document-outside-corpus-root' \
    || fail "an absolute path outside the corpus must be refused by name, got: $out"

  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha \
    --ruling ../outside-the-corpus/captain-rulings-forged.md --line 1 --grade rules)
  printf '%s\n' "$out" | grep -qxF 'reason=ruling-document-outside-corpus-root' \
    || fail "a ../ traversal out of the corpus must be refused, got: $out"

  # A symlink INTO the corpus is the same escape wearing a corpus-relative name.
  ln -s "$forged" "$home/data/captain-rulings-linked.md"
  out=$(run_reconcile "$home" closure-test sample-review-decision-alpha \
    --ruling captain-rulings-linked.md --line 1 --grade rules)
  printf '%s\n' "$out" | grep -qxF 'closure=escalate' \
    || fail "a symlinked ruling must never authorise a closure, got: $out"

  pass "closure-test confines --ruling to the corpus root"
}

# --- 12. the commission suffix is decisive ----------------------------------

test_a_commission_named_like_a_ruling_is_still_a_commission() {
  local home out line
  home=$(make_home commissionname)
  line=$(grep -nF 'sample-review-decision-zeta' \
    "$home/data/cfvc-remediation-ruling-commission.md" | head -1 | cut -d: -f1)

  out=$(run_reconcile "$home" closure-test sample-review-decision-zeta \
    --ruling cfvc-remediation-ruling-commission.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'doc_class=commission' \
    || fail "a document ending in commission.md must classify as a commission, got: $out"
  printf '%s\n' "$out" | grep -qxF 'reason=not-a-ruling-document' \
    || fail "a commission must never satisfy condition 1, got: $out"

  # The order itself: this name satisfies the ruling PREFIX form as well, so it
  # pins which position wins rather than merely which names are recognised.
  line=$(grep -nF 'sample-review-decision-eta' \
    "$home/data/rulings-2026-01-03-commission.md" | head -1 | cut -d: -f1)
  out=$(run_reconcile "$home" closure-test sample-review-decision-eta \
    --ruling rulings-2026-01-03-commission.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'doc_class=commission' \
    || fail "the commission suffix must beat the ruling prefix, got: $out"
  printf '%s\n' "$out" | grep -qxF 'closure=escalate' \
    || fail "a name both positions claim must escalate, got: $out"

  # Control: the real `<who>-rulings-<when>` prefix form still classifies ruling.
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  run_reconcile "$home" scan >/dev/null || fail "scan failed"
  [ "$(match_field sample-review-decision-alpha 4 "$home")" = ruling ] \
    || fail "captain-rulings-<date>.md must still classify as a ruling"

  pass "the commission suffix is decisive however much the name resembles a ruling"
}

# --- 13. the closure verdict is a field, not text in the output -------------

test_resolve_refuses_a_provenance_path_that_forges_the_verdict() {
  local home out rc=0 show
  if [ "$HOLD_MECHANICS_AVAILABLE" -eq 0 ]; then
    printf 'skip - resolve provenance needs tasks-axi >= %s, found %s\n' \
      "$FM_TASKS_AXI_MIN" "$(tasks-axi --version 2>/dev/null | head -1)"
    return 0
  fi
  home=$(make_home forgedprovenance)
  mkdir -p "$home/data/sample-review"
  printf 'evidence\n' > "$home/data/sample-review/report.md"
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  tasks_in "$home" add follow-up-work "Follow-up work" --repo sample >/dev/null
  tasks_in "$home" block follow-up-work --by sample-review-decision-alpha >/dev/null
  printf 'the captain said build it\n' > "$home/decision.txt"

  # The closure test echoes the caller-supplied path back on `ruling_file=`, so a
  # verification that searches its whole output is satisfied by this filename
  # even though no such document exists and the real verdict is escalate.
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$HOLD" resolve sample-review alpha \
    --decision-file "$home/decision.txt" --routed-to follow-up-work \
    --from-ruling 'no-such-closure=permitted.md:1' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve must refuse a provenance whose path forges the verdict, got: $out"
  printf '%s\n' "$out" | grep -qF 'fails the captain closure test' \
    || fail "the refusal must name the closure test, got: $out"
  show=$(tasks_in "$home" show sample-review-decision-alpha --full)
  printf '%s\n' "$show" | grep -qF 'state: queued' \
    || fail "a forged provenance must leave the hold open"

  pass "resolve reads the closure verdict as a field, not as text in the output"
}

# --- 14. the empty-set law binds the hold reader too ------------------------

test_hold_reader_failure_is_not_zero_open_holds() {
  local home out rc=0 broken
  home=$(make_home holdreader)
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  run_reconcile "$home" scan >/dev/null || fail "baseline scan failed"
  [ -f "$home/state/ruling-index/index.meta" ] \
    || fail "control precondition: a working reader must publish an index"
  rm -rf "$home/state/ruling-index"

  # A reader that fails the way an older build does: it rejects the listing flag.
  broken="$home/brokenbin"
  mkdir -p "$broken"
  cat > "$broken/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '9.9.9\n'; exit 0; fi
if [ "${1:-}" = list ]; then printf 'error: "Unknown flag: --kind"\n' >&2; exit 2; fi
exit 0
EOF
  chmod +x "$broken/tasks-axi"

  out=$(PATH="$broken:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_RULING_NOW=2026-01-01T00:00:00Z \
    "$RECONCILE" scan 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "a failing hold reader must exit 3, got rc=$rc: $out"
  printf '%s\n' "$out" | grep -qF 'verdict=NO_HOLD_READ' \
    || fail "a failing hold reader must yield NO_HOLD_READ, got: $out"
  ! printf '%s\n' "$out" | grep -qF 'open_holds=0' \
    || fail "a failing hold reader must never present as zero open holds, got: $out"
  [ ! -f "$home/state/ruling-index/index.meta" ] \
    || fail "a failing hold reader must publish no index, got: $out"

  pass "a failing hold reader refuses instead of reporting zero open holds"
}

# --- 15. the identifier boundary, driven three ways -------------------------
#
# All three of these once returned verbatim_identifier=no, so a fix that made
# them all `yes` would be exactly as wrong as the boundary that refused them.
# They are asserted together for that reason.

test_identifier_boundary_separates_sentence_end_from_shadowing() {
  local home out line

  home=$(make_home boundary)
  line=$(grep -nF 'sample-review-decision-theta' \
    "$home/data/captain-rulings-2026-01-02.md" | head -1 | cut -d: -f1)

  # 1. An identifier that ends a sentence IS a verbatim naming.
  out=$(run_reconcile "$home" closure-test sample-review-decision-theta \
    --ruling captain-rulings-2026-01-02.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'verbatim_identifier=yes' \
    || fail "an identifier ending a sentence must be a verbatim naming, got: $out"
  printf '%s\n' "$out" | grep -qxF 'closure=permitted' \
    || fail "a sentence-ending naming beside a verdict token must be permitted, got: $out"

  # 2. A shorter dotted identifier still cannot stand in for a longer one.
  line=$(grep -nF 'sample.review.decision.kappa.extra' \
    "$home/data/captain-rulings-2026-01-02.md" | head -1 | cut -d: -f1)
  out=$(run_reconcile "$home" closure-test sample.review.decision.kappa \
    --ruling captain-rulings-2026-01-02.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'verbatim_identifier=no' \
    || fail "a longer dotted identifier must not name the shorter hold, got: $out"
  printf '%s\n' "$out" | grep -qxF 'reason=identifier-not-verbatim-on-cited-line' \
    || fail "a dotted prefix collision must escalate, got: $out"
  out=$(run_reconcile "$home" closure-test sample.review.decision.kappa.extra \
    --ruling captain-rulings-2026-01-02.md --line "$line" --grade rules)
  printf '%s\n' "$out" | grep -qxF 'closure=permitted' \
    || fail "control: the dotted identifier's own naming must be permitted, got: $out"

  # 3. The index scan shares the boundary, and a hold named nowhere stays
  # reported open rather than being quietly matched by the widened rule.
  add_hold "$home" sample-review-decision-theta "Theta decision"
  add_hold "$home" sample.review.decision.kappa "Kappa decision"
  add_hold "$home" sample-review-decision-delta "Delta decision"
  run_reconcile "$home" scan >/dev/null || fail "scan failed"
  [ "$(match_field sample-review-decision-theta 2 "$home")" = captain-rulings-2026-01-02.md ] \
    || fail "the scan must find the sentence-ending naming, not report it unmatched"
  [ "$(match_field sample.review.decision.kappa 2 "$home")" = none ] \
    || fail "the scan must not match the shorter dotted hold on the longer identifier"
  [ "$(match_field sample-review-decision-delta 2 "$home")" = none ] \
    || fail "a hold named nowhere must still be reported unmatched"
  run_reconcile "$home" propose \
    | grep -qF 'unmatched: no ruling document names this hold' \
    || fail "the unmatched row must still appear in the grading envelope"

  pass "the identifier boundary accepts a sentence end without accepting a longer identifier"
}

test_eligibility_separates_ruling_commission_and_silence
test_removing_a_verdict_token_flips_eligibility
test_table_row_does_not_inherit_the_next_rows_verdict
test_no_delta_reaches_the_terminal_without_extracting
test_unreadable_ruling_document_refuses_the_run
test_closure_test_enforces_both_conditions
test_resolve_refuses_unverified_ruling_provenance
test_hold_body_carries_no_self_reported_state
test_identifier_must_be_delimited
test_an_emphasised_word_containing_a_token_is_not_a_verdict
test_closure_test_refuses_a_ruling_outside_the_corpus
test_a_commission_named_like_a_ruling_is_still_a_commission
# --- 16. an interrupt stops the resolve, and cleanup still happens ----------
#
# The work file that holds the closure test's stderr is cleaned up on a signal,
# but the signal must still terminate the process. A handler that neither exits
# nor re-raises lets bash resume the script once it returns, and `resolve` would
# then run on and CLOSE the captain hold the operator was interrupting.
#
# The two halves are asserted together on purpose: deleting the trap outright
# would satisfy the interrupt half while reopening the temp-file leak it was
# added to close, and a swallowing trap satisfies the cleanup half while losing
# the interrupt. Neither passes both.

# A stand-in bin/ that runs the REAL fm-decision-hold.sh while letting the test
# hold its closure-test subprocess open. Only the subprocess is substituted.
install_reconcile_shim() {  # <home>
  local home=$1 script shim="$1/shimbin"
  mkdir -p "$shim"
  for script in "$ROOT"/bin/*.sh; do
    ln -sf "$script" "$shim/$(basename "$script")"
  done
  # The stub REPLACES the symlink rather than being written through it: `cat >`
  # onto a symlink follows it and would truncate the real script in bin/.
  rm -f "$shim/fm-ruling-reconcile.sh"
  [ ! -L "$shim/fm-ruling-reconcile.sh" ] \
    || fail "the reconcile stub must not be a symlink into bin/"
  cat > "$shim/fm-ruling-reconcile.sh" <<EOF
#!/usr/bin/env bash
if [ -e "$home/block-closure-test" ]; then
  : > "$home/closure-test-started"
  sleep 2
fi
exec "$ROOT/bin/fm-ruling-reconcile.sh" "\$@"
EOF
  chmod +x "$shim/fm-ruling-reconcile.sh"
  grep -q 'fm-ruling-reconcile.sh - deterministic' "$ROOT/bin/fm-ruling-reconcile.sh" \
    || fail "the stub overwrote the real bin/fm-ruling-reconcile.sh"
}

test_interrupt_stops_the_resolve_and_still_cleans_up() {
  local home rc=0 show pid waited tmp leaked
  if [ "$HOLD_MECHANICS_AVAILABLE" -eq 0 ]; then
    printf 'skip - resolve provenance needs tasks-axi >= %s, found %s\n' \
      "$FM_TASKS_AXI_MIN" "$(tasks-axi --version 2>/dev/null | head -1)"
    return 0
  fi
  home=$(make_home interrupt)
  mkdir -p "$home/data/sample-review"
  printf 'evidence\n' > "$home/data/sample-review/report.md"
  add_hold "$home" sample-review-decision-alpha "Alpha decision"
  tasks_in "$home" add follow-up-work "Follow-up work" --repo sample >/dev/null
  tasks_in "$home" block follow-up-work --by sample-review-decision-alpha >/dev/null
  printf 'the captain said build it\n' > "$home/decision.txt"
  install_reconcile_shim "$home"
  tmp="$home/tmpdir"
  mkdir -p "$tmp"

  # A provenance that WOULD be accepted, so nothing but the interrupt can stop
  # the close. Line 5 is the alpha row of the fixture ruling table.
  #
  # Job control is enabled for the launch because a non-interactive shell starts
  # background jobs with SIGINT ignored, and a signal ignored on entry cannot be
  # trapped at all. Without `set -m` this case would pass against any handler,
  # including no handler, because the signal would never reach the script.
  : > "$home/block-closure-test"
  set -m
  TMPDIR="$tmp" PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/shimbin/fm-decision-hold.sh" resolve sample-review alpha \
    --decision-file "$home/decision.txt" --routed-to follow-up-work \
    --from-ruling captain-rulings-2026-01-01.md:5 >/dev/null 2>&1 &
  pid=$!
  waited=0
  while [ ! -e "$home/closure-test-started" ]; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 300 ] || fail "the closure-test subprocess never started"
  done
  # Only the script is interrupted; its subprocess is left to finish normally and
  # report closure=permitted. Nothing but the signal can stop the close, so a
  # handler that returns instead of terminating closes the hold here.
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" || rc=$?
  set +m
  rm -f "$home/block-closure-test"

  [ "$rc" -ne 0 ] || fail "an interrupted resolve must not exit 0"
  [ "$rc" -ge 128 ] \
    || fail "an interrupted resolve must exit with a signal status, got: $rc"
  show=$(tasks_in "$home" show sample-review-decision-alpha --full)
  printf '%s\n' "$show" | grep -qF 'state: queued' \
    || fail "an interrupted resolve must leave the captain hold open, got: $show"
  leaked=$(find "$tmp" -name 'fm-decision-hold-closure.*' | grep -c . || true)
  [ "$leaked" -eq 0 ] \
    || fail "an interrupted resolve must not leave its work file behind"

  # Controls: the ordinary refusal and the ordinary success still clean up, so
  # the interrupt fix cannot regress into having no trap at all.
  rc=0
  TMPDIR="$tmp" PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/shimbin/fm-decision-hold.sh" resolve sample-review alpha \
    --decision-file "$home/decision.txt" --routed-to follow-up-work \
    --from-ruling sample-commission/commission.md:3 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "control: a commission provenance must still be refused"
  leaked=$(find "$tmp" -name 'fm-decision-hold-closure.*' | grep -c . || true)
  [ "$leaked" -eq 0 ] || fail "a refused resolve must not leave its work file behind"

  rc=0
  TMPDIR="$tmp" PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/shimbin/fm-decision-hold.sh" resolve sample-review alpha \
    --decision-file "$home/decision.txt" --routed-to follow-up-work \
    --from-ruling captain-rulings-2026-01-01.md:5 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "control: an uninterrupted verified resolve must succeed"
  show=$(tasks_in "$home" show sample-review-decision-alpha --full)
  printf '%s\n' "$show" | grep -qF 'state: done' \
    || fail "control: an uninterrupted verified resolve must still close the hold"
  leaked=$(find "$tmp" -name 'fm-decision-hold-closure.*' | grep -c . || true)
  [ "$leaked" -eq 0 ] || fail "a successful resolve must not leave its work file behind"

  pass "an interrupt terminates the resolve, leaves the hold open, and still cleans up"
}

test_resolve_refuses_a_provenance_path_that_forges_the_verdict
test_hold_reader_failure_is_not_zero_open_holds
test_identifier_boundary_separates_sentence_end_from_shadowing
test_interrupt_stops_the_resolve_and_still_cleans_up
