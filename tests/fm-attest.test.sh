#!/usr/bin/env bash
# Behavior tests for bin/fm-attest.sh.
#
# Every refusal here is paired with a positive control that differs from it by
# exactly one input, because a verifier that refuses everything would satisfy
# red-only assertions and would be a worse defect than the honour-system check
# it replaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-attest)
ATTEST="$ROOT/bin/fm-attest.sh"
NOTES_REF=refs/notes/no-mistakes

# A repository with one commit and no attestation ref.
new_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q -b fm/demo .
  git -C "$repo" config user.email attest@example.invalid
  git -C "$repo" config user.name "Attest Test"
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" commit -qm one
}

add_note() {
  local repo=$1 commit=$2 body=$3
  git -C "$repo" notes --ref="$NOTES_REF" add -f -m "$body" "$commit" >/dev/null 2>&1
}

# The exact payload the gate accepts, so every negative fixture below can be
# written as this minus one property.
good_note() {
  printf 'no-mistakes-attestation: v1\nhead: %s\nrun: 01KZ5YTADR5YAXZSNKFXTW8W9F\ngates: intent,rebase,review,test,document,lint,push\ntool: no-mistakes/v1.40.3\n' "$1"
}

# Installs a fake `no-mistakes` on PATH that prints the given `axi status` body,
# so the emitter is exercised against the tool's real output shape without a
# pipeline run. The body goes to stdout and the exit status is the caller's,
# because that is what the real tool does with its own errors.
#
# Every stub also writes the version-upgrade banner to stderr, as the real tool
# does whenever an upgrade is available. That notice is unrelated to any run
# record, so it must never decide, satisfy, or describe one.
STUB_STDERR_NOTICE='A new version of no-mistakes is available: v1.40.3 -> v1.41.2'

install_pipeline_stub() {
  local dir=$1 status=$2 rc=${3:-0}
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  "--version") echo "no-mistakes version v1.40.3 (d873960) 2026-07-22T01:41:41Z" ;;\n'
    printf '  "axi status")\n'
    printf '    echo %s >&2\n' "'$STUB_STDERR_NOTICE'"
    printf '    cat <<%s\n' "'FM_STUB_TOON'"
    printf '%s\n' "$status"
    printf 'FM_STUB_TOON\n'
    printf '    exit %s\n' "$rc"
    printf '  ;;\nesac\n'
  } > "$dir/bin/no-mistakes"
  chmod +x "$dir/bin/no-mistakes"
}

run_status_toon() {
  local branch=$1 head=$2 review_state=$3
  printf 'run:\n  id: "01KZ5YTADR5YAXZSNKFXTW8W9F"\n  branch: %s\n  status: running\n  head: %s\n  steps[8]{step,status,findings,duration_ms}:\n    intent,completed,0,3\n    rebase,completed,0,581\n    review,%s,0,599904\n    test,completed,0,235507\n    document,completed,0,58499\n    lint,completed,0,78748\n    push,completed,0,2200\n    ci,awaiting_approval,1,99775564\ngate:\n  step: ci\n  status: awaiting_approval\n' \
    "$branch" "$head" "$review_state"
}

verify_out() {
  local repo=$1 head=$2
  ( cd "$repo" && "$ATTEST" verify --head "$head" 2>&1 )
}

# ---------------------------------------------------------------------------
# verify - absence, mis-binding and malformed evidence each refuse in their own
# words, and none of them can be reached by editing pull request text.
# ---------------------------------------------------------------------------

test_absent_notes_ref_refuses_as_absent() {
  local repo head out rc
  repo="$TMP_ROOT/absent-ref"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an absent attestation ref was accepted"
  assert_contains "$out" "no-attestation-ref" "absent ref did not report its own reason"
  pass "fm-attest.sh: an absent attestation ref refuses as absent"
}

