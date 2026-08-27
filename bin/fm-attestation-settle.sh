#!/usr/bin/env bash
# fm-attestation-settle.sh - settle the PR body the no-mistakes gate judges.
#
# GitHub snapshots the pull request body into the `synchronize` event payload at
# push time. no-mistakes pushes the branch first and only rewrites the body with
# the attestation for the new head a couple of minutes later, so the snapshot
# the gate would otherwise judge still carries the previous head's attestation.
# Every synchronize run therefore failed with "Pipeline attestation head_sha
# does not match the current PR head" and only the following `edited` run
# passed, leaving a permanent red check beside the green one.
#
# This reads the live PR body instead of that snapshot, retrying until the
# body's v1 attestation binds to the pushed head or the attempts run out, then
# prints the body it settled on. It renders no verdict: the pinned
# require-no-mistakes action stays the only thing that can pass or fail the
# gate, so a genuinely unattested push still fails, just after the wait. A body
# that could never be read prints nothing, which sends the action back to its
# event-payload default.
#
# Usage:
#   fm-attestation-settle.sh --repo <owner/name> --pr <number> --head <sha>
#                            [--attempts <n>] [--interval-seconds <n>]
#                            [--output-name <name>]
#   fm-attestation-settle.sh --help
#
# Attempts default to 31 reads 10s apart (about five minutes). With GITHUB_OUTPUT
# set, the settled body is also appended as the named step output (default
# "body") behind a random heredoc delimiter proven absent from the body.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-attestation-settle.sh"

ATTESTATION_PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '
ATTESTATION_CLOSING=' -->'

usage() {
  sed -n '2,28{s/^# \{0,1\}//;p;}' "$SELF"
}

die() {
  printf 'fm-attestation-settle.sh: %s\n' "$*" >&2
  exit 2
}

note() {
  printf 'fm-attestation-settle.sh: %s\n' "$*" >&2
}

REPO=
PR=
HEAD=
ATTEMPTS=31
INTERVAL=10
OUTPUT_NAME=body

require_value() {
  [ "$2" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) require_value --repo "$#"; REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#*=}; shift ;;
    --pr) require_value --pr "$#"; PR=$2; shift 2 ;;
    --pr=*) PR=${1#*=}; shift ;;
    --head) require_value --head "$#"; HEAD=$2; shift 2 ;;
    --head=*) HEAD=${1#*=}; shift ;;
    --attempts) require_value --attempts "$#"; ATTEMPTS=$2; shift 2 ;;
    --attempts=*) ATTEMPTS=${1#*=}; shift ;;
    --interval-seconds) require_value --interval-seconds "$#"; INTERVAL=$2; shift 2 ;;
    --interval-seconds=*) INTERVAL=${1#*=}; shift ;;
    --output-name) require_value --output-name "$#"; OUTPUT_NAME=$2; shift 2 ;;
    --output-name=*) OUTPUT_NAME=${1#*=}; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$REPO" ] || die "--repo <owner/name> is required"
[ -n "$PR" ] || die "--pr <number> is required"
[ -n "$HEAD" ] || die "--head <sha> is required"
case "$ATTEMPTS" in ''|*[!0-9]*) die "--attempts must be a non-negative integer" ;; esac
case "$INTERVAL" in ''|*[!0-9]*) die "--interval-seconds must be a non-negative integer" ;; esac
[ "$ATTEMPTS" -ge 1 ] || die "--attempts must be at least 1"

# Echo the head_sha the body's v1 attestation binds to, or fail when the body
# carries no parseable attestation. Deliberately narrow: this decides only when
# to stop waiting, never whether the body is compliant.
attested_head() {
  local body=$1 payload rest
  case "$body" in *"$ATTESTATION_PREFIX"*) ;; *) return 1 ;; esac
  payload=${body#*"$ATTESTATION_PREFIX"}
  case "$payload" in *"$ATTESTATION_CLOSING"*) ;; *) return 1 ;; esac
  payload=${payload%%"$ATTESTATION_CLOSING"*}
  case "$payload" in *'"head_sha"'*) ;; *) return 1 ;; esac
  rest=${payload#*'"head_sha"'}
  rest=${rest#*:}
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in '"'*) ;; *) return 1 ;; esac
  rest=${rest#'"'}
  printf '%s\n' "${rest%%'"'*}"
}

read_body() {
  gh api "repos/$REPO/pulls/$PR" --jq '.body // ""' 2>/dev/null
}

BODY=
READ_ANY=0
SETTLED=0
attempt=1
GH_MISSING=0
if ! command -v gh >/dev/null 2>&1; then
  # Nothing to read the live body with; do not burn the whole wait rediscovering
  # that on every attempt.
  GH_MISSING=1
  ATTEMPTS=0
fi
while [ "$attempt" -le "$ATTEMPTS" ]; do
  if current=$(read_body); then
    BODY=$current
    READ_ANY=1
    if bound=$(attested_head "$BODY") && [ "$bound" = "$HEAD" ]; then
      SETTLED=1
      break
    fi
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -le "$ATTEMPTS" ] || break
  [ "$INTERVAL" -eq 0 ] || sleep "$INTERVAL"
done

if [ "$SETTLED" -eq 1 ]; then
  note "PR #$PR body attestation binds to $HEAD after $attempt read(s)."
elif [ "$READ_ANY" -eq 1 ]; then
  note "PR #$PR body attestation still does not bind to $HEAD after $ATTEMPTS read(s); judging the body as it stands."
elif [ "$GH_MISSING" -eq 1 ]; then
  note "gh is not installed; leaving the gate on its event-payload default."
else
  note "could not read the PR #$PR body; leaving the gate on its event-payload default."
fi

emit_github_output() {
  local file=${GITHUB_OUTPUT:-} delim
  [ -n "$file" ] || return 0
  # The body is author-controlled, so the delimiter must be one it cannot
  # contain: draw a random one and redraw until the body does not carry it.
  while :; do
    delim="FM_ATTESTATION_BODY_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    case "$BODY" in *"$delim"*) continue ;; *) break ;; esac
  done
  {
    printf '%s<<%s\n' "$OUTPUT_NAME" "$delim"
    printf '%s\n' "$BODY"
    printf '%s\n' "$delim"
  } >>"$file"
}

emit_github_output
printf '%s\n' "$BODY"
