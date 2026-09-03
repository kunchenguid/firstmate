#!/usr/bin/env bash
# tests/fm-done-verified.test.sh - a terminal `done:` claim must mean something a
# machine checked, not something a worker asserted.
#
# The three incidents this pins, all the same shape: a worker reported a PR as
# validated and green while (1) the commit the pipeline validated was not the
# commit the PR shipped, (2) a force-push had replaced the validated head, and
# (3) the PR was later closed WITHOUT merging while the task record still read
# done, unnoticed for three weeks. Free prose ("done: PR <url> checks green")
# carried no commit identity, so nothing could compare what was validated with
# what shipped, and the merge poll only ever watched for `merged`.
#
# Cases:
#   (a) the claim grammar its owner hands a worker parses back into the exact
#       identity fields the verifier reads - the two cannot drift
#   (b) a claim naming a PR the forge cannot answer for   -> unverified
#   (c) a claim whose head is not the PR's head           -> contradicted
#   (d) a claim whose head is not the VALIDATED commit    -> contradicted  <- (1)
#   (e) a claim on a PR closed without merging            -> contradicted  <- (3)
#   (f) a legacy claim with no commit identity            -> unverified, never a pass
#   (g) an honest claim                                   -> verified
#   (h) a scout claim: report present -> verified, missing -> contradicted
#   (i) a verdict binds to the exact claim it judged: a later claim is unverified
#   (j) the merge poll reports closed-without-merge, and stays silent otherwise
#   (k) the notification marker records WHICH outcome was delivered, so a close
#       does not suppress a later merge of the same PR
#   (l) the drain flags a status line carrying no recognised verb instead of
#       absorbing it silently
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-done-claim-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

VERIFY="$ROOT/bin/fm-verify-done.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-done-verified)
fm_git_identity fmtest fmtest@example.invalid

# A world with a task worktree holding two commits, so a "validated" commit and
# a later "shipped" commit are genuinely different objects. Prints the case dir;
# the caller reads the two commits back with git rather than through a global,
# because this runs inside a command substitution.
make_world() {  # <name> [kind] [mode]
  local name=$1 kind=${2:-ship} mode=${3:-no-mistakes} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data" "$dir/fakebin" "$dir/wt"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m base
  git -C "$dir/wt" checkout -q -b fm/task-v
  git -C "$dir/wt" commit -q --allow-empty -m validated
  git -C "$dir/wt" commit -q --allow-empty -m shipped
  # Two modes. FAKE_GH_OUT returns a pre-formatted line, which keeps the verdict
  # cases independent of jq. FAKE_GH_JSON returns a realistic API payload and
  # applies the script's OWN -q expression with real jq, exactly as gh does, so
  # that expression is exercised rather than mocked away.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = pr ] && [ "${2:-}" = view ] || exit 1
if [ -n "${FAKE_GH_JSON:-}" ]; then
  q=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -q ]; then q=${2:-}; break; fi
    shift
  done
  [ -n "$q" ] || exit 1
  printf '%s' "$FAKE_GH_JSON" | jq -r "$q" || exit 1
  exit 0
fi
[ -n "${FAKE_GH_OUT:-}" ] || exit 1
printf '%s\n' "$FAKE_GH_OUT"
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then printf '%s\n' "${FAKE_NM_STATUS:-}"; fi
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/no-mistakes"
  fm_write_meta "$dir/state/task-v.meta" \
    "window=fm:fm-task-v" "worktree=$dir/wt" "kind=$kind" "mode=$mode"
  printf '%s\n' "$dir"
}

# Run the verifier in <dir> and echo "<exit>\t<line>".
verify() {  # <dir>
  local dir=$1 out rc=0
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" "$VERIFY" task-v 2>&1) || rc=$?
  printf '%s\t%s\n' "$rc" "$out"
}

nm_status() {  # <branch> <head>
  printf 'branch: %s\nhead: %s\nstatus: completed\noutcome: passed\n' "$1" "$2"
}

# --- (a) the grammar its owner hands a worker is the grammar the parser reads --

