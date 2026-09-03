#!/usr/bin/env bash
# Single owner of the terminal-claim grammar and its durable verdict record.
#
# Why this exists: a worker's `done:` line used to be free prose ("done: PR
# <url> checks green"). It carried no commit identity, so nothing could check
# that the commit a pipeline validated was the commit the PR actually shipped,
# and nothing could notice when a PR that a task called done was later closed
# without merging. A claim is now required to name the exact object it is
# claiming, and a separate verifier (bin/fm-verify-done.sh) establishes that
# claim against the forge, git, and the validation run before anything in the
# fleet may treat the task as done.
#
# Grammar (this file is the one owner; bin/fm-dod-lib.sh and bin/fm-brief.sh
# render the worker-facing instruction from fm_done_claim_template):
#
#   no-mistakes / direct-PR   done: pr=<url> head=<full-sha> - <one line>
#   local-only                done: branch=fm/<id> head=<full-sha> - <one line>
#   scout                     done: report=<path> - <one line>
#
# The parser is field-based and separator-agnostic: it reads whitespace-
# delimited `key=value` tokens out of the claim's note and ignores everything
# else, so prose around them, a plain or an em dash, and legacy free-prose
# claims all parse without special cases. A legacy claim simply yields no
# identity fields, which is exactly the "cannot establish" input the verdict
# rules below turn into `unverified`, never into a pass.
#
# Verdict record: state/<id>.done-verdict, five lines,
#   fm-done-verdict-v1
#   <verified|unverified|contradicted|stale>
#   <sha256 of the exact claim line the verdict judged>
#   <epoch seconds when it was established>
#   <single-line reason>
# The claim hash binds a verdict to one exact claim, so appending a new `done:`
# line invalidates the old verdict instead of inheriting it, and a later
# `failed:` line withdraws the claim entirely (see fm_done_claim_last).
#
# THE THREE SHAPES OF TERMINAL EVIDENCE. Evidence about a standing claim comes in
# three shapes, not two, and conflating the third with the first is what let a
# `done` record survive the close of its own PR:
#
#   1. Absence of evidence - we could not check. The forge was unreachable, a
#      tool was off PATH, a reflog had been pruned, a validation run had aged
#      out. The world has not changed; we simply failed to look. This must NEVER
#      downgrade a standing verdict. It is `unverified`.
#   2. Positive evidence of falsity - we looked and the claim is false. The PR
#      was closed without merging. This is `contradicted`, and it overwrites
#      anything.
#   3. The world changed - the PR merged, possibly at a head nobody verified.
#      The standing verdict is neither wrong nor still valid: it is a true
#      statement about a world that no longer exists. This is `stale`, a
#      distinct third state. The rule protecting a record from an outage was
#      written for shape 1; it was never meant to preserve a verdict about a
#      superseded world.
#
# `stale` is not established. Every consumer treats it the way it treats
# `unverified` - bin/fm-crew-state.sh reports `done-unverified`, and
# bin/fm-teardown.sh's record-first gate re-runs the verifier rather than
# passing on it, which is the point: the expensive check is deferred to the gate
# that actually needs the answer. The write precedence that keeps the three
# apart is stated once, on fm_done_verdict_write below.
#
# Read-only apart from fm_done_verdict_write. Sourced by bin/fm-verify-done.sh,
# bin/fm-crew-state.sh, bin/fm-teardown.sh, bin/fm-dod-lib.sh, bin/fm-brief.sh
# and tests; no side effects on source.

# Public results every sourcing consumer reads.
FM_DONE_CLAIM_PR=
FM_DONE_CLAIM_HEAD=
FM_DONE_CLAIM_BRANCH=
FM_DONE_CLAIM_REPORT=
FM_DONE_CLAIM_LINE=
FM_DONE_CLAIM_STATE=
FM_DONE_CLAIM_REASON=
FM_DONE_VERDICT=
FM_DONE_VERDICT_CLAIM_HASH=
FM_DONE_VERDICT_EPOCH=
FM_DONE_VERDICT_REASON=

