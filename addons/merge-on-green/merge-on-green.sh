#!/usr/bin/env bash
# merge-on-green watcher check: merge a yolo task's PR through bin/fm-pr-merge.sh once its required
# checks are green, so the merge wait after green (about 21 min per change) disappears.
# Usage: merge-on-green.sh check <fm-home>
#
# Per home, for each state/<task>.meta with yolo=on and a recorded pr= and pr_head=, it acts only when the
# task's resolved state (bin/fm-crew-state.sh <task>) says checks green / PR ready. It silently skips a task
# marked merge=manual and a PR whose evidence-gate PASS is a not-proven PASS (the gate reads the PR's
# newest "## Checks" block; the lead files the proof gap first). Then, in this order and as separate
# sequential commands, never piped and never in parallel:
#   1. FM_HOME=<home> checks-lint.sh <PR URL> <home>/data/<task> - use done-done lint, or the legacy Firstmate lint if unavailable.
#   2. state/<task>.run-receipt.json - require verdict PASS, head == pr_head, spawn_gen == the meta's spawn_gen.
#   3. FM_HOME=<home> bin/fm-pr-merge.sh <task> <PR URL> - never --auto, never gh merge directly.
# Any refusal or FAIL: one wake line naming the task, the PR URL and the first refusal reason, so the lead
# acts; the refusal is remembered per task+head+reason+receipt state and repeats stay silent until pr_head,
# the run receipt or the reason changes. An evidence gate or the merge this check itself kills on its
# timeout wakes truthfully once per task+head+reason like a refusal, records no merge attempt, and is
# retried next sweep; a fm-crew-state timeout stays silent and is retried next sweep. A merge:
# one wake line with the verified merged URL, so the lead does the post-merge steps (install from main,
# teardown), and the normal "done [at=<epoch>]: merged <PR URL>" line in state/<task>.status, so the
# lead relays it.
# One merge attempt per task per head: the attempted head and the last gate refusal are remembered in this
# add-on's own data dir (<home>/data/fm-merge-on-green/<task>.head, <task>.refused), never in state/.
# Nothing is printed when nothing happened.
# Every command is bounded with timeout; a merge always finishes before the watcher's kill, a gate cut
# by it is retried next sweep.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: merge-on-green.sh check <fm-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
LINT=${FM_MOG_CHECKS_LINT:-$SRC/checks-lint.sh}
DATA=$FMH/data/fm-merge-on-green
umask 077
# One third of the watcher's per-check bound per command (floor 5s). Gate commands start only while
# under 80% of the bound and a merge only when it fits inside the whole bound, so the watcher's kill
# at FM_CHECK_TIMEOUT can at worst cut a gate command (harmlessly retried next sweep), never a merge.
BUDGET=$(( ${FM_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
START=$(date +%s)
DEADLINE=$(( START + ${FM_CHECK_TIMEOUT:-30} * 4 / 5 ))

meta_get() { # <meta-file> <key> -> last value, the same rule fm_meta_get applies
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

first_reason() { # first non-empty line of a command's output, trimmed to keep the wake line short
  local r
  r=$(printf '%s' "$1" | sed '/^[[:space:]]*$/d' | head -1)
  [ -n "$r" ] || r="exit code ${2:-?} with no output"
  [ "${#r}" -le 140 ] || r=${r:0:137}'...'
  printf '%s' "$r"
}

# Every "NOT merging" wake line ends with this routing: a green lead-owned PR is the lead's to merge
# (standing authority), not a card for Main; only a genuine hold goes up.
LEAD_NOTE='lead: clear it and merge through bin/fm-pr-merge.sh; only a genuine hold (owner review, red CI, missing proof, security, destructive) goes to Main'

timed_out() { [ "$1" = 124 ] || [ "$1" = 137 ]; }

refuse() { # <reason> <receipt-stamp>: the wake line prints once per task+head+reason+receipt state,
  # remembered like the merge path in <task>.refused; silent while all three hold.
  [ "$(cat "$DATA/$task.refused" 2>/dev/null)" = "$(printf '%s\n%s\n%s\n' "$pr_head" "$1" "$2")" ] && return 0
  echo "merge-on-green: NOT merging $task $pr: $1; $LEAD_NOTE"
  mkdir -p "$DATA" 2>/dev/null
  printf '%s\n%s\n%s\n' "$pr_head" "$1" "$2" > "$DATA/$task.refused" 2>/dev/null || :
}

for m in "$STATE"/*.meta; do
  [ -f "$m" ] || exit 0
  task=$(basename "$m" .meta)
  case "$task" in [A-Za-z0-9]*) ;; *) continue ;; esac
  yolo=$(meta_get "$m" yolo); pr=$(meta_get "$m" pr); pr_head=$(meta_get "$m" pr_head); gen=$(meta_get "$m" spawn_gen)
  [ "$yolo" = on ] || continue
  # The lead marks merge=manual at intake on destructive, irreversible or security-sensitive work and
  # on work waiting for the captain's own review.
  [ "$(meta_get "$m" merge)" = manual ] && continue
  [ -n "$pr" ] && [ -n "$pr_head" ] || continue
  # One merge attempt per head: a head already attempted (merged or refused) is never retried.
  [ "$(cat "$DATA/$task.head" 2>/dev/null)" = "$pr_head" ] && continue
  [ "$(date +%s)" -lt "$DEADLINE" ] || exit 0

  # Gate: the task's resolved state must say checks green / PR ready. "PR merged" means the work
  # already landed; nothing happened, so nothing is printed.
  cs=$(FM_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/fm-crew-state.sh" "$task" 2>/dev/null) || continue
  case "$cs" in
    *"checks green: PR ready"*|*"checks green: PR held for merge"*) ;;
    *) continue ;;
  esac

  # 1. The evidence gate, run as its own command, must print PASS; a not-proven PASS is the lead's
  # proof gap to file first: skip silently before the receipt or merge.
  lint_out=$(FM_HOME="$FMH" timeout "$BUDGET" "$LINT" "$pr" "$FMH/data/$task" 2>&1); lint_rc=$?
  if timed_out "$lint_rc"; then
    refuse "checks lint timed out after ${BUDGET}s, no verdict; retrying next sweep" ''
    continue
  fi
  if [ "$lint_rc" -ne 0 ] || ! printf '%s\n' "$lint_out" | grep -q 'PASS'; then
    refuse "checks lint refused: $(first_reason "$lint_out" "$lint_rc")" ''
    continue
  fi
  printf '%s\n' "$lint_out" | grep -q 'checks-lint: PASS: not-proven:' && continue

  # 2. The completion receipt must be a PASS for exactly this head and spawn generation.
  rcpt=$STATE/$task.run-receipt.json
  if [ ! -f "$rcpt" ]; then
    refuse "no run receipt at state/$task.run-receipt.json" ''
    continue
  fi
  if ! command -v jq >/dev/null 2>&1; then
    refuse "jq is unavailable, cannot read the run receipt" ''
    continue
  fi
  rstamp=$(cksum < "$rcpt" 2>/dev/null)
  verdict=$(timeout "$BUDGET" jq -r '.verdict // ""' "$rcpt" 2>/dev/null); jq_rc=$?
  if timed_out "$jq_rc"; then
    refuse "reading the run receipt timed out after ${BUDGET}s; retrying next sweep" "$rstamp"
    continue
  fi
  rhead=$(timeout "$BUDGET" jq -r '.head // ""' "$rcpt" 2>/dev/null)
  rgen=$(timeout "$BUDGET" jq -r '.spawn_gen // ""' "$rcpt" 2>/dev/null)
  if [ "$jq_rc" -ne 0 ] || [ -z "$verdict$rhead$rgen" ]; then
    refuse "run receipt is unreadable JSON" "$rstamp"
    continue
  fi
  if [ "$verdict" != PASS ]; then
    refuse "run receipt verdict is ${verdict:-empty}, not PASS" "$rstamp"
    continue
  fi
  if [ "$rhead" != "$pr_head" ]; then
    refuse "run receipt head ${rhead:-empty} != meta pr_head" "$rstamp"
    continue
  fi
  if [ "$rgen" != "$gen" ]; then
    refuse "run receipt spawn_gen ${rgen:-empty} != meta spawn_gen" "$rstamp"
    continue
  fi

  # 3. Merge through fm-pr-merge.sh only: its own live green check, head pin and refusal rules stay in
  # charge, no --auto is ever passed. The attempted head is recorded first, so a check killed between
  # record and merge cannot retry the same head next sweep.
  # A merge killed by the watcher after the head was recorded burns it with no wake line:
  # start one only when it still fits inside the watcher's whole-check bound; the fit arithmetic
  # doubles as the merge's bound, so the whole remaining window is available to it.
  mbudget=$(( START + ${FM_CHECK_TIMEOUT:-30} - $(date +%s) - 1 ))
  [ "$mbudget" -ge "$BUDGET" ] || exit 0
  mkdir -p "$DATA" || { echo "merge-on-green: NOT merging $task $pr: cannot write $DATA; $LEAD_NOTE"; continue; }
  printf '%s\n' "$pr_head" > "$DATA/$task.head" || { echo "merge-on-green: NOT merging $task $pr: cannot write $DATA/$task.head; $LEAD_NOTE"; continue; }
  merge_out=$(FM_HOME="$FMH" timeout "$mbudget" "$FMH/bin/fm-pr-merge.sh" "$task" "$pr" 2>&1); merge_rc=$?
  if timed_out "$merge_rc"; then
    rm -f "$DATA/$task.head" 2>/dev/null || :
    refuse "fm-pr-merge timed out, no verdict; retrying next sweep" ''
    continue
  fi
  if [ "$merge_rc" -eq 0 ]; then
    echo "merge-on-green: merged $task $pr through fm-pr-merge; lead: run the post-merge steps (install from main, teardown)"
    # The normal merged line, so the lead relays it, plus the fleet-ledger hook every status append runs.
    echo "done [at=$(date +%s)]: merged $pr" >> "$STATE/$task.status"
    [ ! -e "$FMH/config/fleet-ledger" ] \
      || "$FMH/bin/fm-fleet-ledger.sh" appended "$FMH/config" "$STATE/$task.status" >/dev/null 2>&1 || :
  else
    echo "merge-on-green: NOT merging $task $pr: fm-pr-merge refused: $(first_reason "$merge_out" "$merge_rc"); $LEAD_NOTE"
  fi
done
