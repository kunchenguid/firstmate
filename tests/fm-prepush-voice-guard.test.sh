#!/usr/bin/env bash
# Pre-push refusal that keeps firstmate's internal voice out of published text,
# owned by bin/fm-prepush-voice-guard.sh.
#
# Regression origin: AGENTS.md tells every agent to address the user as
# "captain" in every response, and agents working inside this repo read that as
# an ordinary repo file and apply it to commit messages. The commits that leaked
# came from the no-mistakes pipeline's own fix agents, so no brief could have
# prevented them. Merged history carried 222 such lines before this guard.
#
# The two cases the task fixed this against, both real:
#   REFUSE  "fix(ci): Captain, fixed the stale-throttle inheritance: ...
#            Changes remain uncommitted for the outer executor"
#   PASS    "A session-scoped negative cache keeps the conclusion"
#
# The second is why the rule set keys on the POSITION of an address rather than
# on house vocabulary: this repo's own subject matter is the fleet machinery, so
# "captain hold", "captain intent", the /ahoy skill, and "shipshape" are all
# legitimate and must keep shipping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-prepush-voice-guard.sh"
LINT="$ROOT/bin/fm-lint.sh"
LINT_WF="$ROOT/bin/fm-lint-workflows.sh"

# fm_voice_repo <dir>: a real repo with a "main" branch carrying one commit and
# a feature branch checked out. Commits added afterwards are the set the guard
# scans by default: reachable from HEAD, not carried by the default branch.
fm_voice_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name 'Firstmate Tests'
  git -C "$dir" config user.email 'tests@example.invalid'
  printf '# fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm 'initial'
  git -C "$dir" checkout -q -b feature
}

# fm_voice_commit <dir> <message>: one commit carrying exactly <message>.
fm_voice_commit() {
  local dir=$1 message=$2 file
  file="$dir/f$(date +%s%N 2>/dev/null || date +%s)$RANDOM"
  printf 'x\n' > "$file"
  git -C "$dir" add -A
  git -C "$dir" commit -q -F - <<EOF
$message
EOF
}

# fm_voice_text <text>: run the guard over <text>, echo its output, return its code.
fm_voice_text() {
  printf '%s\n' "$1" | "$GUARD" --text - 2>&1
}

# fm_voice_scan <dir>: run the guard's default (pre-push) mode inside <dir>.
fm_voice_scan() {
  (cd "$1" && "$GUARD" 2>&1)
}

# --- the two cases the task names -------------------------------------------

test_refuses_the_real_leaked_commit() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-voice-leak)
  fm_voice_repo "$tmp/repo"
  fm_voice_commit "$tmp/repo" \
    'fix(ci): Captain, fixed the stale-throttle inheritance: cadence markers now bind to the current wait declaration. Changes remain uncommitted for the outer executor'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 1 "$rc" "the real leaked commit message was not refused"
  assert_contains "$out" "captain-address-opening" \
    "refusal did not name the address rule that matched"
  assert_contains "$out" "delivery-machinery-handoff" \
    "refusal did not name the machinery-narration rule that matched"
  pass "refuses the real leaked commit message"
}

test_passes_the_real_legitimate_message() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-voice-legit)
  fm_voice_repo "$tmp/repo"
  fm_voice_commit "$tmp/repo" 'A session-scoped negative cache keeps the conclusion'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 0 "$rc" "a legitimate technical message was refused"$'\n'"$out"
  pass "passes the real legitimate message"
}

# --- the precision boundary: this repo's own vocabulary must keep shipping ---

