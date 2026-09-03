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
#   (m) a fabricated local-only claim naming the default branch's tip, on a task
#       whose own branch never existed, is not verified: a commit is its own
#       ancestor, so containment alone proves nothing
#   (n) a local-only claim naming some other branch          -> contradicted
#   (o) a transient unverified never downgrades an established record, while the
#       run that observed it still reports it
#   (p) a contradicted verdict still overwrites a verified record, so (o) is a
#       downgrade guard and not a freeze
#   (q) a task whose meta records no mode= still gets the validated-commit check
#   (r) a relative scout report= resolves against a relocated data root
#   (s) a close with no done claim on record does not invent one
#   (t) a home's configured verb vocabulary is not labelled UNRECOGNISED
#   (u) the omitted-unrecognised count is never printed without its header, and
#       what the cap holds back re-presents on the next drain rather than
#       being skipped past forever
#   (v) an absent mode= with a local-only-shaped claim is judged as local-only,
#       never reported as false for naming no PR
#   (w) an absent mode= the claim's own shape cannot resolve is unverified,
#       naming the unrecorded mode - absence of evidence is never contradicted
#   (x) --help prints the whole header it documents itself with
#   (y) a local-only branch that introduced nothing cannot satisfy a claim, in
#       the shape this fleet actually produces: the branch EXISTS at the spawn
#       base because the brief has the worker create it before any work
#   (z) a scout report present behind a symlink is unverified, not contradicted
#   (ad) a merge marks an established claim stale; a close contradicts it; and
#        neither invents a verdict for a task that claimed nothing
#   (ae) verdict write precedence: absence never downgrades, falsity outranks
#        everything, and a changed world does not soften a contradiction
#   (af) a held-back span containing multibyte prose presents whole lines only
#   (ag) the unrecognised cap is per task, so one chatty worker starves nobody
#   (aa) a branch whose creation reflog entry has expired is unverified, not
#        contradicted: the oldest SURVIVING entry is not the creation point
#   (ab) a contradiction must carry the observation it contradicts with; one
#        that can name nothing observed is recorded unverified instead
#   (ac) prose the cap held back survives a recognised line printed after it in
#        the same span - the shape that silently lost a worker's words
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-done-claim-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-merge-outcome-lib.sh"

VERIFY="$ROOT/bin/fm-verify-done.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-done-verified)
fm_git_identity fmtest fmtest@example.invalid

# A world with a task worktree holding two commits, so a "validated" commit and
# a later "shipped" commit are genuinely different objects. Prints the case dir;
# the caller reads the two commits back with git rather than through a global,
# because this runs inside a command substitution.
#
# This is a standalone repository, NOT the linked worktree of a project repo a
# real spawn produces (make_local_world below is the fixture shaped like a real
# spawn). That is sufficient here and only here: the PR arm judges the claim
# against the forge and the validation run and never consults a default branch
# or a merge base, so the worktree's relationship to a parent repo cannot change
# any verdict it reaches. The same applies to the kind=scout cases, which are
# left on a branch with commits while a real scout sits at detached HEAD in a
# scratch worktree: the scout arm reads only the claimed report path.
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

# Run the verifier in <dir> and echo "<exit>\t<line>". <data-root> defaults to
# the home's own data dir; a case that relocates it passes its own.
verify() {  # <dir> [data-root]
  local dir=$1
  local data=${2:-$dir/data} out rc=0
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$data" "$VERIFY" task-v 2>&1) || rc=$?
  printf '%s\t%s\n' "$rc" "$out"
}

# A local-only world shaped like a real spawn, per bin/fm-brief.sh's shared
# Setup section: a project repo whose default branch keeps advancing, a LINKED
# worktree added at detached HEAD on that default branch, and - as the brief
# makes every ship worker's FIRST action - `git checkout -b fm/task-v` in that
# worktree BEFORE any work exists. So a worker that commits nothing leaves
# fm/task-v EXISTING and pointing at the spawn base, which is the state the
# branch-exists arm has to judge. Prints "<case dir>\t<default branch>".
make_local_world() {  # <name>
  local name=$1 dir default
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data" "$dir/fakebin"
  git -C "$dir" init -q repo
  git -C "$dir/repo" commit -q --allow-empty -m base
  default=$(git -C "$dir/repo" symbolic-ref --quiet --short HEAD)
  git -C "$dir/repo" worktree add -q --detach "$dir/wt" HEAD
  git -C "$dir/wt" checkout -q -b fm/task-v
  # The default branch moves on after the spawn, so its tip is a commit the task
  # never produced - exactly the commit a fabricated claim would reach for.
  git -C "$dir/repo" commit -q --allow-empty -m later
  fm_write_meta "$dir/state/task-v.meta" \
    "window=fm:fm-task-v" "worktree=$dir/wt" "kind=ship" "mode=local-only"
  printf '%s\t%s\n' "$dir" "$default"
}

# Retire fm/task-v the way landing does: the work is merged into the default
# branch, the task's copy leaves the branch, and the branch itself is deleted.
# git refuses to delete a branch a worktree still has checked out, which is why
# a worker that never committed can never present the retired shape.
retire_local_branch() {  # <case dir> <where to leave the worktree>
  local dir=$1 park=$2
  git -C "$dir/repo" merge -q --no-ff -m landed fm/task-v
  git -C "$dir/wt" checkout -q --detach "$park"
  git -C "$dir/repo" branch -q -D fm/task-v
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

# Refusing to read something is not proof that it is false. The symlink refusal
# stays - a link is not followed as evidence - but a report that is plainly
# present behind it must not be reported as missing, and teardown must not print
# stop-and-investigate wording for it.
test_a_symlinked_scout_report_is_unverified_not_contradicted() {
  local dir result
  dir=$(make_world scout-symlink scout scout)
  mkdir -p "$dir/data/task-v" "$dir/elsewhere"
  printf 'findings\n' > "$dir/elsewhere/report.md"
  ln -s "$dir/elsewhere/report.md" "$dir/data/task-v/report.md"
  printf 'done: report=data/task-v/report.md - found it\n' > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 3 ] \
    || fail "a present-but-symlinked scout report was not unverified: $result"
  case "$result" in
    *"missing or empty"*) fail "the verdict called a present report missing: $result" ;;
  esac
  case "$result" in *symlink*) ;; *) fail "the verdict did not name the symlink it refused to read: $result" ;; esac
  pass "a scout report behind a symlink is unverified, never contradicted"
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