test_claim_grammar_round_trips() {
  local rendered

  rendered=$(fm_done_claim_template no-mistakes task-v)
  rendered=${rendered//\{url\}/https://github.com/o/r/pull/7}
  rendered=${rendered//\{full-sha\}/00112233445566778899aabbccddeeff00112233}
  rendered=${rendered//\{one line\}/shipped it}
  fm_done_claim_parse "$rendered" || fail "the rendered no-mistakes claim did not parse as a claim"
  [ "$FM_DONE_CLAIM_PR" = "https://github.com/o/r/pull/7" ] \
    || fail "the rendered no-mistakes claim lost its PR: $rendered"
  [ "$FM_DONE_CLAIM_HEAD" = "00112233445566778899aabbccddeeff00112233" ] \
    || fail "the rendered no-mistakes claim lost its commit: $rendered"
  fm_done_claim_has_identity || fail "the rendered no-mistakes claim has no machine-checkable identity"

  rendered=$(fm_done_claim_template local-only task-v)
  rendered=${rendered//\{full-sha\}/00112233445566778899aabbccddeeff00112233}
  rendered=${rendered//\{one line\}/ready}
  fm_done_claim_parse "$rendered" || fail "the rendered local-only claim did not parse as a claim"
  [ "$FM_DONE_CLAIM_BRANCH" = "fm/task-v" ] \
    || fail "the rendered local-only claim lost its branch: $rendered"
  [ "$FM_DONE_CLAIM_HEAD" = "00112233445566778899aabbccddeeff00112233" ] \
    || fail "the rendered local-only claim lost its commit: $rendered"

  rendered=$(fm_done_claim_template scout task-v)
  rendered=${rendered//\{path\}//tmp/report.md}
  rendered=${rendered//\{one line\}/found it}
  fm_done_claim_parse "$rendered" || fail "the rendered scout claim did not parse as a claim"
  [ "$FM_DONE_CLAIM_REPORT" = "/tmp/report.md" ] \
    || fail "the rendered scout claim lost its report: $rendered"
  fm_done_claim_has_identity || fail "the rendered scout claim has no machine-checkable identity"

  fm_done_claim_parse "working: still going" \
    && fail "a non-terminal line was parsed as a terminal claim"

  # A summary is arbitrary worker prose. Splitting it into fields must not also
  # glob it against whatever directory the reader happens to be in.
  fm_done_claim_parse "done: pr=https://github.com/o/r/pull/7 head=00112233445566778899aabbccddeeff00112233 - fixed *.md and tests/*" \
    || fail "a claim whose summary contains glob characters did not parse"
  [ "$FM_DONE_CLAIM_HEAD" = "00112233445566778899aabbccddeeff00112233" ] \
    || fail "glob characters in the summary corrupted the parsed commit"
  case $- in *f*) fail "the parser left globbing disabled in its caller" ;; esac
  pass "the claim grammar handed to a worker parses back into the identity the verifier reads"
}

# --- (b)-(g) the verifier over PR modes --------------------------------------

test_unreachable_forge_is_unverified_never_a_pass() {
  local dir result shipped
  dir=$(make_world forge-unreachable)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: pr=https://github.com/o/r/pull/999 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT='' verify "$dir")
  [ "${result%%$'\t'*}" = 3 ] || fail "an unanswerable forge did not exit unverified: $result"
  case "$result" in *unverified:*) ;; *) fail "an unanswerable forge was not reported unverified: $result" ;; esac
  case "$result" in *"could not be reached"*) ;; *) fail "the unverified reason did not name the forge: $result" ;; esac
  pass "a claim the forge cannot answer for is unverified, never a pass"
}

test_head_not_the_pr_head_is_contradicted() {
  local dir result shipped validated
  dir=$(make_world head-mismatch)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  validated=$(git -C "$dir/wt" rev-parse 'HEAD~1')
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="OPEN	$validated	SUCCESS" verify "$dir")
  [ "${result%%$'\t'*}" = 4 ] || fail "a head that is not the PR head did not exit contradicted: $result"
  case "$result" in *contradicted:*) ;; *) fail "a head mismatch was not contradicted: $result" ;; esac
  pass "a claim whose commit is not the PR's head is contradicted"
}

