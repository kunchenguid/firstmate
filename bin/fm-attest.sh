#!/usr/bin/env bash
# fm-attest.sh - emit and verify the head-bound no-mistakes attestation.
#
# The attestation is a git note on refs/notes/no-mistakes keyed by the exact
# commit it covers, so it binds to one head instead of to mutable pull request
# prose. A note never rewrites the branch, so emitting one cannot disturb the
# pipeline's custody of it, and the ref reaches the forge as an ordinary ref
# that a pull_request workflow can read with contents: read.
#
# Usage:
#   fm-attest.sh write [--run <id>] [--remote <name>] [--no-push]
#   fm-attest.sh show [--commit <rev>] [--notes-ref <ref>]
#   fm-attest.sh verify --head <sha> [--notes-ref <ref>]
#   fm-attest.sh --print-format
#   fm-attest.sh --help
#
# write reads the local pipeline run record through `no-mistakes axi status`,
# refuses unless that run covers this exact HEAD and completed every required
# validation step, then writes the note and pushes the ref.
#
# verify is the CI side. It reads a note already fetched into this repository
# and reports one distinct reason per failure, so an absent attestation is
# never reported as a rejected one and never as a passing one.
#
# The attestation records what the pipeline did to one commit. It is not a
# proof of who ran the pipeline: a locally run pipeline holds only credentials
# its own operator holds, so no artifact it emits can be unforgeable by that
# operator. docs/no-mistakes-attestation.md owns that boundary in full.
set -u

NOTES_REF_DEFAULT=refs/notes/no-mistakes
ATTESTATION_VERSION=v1
ATTESTATION_KEY=no-mistakes-attestation

# Steps a contribution must have completed for the attestation to mean what the
# gate claims: this exact commit was reviewed, tested, linted, and pushed by the
# pipeline rather than assembled by hand. Recorded steps beyond these are kept
# in the note but are not required, because a repository may legitimately skip
# intent, rebase, document, pr, or ci for a given run.
REQUIRED_GATES='review test lint push'

# Every key a v1 note may carry. An unknown key is malformed rather than
# ignored, so a future format can never be read as a weaker v1 one.
KNOWN_KEYS="$ATTESTATION_KEY head run gates tool"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-attest: %s\n' "$*" >&2
  exit 2
}

# One machine-readable reason plus prose, so a caller can branch on the reason
# and a human reading a CI log gets the explanation with it. A multi-line detail
# is indented line by line, so a refusal can quote a tool's own output verbatim
# instead of paraphrasing it.
refuse() {
  reason=$1
  shift
  printf 'fm-attest: not attested (%s)\n' "$reason" >&2
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" | sed 's/^/  /' >&2
    shift
  done
  exit 1
}

is_full_sha() {
  case "$1" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

is_short_sha() {
  case "$1" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -ge 4 ] && [ "${#1}" -le 40 ]
}

