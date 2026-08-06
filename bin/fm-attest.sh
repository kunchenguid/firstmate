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
# refuses unless that run covers this branch and completed every required
# validation step, then writes the note on the head that run validated and
# pushes the ref. That head is not always HEAD: the pipeline's own fix commits
# advance the run tip past the local checkout, and bin/fm-nm-run-lib.sh owns the
# rule that decides whether a run belongs to a worktree for every caller that
# has to ask, so this reads it from there rather than re-deriving it.
#
# verify is the CI side. It reads a note already fetched into this repository
# and reports one distinct reason per failure, so an absent attestation is
# never reported as a rejected one and never as a passing one.
#
# Every exit from either side names its own cause. A refusal (exit 1) is a
# verdict on the evidence; a failure (exit 2) means no verdict was reached, and
# the two are never worded as each other. docs/no-mistakes-attestation.md lists
# the full set.
#
# The attestation records what the pipeline did to one commit. It is not a
# proof of who ran the pipeline: a locally run pipeline holds only credentials
# its own operator holds, so no artifact it emits can be unforgeable by that
# operator. docs/no-mistakes-attestation.md owns that boundary in full.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

# Every call to the pipeline is bounded, so a tool blocked on a lock or on a
# network read refuses with its own reason instead of hanging at a terminal.
# bin/fm-timeout-lib.sh owns imposing that bound and falls back to a
# dependency-free bash watchdog, so no host is refused for lacking a utility.
NM_TIMEOUT=${FM_ATTEST_NM_TIMEOUT:-20}
case "$NM_TIMEOUT" in '' | *[!0-9]*) NM_TIMEOUT=20 ;; esac

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

# Three exits, and the difference between them is the whole error model.
#
#   refuse <reason>   exit 1, "not attested": the evidence was examined and
#                     found absent, unbound, or invalid. A verdict.
#   fail <reason>     exit 2, "cannot attest": the command could not carry the
#                     work out, so it reached no verdict and says nothing about
#                     the evidence either way.
#   die               exit 2, caller misuse: an argument this program cannot
#                     act on at all, named in plain words because there is no
#                     state to describe.
#
# Every refusal and every failure carries its own machine-readable reason, and
# no condition borrows another's. That rule is the one this component keeps
# having to relearn: an unreadable record reported as head divergence, or a
# missing utility reported as a tool exit, sends a reader to repair something
# that was never broken and to hit the identical message again.
#
# Both forms take prose details after the reason, indented line by line, so a
# refusal can quote a tool's own output verbatim instead of paraphrasing it.
die() {
  printf 'fm-attest: %s\n' "$*" >&2
  exit 2
}

report() {
  headline=$1
  reason=$2
  shift 2
  printf 'fm-attest: %s (%s)\n' "$headline" "$reason" >&2
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" | sed 's/^/  /' >&2
    shift
  done
}

refuse() {
  report 'not attested' "$@"
  exit 1
}