test_head_not_the_validated_commit_is_contradicted() {
  local dir result shipped validated
  dir=$(make_world validated-mismatch)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  validated=$(git -C "$dir/wt" rev-parse 'HEAD~1')
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="OPEN	$shipped	SUCCESS" \
    FAKE_NM_STATUS="$(nm_status fm/task-v "$validated")" verify "$dir")
  [ "${result%%$'\t'*}" = 4 ] \
    || fail "shipping a commit the pipeline never validated did not exit contradicted: $result"
  case "$result" in *"validation ran against"*) ;; *) fail "the contradiction did not name the validated commit: $result" ;; esac
  pass "a commit the PR ships but the pipeline never validated is contradicted"
}

test_closed_unmerged_pr_is_contradicted() {
  local dir result shipped
  dir=$(make_world closed-unmerged)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="CLOSED	$shipped	SUCCESS" verify "$dir")
  [ "${result%%$'\t'*}" = 4 ] || fail "a closed-unmerged PR did not exit contradicted: $result"
  case "$result" in *"closed without merging"*) ;; *) fail "the contradiction did not name the close: $result" ;; esac
  pass "a claim on a PR closed without merging is contradicted"
}

test_legacy_claim_degrades_and_is_never_upgraded() {
  local dir result
  dir=$(make_world legacy-claim)
  printf 'done: PR https://github.com/o/r/pull/7 checks green\n' > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="MERGED	deadbeef	SUCCESS" verify "$dir")
  [ "${result%%$'\t'*}" = 3 ] || fail "a legacy claim did not exit unverified: $result"
  case "$result" in *"legacy claim, no commit identity"*) ;; *) fail "the legacy claim was not named as such: $result" ;; esac
  # The verdict token is the whole word after the exit code, so a check for
  # "verified" must not be satisfied by the "verified" inside "unverified".
  case "${result#*$'\t'}" in verified:*) fail "a legacy claim was silently upgraded to verified: $result" ;; esac
  pass "a legacy claim degrades to unverified and is never upgraded"
}

test_honest_claim_verifies_and_records_the_checks_state() {
  local dir result shipped
  dir=$(make_world honest-claim)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="OPEN	$shipped	SUCCESS" \
    FAKE_NM_STATUS="$(nm_status fm/task-v "$shipped")" verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] || fail "an honest claim was not verified: $result"
  case "$result" in *"checks: SUCCESS"*) ;; *) fail "the checks state was not recorded as fact: $result" ;; esac
  assert_present "$dir/state/task-v.done-verdict" "the verified claim left no durable verdict record"
  assert_grep verified "$dir/state/task-v.done-verdict" "the durable record does not carry the verdict"
  pass "an honest claim verifies and records the checks state as fact"
}

test_red_checks_do_not_by_themselves_contradict_a_claim() {
  local dir result shipped
  dir=$(make_world red-checks)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="OPEN	$shipped	FAILURE" \
    FAKE_NM_STATUS="$(nm_status fm/task-v "$shipped")" verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] \
    || fail "the verifier judged the checks state instead of recording it: $result"
  case "$result" in *"checks: FAILURE"*) ;; *) fail "the red checks state was not recorded: $result" ;; esac
  pass "the checks state is recorded as fact, not judged"
}

# The checks state is read out of a real rollup payload with the script's own
# query, because a rollup mixes check runs (.conclusion, null while a run is
# still going, then .status) with commit statuses (.state). A query that falls
# back across the whole list instead of per entry silently drops every entry of
# the other shape and records SUCCESS for a pull request that still has work in
# flight - a wrong fact in a verdict whose whole purpose is recording facts.
test_checks_state_is_read_from_a_real_rollup() {
  local dir shipped result
  command -v jq >/dev/null 2>&1 || { pass "skip: jq not found, real-rollup checks reading not exercised"; return 0; }
  dir=$(make_world checks-rollup)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"

  # A finished check run, an in-progress one, and a commit status: all three
  # shapes must reach the record.
  result=$(FAKE_GH_JSON="{\"state\":\"OPEN\",\"headRefOid\":\"$shipped\",\"url\":\"u\",\"statusCheckRollup\":[{\"conclusion\":\"SUCCESS\"},{\"conclusion\":null,\"status\":\"IN_PROGRESS\"},{\"state\":\"PENDING\"}]}" \
    FAKE_NM_STATUS="$(nm_status fm/task-v "$shipped")" verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] || fail "a real rollup payload did not verify: $result"
  case "$result" in *IN_PROGRESS*) ;; *) fail "an in-progress check run was dropped from the recorded checks state: $result" ;; esac
  case "$result" in *PENDING*) ;; *) fail "a commit status was dropped from the recorded checks state: $result" ;; esac
  case "$result" in *SUCCESS*) ;; *) fail "a finished check run was dropped from the recorded checks state: $result" ;; esac

  # No checks at all is recorded as such, never as a pass.
  result=$(FAKE_GH_JSON="{\"state\":\"MERGED\",\"headRefOid\":\"$shipped\",\"url\":\"u\",\"statusCheckRollup\":null}" \
    FAKE_NM_STATUS="$(nm_status fm/task-v "$shipped")" verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] || fail "a pull request with no checks did not verify: $result"
  case "$result" in *"checks: none reported"*) ;; *) fail "an absent rollup was not recorded as none reported: $result" ;; esac
  pass "the checks state is read out of a real rollup payload, per entry, with the script's own query"
}

