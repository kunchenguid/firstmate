#!/usr/bin/env bash
# Behavior tests for the deterministic research-corpus scanner.
#
# Every claim this scanner makes is a claim about absence - nothing changed,
# nothing was reopened, no model ran, nothing outside the corpus was read - and
# absence passes vacuously when the test setup is wrong. So each test here
# first proves its own instrument works by watching the negative control fail,
# and only then asserts the real behavior.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-research-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-research-scan)

# A home with its own throwaway git repo standing in for the firstmate
# checkout, so no test ever depends on the real repository's HEAD or contents.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/projects" "$home/repo"
  git -C "$home/repo" init -q -b main
  git -C "$home/repo" config user.email fm@example.invalid
  git -C "$home/repo" config user.name Firstmate
  mkdir -p "$home/repo/bin"
  printf 'placeholder\n' > "$home/repo/bin/placeholder.sh"
  git -C "$home/repo" add -A
  git -C "$home/repo" -c commit.gpgsign=false commit -qm initial
  printf '%s\n' "$home"
}

run_scan() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home/repo" FM_RESEARCH_NOW=2026-08-04T00:00:00Z \
    "$SCAN" "$@"
}

add_report() {  # <home> <slug> <body>
  mkdir -p "$1/data/$2"
  printf '%s\n' "$3" > "$1/data/$2/report.md"
}

value_of() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# --- 1. unchanged corpus reaches no_delta, and spends no model turn ---------
#
# "Zero model turns" is enforced by making every agent runtime on PATH a trap
# that records its own invocation. The negative control fires the trap on
# purpose first, because a trap that never worked would let a broken scanner
# pass this test silently.
test_no_delta_costs_no_model_turn() {
  local home out fired
  home=$(make_home no-delta)
  add_report "$home" alpha '# Alpha
LC-R4 was approved.'
  add_report "$home" beta '# Beta
ADR-0050 is superseded.'

  local trapbin="$home/trapbin" marker="$home/model-was-invoked"
  mkdir -p "$trapbin"
  local agent
  for agent in claude codex pi opencode grok kimi curl wget; do
    cat > "$trapbin/$agent" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$agent" >> "$marker"
exit 97
EOF
    chmod +x "$trapbin/$agent"
  done

  # Negative control: the trap must actually record an invocation.
  PATH="$trapbin:$PATH" claude --version >/dev/null 2>&1
  [ -f "$marker" ] || fail "negative control: model-invocation trap never fired"
  fired=$(wc -l < "$marker" | tr -d ' ')
  [ "$fired" = "1" ] || fail "negative control: trap recorded $fired invocations, expected 1"
  rm -f "$marker"

  out=$(PATH="$trapbin:$PATH" run_scan "$home") || fail "first scan failed"
  [ "$(value_of "$out" verdict)" = "delta" ] || fail "first scan should report delta"

  out=$(PATH="$trapbin:$PATH" run_scan "$home") || fail "second scan failed"
  [ "$(value_of "$out" verdict)" = "no_delta" ] \
    || fail "unchanged corpus should reach no_delta, got: $(value_of "$out" verdict)"
  [ "$(value_of "$out" reports_reopened)" = "0" ] \
    || fail "no_delta must reopen no reports"
  [ ! -f "$marker" ] \
    || fail "no_delta spent a model turn: $(tr '\n' ' ' < "$marker")"

  pass "unchanged corpus reaches no_delta with zero model turns"
}

# --- 2. one changed report is the only report reconsidered ------------------
test_single_change_reopens_only_that_report() {
  local home out
  home=$(make_home single-change)
  add_report "$home" alpha '# Alpha
LC-R4 was approved.'
  add_report "$home" beta '# Beta
ADR-0050 is superseded.'
  add_report "$home" gamma '# Gamma
CAP-015 is deferred.'

  run_scan "$home" >/dev/null || fail "seed scan failed"

  # Negative control: with nothing touched the scanner must not reopen
  # anything, so a nonzero count below is attributable to the edit alone.
  out=$(run_scan "$home") || fail "unchanged scan failed"
  [ "$(value_of "$out" reports_reopened)" = "0" ] \
    || fail "negative control: untouched corpus reopened a report"

  add_report "$home" beta '# Beta
ADR-0050 is superseded, and CAP-016 now supersedes it.'

  out=$(run_scan "$home") || fail "post-edit scan failed"
  [ "$(value_of "$out" verdict)" = "delta" ] || fail "edited corpus should report delta"
  [ "$(value_of "$out" reports_reopened)" = "1" ] \
    || fail "expected exactly 1 report reopened, got $(value_of "$out" reports_reopened)"
  [ "$(value_of "$out" reused)" = "2" ] \
    || fail "expected 2 reports reused, got $(value_of "$out" reused)"
  printf '%s\n' "$out" | grep -qx 'changed=beta/report.md' \
    || fail "the changed report should be named"
  printf '%s\n' "$out" | grep -qx 'changed=alpha/report.md' \
    && fail "an untouched report was reconsidered"

  pass "one changed report reopens only that report"
}