# --- (m)-(n) local-only: containment alone is not evidence --------------------

test_a_fabricated_local_only_claim_is_not_verified() {
  local out dir default tip result
  out=$(make_local_world local-fabricated) || fail "the local-only fixture failed"
  dir=${out%%$'\t'*}
  default=${out#*$'\t'}
  tip=$(git -C "$dir/repo" rev-parse "refs/heads/$default")
  # The worker committed nothing, so fm/task-v still sits at the spawn base. It
  # claims the default branch's tip, which IS contained in the default branch,
  # so bare ancestry would pass a claim holding none of this task's work.
  printf 'done: branch=fm/task-v head=%s - shipped\n' "$tip" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  case "${result#*$'\t'}" in
    verified:*) fail "a fabricated local-only claim naming the default branch tip was verified: $result" ;;
  esac
  [ "${result%%$'\t'*}" = 4 ] \
    || fail "a claim naming a commit the task's branch is not at was not contradicted: $result"
  case "$result" in *"not the claimed $tip"*) ;; *) fail "the contradiction did not name what the branch is actually at: $result" ;; esac
  pass "a fabricated local-only claim naming the default branch's tip is not verified"
}

# The shape that actually occurs in this fleet, and the one bare tip-comparison
# passed: the branch exists because the brief had the worker create it, it still
# points at the spawn base because the worker committed nothing, and the claim
# names that base. Being the branch tip is not the same as being this task's
# work, and a branch that introduced nothing is positive evidence, not absence.
test_a_local_only_claim_naming_the_spawn_base_is_contradicted() {
  local out dir base result
  out=$(make_local_world local-spawn-base) || fail "the local-only fixture failed"
  dir=${out%%$'\t'*}
  base=$(git -C "$dir/wt" rev-parse HEAD)
  [ "$(git -C "$dir/wt" rev-parse refs/heads/fm/task-v)" = "$base" ] \
    || fail "the fixture did not leave fm/task-v at the spawn base"
  printf 'done: branch=fm/task-v head=%s - shipped\n' "$base" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  case "${result#*$'\t'}" in
    verified:*) fail "a claim naming a commit its branch never introduced was verified: $result" ;;
  esac
  [ "${result%%$'\t'*}" = 4 ] \
    || fail "a branch that introduced nothing was not contradicted: $result"
  case "$result" in *"introduced nothing"*) ;; *) fail "the contradiction did not name what was established: $result" ;; esac
  pass "a local-only claim naming the spawn base its branch never left is contradicted"
}

# The honest local-only case, which must stay verified: the branch carries work
# the task actually produced, and the claim names its tip.
test_a_local_only_claim_on_introduced_work_verifies() {
  local out dir default tip result
  out=$(make_local_world local-real-work) || fail "the local-only fixture failed"
  dir=${out%%$'\t'*}
  default=${out#*$'\t'}
  git -C "$dir/wt" commit -q --allow-empty -m "the task's own work"
  tip=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: branch=fm/task-v head=%s - shipped\n' "$tip" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] \
    || fail "a claim naming work the task's own branch introduced was not verified: $result"

  # And it must STILL verify once that work is on the default branch with the
  # branch left standing, which is the shape local-only work is in by the time
  # bin/fm-teardown.sh consults this verdict. A test of the branch's merge base
  # with the default branch would call this true claim false.
  git -C "$dir/repo" update-ref "refs/heads/$default" "$tip"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] \
    || fail "landed local-only work whose branch still stands was not verified: $result"
  pass "a local-only claim naming work its branch introduced verifies, landed or not"
}

test_a_local_only_claim_naming_another_branch_is_contradicted() {
  local out dir tip result
  out=$(make_local_world local-other-branch) || fail "the local-only fixture failed"
  dir=${out%%$'\t'*}
  tip=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/repo" branch -q fm/some-other-task "$tip"
  printf 'done: branch=fm/some-other-task head=%s - shipped\n' "$tip" \
    > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 4 ] \
    || fail "a claim naming another task's branch did not exit contradicted: $result"
  case "$result" in *"not this task's fm/task-v"*) ;; *) fail "the contradiction did not name the expected branch: $result" ;; esac
  pass "a local-only claim naming a branch other than this task's is contradicted"
}

test_a_local_only_claim_on_a_retired_branch_still_verifies() {
  local out dir work result
  out=$(make_local_world local-retired) || fail "the local-only fixture failed"
  dir=${out%%$'\t'*}
  # The task committed real work, that work landed on the default branch, its
  # own copy still sits on the commit it produced, and fm/task-v is retired.
  git -C "$dir/wt" commit -q --allow-empty -m "the task's own work"
  work=$(git -C "$dir/wt" rev-parse HEAD)
  retire_local_branch "$dir" "$work"
  git -C "$dir/wt" rev-parse --verify --quiet refs/heads/fm/task-v >/dev/null 2>&1 \
    && fail "the fixture did not actually retire fm/task-v"
  printf 'done: branch=fm/task-v head=%s - shipped\n' "$work" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] \
    || fail "genuinely landed local-only work with a retired branch was not verified: $result"
  pass "local-only work whose branch was retired after landing still verifies"
}