fail() {
  report 'cannot attest' "$@"
  exit 2
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

  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository."

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

# git quotes the push URL back in its own messages, and the server's rejection
# reason arrives in the same stream. Suppressing that stream keeps a credential
# out of the log but throws the rejection reason away with it, which leaves a
# contributor blocked by a ruleset or a quota with nothing to act on. So text is
# made safe to print rather than withheld wholesale, and one function does it for
# everything this prints, git's output and the push target alike.
#
# It is default deny, and that is the whole design. Redacting what a reader
# recognises means every shape git accepts has to be modelled, and any shape it
# does not model is emitted intact: absence of detection read as absence of a
# credential, which is the same mistake as reading an empty check set as green.
# Two such shapes reached the log before this inversion. So a word that could
# carry a credential is emitted ONLY when it positively matches a URL with no
# userinfo, or can be rewritten into one; unparseable, ambiguous, unfamiliar or
# merely unmatched all withhold. An emitted URL therefore never contains an '@'
# at all, so nothing turns on where a reader believes the authority ends.
#
# The cost is deliberate: an ssh remote, an address, or a URL with an '@' after
# its host is withheld even though it holds no secret. The marker says so in its
# place, because an omission the reader knows about is recoverable and a silent
# one is not. Words that are not URL-shaped are untouched, so the server's own
# rejection reason still reaches the person who has to act on it.
WITHHELD_URL='<url withheld: not provably credential-free>'

credential_safe_text() {
  [ -n "$1" ] || {
    printf '(nothing)'
    return 0
  }
  printf '%s\n' "$1" | awk -v withheld="$WITHHELD_URL" '
    BEGIN {
      quote = sprintf("%c", 39)
      lead = "\"([{<" quote
      trail = "\")]}>,.;:" quote
    }
    function is_safe(t) {
      return t ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\/([A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]+)?(\/[^@]*)?$/
    }
    function without_userinfo(t,   mark, scheme, rest, host, tail) {
      mark = index(t, "://")
      if (mark == 0) return ""
      scheme = substr(t, 1, mark + 2)
      rest = substr(t, mark + 3)
      host = rest
      if (index(host, "/") > 0) host = substr(host, 1, index(host, "/") - 1)
      tail = substr(rest, length(host) + 1)
      if (index(host, "@") == 0) return ""
      sub(/^.*@/, "", host)
      return scheme host tail
    }
    function render(t,   rebuilt) {
      if (is_safe(t)) return t
      rebuilt = without_userinfo(t)
      if (rebuilt != "" && is_safe(rebuilt)) return rebuilt
      return withheld
    }
    function token(x,   pre, post, core, c) {
      if (index(x, "://") == 0 && index(x, "@") == 0) return x
      core = x
      pre = ""
      post = ""
      while (length(core) > 0) {
        c = substr(core, 1, 1)
        if (index(lead, c) == 0) break
        pre = pre c
        core = substr(core, 2)
      }
      while (length(core) > 0) {
        c = substr(core, length(core), 1)
        if (index(trail, c) == 0) break
        post = c post
        core = substr(core, 1, length(core) - 1)
      }
      return pre render(core) post
    }
    {
      n = split($0, words, / /)
      out = ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? " " : "") token(words[i])
      print out
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

  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository, so there is no head to attest."
  command -v no-mistakes >/dev/null 2>&1 || fail pipeline-tool-missing \
    "no-mistakes is not on PATH, so its run record cannot be read." \
    "That is a missing tool rather than a missing run: install it and re-run."

  head=$(git rev-parse --verify HEAD 2>/dev/null) || fail head-unresolvable \
    "HEAD does not resolve to a commit, so there is nothing to attest yet." \
    "Commit this work, validate it, then attest the head the pipeline pushes."
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || fail head-detached \
    "HEAD is not on a branch, and a run record is attributed to one." \
    "Check out the branch the pipeline validated and attest from there."
  [ "$branch" != HEAD ] || fail head-detached \
    "HEAD is detached, and a run record is attributed to a branch." \
    "Check out the branch the pipeline validated and attest from there."

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
    || fail scratch-file-unavailable \
      "Could not create a temporary file to capture the pipeline tool's stderr." \
      "Check TMPDIR and its free space, then re-run."
  status_rc=0
  if [ -n "$run_id" ]; then
    status=$(fm_nm_run_bounded . "$NM_TIMEOUT" axi status --run "$run_id" 2>"$status_err_file") || status_rc=$?
  else
    status=$(fm_nm_run_bounded . "$NM_TIMEOUT" axi status 2>"$status_err_file") || status_rc=$?
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

  # The run record is read through bin/fm-nm-run-lib.sh, the one owner of this
  # tool's output shape, so a change to that shape moves every reader at once
  # instead of leaving this one refusing what the others still understand. Every
  # token it yields is re-checked below, because this is tool output rather than
  # input the note format may inherit unchecked.
  run_field=$(fm_nm_strip_quotes "$(fm_nm_field "$status" id)")
  branch_field=$(fm_nm_strip_quotes "$(fm_nm_field "$status" branch)")
  head_field=$(fm_nm_strip_quotes "$(fm_nm_field "$status" head)")
  gates=
  while IFS= read -r step; do
    is_gate_name "$step" || continue
    list_has "$step" "$gates" && continue
    gates="$gates $step"
  done <<EOF
$(fm_nm_completed_steps "$status")
EOF

  is_run_id "$run_field" || refuse run-record-unparsed \
    "no-mistakes wrote a run record to stdout, but no run identity could be read from it." \
    "Its stdout: $status" \
    "Its stderr: ${status_err:-(nothing)}" \
    "Its stdout was not empty, so this is not an absent run: either that output is not a run record, or its shape changed and this transcription needs updating."
  [ "$branch_field" = "$branch" ] || refuse run-covers-another-branch \
    "The most recent pipeline run covers branch '$branch_field', not '$branch'." \
    "Attest from the branch that run validated, or name the run with --run <id>."

  # The run record abbreviates the head it pushed, and the pipeline's own fix
  # commits routinely advance that tip past the local HEAD, so a run tip ahead of
  # HEAD on the same history is the normal state rather than a stale record.
  # fm_nm_head_matches_worktree owns that directional rule for every caller that
  # has to decide whether a run belongs to a worktree: equal matches, HEAD an
  # ancestor of the run tip matches, and a run tip behind or beside HEAD does
  # not. The note is then bound to the commit that run validated, which is the
  # head the pipeline pushed and therefore the head the gate reads; binding it to
  # a HEAD the run has already moved past would publish a note for a commit no
  # pull request is open on.
  is_short_sha "$head_field" || refuse run-record-no-head \
    "no-mistakes reported run $run_field, but no usable head commit could be read from that record." \
    "Its stdout: $status" \
    "That is a record this transcription cannot read rather than a branch that diverged from it: nothing here says this branch carries uncovered work, so re-validating it would report the same." \
    "Either that output is not a run record, or its shape changed and this transcription needs updating."
  attest_head=$(git rev-parse --verify --quiet "$head_field^{commit}" 2>/dev/null) \
    || refuse run-head-unavailable \
      "The pipeline run validated $head_field, which is not a commit in this checkout." \
      "That is a commit this repository does not have rather than one it has not validated." \
      "Fetch the branch the pipeline pushed so that commit is present, then attest again."
  fm_nm_head_matches_worktree . "$head_field" || refuse run-covers-another-head \
    "The pipeline run validated $attest_head, but HEAD is $head, which that run does not cover." \
    "HEAD is neither that commit nor an ancestor of it, so this branch carries work the run never saw, or its tip was rewritten." \
    "Validate this branch again and attest the head that run pushes."

  missing=
  for gate in $REQUIRED_GATES; do
    list_has "$gate" "$gates" && continue
    missing="$missing $gate"
  done
  [ -z "$missing" ] || refuse run-incomplete \
    "The pipeline run for $attest_head has not completed:$missing." \
    "Required steps: $REQUIRED_GATES."

  tool=$(fm_nm_run_bounded . "$NM_TIMEOUT" --version 2>/dev/null | awk 'NR == 1 { print $3; exit }')
  is_tool_token "$tool" || tool=unknown

  gates_csv=$(printf '%s' "${gates# }" | tr ' ' ',')
  payload=$(printf '%s: %s\nhead: %s\nrun: %s\ngates: %s\ntool: %s\n' \
    "$ATTESTATION_KEY" "$ATTESTATION_VERSION" "$attest_head" "$run_field" "$gates_csv" "no-mistakes/$tool")

  # Refuse to publish anything this repository's own gate would reject, so a
  # malformed note can never reach the forge and be discovered only in CI.
  verify_note_payload "$attest_head" "$payload"

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
  #
  # That repository is named in everything this prints, because "published to
  # origin" does not say which repository was reached and the note is evidence
  # only on the one holding the pull request head. Credentials a URL embeds are
  # stripped from the name, and git's own text is redacted rather than withheld,
  # so the reason a remote refused still reaches the person who has to act on it.
  push_target=$remote
  if [ "$push" -eq 1 ]; then
    push_url=$(git remote get-url --push "$remote" 2>/dev/null) || push_url=$remote
    push_target=$(credential_safe_text "$push_url")
    incoming_ref="$notes_ref-incoming"
    # Absence and unreadability are two different answers and only one of them is
    # a fact about the attestations there. A push target with no
    # refs/notes/no-mistakes has nothing to reconcile against; a push target that
    # cannot be read at all has told us nothing, so it stops the command before
    # anything is recorded. git ls-remote --exit-code reports the first as exit 2
    # and everything else as a failure, which is the same line the gate draws
    # when it fetches this ref.
    ls_rc=0
    ls_err=$(git ls-remote --exit-code "$push_url" "$notes_ref" 2>&1 >/dev/null) || ls_rc=$?
    case "$ls_rc" in
      0)
        fetch_rc=0
        fetch_err=$(git fetch --quiet --no-tags --force "$push_url" "$notes_ref:$incoming_ref" 2>&1 >/dev/null) \
          || fetch_rc=$?
        [ "$fetch_rc" -eq 0 ] || fail push-target-unfetchable \
          "$push_target, the push target of $remote, advertises $notes_ref but would not serve it." \
          "git said: $(credential_safe_text "$fetch_err")" \
          "Resolve that and re-run; nothing was recorded."
        merge_rc=0
        merge_err=$(git notes --ref="$notes_ref" merge -s ours "$incoming_ref" 2>&1 >/dev/null) \
          || merge_rc=$?
        [ "$merge_rc" -eq 0 ] || fail attestation-not-reconciled \
          "Could not reconcile the local $notes_ref with the one on $push_target, the push target of $remote." \
          "git said: $(credential_safe_text "$merge_err")" \
          "Resolve that and re-run; nothing was recorded."
        git update-ref -d "$incoming_ref" 2>/dev/null || true
        ;;
      2) ;;
      *)
        fail push-target-unreadable \
          "Could not read $notes_ref from $push_target, the push target of $remote (git exit $ls_rc)." \
          "git said: $(credential_safe_text "$ls_err")" \
          "That is a repository this could not read rather than one with no attestations, so nothing was recorded." \
          "Check access to it, or name another with --remote <name>, then re-run."
        ;;
    esac
  fi
  notes_err=$(git notes --ref="$notes_ref" add -f -m "$payload" "$attest_head" 2>&1 >/dev/null) \
    || fail attestation-not-recorded \
      "Could not record the attestation note on $attest_head." \
      "git said: $(credential_safe_text "$notes_err")"
  if [ "$attest_head" != "$head" ]; then
    printf 'fm-attest: the run tip is ahead of HEAD %s, as the pipeline advances it with its own fix commits\n' "$head"
  fi
  printf 'fm-attest: recorded %s for %s\n' "$notes_ref" "$attest_head"

  [ "$push" -eq 1 ] || return 0
  push_rc=0
  push_err=$(git push --quiet "$remote" "$notes_ref:$notes_ref" 2>&1 >/dev/null) || push_rc=$?
  [ "$push_rc" -eq 0 ] || fail attestation-not-published \
    "Could not publish $notes_ref to $push_target, the push target of $remote." \
    "git said: $(credential_safe_text "$push_err")" \
    "Any credential in that text is redacted, and a line that still carried one is replaced by a notice rather than shown." \
    "The attestation is evidence only on the repository holding the pull request head, so name that one with --remote <name> if this is not it, or re-run to reconcile if its $notes_ref moved since."
  printf 'fm-attest: published %s to %s (the push target of %s)\n' "$notes_ref" "$push_target" "$remote"
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
  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository."
  sha=$(git rev-parse --verify "$commit^{commit}" 2>/dev/null) || fail commit-unknown \
    "No such commit in this repository: $commit"
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