test_passes_legitimate_captain_and_house_vocabulary() {
  local tmp out rc=0 message
  tmp=$(fm_test_tmproot fm-voice-vocab)
  fm_voice_repo "$tmp/repo"

  # Every line below is taken from, or modelled on, real merged history.
  for message in \
    'fix(bin): never close a captain call during cleanup' \
    'fix(bin): split brief task into captain intent and firstmate spec' \
    'feat(stow): captain-gated offload to local excluded skills' \
    'docs: report full PR URLs to the captain, not bare numbers' \
    'fix(bin): give a captain hold the same bounded pause cadence as a declared pause' \
    'feat(ahoy): guide captains through open decisions' \
    'Require shipshape routine acknowledgement' \
    'fix: keep active children underway beside a captain hold' \
    'perf: the outer process-group kill moves to budget+1s' \
    'docs: captain.md now records the fleet owner' \
    '* captain.md gains a section'
  do
    fm_voice_commit "$tmp/repo" "$message"
  done
  # The wrapped-prose case the line rule is deliberately capital-only for: a
  # body line can begin with a lowercase "captain," carried over mid-sentence.
  fm_voice_commit "$tmp/repo" 'fix(bin): route the decision

The unresolved call is escalated to the
captain, who answers it at the next review.'
  # A spaced dash after "captain" is legitimate prose, not an address.
  fm_voice_commit "$tmp/repo" 'fix(watch): resurface so the pane still reaches the captain - once per window'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 0 "$rc" "legitimate captain/house vocabulary was refused"$'\n'"$out"
  pass "passes legitimate captain and house vocabulary"
}

# --- each rule, driven apart from the others --------------------------------