is_run_id() {
  case "$1" in
    '' | *[!0-9A-Za-z_-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

is_gate_name() {
  case "$1" in
    '' | *[!0-9a-z-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

is_tool_token() {
  case "$1" in
    '' | *[!0-9A-Za-z._/+-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# Membership in a space-separated list. Every needle this script passes is a
# token already validated against its own character class, so padding both sides
# and matching whole words is exact.
list_has() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

print_format() {
  cat <<EOF
$ATTESTATION_KEY: $ATTESTATION_VERSION
head: <the 40-character lowercase sha of the commit this attests>
run: <the pipeline run identity that validated it>
gates: <comma-separated pipeline steps that completed for that head>
tool: <the pipeline binary and version that ran them>
EOF
}

# ---------------------------------------------------------------------------
# verify - the CI side
# ---------------------------------------------------------------------------

cmd_verify() {
  head=
  notes_ref=$NOTES_REF_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || die "--head needs a value"
        head=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        notes_ref=$2
        shift 2
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$head" ] || die "verify needs --head <sha>"
  is_full_sha "$head" || die "--head must be a 40-character lowercase sha"

  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

  # A head whose commit object is absent cannot be attested or refuted here.
  # Report it as its own state rather than as a missing note, because the two
  # need different repairs.
  git rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1 \
    || refuse head-commit-unavailable \
      "The commit $head is not present in this checkout." \
      "Check out the pull request head before verifying its attestation."

  git rev-parse --verify --quiet "$notes_ref" >/dev/null 2>&1 \
    || refuse no-attestation-ref \
      "This repository holds no $notes_ref, so no attestation was published or fetched." \
      "Absence of evidence is not evidence: this is a refusal, not a pass."

  note=$(git notes --ref="$notes_ref" show "$head" 2>/dev/null) \
    || refuse no-attestation-for-head \
      "$notes_ref exists but carries no attestation for $head." \
      "An attestation for any other commit says nothing about this one."

  verify_note_payload "$head" "$note"

  printf 'fm-attest: attested %s (run %s, gates %s, %s)\n' \
    "$head" "$note_run" "$note_gates" "$note_tool"
}

# Parses and checks one note payload. Sets note_run/note_gates/note_tool for the
# caller's success line. Every failure path exits through refuse().
verify_note_payload() {
  expect_head=$1
  payload=$2

  seen_keys=
  note_version=
  note_head=
  note_run=
  note_gates=
  note_tool=

  while IFS= read -r line; do
    # Tolerate a trailing CR so a note written on another platform is read the
    # same way, but nothing else: no blank lines, no comments, no continuations.
    line=${line%$'\r'}
    [ -n "$line" ] || refuse attestation-malformed \
      "The attestation for $expect_head contains a blank line." \
      "A v1 attestation is exactly one 'key: value' line per field."

    case "$line" in
      *': '*) ;;
      *)
        refuse attestation-malformed \
          "The attestation for $expect_head has a line that is not 'key: value': $line"
        ;;
    esac
    key=${line%%': '*}
    value=${line#*': '}

    list_has "$key" "$KNOWN_KEYS" || refuse attestation-malformed \
      "The attestation for $expect_head carries an unknown field '$key'." \
      "A v1 attestation is rejected rather than partly understood."
    list_has "$key" "$seen_keys" && refuse attestation-malformed \
      "The attestation for $expect_head repeats the field '$key'."
    seen_keys="$seen_keys $key"

    case "$key" in
      "$ATTESTATION_KEY") note_version=$value ;;
      head) note_head=$value ;;
      run) note_run=$value ;;
      gates) note_gates=$value ;;
      tool) note_tool=$value ;;
    esac
  done <<EOF
$payload
EOF

  [ "$note_version" = "$ATTESTATION_VERSION" ] || refuse attestation-malformed \
    "The attestation for $expect_head does not declare $ATTESTATION_KEY: $ATTESTATION_VERSION." \
    "Only the format this gate understands is accepted."

  for key in head run gates tool; do
    list_has "$key" "$seen_keys" || refuse attestation-malformed \
      "The attestation for $expect_head is missing the required field '$key'."
  done

  is_full_sha "$note_head" || refuse attestation-malformed \
    "The attestation for $expect_head names a head that is not a 40-character lowercase sha."
  is_run_id "$note_run" || refuse attestation-malformed \
    "The attestation for $expect_head names an unusable run identity."
  is_tool_token "$note_tool" || refuse attestation-malformed \
    "The attestation for $expect_head names an unusable tool identity."

  # The binding this whole gate rests on: the attestation must name the commit
  # under review, not merely sit near it. A note moved, copied, or carried
  # across a rewrite fails here.
  [ "$note_head" = "$expect_head" ] || refuse attestation-not-bound \
    "The attestation attached to $expect_head attests $note_head instead." \
    "An attestation that does not name this exact commit does not cover it."

  case "$note_gates" in
    ,* | *, | *,,* | '')
      refuse attestation-malformed \
        "The attestation for $expect_head has an unusable 'gates' list: $note_gates"
      ;;
  esac
  gates_list=$(printf '%s' "$note_gates" | tr ',' ' ')
  for gate in $gates_list; do
    is_gate_name "$gate" || refuse attestation-malformed \
      "The attestation for $expect_head names an unusable pipeline step '$gate'."
  done
  for gate in $REQUIRED_GATES; do
    list_has "$gate" "$gates_list" || refuse attestation-missing-gate \
      "The attestation for $expect_head does not record a completed '$gate' step." \
      "Required steps: $REQUIRED_GATES."
  done
}

# ---------------------------------------------------------------------------
# write - the contributor side
# ---------------------------------------------------------------------------