test_ref_without_note_for_head_refuses_distinctly() {
  local repo head other out rc
  repo="$TMP_ROOT/ref-no-note"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  other=$(git -C "$repo" commit-tree -m other "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$other" "$(good_note "$other")"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a head with no attestation was accepted"
  assert_contains "$out" "no-attestation-for-head" "missing note for the head was not reported distinctly"
  assert_not_contains "$out" "no-attestation-ref" "a present ref was reported as an absent one"
  pass "fm-attest.sh: an attestation for another commit is not evidence for this one"
}

test_note_naming_another_head_refuses_as_unbound() {
  local repo head other out rc
  repo="$TMP_ROOT/unbound"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  other=$(git -C "$repo" commit-tree -m other "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  # A well-formed attestation for a different commit, attached to this one.
  add_note "$repo" "$head" "$(good_note "$other")"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation naming another commit was accepted"
  assert_contains "$out" "attestation-not-bound" "a mis-bound attestation was not reported as such"
  pass "fm-attest.sh: an attestation must name the commit it is attached to"
}

test_genuine_attestation_does_not_survive_a_rewrite() {
  local repo head rewritten before after
  repo="$TMP_ROOT/rewrite"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head")"
  before=$(verify_out "$repo" "$head")
  case "$before" in
    *"attested $head"*) ;;
    *) fail "the positive control did not pass before the rewrite: $before" ;;
  esac
  # Reword the commit and carry the genuine attestation across verbatim. This is
  # the copy that the replaced body marker permitted and this check must not.
  git -C "$repo" commit -q --amend -m "one (reworded)"
  rewritten=$(git -C "$repo" rev-parse HEAD)
  [ "$rewritten" != "$head" ] || fail "the rewrite did not change the head commit"
  git -C "$repo" notes --ref="$NOTES_REF" show "$head" > "$repo/carried.note"
  git -C "$repo" notes --ref="$NOTES_REF" add -f -F "$repo/carried.note" "$rewritten" >/dev/null 2>&1
  local rc=0
  after=$(verify_out "$repo" "$rewritten") || rc=$?
  [ "$rc" -ne 0 ] || fail "a genuine attestation copied onto a rewritten head was accepted"
  assert_contains "$after" "attestation-not-bound" "a carried attestation was not reported as unbound"
  pass "fm-attest.sh: a genuine attestation copied onto a rewritten head is refused"
}

test_legacy_body_marker_is_not_an_attestation() {
  local repo head out rc
  repo="$TMP_ROOT/legacy-marker"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" \
    'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "the replaced honour-system marker was accepted as an attestation"
  assert_contains "$out" "attestation-malformed" "the legacy marker was not reported as malformed"
  pass "fm-attest.sh: the replaced honour-system marker is not an attestation"
}

test_unknown_field_refuses_rather_than_being_ignored() {
  local repo head out rc
  repo="$TMP_ROOT/unknown-field"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head"; printf 'override: please-pass\n')"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation carrying an unknown field was accepted"
  assert_contains "$out" "attestation-malformed" "an unknown field was not reported as malformed"
  pass "fm-attest.sh: an unknown field is refused rather than ignored"
}

test_missing_required_step_refuses_distinctly() {
  local repo head out rc
  repo="$TMP_ROOT/missing-gate"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" \
    "$(good_note "$head" | sed 's/^gates: .*/gates: intent,rebase,test,document,lint,push/')"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation with no completed review step was accepted"
  assert_contains "$out" "attestation-missing-gate" "a skipped required step was not reported distinctly"
  assert_contains "$out" "review" "the refusal did not name the missing step"
  pass "fm-attest.sh: an attestation that skipped a required step is refused"
}

test_unusable_gate_list_refuses_as_malformed() {
  local repo head out rc
  repo="$TMP_ROOT/bad-gates"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" \
    "$(good_note "$head" | sed 's/^gates: .*/gates: review,,test,lint,push/')"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation with an unusable step list was accepted"
  assert_contains "$out" "attestation-malformed" "an unusable step list was not reported as malformed"
  pass "fm-attest.sh: an unusable step list is refused"
}

test_absent_head_commit_refuses_as_its_own_state() {
  local repo out rc missing
  repo="$TMP_ROOT/no-head-object"
  new_repo "$repo"
  missing=0123456789012345678901234567890123456789
  add_note "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(good_note "$(git -C "$repo" rev-parse HEAD)")"
  out=$(verify_out "$repo" "$missing")
  rc=$?
  [ "$rc" -ne 0 ] || fail "verification of an absent commit was accepted"
  assert_contains "$out" "head-commit-unavailable" "an absent head commit was not reported as its own state"
  pass "fm-attest.sh: a head commit missing from the checkout is its own refusal"
}