test_refuses_each_address_shape() {
  local out rc

  rc=0; out=$(fm_voice_text 'no-mistakes(lint): Captain: fix extension binding findings') || rc=$?
  expect_code 1 "$rc" "a colon address after a commit prefix was not refused"
  assert_contains "$out" "captain-address-opening" "colon address named the wrong rule"

  rc=0; out=$(fm_voice_text '* no-mistakes(review): Bound parent activity evidence scans, captain') || rc=$?
  expect_code 1 "$rc" "a trailing address was not refused"
  assert_contains "$out" "captain-address-trailing" "trailing address named the wrong rule"

  rc=0; out=$(fm_voice_text 'fix(bin): bound the scan

Captain, this also removes the second copy.') || rc=$?
  expect_code 1 "$rc" "an address opening a body paragraph was not refused"
  assert_contains "$out" "captain-address-line" "paragraph address named the wrong rule"

  rc=0; out=$(fm_voice_text 'fix(bin): bound the scan. Captain, the second copy is gone too.') || rc=$?
  expect_code 1 "$rc" "an address after a sentence boundary was not refused"

  rc=0; out=$(fm_voice_text 'fix(ci): Captain - fixed the scan') || rc=$?
  expect_code 1 "$rc" "a spaced-dash address after a commit prefix was not refused"
  assert_contains "$out" "captain-address-opening" "spaced-dash address named the wrong rule"

  rc=0; out=$(fm_voice_text 'fix(ci): Captain. Fixed the scan') || rc=$?
  expect_code 1 "$rc" "a period address after a commit prefix was not refused"

  rc=0; out=$(fm_voice_text 'fix(bin): bound the scan. Captain. Done.') || rc=$?
  expect_code 1 "$rc" "a period address after a sentence boundary was not refused"

  rc=0; out=$(fm_voice_text 'Captain - fixed the scan') || rc=$?
  expect_code 1 "$rc" "a line-start spaced-dash address was not refused"
  assert_contains "$out" "captain-address-line" "line-start spaced-dash address named the wrong rule"

  rc=0; out=$(fm_voice_text 'Captain. Fixed the scan') || rc=$?
  expect_code 1 "$rc" "a line-start period address was not refused"

  rc=0; out=$(fm_voice_text 'Ahoy captain, the branch is ready') || rc=$?
  expect_code 1 "$rc" "a greeting address was not refused"
  assert_contains "$out" "captain-address-greeting" "greeting address named the wrong rule"

  rc=0; out=$(fm_voice_text 'ci: the outer executor can now bind a fresh attestation to the updated head') || rc=$?
  expect_code 1 "$rc" "machinery handoff narration was not refused"
  assert_contains "$out" "delivery-machinery-handoff" "handoff narration named the wrong rule"

  pass "refuses each address and narration shape"
}

# --- the refusal has to be actionable, or it gets disabled ------------------

test_refuses_a_pointer_to_the_working_session() {
  local tmp out rc=0

  # The exact trailer shape already in merged history three times.
  rc=0
  out=$(fm_voice_text 'fix(bin): bound the scan

Claude-Session: https://claude.ai/code/session_01AJfonRT1YLcHJCJ2UYwc3J') || rc=$?
  expect_code 1 "$rc" "a session trailer was not refused"
  assert_contains "$out" "internal-session-pointer" "session trailer named the wrong rule"

  rc=0
  out=$(fm_voice_text 'Codex-Session: https://example.invalid/internal-session') || rc=$?
  expect_code 1 "$rc" "a runtime-prefixed session trailer was not refused"
  assert_contains "$out" "matched: Codex-Session: https://" \
    "refusal did not name the generalized trailer key"

  rc=0
  out=$(fm_voice_text 'Session-Link: https://example.invalid/internal-session') || rc=$?
  expect_code 1 "$rc" "a suffixed session trailer was not refused"

  # The same pointer moved into prose, where the trailer rule cannot see it.
  rc=0
  out=$(fm_voice_text 'Context for reviewers: https://claude.ai/code/session_01AJfonRT1YLcHJCJ2UYwc3J') || rc=$?
  expect_code 1 "$rc" "a session link in prose was not refused"
  assert_contains "$out" "internal-session-link" "session link named the wrong rule"

  rc=0
  out=$(fm_voice_text 'Context for reviewers: https://example.invalid/session-01AJfonRT1YLcHJCJ2UYwc3J') || rc=$?
  expect_code 1 "$rc" "a non-vendor session path link was not refused"
  assert_contains "$out" "session-01AJfonRT1YLcHJCJ2UYwc3J" \
    "refusal did not name the generalized session path token"

  # An opaque id with no URL is still a pointer.
  rc=0
  out=$(fm_voice_text 'Conversation: 01AJfonRT1YLcHJCJ2UYwc3J') || rc=$?
  expect_code 1 "$rc" "an opaque session id was not refused"

  pass "refuses a pointer to the working session"
}

test_passes_ordinary_uses_of_the_word_session() {
  local tmp out rc=0 message
  tmp=$(fm_test_tmproot fm-voice-session-ok)
  fm_voice_repo "$tmp/repo"

  for message in \
    'A session-scoped negative cache keeps the conclusion' \
    'fix(bin): bind the session lock to the home rather than the process' \
    'feat(pi): start a fresh supervision branch for every main session' \
    'docs: explain how session start drains the wake queue' \
    'refs https://github.com/kunchenguid/firstmate/pull/3600' \
    'fix(bin): rename create_session_id to match its record' \
    'Discussion: https://example.invalid/internal-session' \
    'Regression: https://example.invalid/internal-session' \
    'refs https://example.invalid/docs?topic=session'
  do
    fm_voice_commit "$tmp/repo" "$message"
  done
  # A configuration key that merely begins with one of the trailer words: the
  # value shape is what separates a pointer from prose, so this must pass.
  fm_voice_commit "$tmp/repo" 'docs(config): document the poll keys

session: see docs/configuration.md for the timeout keys'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 0 "$rc" "an ordinary use of the word session was refused"$'\n'"$out"
  pass "passes ordinary technical uses of the word session"
}

test_refuses_a_private_per_task_work_document() {
  local out rc=0

  out=$(fm_voice_text 'docs: retire data/alpha/report.md after completion') || rc=$?
  expect_code 1 "$rc" "a private per-task work-document path was not refused"
  assert_contains "$out" "private-task-work-document" \
    "private work-document path named the wrong rule"
  assert_contains "$out" "data/alpha/report.md" \
    "refusal did not name the private work-document path"

  # A deeper path is exactly as private. A rule that stopped at two components
  # would refuse the shallow leak above and pass this one.
  rc=0
  out=$(fm_voice_text 'docs: retire data/alpha/evidence/report.md after completion') || rc=$?
  expect_code 1 "$rc" "a deeper private work-document path was not refused"
  assert_contains "$out" "data/alpha/evidence/report.md" \
    "refusal did not name the deeper private work-document path"
  pass "refuses a private per-task work-document path at any depth"
}

# --- the two shapes the sixth review round measured as still reachable --------
#
# Both are counterfactual-checked: each case was run against the expressions as
# they stood before this pair of corrections and exited 0, so each test fails
# without the correction it pins rather than passing vacuously alongside it.

test_refuses_an_em_or_en_dash_address() {
  local out rc dash

  # The spaced ASCII form was already refused. These two are the same vocative
  # in the same syntactic slot, and the earlier expression let them through.
  for dash in '—' '–'; do
    rc=0
    out=$(fm_voice_text "fix(ci): Captain $dash the stale-throttle inheritance now reads the parent value") || rc=$?
    expect_code 1 "$rc" "a spaced $dash address was not refused"
    assert_contains "$out" "captain-address-opening" \
      "spaced $dash address named the wrong rule"

    # Unspaced, which is how an em dash is conventionally set.
    rc=0
    out=$(fm_voice_text "fix(ci): Captain${dash}the stale-throttle inheritance now reads the parent value") || rc=$?
    expect_code 1 "$rc" "an unspaced $dash address was not refused"

    # The same dash opening a body line of its own, which the opening rule's
    # commit-prefix anchor cannot reach.
    rc=0
    out=$(fm_voice_text "Captain $dash the watcher now reads the parent value") || rc=$?
    expect_code 1 "$rc" "a line-initial $dash address was not refused"
    assert_contains "$out" "captain-address-line" \
      "line-initial $dash address named the wrong rule"
  done
  pass "refuses an em-dash or en-dash address"
}

test_refuses_a_root_qualified_work_document_path() {
  local out rc=0

  # The leak arrives pasted absolute far more often than relative, and the
  # slash that makes it absolute is exactly what the relative rule's leading
  # boundary excluded.
  out=$(fm_voice_text 'docs: retire /Users/someone/firstmate/data/alpha/report.md after completion') || rc=$?
  expect_code 1 "$rc" "a root-qualified private work-document path was not refused"
  assert_contains "$out" "private-task-work-document" \
    "root-qualified work-document path named the wrong rule"
  assert_contains "$out" "/Users/someone/firstmate/data/alpha/report.md" \
    "refusal did not name the root-qualified path that matched"

  # Home-rooted and parent-relative spellings of the same private document.
  rc=0
  out=$(fm_voice_text 'docs: retire ~/firstmate/data/alpha/report.md after completion') || rc=$?
  expect_code 1 "$rc" "a home-rooted private work-document path was not refused"

  rc=0
  out=$(fm_voice_text 'docs: retire ../data/alpha/report.md after completion') || rc=$?
  expect_code 1 "$rc" "a parent-relative private work-document path was not refused"

  # The bound that makes the above safe: a relative path whose own directory is
  # merely named "data" still passes, at any depth. This is the case the earlier
  # round measured, and widening to absolute paths must not cost it.
  rc=0
  out=$(fm_voice_text 'docs: touch tests/data/fixtures/x.txt') || rc=$?
  expect_code 0 "$rc" "a relative tests/data path was wrongly refused"$'\n'"$out"

  rc=0
  out=$(fm_voice_text 'docs: touch src/testdata/fixtures/deep/x.txt') || rc=$?
  expect_code 0 "$rc" "an unrelated data-named directory was wrongly refused"$'\n'"$out"
  pass "refuses a root-qualified private work-document path"
}

test_refuses_a_private_review_artifact() {
  local out rc=0

  out=$(fm_voice_text 'docs: refresh .lavish/sample-board.html before the review') || rc=$?
  expect_code 1 "$rc" "a local review-artifact path was not refused"
  assert_contains "$out" "private-review-artifact" \
    "review-artifact path named the wrong rule"
  assert_contains "$out" ".lavish/sample-board.html" \
    "refusal did not name the review-artifact path that matched"

  rc=0
  out=$(fm_voice_text 'docs: refresh .lavish/board/sample-board.html before the review') || rc=$?
  expect_code 1 "$rc" "a deeper review-artifact path was not refused"
  assert_contains "$out" ".lavish/board/sample-board.html" \
    "refusal did not name the deeper review-artifact path"
  pass "refuses a local review-artifact path at any depth"
}

test_passes_nonprivate_paths_and_work_document_words() {
  local out rc message

  for message in \
    'docs: update data/backlog.md' \
    'docs: update data/projects.md' \
    'docs: update data/learnings.md' \
    'docs: update data/secondmates.md' \
    'docs: touch tests/data/fixtures/x.txt' \
    'fix: clear state/alpha.status' \
    'fix: clear state/01ABCDEF.status' \
    'docs: describe projects/alpha' \
    'docs: document config/crew-harness' \
    'docs: explain the no-mistakes gate worktree (.no-mistakes/repos/)' \
    'feat(lavish): open a Lavish review surface for the plan' \
    'fix(bin): keep typed Lavish comments' \
    'docs: report the outcome'
  do
    rc=0
    out=$(fm_voice_text "$message") || rc=$?
    expect_code 0 "$rc" "a legitimate path or bare work-document word was refused"$'\n'"$message"$'\n'"$out"
  done
  pass "passes flat data files, uncovered roots, the bare word Lavish, and bare report"
}

test_refusal_names_what_matched_and_how_to_fix_it() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-voice-message)
  fm_voice_repo "$tmp/repo"
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, bound the scan'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 1 "$rc" "the guard did not refuse"
  assert_contains "$out" ': Captain,' "refusal did not quote the exact text that matched"
  assert_contains "$out" 'fix(ci): Captain, bound the scan' \
    "refusal did not show the line the match came from"
  assert_contains "$out" 'git commit --amend' "refusal did not give the command that fixes it"
  assert_contains "$out" 'git rebase -i' "refusal did not cover a non-tip commit"
  assert_contains "$out" '--list-patterns' "refusal did not say how to inspect the rule set"
  pass "refusal names the rule, the matched text, and the fix"
}