FM_DONE_VERDICT_VERSION=fm-done-verdict-v1

# status_line_verb / status_line_note are the one owner of leading-verb and
# note extraction, so this file borrows them rather than re-deriving the shape.
# Guarded so a consumer that already sourced the classifier is not re-sourced,
# while one that only wants fm_done_claim_template still gets a working lib.
if ! declare -F status_line_verb >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"
fi

# The worker-facing claim shape for a delivery mode. Rendered verbatim into a
# brief, so the grammar the worker is told to use and the grammar the parser
# accepts cannot drift.
fm_done_claim_template() {  # <no-mistakes|direct-PR|local-only|scout> <task-id>
  case "$1" in
    no-mistakes|direct-PR) printf 'done: pr={url} head={full-sha} - {one line}' ;;
    local-only)            printf 'done: branch=fm/%s head={full-sha} - {one line}' "$2" ;;
    scout)                 printf 'done: report={path} - {one line}' ;;
    *) return 1 ;;
  esac
}

# 0 when $1 is a full 40-character hex object name. The claim must carry the
# exact commit, not an abbreviation: an abbreviation cannot be compared against
# a forge head without resolving it somewhere, and "somewhere" is the ambiguity
# this whole contract exists to remove.
fm_done_claim_head_valid() {  # <value>
  case "${1:-}" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# Parse a status line as a terminal claim. Returns 1 for any line that is not a
# `done:` line; sets the four identity fields (empty when absent) otherwise.
fm_done_claim_parse() {  # <status-line>
  local line=${1:-} note token noglob=off
  FM_DONE_CLAIM_PR=
  FM_DONE_CLAIM_HEAD=
  FM_DONE_CLAIM_BRANCH=
  FM_DONE_CLAIM_REPORT=
  [ -n "$line" ] || return 1
  [ "$(status_line_verb "$line")" = "done" ] || return 1
  note=$(status_line_note "$line")
  # The note is arbitrary worker prose, so splitting it must not also glob it:
  # an unquoted `*.md` in a summary would otherwise expand against whatever
  # directory the caller happens to be in. The caller's own setting is restored.
  case $- in *f*) noglob=on ;; esac
  set -f
  for token in $note; do
    case "$token" in
      pr=*)     [ -n "$FM_DONE_CLAIM_PR" ]     || FM_DONE_CLAIM_PR=${token#pr=} ;;
      head=*)   [ -n "$FM_DONE_CLAIM_HEAD" ]   || FM_DONE_CLAIM_HEAD=${token#head=} ;;
      branch=*) [ -n "$FM_DONE_CLAIM_BRANCH" ] || FM_DONE_CLAIM_BRANCH=${token#branch=} ;;
      report=*) [ -n "$FM_DONE_CLAIM_REPORT" ] || FM_DONE_CLAIM_REPORT=${token#report=} ;;
    esac
  done
  [ "$noglob" = on ] || set +f
  return 0
}

# 0 when the parsed claim names something a machine can check: a full commit
# for ship work, or a report path for a scout. A legacy free-prose claim has
# neither and is the "no commit identity" case throughout.
fm_done_claim_has_identity() {
  fm_done_claim_head_valid "$FM_DONE_CLAIM_HEAD" && return 0
  [ -n "$FM_DONE_CLAIM_REPORT" ]
}