# --- 3. a deleted cache rebuilds deterministically --------------------------
test_deleted_cache_rebuilds_deterministically() {
  local home first second
  home=$(make_home rebuild)
  add_report "$home" alpha '# Alpha
LC-R4 was approved by the captain.'
  add_report "$home" beta '# Beta
ADR-0050 is superseded.'

  run_scan "$home" >/dev/null || fail "seed scan failed"
  first="$TMP_ROOT/rebuild-first"
  cp -R "$home/state/research-index" "$first"

  rm -rf "$home/state/research-index"
  [ ! -d "$home/state/research-index" ] || fail "cache deletion did not take"

  run_scan "$home" >/dev/null || fail "rebuild scan failed"
  second="$home/state/research-index"

  # Negative control: prove the comparison can detect a difference at all.
  printf 'tampered\n' >> "$first/reports.tsv"
  if diff -r "$first" "$second" >/dev/null 2>&1; then
    fail "negative control: tampered index compared equal"
  fi
  sed -i '$ d' "$first/reports.tsv"

  diff -r "$first" "$second" >/dev/null 2>&1 \
    || fail "rebuild was not byte-identical: $(diff -r "$first" "$second" | head -5)"

  pass "a deleted cache rebuilds byte-identically"
}

# --- 4. scope enforcement refuses paths outside the corpus root -------------
test_scope_enforcement_blocks_escape() {
  local home out outside
  home=$(make_home scope)
  add_report "$home" alpha '# Alpha
LC-R4 was approved.'

  # The marker sits in a heading, which is a position the extractor genuinely
  # captures - otherwise its later absence would prove nothing about scope.
  outside="$TMP_ROOT/scope-outside"
  mkdir -p "$outside/secretdir"
  printf '# SHOULD-NOT-BE-INDEXED secret\nADR-0050 approved.\n' > "$outside/secret-report.md"
  printf '# SHOULD-NOT-BE-INDEXED secretdir\nADR-0050 approved.\n' > "$outside/secretdir/report.md"

  # Negative control: the same content inside the corpus IS indexed, so a
  # later absence is caused by the boundary and not by a broken matcher.
  add_report "$home" control '# SHOULD-NOT-BE-INDEXED control
ADR-0050 approved.'
  run_scan "$home" >/dev/null || fail "control scan failed"
  grep -rq 'SHOULD-NOT-BE-INDEXED' "$home/state/research-index/extract" \
    || fail "negative control: in-scope marker was not indexed"
  rm -rf "$home/data/control" "$home/state/research-index"

  # A symlinked report and a symlinked directory are the two escape shapes.
  mkdir -p "$home/data/evil"
  ln -s "$outside/secret-report.md" "$home/data/evil/report.md"
  ln -s "$outside/secretdir" "$home/data/linked-out"

  out=$(run_scan "$home") || fail "scan with escapes failed"
  [ "$(value_of "$out" reports)" = "1" ] \
    || fail "expected only the in-scope report, got $(value_of "$out" reports)"
  printf '%s\n' "$out" | grep -qx 'refused=evil/report.md' \
    || fail "the symlinked report should be refused and reported"
  grep -rq 'SHOULD-NOT-BE-INDEXED' "$home/state/research-index/extract" \
    && fail "content outside the corpus root was read"

  pass "scope enforcement refuses symlinked reports and symlinked directories"
}

