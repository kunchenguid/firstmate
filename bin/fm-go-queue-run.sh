#!/usr/bin/env bash
# Merge a queue of already-reviewed pull requests, one row at a time, through
# bin/fm-pr-merge.sh so every row passes the merge gate.
#
# This is the tracked form of the ad-hoc batch script firstmate used to keep in
# its private data/bin: the same "merge these N pull requests" job, with the
# hand-rolled readiness checks removed. Those checks lived only in that private
# script, so a queue-driven merge could skip them entirely; here the queue has
# no checks of its own and merges only through bin/fm-pr-merge.sh, which calls
# bin/fm-merge-gate-lib.sh before it reaches the forge. A row the gate refuses
# is reported and skipped, never merged.
#
# The queue file holds one row per line, whitespace separated:
#
#   <task-id> <owner/repo> <pr-number> <expected-head> <method>
#
# <method> is the forge merge method (merge, squash, or rebase). Blank lines and
# lines starting with # are ignored. <expected-head> is the commit the reviewer
# approved; the gate refuses the row when the live head has moved off it, so a
# stale approval cannot authorize a newer commit.
#
# Usage: fm-go-queue-run.sh <queue-file>
#
# For a read-only audit of a row, use bin/fm-merge-gate-lib.sh with
# --check-only; this runner has no preview mode.
#
# Environment: FM_HOME selects the firstmate home whose state/ and data/ the
# merge records go to; it defaults to this script's repository root.
#
# Exit: 0 when every row merged or was already merged, 1 when any row was
# refused or failed, 2 on a usage error.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
export FM_HOME

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

QUEUE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --)
      shift
      if [ -n "$QUEUE" ]; then
        [ "$#" -eq 0 ] || { echo "error: unexpected argument: $1" >&2; exit 2; }
      else
        [ "$#" -eq 0 ] || { QUEUE=$1; shift; }
      fi
      break
      ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *)
      if [ -n "$QUEUE" ]; then
        echo "error: only one queue file may be given" >&2
        exit 2
      fi
      QUEUE=$1
      shift
      ;;
  esac
done
[ "$#" -eq 0 ] || { echo "error: unexpected argument: $1" >&2; exit 2; }
if [ -z "$QUEUE" ]; then
  echo "error: a queue file is required" >&2
  exit 2
fi
if [ ! -r "$QUEUE" ]; then
  echo "error: cannot read queue file: $QUEUE" >&2
  exit 2
fi

merged=0
skipped=0
failed=0
lineno=0

while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  # Strip a trailing comment and surrounding whitespace.
  line=${line%%#*}
  read -r -a fields <<<"$line"
  [ "${#fields[@]}" -gt 0 ] || continue
  if [ "${#fields[@]}" -ne 5 ]; then
    printf 'row %d: expected 5 fields (task repo pr expected-head method), got %d: %s\n' \
      "$lineno" "${#fields[@]}" "$line" >&2
    failed=$((failed + 1))
    continue
  fi
  task=${fields[0]}
  repo=${fields[1]}
  number=${fields[2]}
  expected=${fields[3]}
  method=${fields[4]}

  case "$repo" in
    */*) ;;
    *)
      printf 'row %d: repo must be owner/repo, got %s\n' "$lineno" "$repo" >&2
      failed=$((failed + 1))
      continue
      ;;
  esac
  case "$number" in
    ''|*[!0-9]*)
      printf 'row %d: pull request number must be numeric, got %s\n' "$lineno" "$number" >&2
      failed=$((failed + 1))
      continue
      ;;
  esac
  case "$method" in
    merge|squash|rebase) ;;
    *)
      printf 'row %d: method must be merge, squash, or rebase, got %s\n' "$lineno" "$method" >&2
      failed=$((failed + 1))
      continue
      ;;
  esac

  url="https://github.com/$repo/pull/$number"
  printf 'row %d: %s %s (%s)\n' "$lineno" "$repo#$number" "$expected" "$method"

  if out=$("$SCRIPT_DIR/fm-pr-merge.sh" "$task" "$url" -- \
      "--$method" --admin --match-head-commit "$expected" 2>&1); then
    printf 'row %d: merged\n' "$lineno"
    merged=$((merged + 1))
  else
    rc=$?
    # A refusal is the gate doing its job, not a failure of the queue; report
    # the gate's own reason line so the operator sees why.
    printf 'row %d: not merged (exit %d)\n' "$lineno" "$rc" >&2
    printf '%s\n' "$out" | sed -n '1,12p' >&2
    skipped=$((skipped + 1))
  fi
done <"$QUEUE"

printf 'queue: %d merged, %d not merged, %d malformed\n' "$merged" "$skipped" "$failed"
[ "$failed" -eq 0 ] || exit 1
[ "$skipped" -eq 0 ] || exit 1
exit 0