# --- scope: published history is not rescanned forever ----------------------

test_scans_only_commits_off_the_default_branch() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-voice-scope)
  fm_voice_repo "$tmp/repo"
  # A leak that is already on the default branch. Refusing it again would make
  # every later run fail on history nobody can still change.
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, this already shipped'
  git -C "$tmp/repo" branch -f main feature
  fm_voice_commit "$tmp/repo" 'fix(bin): bound the scan'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 0 "$rc" "a leak already on the default branch was re-refused"$'\n'"$out"

  # ...and a new leak on top of that same published history still refuses.
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, this has not shipped'
  rc=0
  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 1 "$rc" "a new leak above published history was missed"
  assert_contains "$out" 'this has not shipped' "refusal named the wrong commit"
  assert_not_contains "$out" 'this already shipped' \
    "refusal reached back into already-published history"
  pass "scans only the commits the default branch does not carry"
}

# The default set is "reachable from HEAD, not carried by the default branch",
# which is deliberately broader than "never pushed anywhere". A commit already
# on a feature remote is still in it, because the leak is still in what a
# maintainer would merge. This pins both the behaviour and the wording the
# refusal uses for it, so neither can drift back to claiming the narrower set.
test_still_refuses_a_leak_already_on_a_feature_remote() {
  local tmp out rc=0 base
  tmp=$(fm_test_tmproot fm-voice-feature-remote)
  fm_voice_repo "$tmp/repo"
  base=$(git -C "$tmp/repo" rev-parse main)
  git -C "$tmp/repo" update-ref refs/remotes/origin/main "$base"

  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, this already reached the feature remote'
  git -C "$tmp/repo" update-ref refs/remotes/origin/feature "$(git -C "$tmp/repo" rev-parse HEAD)"
  fm_voice_commit "$tmp/repo" 'fix(bin): a clean follow-up'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 1 "$rc" "a leak already on a feature remote stopped being refused"$'\n'"$out"
  assert_contains "$out" 'this already reached the feature remote' \
    "refusal did not name the commit that is already on the feature remote"
  assert_contains "$out" 'the commits not yet on the default branch' \
    "refusal described the scanned set as something other than what it scans"
  assert_not_contains "$out" 'about to be pushed' \
    "refusal claimed the narrower never-pushed set it does not scan"
  pass "still refuses a leak that already reached a feature remote"
}