# --- 5. a never-approved recommendation is not reported as approved ---------
test_unapproved_is_not_reported_approved() {
  local home out
  home=$(make_home approval)
  add_report "$home" loop '# Loop autonomy
LC-R4 record route= at dispatch.
LC-R11 adopt the 331-byte supervision block.'
  cat > "$home/data/captain-rulings-2026-08-04.md" <<'EOF'
# Rulings
ADR-0050 is approved for implementation.
EOF

  # Negative control: an identifier that IS in a ruling must come back found,
  # otherwise "not found" below would prove nothing about the sweep.
  out=$(run_scan "$home" evidence ADR-0050) || fail "control evidence failed"
  [ "$(value_of "$out" approval)" = "mentions-found" ] \
    || fail "negative control: a ruled identifier was not found in the sweep"

  out=$(run_scan "$home" evidence LC-R4) || fail "evidence failed"
  [ "$(value_of "$out" approval)" = "no-mentions-in-durable-sources" ] \
    || fail "an unruled identifier must not read as approved"
  printf '%s\n' "$out" | grep -q '^approval=mentions-found' \
    && fail "an unruled identifier was reported approved"

  # Absence of durable evidence must never be published as disproof, because
  # this home has approvals that were given only as a chat instruction.
  printf '%s\n' "$out" | grep -q '^approval_caveat=' \
    || fail "absence was reported without the not-disproof caveat"

  pass "a recommendation with no durable ruling is not reported as approved"
}

# --- 6. work already implemented at HEAD is not reported unimplemented ------
test_implemented_work_is_not_reported_unimplemented() {
  local home out
  home=$(make_home implemented)
  add_report "$home" loop '# Loop autonomy
LC-R4 record route= and floor= at dispatch.'

  # Negative control: before the work exists, two tokens must read as absent.
  out=$(run_scan "$home" evidence LC-R4 --token 'route=' --token 'floor=') \
    || fail "pre-implementation evidence failed"
  [ "$(value_of "$out" implementation)" = "no-matches-at-head" ] \
    || fail "negative control: absent work did not read as absent"

  # Land the work at HEAD.
  printf 'route=direct\nfloor=2\n' > "$home/repo/bin/dispatch.sh"
  git -C "$home/repo" add -A
  git -C "$home/repo" -c commit.gpgsign=false commit -qm 'record route and floor'

  out=$(run_scan "$home" evidence LC-R4 --token 'route=' --token 'floor=') \
    || fail "post-implementation evidence failed"
  [ "$(value_of "$out" implementation)" = "matches-at-head" ] \
    || fail "implemented work was still reported unimplemented"
  printf '%s\n' "$out" | grep -q 'route=	files=1' \
    || fail "the implementing signal was not reported per token"
  # The matching path must be named, because a bare count cannot be graded.
  printf '%s\n' "$out" | grep -q '^impl_match=.*bin/dispatch.sh$' \
    || fail "the matching path was not named for grading"

  pass "work present at HEAD is not reported as unimplemented"
}

# --- 7. absence is never concluded from a single missing name ---------------
test_single_token_cannot_conclude_absence() {
  local home out
  home=$(make_home single-token)
  add_report "$home" loop '# Loop autonomy
LC-R4 record route= at dispatch.'

  out=$(run_scan "$home" evidence LC-R4 --token 'route=') || fail "evidence failed"
  [ "$(value_of "$out" implementation)" = "insufficient-signals" ] \
    || fail "one token must not support an absence verdict, got $(value_of "$out" implementation)"

  # Negative control: the same call with a second token does reach a verdict,
  # proving the refusal is about signal count and not a broken prover.
  out=$(run_scan "$home" evidence LC-R4 --token 'route=' --token 'floor=') || fail "evidence failed"
  [ "$(value_of "$out" implementation)" = "no-matches-at-head" ] \
    || fail "two tokens should reach an absence verdict"

  pass "absence is refused on a single token and reached on two"
}

