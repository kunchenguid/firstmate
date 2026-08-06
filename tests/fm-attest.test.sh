#!/usr/bin/env bash
# Behavior tests for the head-bound no-mistakes attestation: bin/fm-attest.sh,
# which emits and verifies it, and the step scripts in
# .github/workflows/no-mistakes-required.yml that drive it in CI. The workflow
# belongs here rather than in a suite of its own because what the check tells a
# contributor is decided jointly by the verifier's exit status and the step's
# reading of it, and splitting them lets the two drift apart.
#
# Every refusal here is paired with a positive control that differs from it by
# exactly one input, because a verifier that refuses everything would satisfy
# red-only assertions and would be a worse defect than the honour-system check
# it replaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The repository's own bounded runner, used here to bound a call that must not
# run unbounded. Its 124 is what an unbounded read looks like from outside.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-attest)
ATTEST="$ROOT/bin/fm-attest.sh"
WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
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
  local dir=$1 status=$2 rc=${3:-0} notice=${4:-$STUB_STDERR_NOTICE}
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  "--version") echo "no-mistakes version v1.40.3 (d873960) 2026-07-22T01:41:41Z" ;;\n'
    printf '  "axi status")\n'
    printf '    echo %s >&2\n' "'$notice'"
    printf '    cat <<%s\n' "'FM_STUB_TOON'"
    printf '%s\n' "$status"
    printf 'FM_STUB_TOON\n'
    printf '    exit %s\n' "$rc"
    printf '  ;;\nesac\n'
  } > "$dir/bin/no-mistakes"
  chmod +x "$dir/bin/no-mistakes"
}

# A pipeline tool that never answers, so the only thing that can end the call is
# the bound the emitter imposes on it.
install_hanging_pipeline_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  "--version") echo "no-mistakes version v1.40.3 (d873960) 2026-07-22T01:41:41Z" ;;\n'
    printf '  "axi status") sleep 120 ;;\n'
    printf 'esac\n'
  } > "$dir/bin/no-mistakes"
  chmod +x "$dir/bin/no-mistakes"
}

# One step's own script, lifted out of the workflow and run as the workflow runs
# it, so what the check tells a contributor is exercised rather than asserted
# against YAML text. The step is found by name, and an extraction that yields
# nothing is a failure, so a renamed or restructured step cannot pass vacuously.
workflow_step_script() {
  local want=$1
  awk -v want="$want" '
    /^      - / { in_step = 0; collecting = 0 }
    $0 == "      - name: " want { in_step = 1; next }
    in_step && $0 == "        run: |" { collecting = 1; next }
    !collecting { next }
    $0 == "" { print ""; next }
    substr($0, 1, 10) == "          " { print substr($0, 11); next }
    { collecting = 0; in_step = 0 }
  ' "$WORKFLOW"
}

# A verifier that reaches one chosen exit status, so the step's reading of that
# status is the single property under test. --print-format still answers,
# because the refusal branch prints the format and a stub that could not would
# make that branch fail for a reason of the fixture's own making.
install_verifier_stub() {
  local dir=$1 rc=$2
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
    printf 'case "${1:-}" in\n'
    printf '  --print-format) echo "no-mistakes-attestation: v1" ;;\n'
    printf '  *) exit %s ;;\n' "$rc"
    printf 'esac\n'
  } > "$dir/bin/fm-attest.sh"
  chmod +x "$dir/bin/fm-attest.sh"
}

# A PATH carrying everything the emitter needs except any utility that could
# impose a timeout, so the single property under test is the absence of those
# three. bin/fm-timeout-lib.sh's bash watchdog must still bound the call there.
install_unbounded_path() {
  local dir=$1 tool
  mkdir -p "$dir"
  for tool in bash sh git sed awk tr cat cut head rm mktemp sleep dirname basename env uname grep; do
    command -v "$tool" >/dev/null 2>&1 || continue
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
}