# The other half of the retired arm: the branch is gone, but the task's own copy
# is not sitting on the commit claimed, so nothing establishes that this task
# produced it. Absence of evidence, so unverified rather than contradicted.
test_a_retired_branch_claim_with_the_copy_elsewhere_is_not_verified() {
  local out dir default work result
  out=$(make_local_world local-retired-elsewhere) || fail "the local-only fixture failed"
  dir=${out%%$'\t'*}
  default=${out#*$'\t'}
  git -C "$dir/wt" commit -q --allow-empty -m "the task's own work"
  work=$(git -C "$dir/wt" rev-parse HEAD)
  retire_local_branch "$dir" "refs/heads/$default"
  printf 'done: branch=fm/task-v head=%s - shipped\n' "$work" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  case "${result#*$'\t'}" in
    verified:*) fail "a retired-branch claim the local copy does not stand behind was verified: $result" ;;
  esac
  [ "${result%%$'\t'*}" = 3 ] \
    || fail "a retired-branch claim with the copy elsewhere was not unverified: $result"
  case "$result" in *"local copy's own HEAD"*) ;; *) fail "the unverified reason did not name what could not be established: $result" ;; esac
  pass "a retired-branch claim the task's own copy does not stand behind is not verified"
}

# --- (o)-(p) the durable record resists a downgrade but not a contradiction ---

# Establish the claim, then re-run the verifier against the same claim under the
# given fake-forge state. Echoes the re-run's own "<exit>\t<line>" and leaves the
# durable record for the caller to read through fm_done_claim_status.
establish_then_rerun() {  # <name> <rerun-gh-out>
  local name=$1 rerun=$2 dir shipped result
  dir=$(make_world "$name")
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="OPEN	$shipped	SUCCESS" \
    FAKE_NM_STATUS="$(nm_status fm/task-v "$shipped")" verify "$dir")
  [ "${result%%$'\t'*}" = 0 ] || fail "setup error: the claim did not verify: $result"
  result=$(FAKE_GH_OUT="$rerun" FAKE_NM_STATUS="$(nm_status fm/task-v "$shipped")" verify "$dir")
  printf '%s\t%s\n' "$dir" "$result"
}

test_a_transient_unverified_does_not_downgrade_an_established_record() {
  local out dir result
  # The forge is unreachable on the re-run, which is absence of evidence, not
  # evidence of falsity.
  out=$(establish_then_rerun downgrade-guard '') || fail "the downgrade-guard fixture failed"
  dir=${out%%$'\t'*}
  result=${out#*$'\t'}
  [ "${result%%$'\t'*}" = 3 ] \
    || fail "the re-run hid the transient failure it actually observed: $result"
  case "$result" in *unverified:*) ;; *) fail "the re-run did not report the unverified it observed: $result" ;; esac
  fm_done_claim_status "$dir/state" task-v
  [ "$FM_DONE_CLAIM_STATE" = verified ] \
    || fail "a transient forge outage downgraded an established record to $FM_DONE_CLAIM_STATE"
  pass "a transient unverified is reported but never downgrades an established record"
}

test_a_contradiction_still_overwrites_an_established_record() {
  local out dir result other
  other=00112233445566778899aabbccddeeff00112233
  # The forge answers, and it answers with a different head: the claim is now
  # established false, so the protection above must not freeze the record.
  out=$(establish_then_rerun contradiction-overwrites "OPEN	$other	SUCCESS") \
    || fail "the contradiction-overwrite fixture failed"
  dir=${out%%$'\t'*}
  result=${out#*$'\t'}
  [ "${result%%$'\t'*}" = 4 ] || fail "the re-run did not contradict the claim: $result"
  fm_done_claim_status "$dir/state" task-v
  [ "$FM_DONE_CLAIM_STATE" = contradicted ] \
    || fail "a contradiction did not overwrite the verified record ($FM_DONE_CLAIM_STATE)"
  pass "a contradiction still overwrites an established record, so the guard is not a freeze"
}

# --- (q) an absent mode= does not skip the validated-commit check -------------

test_an_absent_mode_still_checks_the_validated_commit() {
  local dir result shipped validated
  dir=$(make_world absent-mode)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  validated=$(git -C "$dir/wt" rev-parse 'HEAD~1')
  # A legacy ship task: spawned before mode= was recorded at all.
  fm_write_meta "$dir/state/task-v.meta" \
    "window=fm:fm-task-v" "worktree=$dir/wt" "kind=ship"
  printf 'done: pr=https://github.com/o/r/pull/7 head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(FAKE_GH_OUT="OPEN	$shipped	SUCCESS" \
    FAKE_NM_STATUS="$(nm_status fm/task-v "$validated")" verify "$dir")
  [ "${result%%$'\t'*}" = 4 ] \
    || fail "a task with no recorded mode skipped the validated-commit check: $result"
  case "$result" in *"validation ran against"*) ;; *) fail "the contradiction did not name the validated commit: $result" ;; esac
  pass "a task whose meta records no mode still gets the validated-commit check"
}

# --- (v) an absent mode= with a local-only claim shape ------------------------

# A task spawned before mode= was recorded, whose worker then appended the
# conforming LOCAL-ONLY claim teardown asked it for. Reading the absent record
# as a PR mode would report that true claim as `contradicted: claim names no
# PR`, and teardown would print a stop-and-investigate falsehood. The claim's
# own shape - a branch and no PR - resolves it.
test_an_absent_mode_with_a_branch_claim_is_judged_as_local_only() {
  local dir result shipped
  dir=$(make_world absent-mode-branch)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/state/task-v.meta" \
    "window=fm:fm-task-v" "worktree=$dir/wt" "kind=ship"
  printf 'done: branch=fm/task-v head=%s - ready\n' "$shipped" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  case "$result" in
    *"claim names no PR"*) fail "a true local-only claim with no recorded mode was reported as false: $result" ;;
  esac
  [ "${result%%$'\t'*}" = 0 ] \
    || fail "a true local-only claim with no recorded mode did not verify: $result"
  pass "an absent mode with a branch-shaped claim is judged as local-only"
}