test_head_bound_attestation_passes() {
  local repo head out rc
  repo="$TMP_ROOT/positive"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head")"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a well-formed head-bound attestation was refused: $out"
  assert_contains "$out" "attested $head" "the success line did not name the attested head"
  pass "fm-attest.sh: a well-formed head-bound attestation passes"
}

# ---------------------------------------------------------------------------
# write - the emitter transcribes the pipeline's own run record and refuses to
# publish anything that record does not support.
# ---------------------------------------------------------------------------

write_out() {
  local repo=$1
  ( cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write --no-push 2>&1 )
}

publish_out() {
  local repo=$1
  ( cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write 2>&1 )
}

test_write_refuses_a_run_head_absent_from_this_checkout() {
  local repo head out rc
  repo="$TMP_ROOT/write-other-head"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo deadbeef completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run record naming a commit this checkout lacks was transcribed"
  assert_contains "$out" "run-head-unavailable" "an absent run head was not reported distinctly"
  # A commit this repository does not have is a fetch, not a re-validation, so
  # it must not borrow the reason for a run that covers different work.
  assert_not_contains "$out" "run-covers-another-head" \
    "a commit absent from the checkout was reported as a run covering other work"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "a refused attestation was still written"
  pass "fm-attest.sh: write refuses a run head that is not a commit in this checkout"
}