# The task's STANDING terminal claim, or empty when it has none. A status log is
# an append-only event log, so the newest `done:` is the one under test; earlier
# claims were superseded by whatever the worker did next.
#
# A later `failed:` line WITHDRAWS the claim, and the task then has none. Two
# things have to be true of that line, and the second is an AUTHORITY rule, not a
# formatting one.
#
# WHAT may retract: only `failed:`. `blocked:` and `needs-decision:` must not,
# because they say the work is ongoing, not that the assertion is withdrawn, and
# a task sitting on a claim it still makes should stay refused while it is merely
# stuck.
#
# WHO may retract: only the task speaking for itself, which means the line must
# carry no correlation token and no routed `[key=...]`. A decorated line is a
# SUB-EVENT - one routed phase, or one child's outcome - and a sub-event has no
# authority over the task's own terminal assertion. This is not hypothetical
# tidiness: bin/fm-brief.sh instructs workers to close routed phases with keyed
# lines, and report_child_ledger_locked publishes `failed [key=child-outcome-...]`
# into a PARENT home's status through bin/fm-parent-channel-lib.sh, so without
# this a child's failure would retract its mate task's own claim. Do not
# "simplify" this back to any-failed-line: the point is who is speaking.
#
# Why the rule exists at all, so it is not "simplified" back: without it a task
# whose PR was abandoned is held forever to an assertion it has already
# disowned - the claim gate refuses, and the only remaining instrument is
# `--force`, which AGENTS.md ties to explicit discard authority. Nothing is
# weakened by letting honesty out: a task that still CLAIMS done cannot be
# cleaned up on a false claim, and unlanded work stays protected by teardown's
# own landed-work gates, which are separate and untouched. The point of the shape
# is which exit it puts within reach. Make the way out of a false claim
# withdrawing it and people withdraw it; make it force and they learn to reach
# for force.
#
# This runs per task on every current-state read and every session-start digest,
# so the leading-verb test is only paid for by lines that could possibly carry
# one of the two verbs. `status_line_verb` costs a fork per call, and a line
# whose verb is `done` or `failed` always begins with that word after its leading
# whitespace - a correlation token or a `[key=...]` only ever follows the verb
# word - so the fork-free prefix test below is exact, not an approximation, and
# skips it for every other line.
fm_done_claim_last() {  # <status-file>
  local f=${1:-} line trimmed last=
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      done*)
        [ "$(status_line_verb "$line")" = "done" ] || continue
        last=$line
        ;;
      failed*)
        # Compared BEFORE any decoration is stripped, which is the authority test
        # itself: status_line_verb reads through a `[key=...]` and through a
        # correlation token, so a sub-event's verb is `failed` too. Only a line
        # whose whole prefix is the bare verb is the task speaking for itself.
        [ "${trimmed%%:*}" = "failed" ] || continue
        last=
        ;;
    esac
  done < "$f"
  printf '%s' "$last"
}

fm_done_claim_hash() {  # <claim-line>
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "${1:-}" | shasum -a 256 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "${1:-}" | sha256sum 2>/dev/null) || return 1
  else
    return 1
  fi
  out=${out%% *}
  case "$out" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out"
}

fm_done_verdict_path() {  # <state> <task-id>
  printf '%s/%s.done-verdict' "$1" "$2"
}

# Collapse a reason to one printable line: the record is line-structured, so a
# newline or tab in a reason would silently reshape it.
fm_done_reason_clean() {  # <reason>
  printf '%s' "${1:-}" | LC_ALL=C tr '\n\t\r' '   ' | cut -c1-400
}