# --- (w) an absent mode= the claim shape cannot resolve -----------------------

# Absence of evidence may never manufacture evidence of falsity. When neither
# the meta nor the claim says which mode to judge against, the honest verdict is
# unverified naming exactly that, not contradicted.
test_an_unresolvable_absent_mode_is_unverified_never_contradicted() {
  local dir result shipped
  dir=$(make_world absent-mode-ambiguous)
  shipped=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/state/task-v.meta" \
    "window=fm:fm-task-v" "worktree=$dir/wt" "kind=ship"

  printf 'done: head=%s - shipped\n' "$shipped" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 3 ] \
    || fail "a claim naming neither a branch nor a PR was not unverified: $result"
  case "$result" in
    *"no delivery mode"*) ;;
    *) fail "the verdict did not name the unrecorded mode: $result" ;;
  esac

  printf 'done: pr=https://github.com/o/r/pull/7 branch=fm/task-v head=%s - shipped\n' "$shipped" \
    > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" = 3 ] \
    || fail "a claim naming both a branch and a PR was not unverified: $result"
  pass "an absent mode the claim cannot resolve is unverified, never contradicted"
}

# --- (x) the help is the whole header ----------------------------------------

# The help IS the header comment, so a hard-coded line range silently truncates
# it the moment the header grows. Asserted on the documented contract the last
# sentence states, which is the one a range that stops short would drop.
test_help_prints_the_whole_header() {
  local out last
  out=$("$VERIFY" --help) || fail "fm-verify-done.sh --help did not exit 0"
  last=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
  case "$last" in
    *"invalidates it rather than inheriting its verdict.") ;;
    *) fail "--help truncated its own header; it ends at: $last" ;;
  esac
  case "$out" in
    *"Verdicts, written to state/"*) ;;
    *) fail "--help dropped the verdict contract it documents" ;;
  esac
  pass "--help prints the whole header it documents itself with"
}

# --- (r) a relative scout report= follows the configured data root ------------

test_a_relative_scout_report_follows_a_relocated_data_root() {
  local dir result
  dir=$(make_world scout-relocated scout scout)
  mkdir -p "$dir/elsewhere/task-v"
  printf 'findings\n' > "$dir/elsewhere/task-v/report.md"
  # Nothing at the home-relative location, so a read that ignored the configured
  # data root would find no report at all.
  assert_absent "$dir/data/task-v/report.md" "setup error: the report exists at the unrelocated path"
  printf 'done: report=data/task-v/report.md - found it\n' > "$dir/state/task-v.status"
  result=$(verify "$dir" "$dir/elsewhere")
  [ "${result%%$'\t'*}" = 0 ] \
    || fail "a relative scout report was not resolved against the relocated data root: $result"
  pass "a relative scout report= resolves against the configured data root, relocated or not"
}

# --- (s) a close does not invent a done claim --------------------------------

# Publish a closed-unmerged outcome in a main home (no parent binding, so the
# outcome routes to this home's durable wake queue) and echo the queue's text.
close_publication() {  # <name> <status-line>
  local name=$1 status_line=$2 dir state
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  mkdir -p "$state"
  printf '%s\n' "$status_line" > "$state/task-v.status"
  fm_merge_outcome_report "$dir" "$state" task-v https://github.com/o/r/pull/7 \
    poll closed-unmerged || fail "the close outcome could not be published for $name"
  cat "$state/.wake-queue"
}

# The same publication from a secondmate home, which reports upward on its
# parent channel instead. Echoes the line the parent actually received.
close_publication_upward() {  # <name> <status-line>
  local name=$1 status_line=$2 dir state parent
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  parent="$TMP_ROOT/$name-parent"
  mkdir -p "$state" "$parent/state"
  printf 'mate-%s\n' "$name" > "$dir/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$dir/.fm-secondmate-parent"
  printf '%s\n' "$status_line" > "$state/task-v.status"
  fm_merge_outcome_report "$dir" "$state" task-v https://github.com/o/r/pull/7 \
    poll closed-unmerged || fail "the upward close outcome could not be published for $name"
  cat "$parent/state/mate-$name.status"
}

test_a_close_does_not_invent_a_done_claim() {
  local out claim
  claim='done: pr=https://github.com/o/r/pull/7 head=00112233445566778899aabbccddeeff00112233 - shipped'

  # The poll is armed at PR registration, so a close can arrive while the worker
  # is still working and has claimed nothing.
  out=$(close_publication close-no-claim 'working: still going') \
    || fail "the no-claim close fixture failed"
  case "$out" in
    *"the done record"*) fail "a close invented a done record the task never wrote: $out" ;;
  esac
  case "$out" in
    *"PR closed without merging"*) ;;
    *) fail "a close with no claim on record was not published at all: $out" ;;
  esac

  out=$(close_publication close-with-claim "$claim") || fail "the claimed close fixture failed"
  case "$out" in
    *"contradicting the done record"*) ;;
    *) fail "a close over a real done claim did not report the contradiction: $out" ;;
  esac

  # The durable parent line is the record the finding named, so it is checked on
  # its own surface rather than inferred from the wake note.
  out=$(close_publication_upward up-no-claim 'working: still going') \
    || fail "the upward no-claim close fixture failed"
  case "$out" in
    *"claims done"*) fail "the parent channel was told a task claims done when it never did: $out" ;;
  esac
  case "$out" in
    *"closed-unmerged-task-v"*"closed without merging"*) ;;
    *) fail "the upward close with no claim was not published at all: $out" ;;
  esac

  out=$(close_publication_upward up-with-claim "$claim") \
    || fail "the upward claimed close fixture failed"
  case "$out" in
    *"claims done but"*) ;;
    *) fail "the parent channel lost the contradiction for a real done claim: $out" ;;
  esac
  pass "a close reports a contradicted done record only when a claim is actually on record"
}