test_prefers_origin_main_over_an_ahead_local_main() {
  local tmp out rc=0 remote_main
  tmp=$(fm_test_tmproot fm-voice-ahead-main)
  fm_voice_repo "$tmp/repo"
  remote_main=$(git -C "$tmp/repo" rev-parse HEAD)
  git -C "$tmp/repo" update-ref refs/remotes/origin/main "$remote_main"

  git -C "$tmp/repo" checkout -q main
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, this local-main commit has not shipped'
  git -C "$tmp/repo" checkout -q feature
  git -C "$tmp/repo" merge -q --ff-only main
  fm_voice_commit "$tmp/repo" 'fix(bin): keep the feature tip clean'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 1 "$rc" "an ahead local main hid a leaking commit off the default branch"
  assert_contains "$out" "this local-main commit has not shipped" \
    "refusal did not identify the hidden commit"
  pass "prefers origin/main when local main is ahead"
}

test_fails_closed_when_the_range_cannot_be_determined() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-voice-noref)
  mkdir -p "$tmp/repo"
  git -C "$tmp/repo" init -q -b work
  git -C "$tmp/repo" config user.name 'Firstmate Tests'
  git -C "$tmp/repo" config user.email 'tests@example.invalid'
  printf 'x\n' > "$tmp/repo/README.md"
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" commit -qm 'fix(ci): Captain, no default branch here'

  out=$(fm_voice_scan "$tmp/repo") || rc=$?
  expect_code 3 "$rc" "an undeterminable range did not fail closed"
  assert_contains "$out" "not a clean range" \
    "fail-closed diagnostic did not explain why it refused"
  assert_contains "$out" "git fetch origin main" \
    "fail-closed diagnostic did not say how to resolve it"
  pass "fails closed when the default-branch range cannot be determined"
}