# Reads `no-mistakes axi status` and emits validated "field value" lines. Every
# token is re-checked by the caller, because this is tool output, not input the
# note format may inherit unchecked.
parse_run_status() {
  awk '
    /^[^ \t]/ { in_run = ($0 == "run:"); in_steps = 0; next }
    !in_run { next }
    /^  steps\[/ { in_steps = 1; next }
    /^  [A-Za-z_]+[:[]/ { in_steps = 0 }
    !in_steps && /^  id:[ \t]/ { v = $0; sub(/^  id:[ \t]*/, "", v); gsub(/"/, "", v); print "id " v; next }
    !in_steps && /^  branch:[ \t]/ { v = $0; sub(/^  branch:[ \t]*/, "", v); gsub(/"/, "", v); print "branch " v; next }
    !in_steps && /^  head:[ \t]/ { v = $0; sub(/^  head:[ \t]*/, "", v); gsub(/"/, "", v); print "head " v; next }
    in_steps && /^    [A-Za-z]/ {
      row = $0
      sub(/^[ \t]+/, "", row)
      n = split(row, f, ",")
      if (n >= 2 && f[2] == "completed") print "gate " f[1]
      next
    }
  '
}

cmd_write() {
  run_id=
  remote=origin
  push=1
  notes_ref=$NOTES_REF_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)
        [ "$#" -ge 2 ] || die "--run needs a value"
        run_id=$2
        shift 2
        ;;
      --remote)
        [ "$#" -ge 2 ] || die "--remote needs a value"
        remote=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        notes_ref=$2
        shift 2
        ;;
      --no-push)
        push=0
        shift
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done

  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes is not installed"

  head=$(git rev-parse --verify HEAD 2>/dev/null) || die "HEAD does not resolve to a commit"
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || die "HEAD is not on a branch"
  [ "$branch" != HEAD ] || die "attest from the branch the pipeline validated, not a detached HEAD"

  # A tool that failed, a tool whose output this transcription cannot read, and a
  # tool reporting no run at all are three different repairs, and none of them
  # may be described as one of the others.
  #
  # The two streams are therefore kept apart. The tool reports its own errors on
  # stdout but writes unrelated notices there too, such as its version-upgrade
  # banner, on stderr. Only stdout decides whether a run record was reported and
  # only stdout is parsed, so a stderr notice can never stand in for a run
  # record; stderr is quoted alongside it purely as diagnostic detail.
  status_err_file=$(mktemp "${TMPDIR:-/tmp}/.fm-attest-status.XXXXXX") \
    || die "could not create a temporary file"
  status_rc=0
  if [ -n "$run_id" ]; then
    status=$(no-mistakes axi status --run "$run_id" 2>"$status_err_file") || status_rc=$?
  else
    status=$(no-mistakes axi status 2>"$status_err_file") || status_rc=$?
  fi
  status_err=$(cat "$status_err_file")
  rm -f "$status_err_file"

  [ "$status_rc" -eq 0 ] || refuse run-record-unreadable \
    "no-mistakes exited $status_rc instead of reporting a pipeline run." \
    "Its stdout: ${status:-(nothing)}" \
    "Its stderr: ${status_err:-(nothing)}" \
    "That is a tool or setup failure rather than a missing run; fix it and re-run."
  [ -n "$status" ] || refuse no-run-record \
    "no-mistakes reported no pipeline run for this repository: it wrote nothing to stdout." \
    "Its stderr: ${status_err:-(nothing)}" \
    "Validate this branch with no-mistakes before attesting its head."

  run_field=
  branch_field=
  head_field=
  gates=
  while read -r field value; do
    case "$field" in
      id) run_field=$value ;;
      branch) branch_field=$value ;;
      head) head_field=$value ;;
      gate)
        is_gate_name "$value" || continue
        list_has "$value" "$gates" && continue
        gates="$gates $value"
        ;;
    esac
  done <<EOF
$(printf '%s\n' "$status" | parse_run_status)
EOF

  is_run_id "$run_field" || refuse run-record-unparsed \
    "no-mistakes wrote a run record to stdout, but no run identity could be read from it." \
    "Its stdout: $status" \
    "Its stderr: ${status_err:-(nothing)}" \
    "Its stdout was not empty, so this is not an absent run: either that output is not a run record, or its shape changed and this transcription needs updating."
  [ "$branch_field" = "$branch" ] || refuse run-covers-another-branch \
    "The most recent pipeline run covers branch '$branch_field', not '$branch'." \
    "Attest from the branch that run validated, or name the run with --run <id>."

  # The run record abbreviates the head it pushed. Requiring the local head to
  # extend that prefix keeps the note bound to a commit the pipeline actually
  # handled instead of to whatever HEAD happens to be now.
  is_short_sha "$head_field" || refuse run-covers-another-head \
    "The pipeline run record names no usable head commit."
  case "$head" in
    "$head_field"*) ;;
    *)
      refuse run-covers-another-head \
        "The pipeline run validated $head_field, but HEAD is $head." \
        "Commits made after that run are not covered by it; validate them first."
      ;;
  esac

  missing=
  for gate in $REQUIRED_GATES; do
    list_has "$gate" "$gates" && continue
    missing="$missing $gate"
  done
  [ -z "$missing" ] || refuse run-incomplete \
    "The pipeline run for $head has not completed:$missing." \
    "Required steps: $REQUIRED_GATES."

  tool=$(no-mistakes --version 2>/dev/null | awk 'NR == 1 { print $3; exit }')
  is_tool_token "$tool" || tool=unknown

  gates_csv=$(printf '%s' "${gates# }" | tr ' ' ',')
  payload=$(printf '%s: %s\nhead: %s\nrun: %s\ngates: %s\ntool: %s\n' \
    "$ATTESTATION_KEY" "$ATTESTATION_VERSION" "$head" "$run_field" "$gates_csv" "no-mistakes/$tool")

  # Refuse to publish anything this repository's own gate would reject, so a
  # malformed note can never reach the forge and be discovered only in CI.
  verify_note_payload "$head" "$payload"

  # Reconcile against the repository this is about to write to, which is the
  # remote's push URL and not its fetch URL. The two are different repositories
  # in the setup CONTRIBUTING.md describes: origin fetches the parent and pushes
  # the contributor's fork, and the fork is the repository the gate reads.
  # Reconciling against the parent would reset the local ref to a history the
  # fork has never seen, so every push would be refused as a non-fast-forward
  # and re-running would refuse identically.
  #
  # The incoming ref is merged rather than forced over the local one, so an
  # attestation recorded locally with --no-push is not silently discarded by the
  # act of publishing a later one.
  # Only the remote's name is ever printed. A resolved URL can embed credentials,
  # and the name is what the caller passed and what they would re-run with.
  if [ "$push" -eq 1 ]; then
    push_url=$(git remote get-url --push "$remote" 2>/dev/null) || push_url=$remote
    incoming_ref="$notes_ref-incoming"
    if git fetch --quiet --no-tags --force "$push_url" "$notes_ref:$incoming_ref" 2>/dev/null; then
      git notes --ref="$notes_ref" merge -s ours "$incoming_ref" >/dev/null 2>&1 \
        || die "could not reconcile $notes_ref with the push target of $remote; resolve it and re-run"
      git update-ref -d "$incoming_ref" 2>/dev/null || true
    fi
  fi
  git notes --ref="$notes_ref" add -f -m "$payload" "$head" >/dev/null \
    || die "could not record the attestation note"
  printf 'fm-attest: recorded %s for %s\n' "$notes_ref" "$head"

  [ "$push" -eq 1 ] || return 0
  git push --quiet "$remote" "$notes_ref:$notes_ref" \
    || die "could not publish $notes_ref to $remote; re-run to reconcile with its push target and retry"
  printf 'fm-attest: published %s to %s\n' "$notes_ref" "$remote"
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

cmd_show() {
  commit=HEAD
  notes_ref=$NOTES_REF_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --commit)
        [ "$#" -ge 2 ] || die "--commit needs a value"
        commit=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        notes_ref=$2
        shift 2
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  sha=$(git rev-parse --verify "$commit^{commit}" 2>/dev/null) || die "no such commit: $commit"
  git notes --ref="$notes_ref" show "$sha" 2>/dev/null \
    || refuse no-attestation-for-head "No attestation is recorded for $sha."
}

# ---------------------------------------------------------------------------

[ "$#" -ge 1 ] || {
  usage
  exit 2
}
command=$1
shift
case "$command" in
  write) cmd_write "$@" ;;
  verify) cmd_verify "$@" ;;
  show) cmd_show "$@" ;;
  --print-format) print_format ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