# --- (t)-(u) the unread surface ----------------------------------------------

test_a_configured_verb_vocabulary_is_not_unrecognised() {
  # A home may replace the whole captain-relevant verb set. Its own states must
  # not then be labelled as matching no status verb.
  # Read by the sourced classifier, not by this file.
  # shellcheck disable=SC2034
  FM_CAPTAIN_RE='escalate:|shipped:'
  status_line_is_unrecognized "escalate: the migration needs a decision" \
    && fail "a verb this home configured as a real state was called unrecognised"
  status_line_is_unrecognized "shipped: the fix is out" \
    && fail "a second configured verb was called unrecognised"
  status_line_is_unrecognized "Migration syntax: OK" \
    || fail "worker prose stopped being unrecognised under a configured vocabulary"
  unset FM_CAPTAIN_RE

  # The default set also routes legacy bare lines as real states, so they are
  # not unrecognised either.
  status_line_is_unrecognized "merged" && fail "a legacy bare captain line was called unrecognised"
  status_line_is_unrecognized "PR ready" && fail "a legacy bare PR line was called unrecognised"
  pass "a home's configured verb vocabulary and the legacy bare lines stay recognised"
}

# The reflog is the branch's own history, but only while its creation entry
# survives: `git gc` prunes entries past gc.reflogExpire, and on a long-lived
# branch that can leave the oldest SURVIVING entry sitting on the tip. Reading
# that as "created here, introduced nothing" would report a true claim as false.
# A history that no longer reaches the creation is absence of evidence.
test_a_pruned_reflog_is_unverified_not_contradicted() {
  local out dir tip result
  out=$(make_local_world local-pruned-reflog) || fail "the local-only fixture failed"
  dir=${out%%$'\t'*}
  git -C "$dir/wt" commit -q --allow-empty -m "work the task itself produced"
  tip=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" reflog show refs/heads/fm/task-v --format='%gs' \
    | tail -1 | grep -q '^branch: Created from ' \
    || fail "the fixture did not leave a branch-creation entry to expire"
  # Exactly what gc.reflogExpire leaves behind on a long-lived branch: the
  # creation entry gone, the branch's own tip now the oldest entry git can see.
  git -C "$dir/wt" reflog delete 'refs/heads/fm/task-v@{1}' \
    || fail "the fixture could not expire the branch-creation entry"
  [ "$(git -C "$dir/wt" reflog show --format=%H refs/heads/fm/task-v | tail -1)" = "$tip" ] \
    || fail "expiring the creation entry did not leave the tip as the oldest entry"
  printf 'done: branch=fm/task-v head=%s - shipped\n' "$tip" > "$dir/state/task-v.status"
  result=$(verify "$dir")
  [ "${result%%$'\t'*}" != 4 ] \
    || fail "a true claim was contradicted because the branch's creation entry had expired: $result"
  [ "${result%%$'\t'*}" = 3 ] \
    || fail "a branch history that no longer reaches its creation was not unverified: $result"
  case "$result" in
    *"oldest surviving reflog entry"*) ;;
    *) fail "the unverified reason did not name the unreadable history: $result" ;;
  esac
  pass "a branch whose creation entry has been pruned reads unverified, never contradicted"
}

# The rule the whole contract rests on, exercised through its owner rather than
# left to each judging site to remember: `contradicted` is positive evidence of
# falsity, so it must carry the observation it contradicts with. A site that can
# name nothing it observed records `unverified` however it asked to be recorded.
test_a_contradiction_needs_the_observation_it_contradicts_with() {
  fm_done_verdict_resolve contradicted 'the branch introduced nothing' ''
  [ "$FM_DONE_VERDICT_RESOLVED" = unverified ] \
    || fail "a contradiction with nothing observed was recorded as $FM_DONE_VERDICT_RESOLVED"
  case "$FM_DONE_VERDICT_RESOLVED_REASON" in
    *"nothing was observed"*"the branch introduced nothing"*) ;;
    *) fail "the downgraded reason lost either the rule or the caller's words: $FM_DONE_VERDICT_RESOLVED_REASON" ;;
  esac

  fm_done_verdict_resolve contradicted 'the branch introduced nothing' 'fm/task-v is still at abc123'
  [ "$FM_DONE_VERDICT_RESOLVED" = contradicted ] \
    || fail "an ordinary contradiction carrying its observation was downgraded"
  [ "$FM_DONE_VERDICT_RESOLVED_REASON" = 'the branch introduced nothing' ] \
    || fail "an established contradiction had its reason rewritten: $FM_DONE_VERDICT_RESOLVED_REASON"

  # The other two verdicts are untouched by the rule; only falsity needs evidence.
  fm_done_verdict_resolve unverified 'the forge could not be reached' ''
  [ "$FM_DONE_VERDICT_RESOLVED" = unverified ] || fail "an unverified verdict was rewritten"
  fm_done_verdict_resolve verified 'the PR is at the claimed head' ''
  [ "$FM_DONE_VERDICT_RESOLVED" = verified ] || fail "a verified verdict was rewritten"
  pass "a contradiction must name what it observed, and one that cannot reads unverified"
}

