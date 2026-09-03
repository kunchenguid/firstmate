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
#   <verified|unverified|contradicted>
#   <sha256 of the exact claim line the verdict judged>
#   <epoch seconds when it was established>
#   <single-line reason>
# The claim hash binds a verdict to one exact claim, so appending a new `done:`
# line invalidates the old verdict instead of inheriting it.
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

# The last `done:` line in a status log, or empty. A status log is an
# append-only event log, so the newest claim is the one under test; earlier
# claims were superseded by whatever the worker did next.
#
# This runs per task on every current-state read and every session-start digest,
# so the leading-verb test is only paid for by lines that could possibly carry
# it. `status_line_verb` costs a fork per call, and a line whose verb is `done`
# always begins with `done` after its leading whitespace - a correlation token
# or a `[key=...]` only ever follows the verb word - so the fork-free prefix
# test below is exact, not an approximation, and skips it for every other line.
fm_done_claim_last() {  # <status-file>
  local f=${1:-} line trimmed last=
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in done*) ;; *) continue ;; esac
    [ "$(status_line_verb "$line")" = "done" ] || continue
    last=$line
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

# 0 when a durable record already establishes THIS exact claim as verified. Run
# in a subshell so reading it does not clobber a caller's FM_DONE_VERDICT* view.
_fm_done_verdict_already_verified() {  # <state> <task-id> <claim-hash>
  (
    fm_done_verdict_read "$1" "$2" || exit 1
    [ "$FM_DONE_VERDICT" = verified ] || exit 1
    [ "$FM_DONE_VERDICT_CLAIM_HASH" = "$3" ] || exit 1
  )
}

# Write the durable verdict record, with one refusal: an `unverified` verdict
# never overwrites a record that already establishes the SAME claim as
# `verified`. Unverified is only the absence of evidence - a forge that could
# not be reached, a tool missing from PATH - so letting it overwrite would let a
# transient outage un-establish work that was genuinely established. A
# `contradicted` verdict still overwrites, because that is positive evidence of
# falsity. The refusal protects only the DURABLE record: the run that observed
# the transient unverified result still prints and exits with it (see finish()
# in bin/fm-verify-done.sh), so nothing hides the outage from its caller.
# Returns 0 for that refusal, because the record already holds a stronger
# verdict for this claim and there is nothing left to record.
fm_done_verdict_write() {  # <state> <task-id> <verdict> <claim-hash> <reason>
  local state=$1 id=$2 verdict=$3 hash=$4 reason=$5 path tmp
  case "$verdict" in verified|unverified|contradicted) ;; *) return 2 ;; esac
  case "$hash" in *[!0-9a-f]*|'') return 2 ;; esac
  [ "${#hash}" -eq 64 ] || return 2
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  if [ "$verdict" = unverified ] && _fm_done_verdict_already_verified "$state" "$id" "$hash"; then
    return 0
  fi
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
  case "$verdict" in verified|unverified|contradicted) ;; *) return 1 ;; esac
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
#   none          the task has made no terminal claim; nothing to verify.
#   verified      a matching verdict record establishes the claim.
#   unverified    the claim cannot be established: no commit identity (every
#                 legacy claim), no verdict yet, a verdict for a superseded
#                 claim, or a verifier that could not reach its sources.
#   contradicted  the claim was established and is false.
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
