#!/usr/bin/env bash
# fm-pr-body-settled.sh - print the pull request body the no-mistakes gate judges.
#
# The gate's verdict is a pure function of the PR body plus the PR head commit,
# and no-mistakes publishes the body's head-bound attestation only AFTER it has
# pushed that head. A workflow that judges its own `pull_request` event payload
# is therefore judging a body snapshot taken before the attestation for the
# pushed head could exist, so the `synchronize` run of every pipeline push fails
# on a body that was simply not written yet, and the run never recovers: a
# re-run replays the same frozen payload and reaches the same verdict. The
# failed check run also survives the later `edited` run's pass, because the two
# land in different check suites under one check name.
#
# This script reads the body the forge holds right now instead, waiting a
# bounded time for the pipeline's own write for THIS head to land. The wait ends
# the moment the body names the head commit, so a body-bearing event costs no
# delay.
#
# The wait can delay a verdict but never change one. When the bound expires the
# last body read is still printed and still judged, so a head with no compliant
# attestation fails with the gate's own diagnosis instead of going quiet; and a
# body that could not be read at all fails here rather than falling back to the
# stale snapshot. Reading live is also strictly stricter than reading the event
# payload, which would still certify a body that has since been edited to drop
# its attestation.
#
# A failed read is not evidence about the body, so --read-retries is budgeted
# separately from --timeout and outlives it: an event that needs no settle wait
# still survives a transient forge error rather than reporting a red gate for it.
#
# Trailing newlines are not preserved: the gate searches the body for fixed
# substrings, so only the body's content matters, never its final framing.
#
# Usage:
#   fm-pr-body-settled.sh --repo <owner/name> --number <n> --head-sha <sha>
#                         [--timeout <seconds>] [--interval <seconds>]
#                         [--read-retries <n>] [--github-output <name>]
#   fm-pr-body-settled.sh --help
#
# Prints the body on stdout, or appends it to $GITHUB_OUTPUT as <name> with a
# heredoc delimiter proven absent from the body when --github-output is given.
# Exits 1 when no body could be read at all within the bounds.
set -u

SELF="$(basename "${BASH_SOURCE[0]}")"

die() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit 1
}

note() {
  printf '%s: %s\n' "$SELF" "$*" >&2
}

usage() {
  sed -n '2,42{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

require_value() {  # <flag> <argument-count>
  [ "$2" -ge 2 ] || die "$1 requires a value"
}

require_count() {  # <flag> <value> <minimum>
  case "$2" in
    ''|*[!0-9]*) die "$1 requires a non-negative whole number, got: $2" ;;
  esac
  [ "$2" -ge "$3" ] || die "$1 must be at least $3, got: $2"
}

REPO=
NUMBER=
HEAD_SHA=
# The observed gap between a pipeline push and its PR body write is a few
# seconds; this bound keeps ~30x margin over that while still ending in a loud
# failure rather than an unbounded wait.
TIMEOUT=180
INTERVAL=5
READ_RETRIES=3
OUTPUT_NAME=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) require_value "$1" "$#"; REPO=$2; shift 2 ;;
    --number) require_value "$1" "$#"; NUMBER=$2; shift 2 ;;
    --head-sha) require_value "$1" "$#"; HEAD_SHA=$2; shift 2 ;;
    --timeout) require_value "$1" "$#"; TIMEOUT=$2; shift 2 ;;
    --interval) require_value "$1" "$#"; INTERVAL=$2; shift 2 ;;
    --read-retries) require_value "$1" "$#"; READ_RETRIES=$2; shift 2 ;;
    --github-output) require_value "$1" "$#"; OUTPUT_NAME=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$REPO" in
  ''|*/*/*|/*|*/) die "--repo must be owner/name, got: $REPO" ;;
  */*) ;;
  *) die "--repo must be owner/name, got: $REPO" ;;
esac
case "$NUMBER" in
  ''|*[!0-9]*|0*) die "--number must be a positive pull request number, got: $NUMBER" ;;
esac
case "$HEAD_SHA" in
  ''|*[!0-9a-fA-F]*) die "--head-sha must be a hexadecimal commit SHA, got: $HEAD_SHA" ;;
esac
[ "${#HEAD_SHA}" -ge 7 ] || die "--head-sha is too short to identify a commit: $HEAD_SHA"
require_count --timeout "$TIMEOUT" 0
require_count --interval "$INTERVAL" 1
require_count --read-retries "$READ_RETRIES" 0
if [ -n "$OUTPUT_NAME" ]; then
  case "$OUTPUT_NAME" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_-]*) die "--github-output must be a workflow output name, got: $OUTPUT_NAME" ;;
  esac
  [ -n "${GITHUB_OUTPUT:-}" ] || die "--github-output needs GITHUB_OUTPUT to be set"
fi

command -v gh >/dev/null 2>&1 || die "gh is required to read the pull request body"

# Append <value> to $GITHUB_OUTPUT under <name>. The value is contributor-
# controlled text, so the heredoc delimiter is extended until no line of the
# value equals it; without that a body carrying the delimiter on its own line
# would terminate the block early and inject further workflow outputs.
emit_github_output() {  # <name> <value>
  local name=$1 value=$2 delim=fm-pr-body-settled-EOF
  while printf '%s\n' "$value" | grep -qxF -- "$delim"; do
    delim="${delim}0"
  done
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$GITHUB_OUTPUT" || die "could not append $name to GITHUB_OUTPUT"
}

STDERR_CAPTURE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-body-settled.XXXXXX") ||
  die "could not create a temporary file"
trap 'rm -f "$STDERR_CAPTURE"' EXIT

body=
have_body=0
bound=0
reads=0
read_failures=0
last_problem="no read attempted"
started=$(date +%s)
deadline=$((started + TIMEOUT))

while :; do
  reads=$((reads + 1))
  if fetched=$(gh api "repos/$REPO/pulls/$NUMBER" --jq '.body // ""' 2>"$STDERR_CAPTURE"); then
    body=$fetched
    have_body=1
    case "$body" in
      *"$HEAD_SHA"*) bound=1; break ;;
    esac
    last_problem="body does not name head $HEAD_SHA"
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || break
  else
    last_problem="read failed: $(tr '\n' ' ' < "$STDERR_CAPTURE")"
    read_failures=$((read_failures + 1))
    [ "$read_failures" -le "$READ_RETRIES" ] || break
  fi
  now=$(date +%s)
  if [ "$now" -lt "$deadline" ] && [ $((deadline - now)) -lt "$INTERVAL" ]; then
    sleep $((deadline - now))
  else
    sleep "$INTERVAL"
  fi
done

waited=$(($(date +%s) - started))

if [ "$have_body" -eq 0 ]; then
  die "could not read the body of $REPO#$NUMBER in ${waited}s over $reads read(s); $last_problem"
fi

if [ "$bound" -eq 1 ]; then
  note "$REPO#$NUMBER body names head $HEAD_SHA after ${waited}s over $reads read(s)."
else
  note "$REPO#$NUMBER body still does not name head $HEAD_SHA after ${waited}s over $reads read(s); judging the body as it stands."
fi

if [ -n "$OUTPUT_NAME" ]; then
  emit_github_output "$OUTPUT_NAME" "$body"
else
  printf '%s\n' "$body"
fi