# The mixed span, which is the shape that actually loses words: prose past the
# cap, then a line the drain DOES recognise. The acknowledgement is one
# contiguous byte offset, so a `note:` printed after an omission would carry the
# cursor past the held-back prose and retire it as presented - while this same
# drain has just told the operator it was held for the next one.
test_capped_lines_return_even_when_a_recognised_line_follows_them() {
  local dir state status first second i
  dir=$(make_case unrecognised-mixed-span)
  state="$dir/state"
  status="$state/task9.status"
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the cursor"

  for i in 1 2 3; do
    printf 'prose line %s from the worker\n' "$i" >> "$status"
  done
  printf 'note: here is the answer you asked for\n' >> "$status"

  first="$dir/first.out"; second="$dir/second.out"
  FM_DRAIN_UNRECOGNISED_MAX=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first" \
    || fail "the capped drain failed on a mixed span"
  assert_grep 'prose line 1 from the worker' "$first" \
    "the capped drain printed no prose at all: $(cat "$first")"
  assert_grep 'UNREAD STATUS: 2 more unrecognised line(s) held' "$first" \
    "the held-back prose was not counted: $(cat "$first")"

  FM_DRAIN_UNRECOGNISED_MAX=9 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" \
    || fail "the second drain failed"
  assert_grep 'prose line 2 from the worker' "$second" \
    "prose the cap held back was retired by a recognised line printed after it: $(cat "$second")"
  assert_grep 'prose line 3 from the worker' "$second" \
    "the rest of the held-back prose never came back: $(cat "$second")"
  assert_no_grep 'prose line 1 from the worker' "$second" \
    "a line that was already presented was replayed: $(cat "$second")"
  pass "held-back prose survives a recognised line printed later in the same span"
}

# --- the three shapes of terminal evidence -----------------------------------
# A verdict is a statement about a world. Absence of evidence must never
# downgrade one; positive evidence of falsity outranks everything; and a world
# that has CHANGED under a verdict leaves it neither wrong nor still valid,
# which is the third shape the record now names. The site that observes a PR
# reach a terminal state is the only one that can see the third, so these drive
# it through fm_merge_outcome_report rather than through the verifier.

HEAD_A=00112233445566778899aabbccddeeff00112233
PR_A=https://github.com/o/r/pull/7

# A world holding one terminal claim, optionally with a verdict already
# standing for it. Echoes the state dir; the caller reads the record back
# through the library rather than through a global, because this runs inside a
# command substitution.
make_claim_world() {  # <name> <claim-line> [<standing-verdict> <reason>]
  local name=$1 claim=$2 verdict=${3:-} reason=${4:-} dir state hash
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  mkdir -p "$state"
  printf '%s\n' "$claim" > "$state/task-v.status"
  if [ -n "$verdict" ]; then
    hash=$(fm_done_claim_hash "$claim") || return 1
    fm_done_verdict_write "$state" task-v "$verdict" "$hash" "$reason" || return 1
  fi
  printf '%s\n' "$dir"
}

# A merge is not a contradiction and not an outage: it is the world moving past
# what was established. The verdict was true when it was made and no longer
# describes anything, so it must stop counting as established rather than
# survive untouched or be recorded as false.
test_a_merge_marks_an_established_claim_stale() {
  local claim dir
  claim="done: pr=$PR_A head=$HEAD_A - shipped"
  dir=$(make_claim_world merge-stale "$claim" verified "the PR is open at the claimed head") \
    || fail "the established-claim fixture failed"
  fm_merge_outcome_report "$dir" "$dir/state" task-v "$PR_A" poll merged \
    || fail "the merge outcome could not be published"
  fm_done_claim_status "$dir/state" task-v
  [ "$FM_DONE_CLAIM_STATE" = stale ] \
    || fail "a merge left an established claim reported as $FM_DONE_CLAIM_STATE"
  case "$FM_DONE_CLAIM_REASON" in
    *"re-run bin/fm-verify-done.sh"*) ;;
    *) fail "the stale record did not say what to do about it: $FM_DONE_CLAIM_REASON" ;;
  esac
  pass "a merge marks an established claim stale rather than leaving it established"
}

# The three-week rot, at the record rather than at the publication: a claim
# established while the PR was open must not survive that PR being closed.
test_a_close_contradicts_an_established_claim_in_the_record() {
  local claim dir
  claim="done: pr=$PR_A head=$HEAD_A - shipped"
  dir=$(make_claim_world close-contradicts "$claim" verified "the PR is open at the claimed head") \
    || fail "the established-claim fixture failed"
  fm_merge_outcome_report "$dir" "$dir/state" task-v "$PR_A" poll closed-unmerged \
    || fail "the close outcome could not be published"
  fm_done_claim_status "$dir/state" task-v
  [ "$FM_DONE_CLAIM_STATE" = contradicted ] \
    || fail "a close left an established claim reported as $FM_DONE_CLAIM_STATE"
  case "$FM_DONE_CLAIM_REASON" in
    *"closed without merging"*) ;;
    *) fail "the contradiction did not name the close: $FM_DONE_CLAIM_REASON" ;;
  esac
  pass "a close records a contradiction over a claim established while the PR was open"
}

# Neither arm may invent a verdict for a task that has asserted nothing. The
# poll is armed at PR registration, long before any claim.
test_a_terminal_outcome_invents_no_verdict_without_a_claim() {
  local dir outcome
  for outcome in merged closed-unmerged; do
    dir=$(make_claim_world "no-claim-$outcome" 'working: still going') \
      || fail "the no-claim fixture failed"
    fm_merge_outcome_report "$dir" "$dir/state" task-v "$PR_A" poll "$outcome" \
      || fail "the $outcome outcome could not be published without a claim"
    assert_absent "$dir/state/task-v.done-verdict" \
      "a $outcome outcome invented a verdict for a task that never claimed done"
    fm_done_claim_status "$dir/state" task-v
    [ "$FM_DONE_CLAIM_STATE" = none ] \
      || fail "a $outcome outcome gave a claimless task the state $FM_DONE_CLAIM_STATE"
  done
  pass "a terminal PR outcome invents no verdict for a task that never claimed done"
}