# --- 8. malformed and oversized reports stay inside budget ------------------
test_malformed_and_oversized_stay_in_budget() {
  local home out ceiling extract sha size
  home=$(make_home budget)
  ceiling=4096

  # An oversized report, a single enormous line, and NUL bytes: the three
  # shapes that break naive line-oriented extraction.
  mkdir -p "$home/data/huge" "$home/data/oneline" "$home/data/binary"
  {
    printf '# Huge\n'
    local i=0
    while [ "$i" -lt 4000 ]; do
      printf '## Section %s with ADR-%04d approved\n' "$i" "$i"
      i=$((i + 1))
    done
  } > "$home/data/huge/report.md"
  {
    printf '# Oneline '
    local i=0
    while [ "$i" -lt 20000 ]; do
      printf 'ADR-0050 approved and superseded '
      i=$((i + 1))
    done
    printf '\n'
  } > "$home/data/oneline/report.md"
  printf '# Binary\nLC-R4\000\000\000 approved\n' > "$home/data/binary/report.md"

  size=$(wc -c < "$home/data/huge/report.md" | tr -d ' ')
  [ "$size" -gt "$ceiling" ] || fail "negative control: oversized fixture is not oversized"

  out=$(FM_RESEARCH_MAX_BYTES="$ceiling" FM_RESEARCH_MAX_HEADINGS=10 \
    FM_RESEARCH_MAX_IDENTS=10 FM_RESEARCH_MAX_DECISIONS=10 \
    FM_RESEARCH_EXCERPT_CHARS=120 run_scan "$home") || fail "budget scan failed"
  [ "$(value_of "$out" verdict)" = "delta" ] || fail "budget scan should report delta"

  # No extraction may exceed a generous multiple of the caps: 30 lines of at
  # most 120 characters plus two header lines cannot approach 8 KB.
  for extract in "$home/state/research-index/extract"/*.txt; do
    size=$(wc -c < "$extract" | tr -d ' ')
    [ "$size" -le 8192 ] || fail "extraction exceeded budget at $size bytes: $extract"
    [ "$(wc -l < "$extract" | tr -d ' ')" -le 34 ] \
      || fail "extraction exceeded its line caps: $extract"
  done

  # The binding budget is bytes READ, not bytes emitted: the output caps alone
  # would keep an extraction small even if the scanner had slurped the whole
  # file, which is exactly the cost this design exists to avoid.
  local read_bytes
  for extract in "$home/state/research-index/extract"/*.txt; do
    read_bytes=$(sed -n 's/.*read_bytes=\([0-9]*\).*/\1/p' "$extract" | head -n1)
    [ -n "$read_bytes" ] || fail "extraction did not record how many bytes it read: $extract"
    [ "$read_bytes" -le "$ceiling" ] \
      || fail "scanner read $read_bytes bytes past the $ceiling ceiling: $extract"
  done

  sha=$(awk -F'\t' '$1 == "huge/report.md" {print $3}' "$home/state/research-index/reports.tsv")
  grep -q 'truncated=1' "$home/state/research-index/extract/$sha.txt" \
    || fail "an oversized report was not recorded as truncated"

  sha=$(awk -F'\t' '$1 == "binary/report.md" {print $3}' "$home/state/research-index/reports.tsv")
  grep -q '^\[ident\] LC-R4$' "$home/state/research-index/extract/$sha.txt" \
    || fail "a NUL-bearing report yielded no identifier"

  pass "malformed and oversized reports stay inside the extraction budget"
}

# --- 9. changed decision records and HEADs invalidate the index -------------
#
# The corpus is only one of three inputs that can change the answer. If a new
# ruling or a new commit did not invalidate, the skill would keep serving a
# stale verdict from an unchanged corpus.
test_decision_and_head_changes_invalidate() {
  local home out
  home=$(make_home invalidate)
  add_report "$home" alpha '# Alpha
LC-R4 was approved.'
  run_scan "$home" >/dev/null || fail "seed scan failed"

  out=$(run_scan "$home") || fail "baseline scan failed"
  [ "$(value_of "$out" verdict)" = "no_delta" ] \
    || fail "negative control: baseline was not stable"

  printf '# Rulings\nLC-R4 is approved.\n' > "$home/data/captain-rulings-2026-08-04.md"
  out=$(run_scan "$home") || fail "post-ruling scan failed"
  [ "$(value_of "$out" verdict)" = "delta" ] \
    || fail "a new ruling must invalidate the index"

  out=$(run_scan "$home") || fail "restabilise scan failed"
  [ "$(value_of "$out" verdict)" = "no_delta" ] || fail "index did not restabilise"

  printf 'new work\n' > "$home/repo/bin/new.sh"
  git -C "$home/repo" add -A
  git -C "$home/repo" -c commit.gpgsign=false commit -qm 'land work'
  out=$(run_scan "$home") || fail "post-commit scan failed"
  [ "$(value_of "$out" verdict)" = "delta" ] \
    || fail "a new implementation HEAD must invalidate the index"

  pass "new decision records and new implementation HEADs invalidate the index"
}