# Decide the verdict a caller may actually record, given what it observed. This
# is the one rule the whole done-claim contract rests on, held in the vocabulary's
# owner rather than in each judging site's head:
#
#   `contradicted` means POSITIVE EVIDENCE of falsity. Absence of evidence is
#   `unverified` - never contradicted, and never a pass.
#
# So a contradiction has to CARRY the observation it contradicts with: the branch
# tip actually read, the head the forge actually reported, the commit the
# validation run actually recorded. A caller asking for `contradicted` with
# nothing observed is recording falsity it did not establish, so this downgrades
# it to `unverified` whatever it asked for. Results land in
# FM_DONE_VERDICT_RESOLVED and FM_DONE_VERDICT_RESOLVED_REASON.
#
# The limit of the guard, named so no reader assumes it is total: it stops a site
# that observed NOTHING from recording falsity. It cannot stop a site that
# observed something real and drew the WRONG INFERENCE from it. The merge-base
# test bin/fm-verify-done.sh once used for local-only work was of that second
# kind - a merge base equal to the branch tip is a true observation that was
# simply the wrong invariant for landed work, and it would pass this guard
# untouched. Only reading an arm's reasoning catches that class.
FM_DONE_VERDICT_RESOLVED=
FM_DONE_VERDICT_RESOLVED_REASON=
fm_done_verdict_resolve() {  # <verdict> <reason> [<observed>]
  local verdict=${1:-} reason=${2:-} observed=${3:-}
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_DONE_VERDICT_RESOLVED=$verdict
  # shellcheck disable=SC2034
  FM_DONE_VERDICT_RESOLVED_REASON=$reason
  [ "$verdict" = contradicted ] || return 0
  [ -z "$observed" ] || return 0
  # shellcheck disable=SC2034
  FM_DONE_VERDICT_RESOLVED=unverified
  # shellcheck disable=SC2034
  FM_DONE_VERDICT_RESOLVED_REASON="nothing was observed that contradicts the claim, so it is not established either way: $reason"
}

# The verdict a durable record currently holds for THIS exact claim, or empty
# when no record stands for it. Run in a subshell so reading it does not clobber
# a caller's FM_DONE_VERDICT* view.
_fm_done_verdict_standing() {  # <state> <task-id> <claim-hash>
  (
    fm_done_verdict_read "$1" "$2" || exit 0
    [ "$FM_DONE_VERDICT_CLAIM_HASH" = "$3" ] || exit 0
    printf '%s' "$FM_DONE_VERDICT"
  )
}

# Write the durable verdict record, subject to the write precedence stated at
# the top of this file: an incoming verdict never replaces a standing one that
# says something stronger about the SAME claim.
#
#   contradicted  always written. Positive evidence of falsity outranks
#                 everything, including a `verified` established earlier.
#   verified      always written. It is the verifier's fresh look at the world.
#   stale         written unless the standing record is already `contradicted`,
#                 which is the stronger statement. Stale says the world moved
#                 past what was established, not that the claim was false.
#   unverified    written only when nothing stands for this claim, or what
#                 stands is itself `unverified`. Absence of evidence is not
#                 evidence: a forge that could not be reached or a tool missing
#                 from PATH must never un-establish, un-contradict, or un-stale
#                 a record, because the world did not change - we failed to look.
#
# The precedence protects only the DURABLE record: the run that observed the
# refused verdict still prints and exits with it (see finish() in
# bin/fm-verify-done.sh), so nothing hides an outage from its caller. A refusal
# returns 0, because the record already holds the stronger verdict for this
# claim and there is nothing left to record.
fm_done_verdict_write() {  # <state> <task-id> <verdict> <claim-hash> <reason>
  local state=$1 id=$2 verdict=$3 hash=$4 reason=$5 path tmp standing
  case "$verdict" in verified|unverified|contradicted|stale) ;; *) return 2 ;; esac
  case "$hash" in *[!0-9a-f]*|'') return 2 ;; esac
  [ "${#hash}" -eq 64 ] || return 2
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  standing=$(_fm_done_verdict_standing "$state" "$id" "$hash")
  case "$verdict" in
    unverified)
      case "$standing" in ''|unverified) ;; *) return 0 ;; esac
      ;;
    stale)
      [ "$standing" != contradicted ] || return 0
      ;;
  esac
  path=$(fm_done_verdict_path "$state" "$id")
  [ ! -L "$path" ] || return 1
  umask 077
  tmp=$(mktemp "$state/.fm-done-verdict.XXXXXX") || return 1
  {
    printf '%s\n' "$FM_DONE_VERDICT_VERSION"
    printf '%s\n' "$verdict"
    printf '%s\n' "$hash"
    printf '%s\n' "$(date +%s)"
    printf '%s\n' "$(fm_done_reason_clean "$reason")"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
}