# The precedence itself, driven through the record's owner. Each incoming
# verdict is tried against a standing one and the record is read back.
test_verdict_write_precedence_keeps_the_stronger_statement() {
  local dir state claim hash
  claim="done: pr=$PR_A head=$HEAD_A - shipped"
  dir="$TMP_ROOT/verdict-precedence"
  state="$dir/state"
  mkdir -p "$state"
  printf '%s\n' "$claim" > "$state/task-v.status"
  hash=$(fm_done_claim_hash "$claim") || fail "the claim could not be hashed"

  # Absence of evidence overwrites nothing: not an establishment, not a
  # contradiction, not a superseded world.
  fm_done_verdict_write "$state" task-v verified "$hash" established || fail "verified did not record"
  fm_done_verdict_write "$state" task-v unverified "$hash" 'the forge could not be reached' \
    || fail "the refused unverified write reported failure"
  fm_done_verdict_read "$state" task-v || fail "the record became unreadable"
  [ "$FM_DONE_VERDICT" = verified ] \
    || fail "an outage un-established a verified record: $FM_DONE_VERDICT"

  fm_done_verdict_write "$state" task-v stale "$hash" 'the PR merged' || fail "stale did not record"
  fm_done_verdict_read "$state" task-v || fail "the record became unreadable"
  [ "$FM_DONE_VERDICT" = stale ] || fail "stale did not overwrite verified: $FM_DONE_VERDICT"

  fm_done_verdict_write "$state" task-v unverified "$hash" 'the forge could not be reached' \
    || fail "the refused unverified write reported failure"
  fm_done_verdict_read "$state" task-v || fail "the record became unreadable"
  [ "$FM_DONE_VERDICT" = stale ] || fail "an outage overwrote a stale record: $FM_DONE_VERDICT"

  fm_done_verdict_write "$state" task-v contradicted "$hash" 'the PR was closed unmerged' \
    || fail "contradicted did not record"
  fm_done_verdict_read "$state" task-v || fail "the record became unreadable"
  [ "$FM_DONE_VERDICT" = contradicted ] \
    || fail "contradicted did not overwrite stale: $FM_DONE_VERDICT"

  # Falsity is the strongest statement: neither absence nor a changed world
  # may soften it. Only the verifier's own fresh look may.
  fm_done_verdict_write "$state" task-v stale "$hash" 'the PR merged' \
    || fail "the refused stale write reported failure"
  fm_done_verdict_read "$state" task-v || fail "the record became unreadable"
  [ "$FM_DONE_VERDICT" = contradicted ] \
    || fail "stale overwrote a contradiction: $FM_DONE_VERDICT"

  fm_done_verdict_write "$state" task-v unverified "$hash" 'the forge could not be reached' \
    || fail "the refused unverified write reported failure"
  fm_done_verdict_read "$state" task-v || fail "the record became unreadable"
  [ "$FM_DONE_VERDICT" = contradicted ] \
    || fail "an outage overwrote a contradiction: $FM_DONE_VERDICT"

  fm_done_verdict_write "$state" task-v verified "$hash" 're-established' \
    || fail "a fresh establishment did not record"
  fm_done_verdict_read "$state" task-v || fail "the record became unreadable"
  [ "$FM_DONE_VERDICT" = verified ] \
    || fail "the verifier's fresh look could not overwrite a contradiction: $FM_DONE_VERDICT"
  pass "verdict write precedence keeps the stronger statement about the same claim"
}

# The presentation cursor is a BYTE offset. A worker's prose is arbitrary text,
# so a held-back span containing one multibyte character must not leave the
# cursor mid-line and turn the tail of an already-presented line into a whole
# new status line on the next drain.
test_a_held_back_span_with_multibyte_prose_presents_no_fragment() {
  local dir state status first second line
  dir=$(make_case unrecognised-multibyte)
  state="$dir/state"
  status="$state/task9.status"
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the cursor"

  {
    printf 'prose \xe2\x9c\x93 line one from the worker\n'
    printf 'prose \xe2\x9c\x93 line two from the worker\n'
    printf 'prose \xe2\x9c\x93 line three from the worker\n'
  } >> "$status"

  first="$dir/first.out"; second="$dir/second.out"
  FM_DRAIN_UNRECOGNISED_MAX=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first" \
    || fail "the capped drain failed on a multibyte span"
  assert_grep 'line one from the worker' "$first" \
    "the capped drain printed nothing: $(cat "$first")"

  FM_DRAIN_UNRECOGNISED_MAX=9 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" \
    || fail "the second drain failed"
  assert_grep 'line two from the worker' "$second" \
    "a held-back multibyte line never came back: $(cat "$second")"
  assert_grep 'line three from the worker' "$second" \
    "the rest of the held-back multibyte prose never came back: $(cat "$second")"
  # Every unrecognised line presented must be a whole line the worker wrote, not
  # a tail sliced out of one that was already shown.
  while IFS= read -r line; do
    case "$line" in
      *'UNRECOGNISED (matches no status verb): '*) ;;
      *) continue ;;
    esac
    case "${line#*'UNRECOGNISED (matches no status verb): '}" in
      'prose '*' from the worker') ;;
      *) fail "the drain presented a fragment of an already-presented line: $line" ;;
    esac
  done < "$second"
  pass "a held-back span with multibyte prose presents whole lines, never a fragment"
}