# --- 10. duplicate grouping --------------------------------------------------
test_duplicates_are_grouped() {
  local home dup
  home=$(make_home duplicates)
  # Three genuinely overlapping routing reports: two byte-identical, one a
  # rewrite covering the same identifiers.
  add_report "$home" first '# Routing
ADR-0050 ADR-0042 ADR-0048 all approved.'
  add_report "$home" second '# Routing
ADR-0050 ADR-0042 ADR-0048 all approved.'
  add_report "$home" third '# Routing rework
ADR-0050 ADR-0042 ADR-0048 revisited with new prose.'
  add_report "$home" unrelated '# Something else
CAP-015 deferred.'
  # Two broad reports that share three identifiers out of twenty. A bare
  # shared-count threshold pairs these; they are not near-duplicates.
  add_report "$home" broadx '# Broad X
SH-1 SH-2 SH-3 BX-1 BX-2 BX-3 BX-4 BX-5 BX-6 BX-7 BX-8 BX-9 BX-10 BX-11 BX-12 BX-13 BX-14 BX-15 BX-16 BX-17'
  add_report "$home" broady '# Broad Y
SH-1 SH-2 SH-3 BY-1 BY-2 BY-3 BY-4 BY-5 BY-6 BY-7 BY-8 BY-9 BY-10 BY-11 BY-12 BY-13 BY-14 BY-15 BY-16 BY-17'
  # A report sharing exactly one house-wide identifier with the routing set.
  add_report "$home" wide '# Wide vocabulary
ADR-0050 WD-1 WD-2'

  run_scan "$home" >/dev/null || fail "scan failed"
  dup="$home/state/research-index/duplicates.tsv"

  grep -q '^exact:' "$dup" || fail "identical reports were not grouped as exact duplicates"
  grep -q '^shared:' "$dup" || fail "identifier-overlapping reports were not grouped"
  grep -q 'unrelated/report.md' "$dup" \
    && fail "an unrelated report was grouped as a duplicate"

  # The grouped members must be reports. A grouping keyed on identifiers
  # instead would still produce plausible-looking rows, so assert the member
  # column against the actual report inventory rather than eyeballing shape.
  local member
  while IFS=$'\t' read -r _ member; do
    [ -n "$member" ] || continue
    awk -F'\t' -v m="$member" '$1 == m {found = 1} END {exit found ? 0 : 1}' \
      "$home/state/research-index/reports.tsv" \
      || fail "duplicate group member '$member' is not a report key"
  done < "$dup"

  # Exactly the three routing pairs may be grouped. A house-wide identifier
  # shared with `wide`, or three-of-twenty shared between the broad pair, must
  # not pair anything - those are the two shapes that flood a real corpus.
  local shared_rows
  shared_rows=$(cut -f1 "$dup" | grep -c '^shared:')
  [ "$shared_rows" -eq 6 ] \
    || fail "expected 6 shared rows (3 routing pairs), got $shared_rows"
  grep '^shared:' "$dup" | grep -qE 'broadx|broady' \
    && fail "reports sharing 3 identifiers out of 20 were grouped as duplicates"
  grep '^shared:' "$dup" | grep -q 'wide/report.md' \
    && fail "a single house-wide shared identifier grouped unrelated reports"

  pass "identical and identifier-overlapping reports are grouped as reports"
}

# --- 11. the index announces that it is derived, not authority ---------------
test_index_is_labelled_derived() {
  local home
  home=$(make_home derived)
  add_report "$home" alpha '# Alpha
LC-R4 approved.'
  run_scan "$home" >/dev/null || fail "scan failed"

  grep -qx 'derived=true' "$home/state/research-index/index.meta" \
    || fail "index does not declare itself derived"
  grep -qx 'authority=none' "$home/state/research-index/index.meta" \
    || fail "index does not disclaim authority"
  run_scan "$home" schema | grep -q 'never authority' \
    || fail "schema does not state the index is never authority"

  pass "the derived index labels itself derived and disclaims authority"
}