test_fails_closed_when_the_commit_list_is_unusable() {
  local tmp fakebin out rc=0
  tmp=$(fm_test_tmproot fm-voice-revlist)
  fm_voice_repo "$tmp/repo"
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, a leak nobody can enumerate'

  # A git that resolves the default branch but cannot enumerate the range. The
  # guard must not read that as "nothing to report", and must not read it as a
  # refusal either: it does not know, so it says so.
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree") printf 'true\n'; exit 0 ;;
  "rev-parse --verify -q origin/main") exit 0 ;;
  "rev-list "*) exit 128 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/git"

  out=$(cd "$tmp/repo" && PATH="$fakebin:$PATH" "$GUARD" 2>&1) || rc=$?
  expect_code 3 "$rc" "an unusable commit list did not fail closed"$'\n'"$out"
  assert_contains "$out" "cannot list the commits" \
    "fail-closed diagnostic did not name the unusable commit list"
  pass "fails closed when the commit list cannot be enumerated"
}

test_fails_closed_when_the_scanner_errors() {
  local tmp fakebin out rc=0
  tmp=$(fm_test_tmproot fm-voice-grep-error)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/grep" <<'SH'
#!/usr/bin/env bash
exit 2
SH
  chmod +x "$fakebin/grep"

  out=$(printf 'fix(ci): Captain, hidden by scanner failure\n' | \
    PATH="$fakebin:$PATH" "$GUARD" --text - 2>&1) || rc=$?
  expect_code 3 "$rc" "a scanner error was reported as clean or as a match"$'\n'"$out"
  assert_contains "$out" "scanner failed for rule captain-address-opening (grep exit 2)" \
    "scanner error did not name the rule and failure"
  pass "fails closed when the scanner errors"
}