# The cap bounds one TASK, not the whole drain. A per-drain budget would let one
# chatty worker defer every alphabetically later task behind it, drain after
# drain, which is the starvation the cap exists to prevent.
test_the_unrecognised_cap_is_per_task_not_per_drain() {
  local dir state out i
  dir=$(make_case unrecognised-per-task)
  state="$dir/state"
  printf 'note: bootstrap cursor line\n' > "$state/task-a.status"
  printf 'note: bootstrap cursor line\n' > "$state/task-z.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the cursors"

  for i in 1 2 3; do
    printf 'chatty prose %s from task-a\n' "$i" >> "$state/task-a.status"
  done
  printf 'the one line task-z had to say\n' >> "$state/task-z.status"

  out="$dir/drain.out"
  FM_DRAIN_UNRECOGNISED_MAX=2 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "the capped drain failed across two tasks"
  assert_grep 'chatty prose 1 from task-a' "$out" \
    "the chatty task printed nothing: $(cat "$out")"
  assert_grep 'the one line task-z had to say' "$out" \
    "a quiet task was starved behind a chatty one's exhausted budget: $(cat "$out")"
  pass "the unrecognised cap is per task, so one chatty worker cannot starve the rest"
}

test_the_omitted_unrecognised_count_carries_its_header() {
  local dir state status out
  dir=$(make_case unrecognised-cap-zero)
  state="$dir/state"
  status="$state/task9.status"
  out="$dir/drain.out"
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the cursor"

  printf 'Migration syntax: OK\n' >> "$status"
  printf -- '- ruff check on all changed files: all passed\n' >> "$status"
  # Opting out of the surface must not leave a bare counter with nothing to
  # say what it is counting.
  FM_DRAIN_UNRECOGNISED_MAX=0 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed with the unrecognised surface capped at zero"
  assert_grep 'UNREAD STATUS: 2 more unrecognised line(s) held for the next drain' "$out" \
    "the omitted unrecognised lines were not counted: $(cat "$out")"
  assert_grep 'UNREAD STATUS (new since last drain' "$out" \
    "the omitted count was printed without its section header: $(cat "$out")"
  pass "the omitted-unrecognised count is never printed as a bare orphan line"
}

# The cap bounds one drain; it must not cost the worker's words. What the cap
# held back stays unread and comes back on the next drain, while what was
# printed is not replayed - the brief is explicit that losing a worker's words
# is worse than showing them.
test_capped_unrecognised_lines_return_on_the_next_drain() {
  local dir state status first second third
  dir=$(make_case unrecognised-deferred)
  state="$dir/state"
  status="$state/task9.status"
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the cursor"

  {
    printf 'first prose line from the worker\n'
    printf 'second prose line from the worker\n'
    printf 'third prose line from the worker\n'
  } >> "$status"

  first="$dir/first.out"; second="$dir/second.out"; third="$dir/third.out"
  FM_DRAIN_UNRECOGNISED_MAX=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first" \
    || fail "the capped drain failed"
  assert_grep 'first prose line' "$first" "the capped drain printed nothing: $(cat "$first")"
  assert_no_grep 'second prose line' "$first" "the cap did not hold the second line back"
  assert_grep 'UNREAD STATUS: 2 more unrecognised line(s) held' "$first" \
    "the held-back lines were not counted: $(cat "$first")"

  FM_DRAIN_UNRECOGNISED_MAX=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" \
    || fail "the second drain failed"
  assert_grep 'second prose line' "$second" \
    "a line the cap held back never came back: $(cat "$second")"
  assert_no_grep 'first prose line' "$second" \
    "a line that was already presented was replayed: $(cat "$second")"

  FM_DRAIN_UNRECOGNISED_MAX=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$third" \
    || fail "the third drain failed"
  assert_grep 'third prose line' "$third" \
    "the last held-back line never came back: $(cat "$third")"
  assert_no_grep 'second prose line' "$third" \
    "an already-presented line was replayed on the third drain: $(cat "$third")"
  pass "unrecognised lines the cap holds back re-present instead of being lost"
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
test_a_symlinked_scout_report_is_unverified_not_contradicted
test_a_verdict_does_not_cover_a_later_claim
test_no_claim_is_not_a_verdict
test_poll_reports_a_close_as_well_as_a_merge
test_marker_distinguishes_the_two_terminal_outcomes
test_drain_flags_a_line_matching_no_status_verb
test_known_verbs_are_not_flagged_as_unrecognised
test_a_fabricated_local_only_claim_is_not_verified
test_a_local_only_claim_naming_the_spawn_base_is_contradicted
test_a_local_only_claim_on_introduced_work_verifies
test_a_local_only_claim_naming_another_branch_is_contradicted
test_a_local_only_claim_on_a_retired_branch_still_verifies
test_a_retired_branch_claim_with_the_copy_elsewhere_is_not_verified
test_a_transient_unverified_does_not_downgrade_an_established_record
test_a_contradiction_still_overwrites_an_established_record
test_an_absent_mode_still_checks_the_validated_commit
test_a_relative_scout_report_follows_a_relocated_data_root
test_an_absent_mode_with_a_branch_claim_is_judged_as_local_only
test_an_unresolvable_absent_mode_is_unverified_never_contradicted
test_help_prints_the_whole_header
test_a_close_does_not_invent_a_done_claim
test_a_configured_verb_vocabulary_is_not_unrecognised
test_a_pruned_reflog_is_unverified_not_contradicted
test_a_contradiction_needs_the_observation_it_contradicts_with
test_a_merge_marks_an_established_claim_stale
test_a_close_contradicts_an_established_claim_in_the_record
test_a_terminal_outcome_invents_no_verdict_without_a_claim
test_verdict_write_precedence_keeps_the_stronger_statement
test_a_held_back_span_with_multibyte_prose_presents_no_fragment
test_the_unrecognised_cap_is_per_task_not_per_drain
test_the_omitted_unrecognised_count_carries_its_header
test_capped_unrecognised_lines_return_on_the_next_drain
test_capped_lines_return_even_when_a_recognised_line_follows_them
echo "all fm-done-verified tests passed"