# --- 12. the provers under-claim: a mention is not an approval --------------
#
# Found against the real corpus: sweeping durable records for LC-R4 hit four
# commission files that merely ASKED an investigation to examine it. A prover
# that answers "approved" from those hits manufactures approvals, which is the
# precise failure this whole skill exists to prevent.
test_provers_report_mentions_not_conclusions() {
  local home out
  home=$(make_home underclaim)
  add_report "$home" loop '# Loop autonomy
LC-R4 record route= at dispatch.'
  mkdir -p "$home/data/audit"
  cat > "$home/data/audit/commission.md" <<'EOF'
# Commission
Examine the substrate and report on LC-R4 and its siblings.
EOF

  out=$(run_scan "$home" evidence LC-R4) || fail "evidence failed"

  # It must report the mention, and it must not call the mention an approval.
  [ "$(value_of "$out" approval)" = "mentions-found" ] \
    || fail "a commission mention should surface as a mention"
  printf '%s\n' "$out" | grep -q '^approval=approved' \
    && fail "a commission mention was reported as an approval"
  printf '%s\n' "$out" | grep -q '^approval_hit=.*commission.md' \
    || fail "the mention was not cited for grading"
  printf '%s\n' "$out" | grep -q '^approval_caveat=.*mention is not an approval' \
    || fail "the mention-is-not-approval caveat is missing"

  # Same discipline for a coincidental code match: `route=` is a shell local
  # in unrelated files, so the prover must name paths and not claim success.
  printf 'local route=""\n' > "$home/repo/bin/unrelated.sh"
  git -C "$home/repo" add -A
  git -C "$home/repo" -c commit.gpgsign=false commit -qm 'unrelated local variable'

  out=$(run_scan "$home" evidence LC-R4 --token 'route=' --token 'floor=') \
    || fail "evidence failed"
  [ "$(value_of "$out" implementation)" = "matches-at-head" ] \
    || fail "a textual match should surface as a match"
  printf '%s\n' "$out" | grep -q '^implementation=implemented' \
    && fail "a coincidental match was reported as an implementation"
  printf '%s\n' "$out" | grep -q '^impl_match=.*bin/unrelated.sh$' \
    || fail "the coincidental match path was not named for grading"
  printf '%s\n' "$out" | grep -q '^implementation_caveat=' \
    || fail "the match-is-not-implementation caveat is missing"

  # And delivery: a negative only ever covers titles and branch names.
  printf '%s\n' "$out" | grep -qx 'landing=not-checked' \
    || fail "delivery must be reported as unchecked when --landing is absent"

  pass "provers report mentions and matches, never approval or implementation"
}

# --- 13. a failed delivery listing is not an absence of delivery ------------
#
# Found against the real corpus: the delivery prober passed a field list the
# forge tool rejected, the call failed, and the failure was reported as
# "nothing was delivered" - which would re-commission finished work.
test_failed_delivery_listing_is_not_absence() {
  local home out ghbin
  home=$(make_home landing)
  add_report "$home" loop '# Loop autonomy
LC-R4 record route= at dispatch.'
  ghbin="$home/ghbin"
  mkdir -p "$ghbin"

  # Negative control: a working listing that names the work must be found,
  # so a later non-match is attributable to the failure and not to the search.
  cat > "$ghbin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf '  1629,"feat(bin): record dispatch route at spawn",open,someone,no,none\n'
exit 0
EOF
  chmod +x "$ghbin/gh-axi"
  out=$(PATH="$ghbin:$PATH" run_scan "$home" evidence LC-R4 \
    --token 'dispatch route' --token 'floor=' --landing) || fail "landing evidence failed"
  [ "$(value_of "$out" landing)" = "title-match" ] \
    || fail "negative control: a matching pull request title was not found"

  # Now the same call with a forge that refuses the request.
  cat > "$ghbin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf 'error: "Unknown field(s)"\n' >&2
exit 1
EOF
  chmod +x "$ghbin/gh-axi"
  out=$(PATH="$ghbin:$PATH" run_scan "$home" evidence LC-R4 \
    --token 'dispatch route' --token 'floor=' --landing) || fail "landing evidence failed"
  [ "$(value_of "$out" landing)" = "unavailable-listing-failed" ] \
    || fail "a failed listing must not read as absence, got $(value_of "$out" landing)"
  printf '%s\n' "$out" | grep -q '^landing=no-title-match' \
    && fail "a failed listing was reported as no delivery"
  printf '%s\n' "$out" | grep -q '^landing_error=' \
    || fail "the listing failure was not reported"

  pass "a failed delivery listing reports unavailable, never absence"
}

test_no_delta_costs_no_model_turn
test_single_change_reopens_only_that_report
test_deleted_cache_rebuilds_deterministically
test_scope_enforcement_blocks_escape
test_unapproved_is_not_reported_approved
test_implemented_work_is_not_reported_unimplemented
test_single_token_cannot_conclude_absence
test_malformed_and_oversized_stay_in_budget
test_decision_and_head_changes_invalidate
test_duplicates_are_grouped
test_index_is_labelled_derived
test_provers_report_mentions_not_conclusions
test_failed_delivery_listing_is_not_absence