# --- (h) scout claims ---------------------------------------------------------

test_scout_claim_checks_the_report_exists() {
  local dir result
  dir=$(make_world scout-report scout scout)
  mkdir -p "$dir/data/task-v"
  printf 'findings\n' > "$dir/data/task-v/report.md"
  printf 'done: report=data/task-v/report.md - found it\n' > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] || fail "a scout claim naming a real report was not verified: $result"

  dir=$(make_world scout-missing scout scout)
  printf 'done: report=data/task-v/report.md - found it\n' > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 4 ] || fail "a scout claim naming a missing report was not contradicted: $result"
  pass "a scout claim is established against the report it names"
}

# --- (i) a verdict judges one exact claim ------------------------------------

test_a_verdict_does_not_cover_a_later_claim() {
  local dir shipped
  dir=$(make_world verdict-binding)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  FAKE_GH_OUT="OPEN	$shipped	SUCCESS" FAKE_NM_STATUS="$(nm_status fm/task-v "$shipped")" \
    verify "$dir" >/dev/null
  fm_done_claim_status "$dir/state" task-v
  [ "$FM_DONE_CLAIM_STATE" = verified ] \
    || fail "setup error: the first claim did not verify ($FM_DONE_CLAIM_STATE)"

  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - and one more thing\n' "$shipped" \
    >> "$dir/state/task-v.status"
  fm_done_claim_status "$dir/state" task-v
  [ "$FM_DONE_CLAIM_STATE" = unverified ] \
    || fail "a verdict for an earlier claim was inherited by a later one ($FM_DONE_CLAIM_STATE)"
  case "$FM_DONE_CLAIM_REASON" in *"earlier claim"*) ;; *) fail "the reason did not name the superseded claim: $FM_DONE_CLAIM_REASON" ;; esac
  pass "a verdict judges one exact claim and is not inherited by a later one"
}

test_no_claim_is_not_a_verdict() {
  local dir
  dir=$(make_world no-claim)
  printf 'working: still going\n' > "$dir/state/task-v.status"
  fm_done_claim_status "$dir/state" task-v
  [ "$FM_DONE_CLAIM_STATE" = none ] \
    || fail "a task that never claimed done was given a verdict ($FM_DONE_CLAIM_STATE)"
  pass "a task that never claimed done has nothing to verify"
}

# --- (j) the merge poll sees a close, not only a merge ------------------------

poll_says() {  # <gh-state> -> the poll's one line
  local state=$1 dir out
  dir="$TMP_ROOT/poll-$state"
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = pr ] && [ "\${2:-}" = view ] || exit 1
printf '%s\\n' "$state"
SH
  chmod +x "$dir/fakebin/gh"
  out=$(PATH="$dir/fakebin:$PATH" "$POLL" --validated github \
    https://github.com/o/r/pull/7 github.com o/r 7 2>/dev/null || true)
  printf '%s' "$out"
}

test_poll_reports_a_close_as_well_as_a_merge() {
  [ "$(poll_says MERGED)" = merged ] || fail "the poll stopped reporting a merge"
  [ "$(poll_says CLOSED)" = closed-unmerged ] \
    || fail "the poll did not report a PR closed without merging"
  [ -z "$(poll_says OPEN)" ] || fail "the poll reported a terminal outcome for an open PR"
  pass "the merge poll reports a close without merge as well as a merge"
}

# --- (k) the marker records WHICH outcome was delivered ----------------------