test_write_attests_the_run_tip_the_pipeline_advanced_past_head() {
  local repo head tip out rc verified
  repo="$TMP_ROOT/write-tip-ahead"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # The pipeline's own fix commits advance the run tip past the local checkout,
  # so a run head ahead of HEAD on the same history is the normal state and the
  # tip is the head the pull request is opened on.
  tip=$(git -C "$repo" commit-tree -p "$head" -m "no-mistakes(review): fix" \
    "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${tip:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a run tip ahead of HEAD on the same history was refused: $out"
  assert_contains "$out" "recorded $NOTES_REF for $tip" \
    "the note was not bound to the head that run validated"
  verified=$(verify_out "$repo" "$tip") \
    || fail "the gate rejected the attestation for the run tip: $verified"
  assert_contains "$verified" "attested $tip" "the run tip was not attested"
  rc=0
  out=$(verify_out "$repo" "$head") || rc=$?
  [ "$rc" -ne 0 ] || fail "a commit the run advanced past was attested too"
  assert_contains "$out" "no-attestation-for-head" \
    "the commit the run advanced past was not refused for its own reason"
  pass "fm-attest.sh: write attests the run tip the pipeline advanced past HEAD"
}

test_write_refuses_an_incomplete_run() {
  local repo head out rc
  repo="$TMP_ROOT/write-incomplete"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" running)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run with no completed review step was transcribed"
  assert_contains "$out" "run-incomplete" "an incomplete run was not reported distinctly"
  assert_contains "$out" "review" "the refusal did not name the incomplete step"
  pass "fm-attest.sh: write refuses a run that has not completed a required step"
}

test_write_refuses_a_run_from_another_branch() {
  local repo head out rc
  repo="$TMP_ROOT/write-other-branch"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/elsewhere "${head:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run record for another branch was transcribed"
  assert_contains "$out" "run-covers-another-branch" "a foreign branch run was not reported distinctly"
  pass "fm-attest.sh: write refuses a run record for another branch"
}

test_write_emits_an_attestation_the_gate_accepts() {
  local repo head out rc verified
  repo="$TMP_ROOT/write-positive"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a complete run covering this exact head was refused: $out"
  verified=$(verify_out "$repo" "$head") \
    || fail "the emitted attestation was rejected by the gate: $verified"
  assert_contains "$verified" "attested $head" "the round trip did not attest this head"
  assert_contains "$verified" "01KZ5YTADR5YAXZSNKFXTW8W9F" "the attestation lost the run identity"
  pass "fm-attest.sh: write emits an attestation the gate accepts for that exact head"
}

test_write_refuses_a_later_commit_on_the_same_branch() {
  local repo head later out rc
  repo="$TMP_ROOT/write-later-commit"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  write_out "$repo" >/dev/null || fail "the positive control failed before the later commit"
  printf 'two\n' > "$repo/b.txt"
  git -C "$repo" add b.txt
  git -C "$repo" commit -qm two
  later=$(git -C "$repo" rev-parse HEAD)
  [ "$later" != "$head" ] || fail "the later commit did not move the head"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unvalidated later commit was attested from the earlier run"
  assert_contains "$out" "run-covers-another-head" "the stale run was not reported distinctly"
  rc=0
  out=$(verify_out "$repo" "$later") || rc=$?
  [ "$rc" -ne 0 ] || fail "the gate accepted a head the pipeline never validated"
  assert_contains "$out" "no-attestation-for-head" "the unvalidated head was not refused for its own reason"
  pass "fm-attest.sh: work committed after a run is not covered by it"
}

test_write_refuses_without_a_run_record() {
  local repo out rc
  repo="$TMP_ROOT/write-no-run"
  new_repo "$repo"
  install_pipeline_stub "$repo/stub" ""
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation was emitted with no pipeline run record"
  assert_contains "$out" "no-run-record" "a missing run record was not reported distinctly"
  # The stub reported nothing on stdout and only the upgrade banner on stderr.
  # An absent run must stay an absent run, and the banner must still be shown.
  assert_not_contains "$out" "run-record-unparsed" \
    "an unrelated stderr notice was read as a run record"
  assert_contains "$out" "$STUB_STDERR_NOTICE" "the tool's stderr was not surfaced as detail"
  pass "fm-attest.sh: write refuses when the pipeline reports no run"
}

test_write_surfaces_a_tool_failure_instead_of_reporting_no_run() {
  local repo out rc
  repo="$TMP_ROOT/write-tool-error"
  new_repo "$repo"
  # The real tool reports its own errors on stdout and exits non-zero, so the
  # captured output looks like a run record to anything that only checks for
  # emptiness.
  install_pipeline_stub "$repo/stub" \
    "error: repo not initialized (run 'no-mistakes init' first)" 1
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation was emitted while the pipeline tool was failing"
  assert_contains "$out" "run-record-unreadable" "a failing tool was not reported distinctly"
  assert_contains "$out" "repo not initialized" "the tool's own message was swallowed"
  assert_contains "$out" "$STUB_STDERR_NOTICE" "the tool's stderr was not surfaced as detail"
  assert_not_contains "$out" "no-run-record" "a failing tool was reported as an absent run"
  pass "fm-attest.sh: write surfaces a failing pipeline tool rather than reporting no run"
}

test_write_reports_an_unreadable_run_record_distinctly() {
  local repo out rc
  repo="$TMP_ROOT/write-unparsed-run"
  new_repo "$repo"
  # A successful call whose output carries no run identity: a record that exists
  # but cannot be read is a different repair from a record that does not exist.
  install_pipeline_stub "$repo/stub" "runs: none matching this worktree"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation was emitted from an unreadable run record"
  assert_contains "$out" "run-record-unparsed" "an unreadable run record was not reported distinctly"
  assert_contains "$out" "none matching this worktree" "the reported record was not quoted back"
  assert_contains "$out" "$STUB_STDERR_NOTICE" "the tool's stderr was not surfaced as detail"
  assert_not_contains "$out" "no-run-record" "an unreadable record was reported as an absent run"
  pass "fm-attest.sh: write distinguishes an unreadable run record from an absent one"
}

test_write_publishes_to_the_push_target_it_reconciled_against() {
  local repo parent fork head parent_seed fork_seed local_only out rc published
  repo="$TMP_ROOT/write-push-target"
  parent="$TMP_ROOT/write-push-target-parent.git"
  fork="$TMP_ROOT/write-push-target-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git init -q --bare "$fork"
  # Two unrelated attestation histories, one already published in each
  # repository, so reconciling against the wrong one cannot fast-forward into
  # the other. This is the setup CONTRIBUTING.md describes: origin fetches the
  # parent and pushes the contributor's fork.
  parent_seed=$(git -C "$repo" commit-tree -m parent-seed "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$parent_seed" "$(good_note "$parent_seed")"
  git -C "$repo" push -q "$parent" "$NOTES_REF:$NOTES_REF"
  git -C "$repo" update-ref -d "$NOTES_REF"
  fork_seed=$(git -C "$repo" commit-tree -m fork-seed "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$fork_seed" "$(good_note "$fork_seed")"
  git -C "$repo" push -q "$fork" "$NOTES_REF:$NOTES_REF"
  git -C "$repo" update-ref -d "$NOTES_REF"
  # An attestation held locally only, which publishing a later one must not
  # discard.
  local_only=$(git -C "$repo" commit-tree -m local-only "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$local_only" "$(good_note "$local_only")"

  git -C "$repo" remote add origin "$parent"
  git -C "$repo" config remote.origin.pushurl "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "publishing to the remote's push target was refused: $out"
  # The repository the note actually reached, because a remote's name does not
  # say which repository that is and only one of these two is the one the gate
  # reads.
  assert_contains "$out" "published $NOTES_REF to $fork" \
    "the success line did not name the repository the note reached"
  assert_not_contains "$out" "$parent" "the fetch URL was reported as the published target"
  published=$(git -C "$fork" ls-tree -r --name-only "$NOTES_REF" | tr -d '/')
  assert_contains "$published" "$head" "the attested head never reached the push target"
  assert_contains "$published" "$fork_seed" "publishing discarded the push target's own attestation"
  assert_not_contains "$published" "$parent_seed" \
    "the fetch URL's attestation history was published to the push target"
  assert_contains "$(git -C "$repo" notes --ref="$NOTES_REF" list)" "$local_only" \
    "publishing discarded an attestation recorded with --no-push"
  pass "fm-attest.sh: write reconciles with and publishes to the remote's push target"
}

test_write_publishes_a_first_attestation_to_a_push_target_with_no_ref() {
  local repo fork head out rc published
  repo="$TMP_ROOT/write-first-publish"
  fork="$TMP_ROOT/write-first-publish-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  # A push target that carries no attestation ref yet genuinely has nothing to
  # reconcile against, which is the one reading of a failed read that is a fact
  # about that repository rather than about our ability to reach it.
  [ "$rc" -eq 0 ] || fail "a push target with no attestation ref yet was refused: $out"
  assert_contains "$out" "published $NOTES_REF to $fork" \
    "the success line did not name the repository the note reached"
  published=$(git -C "$fork" ls-tree -r --name-only "$NOTES_REF" | tr -d '/')
  assert_contains "$published" "$head" "the first attestation never reached the push target"
  pass "fm-attest.sh: a push target with no attestation ref yet still receives the note"
}

test_write_refuses_an_unreadable_push_target_without_leaking_credentials() {
  local repo parent head out rc
  repo="$TMP_ROOT/write-unreadable-target"
  parent="$TMP_ROOT/write-unreadable-target-parent.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git -C "$repo" remote add origin "$parent"
  # A push target that cannot be read at all, carrying a secret in its URL as a
  # remote's configuration may. Nothing listens on port 1, so the read fails
  # locally without reaching any network.
  git -C "$repo" config remote.origin.pushurl 'https://someone:s3cr3t@127.0.0.1:1/owner/repo.git'
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && GIT_TERMINAL_PROMPT=0 no_proxy='*' NO_PROXY='*' \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable push target was treated as one with no attestations"
  assert_contains "$out" "127.0.0.1:1/owner/repo.git" \
    "the refusal did not name the repository it could not read"
  assert_not_contains "$out" "s3cr3t" "the push target's credentials were printed"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "an attestation was recorded against a push target that was never read"
  pass "fm-attest.sh: an unreadable push target stops the command rather than reading as an absent one"
}

test_absent_notes_ref_refuses_as_absent
test_ref_without_note_for_head_refuses_distinctly
test_note_naming_another_head_refuses_as_unbound
test_genuine_attestation_does_not_survive_a_rewrite
test_legacy_body_marker_is_not_an_attestation
test_unknown_field_refuses_rather_than_being_ignored
test_missing_required_step_refuses_distinctly
test_unusable_gate_list_refuses_as_malformed
test_absent_head_commit_refuses_as_its_own_state
test_head_bound_attestation_passes
test_write_refuses_a_run_head_absent_from_this_checkout
test_write_attests_the_run_tip_the_pipeline_advanced_past_head
test_write_refuses_an_incomplete_run
test_write_refuses_a_run_from_another_branch
test_write_emits_an_attestation_the_gate_accepts
test_write_refuses_a_later_commit_on_the_same_branch
test_write_refuses_without_a_run_record
test_write_surfaces_a_tool_failure_instead_of_reporting_no_run
test_write_reports_an_unreadable_run_record_distinctly
test_write_publishes_to_the_push_target_it_reconciled_against
test_write_publishes_a_first_attestation_to_a_push_target_with_no_ref
test_write_refuses_an_unreadable_push_target_without_leaking_credentials