test_fails_closed_when_a_commit_message_cannot_be_read() {
  local tmp fakebin out rc=0
  tmp=$(fm_test_tmproot fm-voice-message-error)
  mkdir -p "$tmp/repo"
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree") printf 'true\n'; exit 0 ;;
  "rev-parse --verify -q HEAD^{commit}") printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'; exit 0 ;;
  "log -1 --format=%B deadbeefdeadbeefdeadbeefdeadbeefdeadbeef") exit 128 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/git"

  out=$(cd "$tmp/repo" && PATH="$fakebin:$PATH" "$GUARD" --commit HEAD 2>&1) || rc=$?
  expect_code 3 "$rc" "an unreadable commit message was skipped"$'\n'"$out"
  assert_contains "$out" "cannot read commit message for deadbeefdead" \
    "commit-message error did not name the unreadable commit"
  pass "fails closed when a commit message cannot be read"
}

test_an_explicit_range_bounds_the_scan() {
  local tmp out rc=0 base
  tmp=$(fm_test_tmproot fm-voice-base)
  fm_voice_repo "$tmp/repo"
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, older leak'
  base=$(git -C "$tmp/repo" rev-parse HEAD)
  fm_voice_commit "$tmp/repo" 'fix(bin): bound the scan'

  out=$(cd "$tmp/repo" && "$GUARD" --range "$base..HEAD" 2>&1) || rc=$?
  expect_code 0 "$rc" "an explicit range did not bound the scanned range"$'\n'"$out"
  pass "an explicit --range scans only what it names"
}

# The pre-push default must have no environment-reachable base. A caller-chosen
# base equal to HEAD would leave "git rev-list HEAD --not HEAD" empty, so the
# guard would report clean having scanned nothing: an off switch on the one
# check that is meant to be mechanically unavoidable.
test_the_default_range_has_no_environment_off_switch() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-voice-no-off-switch)
  fm_voice_repo "$tmp/repo"
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, a leak off the default branch'

  out=$(cd "$tmp/repo" && FM_VOICE_GUARD_BASE=HEAD "$GUARD" 2>&1) || rc=$?
  expect_code 1 "$rc" "an environment base silenced the pre-push default scan"$'\n'"$out"
  assert_contains "$out" 'a leak off the default branch' "refusal did not name the leaking commit"
  pass "the default range cannot be narrowed from the environment"
}

# --- explicit selectors -----------------------------------------------------

test_explicit_range_and_commit_selectors() {
  local tmp out rc=0 first
  tmp=$(fm_test_tmproot fm-voice-select)
  fm_voice_repo "$tmp/repo"
  fm_voice_commit "$tmp/repo" 'fix(ci): Captain, first'
  first=$(git -C "$tmp/repo" rev-parse HEAD)
  fm_voice_commit "$tmp/repo" 'fix(bin): second is clean'

  rc=0
  out=$(cd "$tmp/repo" && "$GUARD" --commit "$first" 2>&1) || rc=$?
  expect_code 1 "$rc" "--commit did not refuse the named commit"

  rc=0
  out=$(cd "$tmp/repo" && "$GUARD" --commit HEAD 2>&1) || rc=$?
  expect_code 0 "$rc" "--commit refused a clean commit"$'\n'"$out"

  rc=0
  out=$(cd "$tmp/repo" && "$GUARD" --range "main..HEAD" 2>&1) || rc=$?
  expect_code 1 "$rc" "--range did not scan the whole branch"
  pass "explicit --commit and --range selectors scan what they name"
}

test_text_mode_reads_a_pull_request_description() {
  local out rc=0 tmp
  tmp=$(fm_test_tmproot fm-voice-text)

  rc=0
  out=$(printf 'Captain, this PR rewrites the throttle.\n' | "$GUARD" --text - 2>&1) || rc=$?
  expect_code 1 "$rc" "a leaking pull request description was not refused"
  assert_contains "$out" "Reword the text above" \
    "text-mode refusal gave a commit-only remedy"
  assert_not_contains "$out" "git rebase -i" \
    "text-mode refusal offered a commit remedy for text that is not a commit"

  printf 'Bounds the scan to the changed set.\n' > "$tmp/body"
  rc=0
  out=$("$GUARD" --text "$tmp/body" 2>&1) || rc=$?
  expect_code 0 "$rc" "a clean pull request description was refused"$'\n'"$out"
  pass "text mode reads a pull request description from stdin and from a file"
}

