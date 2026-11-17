#!/usr/bin/env bash
# fm-ci-zombie-sweep.sh - cancel this fork's zombie GitHub Actions runs.
#
# Usage: fm-ci-zombie-sweep.sh [--apply] [--max-age-hours <N>] [--repo <owner/name>]
#
# A run that is still queued, waiting, or in progress long after it was created
# will never finish: its runner is gone or its concurrency group was abandoned.
# Left alone it inflates the queue depth the capacity admission reads and holds
# a runner slot. This sweep lists those runs through `gh` and cancels the ones
# older than --max-age-hours (default 24).
#
# DRY RUN FIRST. Without --apply nothing is written to the forge; each zombie is
# printed as `would-cancel: <run-id> <status> <age>h <workflow>` and the summary
# line says `mode=dry-run`. --apply cancels each one and prints `cancelled:`
# (or `cancel-failed:`, which makes the exit status nonzero).
#
# SCOPE. This fork only: doitdigital0495/firstmate. --repo exists so a caller
# can state the target explicitly, but any other repository, upstream and
# project repositories included, is refused before any forge call.
#
# NOT A POLL. This is one on-demand sweep: a few REST reads and one cancel per
# zombie. It never loops. It also refuses to run when the REST budget has fewer
# than FM_CI_SWEEP_MIN_RATE_REMAINING (default 500) calls left.
#
# Test seams: FM_CI_SWEEP_NOW (epoch) pins the clock.
set -u
LC_ALL=C
export LC_ALL

FORK_REPO=doitdigital0495/firstmate
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

apply=0 max_age=24 repo=$FORK_REPO
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --max-age-hours) [ "$#" -ge 2 ] || usage; max_age=$2; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || usage; repo=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
case "$max_age" in ''|*[!0-9]*|0) die "--max-age-hours must be a positive integer" ;; esac
[ "$repo" = "$FORK_REPO" ] || die "refusing repo $repo: this sweep is scoped to $FORK_REPO only"
command -v gh >/dev/null 2>&1 || die "gh is not installed"

min_rate=${FM_CI_SWEEP_MIN_RATE_REMAINING:-500}
case "$min_rate" in ''|*[!0-9]*) die "FM_CI_SWEEP_MIN_RATE_REMAINING must be a non-negative integer" ;; esac
remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null) \
  || die "cannot read the GitHub REST budget; not sweeping"
case "$remaining" in ''|*[!0-9]*) die "cannot read the GitHub REST budget; not sweeping" ;; esac
if [ "$remaining" -lt "$min_rate" ]; then
  printf 'zombie-sweep: held: REST budget %s is under %s\n' "$remaining" "$min_rate"
  exit 0
fi

now=${FM_CI_SWEEP_NOW:-$(date +%s)}
limit=$((max_age * 3600))
found=0 acted=0 failed=0
for status in queued waiting in_progress; do
  rows=$(gh api --paginate "repos/$repo/actions/runs?status=$status&per_page=100" \
    --jq '.workflow_runs[] | [.id, .status, .created_at, (.name // "")] | @tsv') \
    || die "cannot list $status runs of $repo"
  while IFS=$'\t' read -r id rstatus created name; do
    [ -n "$id" ] || continue
    case "$id" in *[!0-9]*) continue ;; esac
    created_epoch=$(perl -MTime::Local=timegm -e '
      my ($y, $mo, $d, $h, $mi, $s) = $ARGV[0] =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z\z/ or exit 1;
      print timegm($s, $mi, $h, $d, $mo - 1, $y), "\n";
    ' "$created" 2>/dev/null) || continue
    age=$((now - created_epoch))
    [ "$age" -gt "$limit" ] || continue
    found=$((found + 1))
    if [ "$apply" -eq 0 ]; then
      printf 'would-cancel: %s %s %sh %s\n' "$id" "$rstatus" "$((age / 3600))" "$name"
    elif gh api -X POST "repos/$repo/actions/runs/$id/cancel" >/dev/null 2>&1; then
      acted=$((acted + 1))
      printf 'cancelled: %s %s %sh %s\n' "$id" "$rstatus" "$((age / 3600))" "$name"
    else
      failed=$((failed + 1))
      printf 'cancel-failed: %s %s %sh %s\n' "$id" "$rstatus" "$((age / 3600))" "$name"
    fi
  done <<< "$rows"
done
mode=dry-run
[ "$apply" -eq 0 ] || mode=apply
printf 'zombie-sweep: repo=%s mode=%s older_than=%sh found=%s cancelled=%s failed=%s\n' \
  "$repo" "$mode" "$max_age" "$found" "$acted" "$failed"
[ "$failed" -eq 0 ]