test_marker_distinguishes_the_two_terminal_outcomes() {
  local dir state
  dir="$TMP_ROOT/marker-outcome"
  state="$dir/state"
  mkdir -p "$state"

  fm_pr_poll_merge_mark_notified "$state" task-v github github.com o/r 7 closed-unmerged \
    || fail "the close outcome could not be recorded"
  fm_pr_poll_merge_already_notified "$state" task-v github github.com o/r 7 closed-unmerged \
    || fail "a recorded close was not recognised as already delivered"
  if fm_pr_poll_merge_already_notified "$state" task-v github github.com o/r 7 merged; then
    fail "a recorded close suppressed a later merge of the same PR"
  fi

  # A marker written before the outcome was recorded means `merged`.
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n7\n' > "$state/legacy.pr-poll-merge-notified"
  chmod 0600 "$state/legacy.pr-poll-merge-notified"
  fm_pr_poll_merge_already_notified "$state" legacy github github.com o/r 7 merged \
    || fail "a legacy marker stopped meaning that the merge was already delivered"
  if fm_pr_poll_merge_already_notified "$state" legacy github github.com o/r 7 closed-unmerged; then
    fail "a legacy merge marker was read as a delivered close"
  fi
  pass "the notification marker records which terminal outcome was delivered"
}

# --- (l) a line matching no status verb is flagged, not absorbed --------------

test_drain_flags_a_line_matching_no_status_verb() {
  local dir state status out
  dir=$(make_case unrecognised-line)
  state="$dir/state"
  status="$state/task9.status"
  out="$dir/drain.out"
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the cursor"

  printf 'Migration syntax: OK\n' >> "$status"
  printf -- '- ruff check on all changed files: all passed\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed over unrecognised lines"

  grep -F 'UNRECOGNISED (matches no status verb): Migration syntax: OK' "$out" >/dev/null \
    || fail "a line matching no status verb was absorbed silently: $(cat "$out")"
  grep -F 'UNRECOGNISED (matches no status verb): - ruff check on all changed files: all passed' "$out" >/dev/null \
    || fail "the second unrecognised line was dropped: $(cat "$out")"
  pass "a status line matching no known verb is flagged in the drain, not absorbed"
}

test_known_verbs_are_not_flagged_as_unrecognised() {
  status_line_is_unrecognized "working: building" && fail "working: was called unrecognised"
  status_line_is_unrecognized "done: pr=x head=y - z" && fail "done: was called unrecognised"
  status_line_is_unrecognized "needs-decision: which" && fail "needs-decision: was called unrecognised"
  status_line_is_unrecognized "blocked: stuck" && fail "blocked: was called unrecognised"
  status_line_is_unrecognized "paused: upstream" && fail "paused: was called unrecognised"
  status_line_is_unrecognized "failed: rc 2" && fail "failed: was called unrecognised"
  status_line_is_unrecognized "note: fyi" && fail "note: was called unrecognised"
  status_line_is_unrecognized "resolved: cleared" && fail "resolved: was called unrecognised"
  status_line_is_unrecognized "captain-held: waiting" && fail "captain-held: was called unrecognised"
  status_line_is_unrecognized "   " && fail "a blank line was called unrecognised"
  status_line_is_unrecognized "Migration syntax: OK" || fail "worker prose was not called unrecognised"
  pass "every known status verb stays recognised while prose does not"
}

test_claim_grammar_round_trips
test_unreachable_forge_is_unverified_never_a_pass
test_head_not_the_pr_head_is_contradicted
test_head_not_the_validated_commit_is_contradicted
test_closed_unmerged_pr_is_contradicted
test_legacy_claim_degrades_and_is_never_upgraded
test_honest_claim_verifies_and_records_the_checks_state
test_red_checks_do_not_by_themselves_contradict_a_claim
test_checks_state_is_read_from_a_real_rollup
test_scout_claim_checks_the_report_exists
test_a_verdict_does_not_cover_a_later_claim
test_no_claim_is_not_a_verdict
test_poll_reports_a_close_as_well_as_a_merge
test_marker_distinguishes_the_two_terminal_outcomes
test_drain_flags_a_line_matching_no_status_verb
test_known_verbs_are_not_flagged_as_unrecognised
echo "all fm-done-verified tests passed"