test_rejects_unknown_arguments() {
  local out rc=0
  out=$("$GUARD" --nope 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown argument was not a usage error"
  assert_contains "$out" "unknown argument" "usage error did not name the problem"
  pass "rejects unknown arguments as a usage error"
}

test_lists_its_rules_for_inspection() {
  local out
  out=$("$GUARD" --list-patterns)
  assert_contains "$out" "captain-address-opening" "rule table omitted the opening address rule"
  assert_contains "$out" "delivery-machinery-handoff" "rule table omitted the handoff rule"
  pass "prints its rule table for inspection"
}

# --- the wiring that makes it run before the first push ---------------------

# The guard is only load-bearing if the gate's pinned lint command runs it, so
# this drives the real fm-lint.sh default path over a real repository whose tip
# commit leaks, with the two linters stubbed at their pinned versions.
test_lint_default_path_runs_the_voice_guard() {
  local tmp fakebin out rc=0
  tmp=$(fm_test_tmproot fm-voice-lint)
  fm_voice_repo "$tmp"
  mkdir -p "$tmp/bin" "$tmp/.github/workflows"
  cp "$LINT" "$tmp/bin/fm-lint.sh"
  cp "$LINT_WF" "$tmp/bin/fm-lint-workflows.sh"
  cp "$GUARD" "$tmp/bin/fm-prepush-voice-guard.sh"
  chmod +x "$tmp/bin/fm-lint.sh" "$tmp/bin/fm-lint-workflows.sh" "$tmp/bin/fm-prepush-voice-guard.sh"
  printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' \
    > "$tmp/.github/workflows/ci.yml"

  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/actionlint" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '1.7.12\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck" "$fakebin/actionlint"

  fm_voice_commit "$tmp" 'fix(ci): Captain, bound the scan for the outer executor'

  out=$(cd "$tmp" && PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    "$tmp/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh default path did not refuse a leaking commit message"$'\n'"$out"
  assert_contains "$out" "fm-prepush-voice-guard.sh: REFUSING" \
    "fm-lint.sh default path did not run the voice guard"$'\n'"$out"

  # Explicit paths are a ShellCheck-only override and must not scan commits,
  # so a targeted lint of one script still works on a branch that is refusing.
  rc=0
  out=$(cd "$tmp" && PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    "$tmp/bin/fm-lint.sh" bin/fm-lint.sh 2>&1) || rc=$?
  expect_code 0 "$rc" "an explicit-path lint ran the voice guard"$'\n'"$out"
  assert_not_contains "$out" "REFUSING" "an explicit-path lint ran the voice guard"
  pass "fm-lint.sh runs the voice guard on its default path only"
}

test_refuses_the_real_leaked_commit
test_passes_the_real_legitimate_message
test_passes_legitimate_captain_and_house_vocabulary
test_refuses_each_address_shape
test_refuses_a_pointer_to_the_working_session
test_passes_ordinary_uses_of_the_word_session
test_refuses_a_private_per_task_work_document
test_refuses_a_private_review_artifact
test_refuses_an_em_or_en_dash_address
test_refuses_a_root_qualified_work_document_path
test_passes_nonprivate_paths_and_work_document_words
test_refusal_names_what_matched_and_how_to_fix_it
test_scans_only_commits_off_the_default_branch
test_still_refuses_a_leak_already_on_a_feature_remote
test_prefers_origin_main_over_an_ahead_local_main
test_fails_closed_when_the_range_cannot_be_determined
test_fails_closed_when_the_commit_list_is_unusable
test_fails_closed_when_the_scanner_errors
test_fails_closed_when_a_commit_message_cannot_be_read
test_an_explicit_range_bounds_the_scan
test_the_default_range_has_no_environment_off_switch
test_explicit_range_and_commit_selectors
test_text_mode_reads_a_pull_request_description
test_rejects_unknown_arguments
test_lists_its_rules_for_inspection
test_lint_default_path_runs_the_voice_guard
