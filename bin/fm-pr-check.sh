#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's PR poll by writing
# state/<id>.check.sh (the watcher's check contract: one line of output = wake
# firstmate, silence = keep sleeping).
#
# The generated poll wakes firstmate on two things: the PR merging (echoes
# "merged"), and any new review activity - a review, a PR issue comment, or an
# inline review comment - since the last poll (echoes "new-review-activity: +N
# on <url>"). Merge wins: a merged PR echoes only "merged" and skips activity,
# so each fire prints exactly one line. Activity counts are the reviews +
# comments totals from gh pr view --json, persisted in state/<id>.pr-activity;
# the first poll records the baseline silently so activity predating the arm
# never wakes firstmate, and a gh error stays silent without touching the
# marker. We deliberately do NOT classify bots: any new activity wakes
# firstmate, who triages - cheaper than getting bot-detection wrong.
# fm-teardown.sh removes state/<id>.pr-activity alongside the other per-task
# state files.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

ACT="$STATE/$ID.pr-activity"
# Inject the URL and marker path as %q-quoted assignments, then a quoted heredoc
# for the poll logic, so nothing in the body expands at generation time.
{
  printf 'url=%q\n' "$URL"
  printf 'act=%q\n' "$ACT"
  cat <<'EOF'
# Merge wins: a merged PR wakes for the merge and skips the activity check, so
# each fire prints exactly one line.
state=$(gh pr view "$url" --json state -q .state 2>/dev/null)
[ "$state" = "MERGED" ] && { echo "merged"; exit 0; }

# Review activity = reviews + PR comments, counted with gh's built-in jq.
count=$(gh pr view "$url" --json reviews,comments -q '(.reviews|length)+(.comments|length)' 2>/dev/null)
# A gh error (empty) or any non-integer stays silent and leaves the marker alone.
case "$count" in ''|*[!0-9]*) exit 0 ;; esac

last=
[ -f "$act" ] && last=$(cat "$act" 2>/dev/null)
# First poll (no marker) or a corrupt marker: record the baseline silently.
case "$last" in ''|*[!0-9]*) printf '%s\n' "$count" > "$act"; exit 0 ;; esac

if [ "$count" -gt "$last" ]; then
  printf '%s\n' "$count" > "$act"
  echo "new-review-activity: +$((count - last)) on $url"
elif [ "$count" -ne "$last" ]; then
  printf '%s\n' "$count" > "$act"  # count fell (rare): resync the marker, no wake
fi
EOF
} > "$STATE/$ID.check.sh"
echo "armed: state/$ID.check.sh polls $URL"