# A push target that reads fine but refuses the write, echoing the given text as
# the server's own reason. git passes `remote:` lines through verbatim, so any
# redaction observed on them is this script's rather than git's own.
install_rejecting_fork() {
  local fork=$1 message=$2
  git init -q --bare "$fork"
  {
    printf '#!/bin/sh\n'
    printf 'cat <<%s >&2\n' "'FM_HOOK_MSG'"
    printf '%s\n' "$message"
    printf 'FM_HOOK_MSG\n'
    printf 'exit 1\n'
  } > "$fork/hooks/pre-receive"
  chmod +x "$fork/hooks/pre-receive"
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

test_write_reports_a_record_with_no_head_as_a_record_fault() {
  local repo head out rc
  repo="$TMP_ROOT/write-record-no-head"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # The passing record minus exactly one property: the head it covers.
  install_pipeline_stub "$repo/stub" \
    "$(run_status_toon fm/demo "${head:0:8}" completed | sed '/^  head: /d')"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run record naming no head was transcribed"
  assert_contains "$out" "run-record-no-head" "a record with no readable head was not reported distinctly"
  # Unreadability is not divergence. Saying the branch is uncovered sends a
  # contributor to re-validate a branch that is fine, for the identical refusal.
  assert_not_contains "$out" "run-covers-another-head" \
    "a record this transcription cannot read was reported as a diverged branch"
  assert_not_contains "$out" "run-head-unavailable" \
    "a record with no head was reported as a commit missing from the checkout"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "a refused attestation was still written"
  # The matched control: the same record, differing only by that one line.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same record with its head line was refused: $out"
  pass "fm-attest.sh: a run record with no readable head is a record fault, not a diverged branch"
}

test_write_attests_on_a_host_with_no_timeout_utility() {
  local repo bare head out rc tool verified
  repo="$TMP_ROOT/write-unbounded"
  bare="$TMP_ROOT/write-unbounded-path"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  install_unbounded_path "$bare"
  for tool in timeout gtimeout perl; do
    PATH="$repo/stub/bin:$bare" command -v "$tool" >/dev/null 2>&1 \
      && fail "the fixture PATH still offers $tool, so this would not exercise the fallback"
  done
  out=$(cd "$repo" && PATH="$repo/stub/bin:$bare" "$ATTEST" write --no-push 2>&1)
  rc=$?
  # The repository's own policy: bin/fm-timeout-lib.sh falls back to a
  # dependency-free bash watchdog, so such a host is bounded rather than turned
  # away from the one command CONTRIBUTING.md prescribes.
  [ "$rc" -eq 0 ] || fail "a host with no timeout utility could not attest at all: $out"
  verified=$(verify_out "$repo" "$head") \
    || fail "the attestation written on that host was rejected by the gate: $verified"
  assert_contains "$verified" "attested $head" "the round trip did not attest this head"
  # The matched control: the same repository and record on a PATH that does
  # offer one, which must reach the same verdict rather than a different one.
  git -C "$repo" update-ref -d "$NOTES_REF"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same run record was refused where a timeout utility exists: $out"
  pass "fm-attest.sh: a host with no timeout, gtimeout or perl still attests under the shared bash bound"
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

test_write_reports_the_rejection_reason_with_credentials_redacted() {
  local repo fork head out rc
  repo="$TMP_ROOT/write-push-rejected"
  fork="$TMP_ROOT/write-push-rejected-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  # A push target that reads fine but refuses the write, and explains why in the
  # server's own words. `remote:` text is passed through verbatim by git, so a
  # credentialed URL inside it is the one form this fixture controls exactly:
  # whatever redaction happens to it is ours, not git's.
  {
    printf '#!/bin/sh\n'
    printf 'echo "refs/notes/* is blocked by a ruleset" >&2\n'
    printf 'echo "retry against https://someone:s3cr3t@example.invalid/owner/repo.git" >&2\n'
    printf 'exit 1\n'
  } > "$fork/hooks/pre-receive"
  chmod +x "$fork/hooks/pre-receive"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  assert_contains "$out" "attestation-not-published" \
    "a rejected push did not report its own reason"
  assert_contains "$out" "Could not publish $NOTES_REF to $fork" \
    "the refusal did not name the repository it could not publish to"
  # The reason the server gave must reach the person who has to act on it:
  # suppressing it leaves a ruleset or quota rejection undiagnosable.
  assert_contains "$out" "refs/notes/* is blocked by a ruleset" \
    "the server's own rejection reason was discarded"
  # And it must arrive with the credential stripped out of the URL it named.
  assert_contains "$out" "https://example.invalid/owner/repo.git" \
    "the redacted URL did not survive redaction"
  assert_not_contains "$out" "s3cr3t" "a credential in the remote's text reached the caller"
  # The matched control: the same repository and the same remote, differing only
  # in that this push target accepts the write.
  rm -f "$fork/hooks/pre-receive"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "publishing was refused once the same target accepted writes: $out"
  assert_contains "$out" "published $NOTES_REF to $fork" \
    "the success line did not name the repository the note reached"
  pass "fm-attest.sh: a rejected push reports the server's reason with credentials redacted"
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

test_write_emits_only_positively_safe_urls() {
  local repo fork head out rc
  repo="$TMP_ROOT/redact-shapes"
  fork="$TMP_ROOT/redact-shapes-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_rejecting_fork "$fork" "$(printf '%s\n' \
    'none https://plain.invalid/o/r.git' \
    'user https://alice@u1.invalid/o/r.git' \
    'userpass https://alice:hunter2@u2.invalid/o/r.git' \
    'at-in-pass https://alice:pw@word@u3.invalid/o/r.git' \
    'colon-in-pass https://alice:pw:word@u4.invalid/o/r.git' \
    'encoded-at https://alice:pw%40word@u5.invalid/o/r.git' \
    'encoded-slash https://alice:s%2Fs@u9.invalid/o/r.git' \
    'explicit-port https://alice:pw@u7.invalid:8443/o/r.git' \
    'ipv6-host https://alice:pw@[2001:db8::1]/o/r.git' \
    'scp-style git@u15.invalid:o/r.git' \
    "trailing-garbage 'https://alice:pw@u13.invalid/r.git')," \
    'unparseable https://alice:pa/ss@u8.invalid/x')"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  # A URL is emitted only in a form that positively matches a shape with no
  # userinfo at all, so what reaches the caller is the repository it names.
  assert_contains "$out" "https://plain.invalid/o/r.git" "a URL with no userinfo was altered"
  assert_contains "$out" "https://u1.invalid/o/r.git" "a user-only URL was not rewritten to its host"
  assert_contains "$out" "https://u2.invalid/o/r.git" "a user:password URL was not rewritten to its host"
  assert_contains "$out" "https://u3.invalid/o/r.git" \
    "a password holding an unencoded @ was not rewritten to its host"
  assert_contains "$out" "https://u4.invalid/o/r.git" "a password holding a colon was not rewritten"
  assert_contains "$out" "https://u5.invalid/o/r.git" "a percent-encoded password was not rewritten"
  assert_contains "$out" "https://u9.invalid/o/r.git" "a percent-encoded slash was not rewritten"
  assert_contains "$out" "https://u7.invalid:8443/o/r.git" "an explicit port was not preserved"
  assert_contains "$out" "https://[2001:db8::1]/o/r.git" "an IPv6 literal host was not preserved"
  assert_contains "$out" "u15.invalid:o/r.git" "an scp-style remote was not named by its host and path"
  assert_not_contains "$out" "git@u15.invalid" "an scp-style remote kept its user"
  assert_contains "$out" "https://u13.invalid/r.git" "punctuation around a URL defeated the rewrite"
  # No fragment of any credential survives, whatever shape it took.
  assert_not_contains "$out" "alice" "a username reached the caller"
  assert_not_contains "$out" "hunter2" "a plain password reached the caller"
  assert_not_contains "$out" "pw@word" "a password holding an unencoded @ reached the caller"
  assert_not_contains "$out" "word@u3" "a fragment of that password reached the caller"
  assert_not_contains "$out" "pw:word" "a password holding a colon reached the caller"
  assert_not_contains "$out" "pw%40word" "a percent-encoded password reached the caller"
  assert_not_contains "$out" "s%2Fs" "a percent-encoded slash password reached the caller"
  # The pairing that stops this passing under blanket suppression: the one shape
  # here that cannot be positively parsed is withheld while the rest are shown.
  assert_not_contains "$out" "pa/ss" "a password holding an unencoded slash reached the caller"
  assert_not_contains "$out" "u8.invalid" "a URL that could not be positively parsed was emitted"
  assert_contains "$out" "withheld in full" "the withheld URL was dropped without saying so"
  pass "fm-attest.sh: a URL reaches the caller only in a form with no userinfo at all"
}

test_write_withholds_a_push_target_it_cannot_positively_parse() {
  local repo parent head out rc
  repo="$TMP_ROOT/redact-unlocatable"
  parent="$TMP_ROOT/redact-unlocatable-parent.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git -C "$repo" remote add origin "$parent"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  # A push URL no reader here models, because the credential holds a space.
  # Emitting it because nothing recognised a credential in it is the fail-open
  # hole this design exists to close.
  git -C "$repo" config remote.origin.pushurl 'https://someone:pa ss@127.0.0.1:1/owner/repo.git'
  out=$(cd "$repo" && GIT_TERMINAL_PROMPT=0 no_proxy='*' NO_PROXY='*' \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable push target was published to"
  assert_contains "$out" "withheld in full" "a URL that could not be positively parsed was emitted"
  assert_not_contains "$out" "pa ss" "the credential reached the caller"
  assert_not_contains "$out" "someone" "the credential's user reached the caller"
  # The space splits this URL into two words, and its tail alone matches the
  # scp-style shape. Emitting that beside the marker names a host and path that
  # were never a remote, so the whole target must go, not the half that parsed.
  assert_not_contains "$out" "credential-free> 127.0.0.1" \
    "the tail of a split URL was emitted beside the marker as a remote of its own"
  assert_contains "$out" "credential-free>, the push target of origin" \
    "the marker was not the whole target, so part of a split URL survived beside it"
  # Deliberate rather than incidental: the same unreachable target, differing
  # only in that this URL does positively parse, is named rather than withheld.
  git -C "$repo" config remote.origin.pushurl 'https://someone:passphrase@127.0.0.1:1/owner/repo.git'
  out=$(cd "$repo" && GIT_TERMINAL_PROMPT=0 no_proxy='*' NO_PROXY='*' \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable push target was published to"
  assert_contains "$out" "https://127.0.0.1:1/owner/repo.git" \
    "a push target that positively parses was not named"
  assert_not_contains "$out" "passphrase" "the credential reached the caller"
  pass "fm-attest.sh: a push target that cannot be positively parsed is withheld, not emitted"
}

test_write_names_an_scp_style_push_target() {
  local repo parent head out rc
  repo="$TMP_ROOT/scp-push-target"
  parent="$TMP_ROOT/scp-push-target-parent.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git -C "$repo" remote add origin "$parent"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  # The form CONTRIBUTING.md prescribes. It must be named, because a contributor
  # who cannot see which repository the note reached cannot tell their fork from
  # the parent, and this form has no password field to protect.
  git -C "$repo" config remote.origin.pushurl 'git@u14.invalid:owner/repo.git'
  out=$(cd "$repo" && GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0 \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable push target was published to"
  assert_contains "$out" "u14.invalid:owner/repo.git" "an scp-style push target was not named"
  assert_not_contains "$out" "git@u14.invalid" "the scp-style push target kept its user"
  # The matched control, differing by one property: a colon before the @ means
  # this is not that shape, because that is where a password lives. It must be
  # withheld entirely rather than emitted with the password stripped off.
  git -C "$repo" config remote.origin.pushurl 'someone:hunter2@u14.invalid:owner/repo.git'
  out=$(cd "$repo" && GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0 \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable push target was published to"
  assert_contains "$out" "withheld in full" "a token with a colon before its @ was not withheld"
  assert_not_contains "$out" "hunter2" "the password reached the caller"
  assert_not_contains "$out" "u14.invalid:owner/repo.git" \
    "a token with a colon before its @ was emitted with its password stripped instead of withheld"
  pass "fm-attest.sh: an scp-style push target is named, and a colon before its user is not"
}

test_write_withholds_the_whole_line_a_withheld_url_sat_on() {
  local repo fork head out rc
  repo="$TMP_ROOT/line-withheld"
  fork="$TMP_ROOT/line-withheld-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # Words are split on spaces, so half a URL can match a shape the whole never
  # would. Emitting the safe half beside a marker reads as two places where
  # there was one, so the line goes whole.
  install_rejecting_fork "$fork" "$(printf '%s\n' \
    'mixed push failed for https://user:pa/ss@bad.invalid/x see https://companion.invalid/o/r.git' \
    'clean see https://alone.invalid/o/r.git' \
    'refs/notes/* is blocked by a ruleset')"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  assert_contains "$out" "withheld in full" "a line holding a withheld URL was dropped without saying so"
  assert_not_contains "$out" "pa/ss" "the credential reached the caller"
  assert_not_contains "$out" "bad.invalid" "the URL that could not be parsed was emitted"
  # The control that proves line granularity rather than reworded marker text:
  # this URL is safe on its own and would survive per-word withholding.
  assert_not_contains "$out" "companion.invalid" \
    "a safe URL sharing a line with a withheld one survived, so withholding is still per word"
  # The pairing, so this is not blanket suppression: a clean line is untouched,
  # and so is the server's own reason.
  assert_contains "$out" "https://alone.invalid/o/r.git" "a line with nothing withheld was suppressed"
  assert_contains "$out" "refs/notes/* is blocked by a ruleset" \
    "the server's own rejection reason was suppressed along with the URLs"
  pass "fm-attest.sh: a line holding a URL that cannot be parsed is withheld whole"
}

test_write_withholds_url_shapes_no_reader_models() {
  local repo fork head out rc
  repo="$TMP_ROOT/default-deny"
  fork="$TMP_ROOT/default-deny-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # Shapes that no reader here models. Under redact-what-you-recognise each of
  # these was emitted verbatim, because nothing recognised a credential in them.
  install_rejecting_fork "$fork" "$(printf '%s\n' \
    'refs/notes/* is blocked by a ruleset' \
    'safe https://safe.invalid/o/r.git' \
    'no-scheme alice:pw@u10.invalid/r.git' \
    'colon-before-at bob:hunter2@u11.invalid:o/r.git' \
    'at-after-authority https://u6.invalid/o/r.git@v2' \
    'unfamiliar weird+scheme://a:b/c@d:e/f?g#h')"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  assert_contains "$out" "withheld in full" "a URL-shaped token was dropped without saying so"
  assert_not_contains "$out" "alice" "a credential in a URL with no scheme reached the caller"
  assert_not_contains "$out" "u10.invalid" "a URL with no scheme was emitted"
  # The guard on the scp-style shape. Its colon separates host from path, which
  # is what makes that form credential-free, so a colon BEFORE the @ means this
  # is not that shape: it is where a password lives. Emitting anything at all
  # here, even with the password stripped, is an unproven shape being emitted.
  assert_not_contains "$out" "hunter2" "a password before the @ reached the caller"
  assert_not_contains "$out" "u11.invalid" \
    "a token with a colon before its @ was emitted as though it were an scp-style remote"
  assert_not_contains "$out" "u6.invalid" "a URL with an @ after its authority was emitted"
  # The class control: a deliberately unfamiliar URL-shaped token that no reader
  # models must be withheld. Emitting it is what "unmatched means safe" looks
  # like, and it is the shape that proves the default is deny.
  assert_not_contains "$out" "a:b/c@d:e" "an unfamiliar URL-shaped token was emitted"
  assert_not_contains "$out" "weird+scheme" "an unfamiliar URL-shaped token was emitted"
  # The pairing, twice over: withholding is not blanket. A URL that positively
  # parses still reaches the caller, and so does the server's own reason.
  assert_contains "$out" "https://safe.invalid/o/r.git" "a positively safe URL was withheld"
  assert_contains "$out" "refs/notes/* is blocked by a ruleset" \
    "the server's own rejection reason was withheld along with the URLs"
  pass "fm-attest.sh: a URL-shaped token no reader models is withheld rather than emitted"
}

# The pipeline tool's own two streams are text from outside this script exactly
# as git's are, and all four run-record refusals quote them. Redaction is a
# property of printing rather than of each call site remembering, so these four
# get it without asking for it.
LEAKY_STDOUT_URL='https://alice:hunter2@u20.invalid/o/r.git'
LEAKY_STDERR_URL='https://bob:s3cr3t@u21.invalid/o/r.git'

assert_tool_stream_made_safe() {
  local out=$1 reason=$2 kept=$3 host=$4
  assert_contains "$out" "$reason" "the refusal lost its own reason"
  assert_not_contains "$out" "hunter2" "a password on the tool's stdout reached the caller"
  assert_not_contains "$out" "s3cr3t" "a password on the tool's stderr reached the caller"
  assert_not_contains "$out" "alice" "a username on the tool's stdout reached the caller"
  assert_not_contains "$out" "bob" "a username on the tool's stderr reached the caller"
  # The pairing, so this cannot pass by suppressing the diagnostic instead of
  # redacting it: what the tool said still reaches the person who has to act.
  assert_contains "$out" "$kept" "the tool's own words were discarded rather than made safe"
  assert_contains "$out" "$host" "the URL the tool named was withheld rather than shown without its userinfo"
}

test_write_makes_the_pipeline_tools_own_streams_safe_to_print() {
  local repo head out
  repo="$TMP_ROOT/tool-stream-redaction"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)

  # run-record-unreadable: the tool failed, and reports its own error on stdout.
  install_pipeline_stub "$repo/stub" \
    "error: repo not initialized, retry against $LEAKY_STDOUT_URL" 1 \
    "upgrade available from $LEAKY_STDERR_URL"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" run-record-unreadable "repo not initialized" \
    'https://u20.invalid/o/r.git'
  assert_contains "$out" 'https://u21.invalid/o/r.git' \
    "the tool's stderr was withheld rather than shown without its userinfo"

  # no-run-record: nothing on stdout, so only stderr is quoted.
  install_pipeline_stub "$repo/stub" "" 0 "upgrade available from $LEAKY_STDERR_URL"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" no-run-record "upgrade available" \
    'https://u21.invalid/o/r.git'

  # run-record-unparsed: stdout was not empty, but no run identity is in it.
  install_pipeline_stub "$repo/stub" \
    "runs: none matching this worktree, see $LEAKY_STDOUT_URL" 0 \
    "upgrade available from $LEAKY_STDERR_URL"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" run-record-unparsed "none matching this worktree" \
    'https://u20.invalid/o/r.git'

  # run-record-no-head: a run record this transcription cannot read a head from.
  install_pipeline_stub "$repo/stub" \
    "$(run_status_toon fm/demo "${head:0:8}" completed | sed '/^  head: /d'
      printf '  detail: %s\n' "$LEAKY_STDOUT_URL")"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" run-record-no-head "01KZ5YTADR5YAXZSNKFXTW8W9F" \
    'https://u20.invalid/o/r.git'

  # The matched positive control: the same tool, the same streams, differing
  # only in that this record is complete. Redaction must not have cost the
  # emitter its ability to read a record at all.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)" 0 \
    "upgrade available from $LEAKY_STDERR_URL"
  local rc=0
  out=$(write_out "$repo") || rc=$?
  [ "$rc" -eq 0 ] || fail "a complete run record was refused once its streams were redacted: $out"
  pass "fm-attest.sh: every run-record refusal quotes the tool's streams with credentials made safe"
}

test_write_rejects_a_zero_bound_rather_than_running_the_read_unbounded() {
  local repo head out rc
  repo="$TMP_ROOT/zero-timeout"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_hanging_pipeline_stub "$repo/stub"
  # bin/fm-timeout-lib.sh states the rule for every caller: `timeout 0` and the
  # perl fallback's `alarm 0` both disable the deadline, so a zero that reached
  # the runner would be no bound at all. The bound below is this test's own, and
  # reaching it is exactly the regression.
  out=$(cd "$repo" && fm_run_timed 60 \
    env FM_ATTEST_NM_TIMEOUT=0 PATH="$repo/stub/bin:$PATH" \
    "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 124 ] || fail "a zero bound left the run-record read unbounded: it outlived this test's own bound"
  [ "$rc" -ne 0 ] || fail "a pipeline tool that never answered was transcribed"
  assert_contains "$out" "run-record-unreadable" \
    "a read that hit its bound was not reported as an unreadable record"
  # The matched control, differing by one property: the same zero against a tool
  # that answers at once must still attest. A zero read as an instant deadline,
  # which is what it becomes on a host falling back to the bash watchdog, would
  # refuse this too, and refusing every read is not a bound either.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && FM_ATTEST_NM_TIMEOUT=0 PATH="$repo/stub/bin:$PATH" \
    "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a zero bound expired a run-record read that answered at once: $out"
  pass "fm-attest.sh: a zero FM_ATTEST_NM_TIMEOUT falls back to the default bound rather than removing it"
}

# ---------------------------------------------------------------------------
# The workflow's own step scripts. The check fails closed on every path below;
# what these pin is what it tells the contributor, because a gate that reports
# evidence it never examined as absent evidence is committing the defect the
# whole check exists to remove.
# ---------------------------------------------------------------------------

test_check_step_separates_a_verdict_from_a_verifier_that_could_not_run() {
  local dir script head out rc
  dir="$TMP_ROOT/workflow-verify"
  mkdir -p "$dir"
  script="$dir/verify-step.sh"
  head=0123456789012345678901234567890123456789
  workflow_step_script 'Verify the head-bound no-mistakes attestation' > "$script"
  [ -s "$script" ] || fail "the verify step's own script could not be read out of the workflow"
  assert_contains "$(cat "$script")" 'fm-attest.sh verify --head' \
    "the extracted script is not the step that runs the verifier"

  run_verify_step() {
    ( cd "$dir" && HEAD_SHA="$head" PR_AUTHOR=someone bash "$script" 2>&1 )
  }

  # Exit 1 is a refusal: the evidence was examined and found absent. That is a
  # verdict, and it is told as one.
  install_verifier_stub "$dir" 1
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a refused attestation passed the check"
  assert_contains "$out" "carries no verified no-mistakes attestation" \
    "a refusal was not reported as an absent attestation"
  assert_not_contains "$out" "could not evaluate" \
    "a verdict about the evidence was reported as an inability to reach one"

  # Exit 2 is a failure: no verdict was reached, so it says nothing about the
  # evidence either way and must not borrow the refusal's words.
  install_verifier_stub "$dir" 2
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a verifier that reached no verdict passed the check"
  assert_contains "$out" "could not evaluate" \
    "a verifier that reached no verdict was not reported as such"
  assert_contains "$out" "exited 2" "the failing exit status was not named"
  assert_not_contains "$out" "carries no verified no-mistakes attestation" \
    "evidence the check never examined was reported as absent evidence"

  # The reachable case this was found on: a head where the verifier is not there
  # to run at all. That is not exit 1 either, and the branch reporting it must
  # not itself depend on the script that is missing.
  rm -f "$dir/bin/fm-attest.sh"
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a head carrying no verifier passed the check"
  assert_contains "$out" "could not evaluate" \
    "a head that carries no verifier was not reported as one the check could not evaluate"
  assert_not_contains "$out" "carries no verified no-mistakes attestation" \
    "a head that carries no verifier was reported as one carrying no attestation"

  # The matched positive control: an attested head still passes, and is told
  # neither of the two failure stories.
  install_verifier_stub "$dir" 0
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -eq 0 ] || fail "an attested head was failed by the check: $out"
  assert_not_contains "$out" "could not evaluate" "a passing head was told the check could not look"
  assert_not_contains "$out" "carries no verified no-mistakes attestation" \
    "a passing head was told it carries no attestation"
  unset -f run_verify_step
  pass "no-mistakes-required.yml: a verifier that could not run is not reported as an absent attestation"
}

test_check_step_reads_the_head_repository_without_logging_its_token() {
  local dir script log out rc
  dir="$TMP_ROOT/workflow-fetch"
  mkdir -p "$dir/bin"
  script="$dir/fetch-step.sh"
  log="$dir/git-said.log"
  workflow_step_script 'Fetch the attestation ref from the head repository' > "$script"
  [ -s "$script" ] || fail "the fetch step's own script could not be read out of the workflow"
  assert_contains "$(cat "$script")" 'git fetch' "the extracted script is not the step that fetches the ref"
  # git quotes the whole remote URL back in its own http errors, and when the
  # head repository is the base repository that URL carries the job token. This
  # stand-in does exactly that, and also records what it said, so the assertion
  # below cannot pass merely because the fixture stayed quiet.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "${1:-}" in\n'
    printf '  ls-remote) exit "${FM_FAKE_GIT_LS_RC:-0}" ;;\n'
    printf '  fetch)\n'
    printf '    printf "fatal: unable to access %%s: the server said no\\n" "$5" | tee -a %s >&2\n' "$log"
    printf '    exit "${FM_FAKE_GIT_FETCH_RC:-0}"\n'
    printf '  ;;\n'
    printf 'esac\n'
  } > "$dir/bin/git"
  chmod +x "$dir/bin/git"

  run_fetch_step() {
    (
      cd "$dir" || exit 1
      PATH="$dir/bin:$PATH" HEAD_REPO=owner/repo BASE_REPO=owner/repo \
        GH_TOKEN=ghs_fixturetokenvalue bash "$script" 2>&1
    )
  }

  FM_FAKE_GIT_FETCH_RC=128
  export FM_FAKE_GIT_FETCH_RC
  out=$(run_fetch_step)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a fetch that failed was reported as a successful read"
  assert_contains "$(cat "$log")" "ghs_fixturetokenvalue" \
    "the fixture never quoted the tokenized URL back, so this assertion proves nothing"
  assert_not_contains "$out" "ghs_fixturetokenvalue" "the job token reached the step's output"
  assert_contains "$out" "owner/repo" "the failure did not name the head repository it could not read"
  assert_contains "$out" "would not serve it" \
    "a target that advertised the ref but would not serve it was not reported as such"

  # The matched positive control: the same call, differing only in that this
  # fetch succeeds, must say nothing about a failure and must not fail the job.
  FM_FAKE_GIT_FETCH_RC=0
  : > "$log"
  out=$(run_fetch_step)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a fetch that succeeded failed the step: $out"
  assert_not_contains "$out" "would not serve it" "a successful fetch was reported as a failure"
  assert_not_contains "$out" "ghs_fixturetokenvalue" "the job token reached the step's output"

  # And the arm that must stay untouched: an absent ref is a fact about that
  # repository, so it is left absent for the verifier to name in its own words
  # rather than fetched or failed here.
  FM_FAKE_GIT_LS_RC=2
  export FM_FAKE_GIT_LS_RC
  : > "$log"
  out=$(run_fetch_step)
  rc=$?
  [ "$rc" -eq 0 ] || fail "an absent attestation ref stopped the job instead of being left absent: $out"
  assert_contains "$out" "No refs/notes/no-mistakes on owner/repo" \
    "an absent ref was not reported as absent"
  [ ! -s "$log" ] || fail "a ref the head repository does not advertise was fetched anyway"
  unset FM_FAKE_GIT_LS_RC FM_FAKE_GIT_FETCH_RC
  unset -f run_fetch_step
  pass "no-mistakes-required.yml: a failed fetch is named by repository rather than by its tokenized URL"
}

# ---------------------------------------------------------------------------
# write and show - the failure half of the error model. Every documented
# `cannot attest` reason fires for its own condition and for no other's.
# ---------------------------------------------------------------------------

test_write_outside_a_repository_fails_as_such() {
  local dir out rc
  dir="$TMP_ROOT/no-repo"
  mkdir -p "$dir"
  out=$(cd "$dir" && "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran outside a git repository"
  assert_contains "$out" "not-a-git-repository" "a non-repository was not reported as such"
  assert_not_contains "$out" "head-unresolvable" "a non-repository was reported as an unresolvable head"
  pass "fm-attest.sh: write outside a repository fails as a non-repository"
}

test_write_without_the_pipeline_tool_fails_as_such() {
  local repo bare head out rc
  repo="$TMP_ROOT/no-tool"
  bare="$TMP_ROOT/no-tool-path"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_unbounded_path "$bare"
  out=$(cd "$repo" && PATH="$bare" "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran with no pipeline tool on PATH"
  assert_contains "$out" "pipeline-tool-missing" "an absent pipeline tool was not reported as such"
  assert_not_contains "$out" "no-run-record" "an absent tool was reported as an absent run"
  # The matched control: the same repository and PATH, plus the tool.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && PATH="$repo/stub/bin:$bare" "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused once the tool was on PATH: $out"
  pass "fm-attest.sh: an absent pipeline tool fails as a missing tool, not as a missing run"
}

test_write_on_an_unborn_head_fails_as_such() {
  local repo out rc
  repo="$TMP_ROOT/unborn-head"
  mkdir -p "$repo"
  git -C "$repo" init -q -b fm/demo .
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo deadbeef completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran with no commit to attest"
  assert_contains "$out" "head-unresolvable" "an unborn HEAD was not reported as such"
  assert_not_contains "$out" "head-detached" "an unborn HEAD was reported as a detached one"
  pass "fm-attest.sh: an unborn HEAD fails as unresolvable, not as detached"
}

test_write_on_a_detached_head_fails_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/detached-head"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  git -C "$repo" checkout -q --detach
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran from a detached HEAD"
  assert_contains "$out" "head-detached" "a detached HEAD was not reported as such"
  assert_not_contains "$out" "head-unresolvable" "a detached HEAD was reported as an unresolvable one"
  # The matched control: the same repository back on the branch the run covers.
  git -C "$repo" checkout -q fm/demo
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused once back on its branch: $out"
  pass "fm-attest.sh: a detached HEAD fails as detached, not as unresolvable"
}

test_write_without_a_usable_scratch_directory_fails_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/no-tmpdir"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && TMPDIR="$repo/absent" PATH="$repo/stub/bin:$PATH" \
    "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran with no usable temporary directory"
  assert_contains "$out" "scratch-file-unavailable" "an unusable TMPDIR was not reported as such"
  assert_not_contains "$out" "run-record-unreadable" "an unusable TMPDIR was reported as a failing tool"
  # The matched control: the same repository with a usable one.
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused with a usable TMPDIR: $out"
  pass "fm-attest.sh: an unusable scratch directory fails as its own state, not as a tool failure"
}

test_write_reports_an_unfetchable_push_target_as_such() {
  local repo fork head out rc
  repo="$TMP_ROOT/unfetchable"
  fork="$TMP_ROOT/unfetchable-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  # A push target that advertises the ref but cannot serve it, because the ref
  # names an object it does not have. Readable is not the same as fetchable.
  mkdir -p "$fork/refs/notes"
  printf '0123456789012345678901234567890123456789\n' > "$fork/refs/notes/no-mistakes"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unfetchable push target was published to"
  assert_contains "$out" "push-target-unfetchable" "an unfetchable push target was not reported as such"
  assert_not_contains "$out" "push-target-unreadable" \
    "a target that advertised the ref was reported as one that could not be read"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "an attestation was recorded against a target that would not serve its ref"
  # The matched control: the same target once that ref is serviceable.
  rm -f "$fork/refs/notes/no-mistakes"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same target was refused once its ref was serviceable: $out"
  pass "fm-attest.sh: a push target that advertises a ref it cannot serve fails as unfetchable"
}

test_write_reports_an_unreconcilable_local_ref_as_such() {
  local repo fork head seed out rc
  repo="$TMP_ROOT/unreconcilable"
  fork="$TMP_ROOT/unreconcilable-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  # The push target holds a real attestation history, so the reconcile is
  # reached; the local ref is broken, so it cannot complete.
  seed=$(git -C "$repo" commit-tree -m seed "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$seed" "$(good_note "$seed")"
  git -C "$repo" push -q "$fork" "$NOTES_REF:$NOTES_REF"
  # A local ref that resolves, so the fetch completes, but that names no notes
  # tree, so only the reconcile itself can fail.
  git -C "$repo" update-ref "$NOTES_REF" "$(printf 'x' | git -C "$repo" hash-object -w --stdin)"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a local ref naming no notes tree was published over"
  assert_contains "$out" "attestation-not-reconciled" "a failed reconcile was not reported as such"
  assert_not_contains "$out" "attestation-not-recorded" \
    "a reconcile that failed was reported as a record that failed"
  assert_not_contains "$out" "push-target-unfetchable" \
    "a reconcile that failed was reported as a target that would not serve its ref"
  # The matched control: the same target with a usable local ref.
  git -C "$repo" update-ref -d "$NOTES_REF"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same push target was refused with a usable local ref: $out"
  pass "fm-attest.sh: a local ref that cannot be reconciled fails as unreconciled"
}

test_write_reports_an_unrecordable_note_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/unrecordable"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  git -C "$repo" update-ref "$NOTES_REF" "$(printf 'x' | git -C "$repo" hash-object -w --stdin)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a note was recorded against a ref naming no notes tree"
  assert_contains "$out" "attestation-not-recorded" "a failed record was not reported as such"
  assert_not_contains "$out" "attestation-not-reconciled" \
    "a record that failed with no push was reported as a failed reconcile"
  # The matched control: the same repository with a usable ref.
  git -C "$repo" update-ref -d "$NOTES_REF"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused with a readable ref: $out"
  pass "fm-attest.sh: a note that cannot be recorded fails as unrecorded"
}

test_show_reports_an_unknown_commit_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/show-unknown"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head")"
  out=$(cd "$repo" && "$ATTEST" show --commit 0123456789012345678901234567890123456789 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "show accepted a commit this repository does not have"
  assert_contains "$out" "commit-unknown" "an unknown commit was not reported as such"
  assert_not_contains "$out" "no-attestation-for-head" \
    "a commit this repository does not have was reported as one carrying no attestation"
  # The matched control: the commit this repository does have.
  out=$(cd "$repo" && "$ATTEST" show --commit "$head" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "show refused the attested commit: $out"
  pass "fm-attest.sh: show fails as commit-unknown rather than as an absent attestation"
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
test_write_reports_a_record_with_no_head_as_a_record_fault
test_write_attests_on_a_host_with_no_timeout_utility
test_write_publishes_to_the_push_target_it_reconciled_against
test_write_reports_the_rejection_reason_with_credentials_redacted
test_write_publishes_a_first_attestation_to_a_push_target_with_no_ref
test_write_refuses_an_unreadable_push_target_without_leaking_credentials
test_write_emits_only_positively_safe_urls
test_write_withholds_a_push_target_it_cannot_positively_parse
test_write_names_an_scp_style_push_target
test_write_withholds_the_whole_line_a_withheld_url_sat_on
test_write_withholds_url_shapes_no_reader_models
test_write_makes_the_pipeline_tools_own_streams_safe_to_print
test_write_rejects_a_zero_bound_rather_than_running_the_read_unbounded
test_check_step_separates_a_verdict_from_a_verifier_that_could_not_run
test_check_step_reads_the_head_repository_without_logging_its_token
test_write_outside_a_repository_fails_as_such
test_write_without_the_pipeline_tool_fails_as_such
test_write_on_an_unborn_head_fails_as_such
test_write_on_a_detached_head_fails_as_such
test_write_without_a_usable_scratch_directory_fails_as_such
test_write_reports_an_unfetchable_push_target_as_such
test_write_reports_an_unreconcilable_local_ref_as_such
test_write_reports_an_unrecordable_note_as_such
test_show_reports_an_unknown_commit_as_such