# Read a verdict record. Returns 1 when it is absent, unreadable, or malformed;
# a malformed record is never partially trusted.
fm_done_verdict_read() {  # <state> <task-id>
  local path version verdict hash epoch reason _extra
  FM_DONE_VERDICT=
  FM_DONE_VERDICT_CLAIM_HASH=
  FM_DONE_VERDICT_EPOCH=
  FM_DONE_VERDICT_REASON=
  path=$(fm_done_verdict_path "$1" "$2")
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 1
  exec 7< "$path" || return 1
  IFS= read -r version <&7 || { exec 7<&-; return 1; }
  IFS= read -r verdict <&7 || { exec 7<&-; return 1; }
  IFS= read -r hash <&7 || { exec 7<&-; return 1; }
  IFS= read -r epoch <&7 || { exec 7<&-; return 1; }
  IFS= read -r reason <&7 || reason=
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$version" = "$FM_DONE_VERDICT_VERSION" ] || return 1
  case "$verdict" in verified|unverified|contradicted|stale) ;; *) return 1 ;; esac
  case "$hash" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#hash}" -eq 64 ] || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  FM_DONE_VERDICT=$verdict
  FM_DONE_VERDICT_CLAIM_HASH=$hash
  # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
  FM_DONE_VERDICT_EPOCH=$epoch
  FM_DONE_VERDICT_REASON=$reason
}

# THE predicate every consumer asks: for this task's current terminal claim,
# what has actually been established? Sets FM_DONE_CLAIM_LINE (the claim under
# test, empty when the task has never claimed done), FM_DONE_CLAIM_STATE, and
# FM_DONE_CLAIM_REASON, plus the parsed claim fields.
#
#   none          the task has no standing terminal claim: it never made one, or
#                 it made one and a later `failed:` line withdrew it.
#   verified      a matching verdict record establishes the claim.
#   unverified    the claim cannot be established: no commit identity (every
#                 legacy claim), no verdict yet, a verdict for a superseded
#                 claim, or a verifier that could not reach its sources.
#   contradicted  the claim was established and is false.
#   stale         the claim was established, and its PR then reached a terminal
#                 state the establishment did not cover. Not established: the
#                 verdict is a true statement about a superseded world.
#
# Pure read; returns 0 whatever the outcome, so a caller branches on the state
# rather than on an exit code.
fm_done_claim_status() {  # <state> <task-id>
  local state=$1 id=$2 hash
  FM_DONE_CLAIM_LINE=
  FM_DONE_CLAIM_STATE=none
  FM_DONE_CLAIM_REASON=
  FM_DONE_CLAIM_LINE=$(fm_done_claim_last "$state/$id.status")
  [ -n "$FM_DONE_CLAIM_LINE" ] || return 0
  fm_done_claim_parse "$FM_DONE_CLAIM_LINE" || return 0
  if ! fm_done_claim_has_identity; then
    FM_DONE_CLAIM_STATE=unverified
    FM_DONE_CLAIM_REASON='legacy claim, no commit identity'
    return 0
  fi
  if ! hash=$(fm_done_claim_hash "$FM_DONE_CLAIM_LINE"); then
    FM_DONE_CLAIM_STATE=unverified
    FM_DONE_CLAIM_REASON='claim identity could not be computed (no sha256 tool)'
    return 0
  fi
  if ! fm_done_verdict_read "$state" "$id"; then
    FM_DONE_CLAIM_STATE=unverified
    FM_DONE_CLAIM_REASON="not verified yet; run bin/fm-verify-done.sh $id"
    return 0
  fi
  if [ "$FM_DONE_VERDICT_CLAIM_HASH" != "$hash" ]; then
    FM_DONE_CLAIM_STATE=unverified
    FM_DONE_CLAIM_REASON="recorded verdict judged an earlier claim; re-run bin/fm-verify-done.sh $id"
    return 0
  fi
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_DONE_CLAIM_STATE=$FM_DONE_VERDICT
  # shellcheck disable=SC2034
  FM_DONE_CLAIM_REASON=$FM_DONE_VERDICT_REASON
}
