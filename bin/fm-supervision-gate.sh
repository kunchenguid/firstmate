#!/usr/bin/env bash
# fm-supervision-gate.sh - the supervision host's repeat bound and its opt-in
# pre-turn judge hook: whether a wake the host's engine was about to take needs
# an engine turn at all (docs/supervision-host.md "The repeat bound").
#
# Usage:
#   fm-supervision-gate.sh decide --task <id> --posture attended|away \
#       --rows "<seq> ..." [--mirror-file <feed>]
#
# decide prints key=value lines and exits 0 for every decision (2 for usage):
#   decision=skip|turn
#   why=<one line>
#   judge=none|skip|turn|other|timeout|exit-<n>|invalid
#   skips=<the task's consecutive skips before this wake>
#   summary=<the silent outcome a skip records>   (skip only)
#
# THE BOUND. decision=skip only when every one of these holds, checked in this
# order; the first that fails is the why of a turn:
#   1. Every granted row is still queued, is a stale row, and carries the
#      watcher's plain reason "stale: <window>" with no detail: any wedge,
#      escalation, deep-inspection, prompt, dead-record, inbox, or declared-wait
#      recheck wording means a turn. Signal, check, and heartbeat rows are never
#      skipped, so a status append - a decision, blocker, or result included -
#      always reaches a turn.
#   2. Attended, the dialog-mirror feed the turn would carry (--mirror-file)
#      holds no [captain] entry, because the engine never judges without the
#      captain's words; a missing or unreadable feed means a turn.
#   3. The task has a previous outcome (bin/fm-branch-outcome.sh latest), it
#      was a silent routine outcome, it was recorded at most WINDOW (3600)
#      seconds ago, and the task's status log has not changed since it was
#      recorded.
#   4. Fewer than CAP (5) skips in a row: the count is the one the previous
#      outcome's summary carries when that outcome is a skip's, and 0 for any
#      other outcome, so any real turn's outcome resets it.
#
# THE JUDGE. config/supervision-judge (docs/configuration.md "Pre-turn judge"
# owns its format and modes) is consulted only for a wake the bound would
# skip, so it can veto a skip and never widens one. Its stdin is one JSON
# object: {version: 1, mode, task, posture, wake: {kind: "stale", rows: [{seq,
# key, reason}]}, previousOutcome: {seq, verdict, silent, ageSeconds, summary},
# consecutiveSkips, latestStatusLine}. Only a first stdout line of exactly
# "skip", within JUDGE_TIMEOUT (10) seconds and with exit 0, is a skip; judge= reports any other answer as turn or other, a
# nonzero exit as exit-<n>, the bound as timeout, and an unusable file as
# invalid. A shadow judge's why carries what it would have decided.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

JUDGE_FILE="$CONFIG/supervision-judge"

usage() {
  sed -n '/^# Usage:/,/^# decide prints/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

CAP=5
WINDOW=3600
JUDGE_TIMEOUT=10
SKIP_SUMMARY_RE='^No supervision turn: the repeat bound found .*, skip (?<n>[0-9]+) of at most [0-9]+ in a row;'

TASK='' POSTURE='' ROWS='' MIRROR='' MIRROR_SET=0
JUDGE=none
PRIOR_SKIPS=0

verdict() {  # <decision> <why> [summary]
  printf 'decision=%s\nwhy=%s\njudge=%s\nskips=%s\n' "$1" "$2" "$JUDGE" "$PRIOR_SKIPS"
  [ -z "${3:-}" ] || printf 'summary=%s\n' "$3"
  exit 0
}

# Rule 1: every granted row is a queued plain stale row.
rows_plain_stale() {
  [ -f "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' -v seqs="$ROWS" '
    BEGIN { n = split(seqs, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
    NF >= 5 && ($2 in want) {
      found[$2] = 1
      if ($3 != "stale" || $5 != "stale: " $4) bad = 1
    }
    END {
      if (n == 0 || bad) exit 1
      for (s in want) if (!(s in found)) exit 1
    }
  ' "$FM_WAKE_QUEUE"
}

# Sets JUDGE_MODE and JUDGE_BIN from config/supervision-judge; 1 when the file
# exists but cannot name a runnable judge.
judge_config() {
  local line
  JUDGE_MODE=
  JUDGE_BIN=
  line=$(grep -v -E '^[[:space:]]*(#|$)' "$JUDGE_FILE" 2>/dev/null | head -n 1) || line=
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  JUDGE_MODE=${line%%[[:space:]]*}
  JUDGE_BIN=$(printf '%s' "${line#"$JUDGE_MODE"}" | sed 's/^[[:space:]]*//')
  case "$JUDGE_MODE" in on|shadow) ;; *) return 1 ;; esac
  [ -n "$JUDGE_BIN" ] || return 1
  case "$JUDGE_BIN" in /*) ;; *) JUDGE_BIN="$FM_HOME/$JUDGE_BIN" ;; esac
  [ -f "$JUDGE_BIN" ] && [ -x "$JUDGE_BIN" ]
}

# The judge's input: what the bound already established, plus the wake rows.
judge_input() {  # <previous-outcome-json>
  local status="$STATE/$TASK.status" latest='' wake
  if [ -f "$status" ] && [ ! -L "$status" ]; then
    latest=$(grep -v '^[[:space:]]*$' "$status" 2>/dev/null | tail -n 1 | cut -c1-600) || latest=
  fi
  wake=$(awk -F '\t' -v seqs="$ROWS" '
    BEGIN { n = split(seqs, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
    NF >= 5 && ($2 in want) { printf "%s\t%s\t%s\n", $2, $4, $5 }
  ' "$FM_WAKE_QUEUE" | jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
      | {seq: (.[0] | tonumber), key: .[1], reason: .[2]})') || return 1
  jq -cn --arg mode "$JUDGE_MODE" --arg task "$TASK" --arg posture "$POSTURE" \
    --argjson rows "$wake" --argjson previous "$1" --argjson skips "$PRIOR_SKIPS" \
    --argjson now "$(date +%s)" --arg latest "$latest" '{
      version: 1, mode: $mode, task: $task, posture: $posture,
      wake: {kind: "stale", rows: $rows},
      previousOutcome: ($previous | {seq, verdict, silent, ageSeconds: ([$now - .epoch, 0] | max),
        summary: (.summary | .[0:1000])}),
      consecutiveSkips: $skips,
      latestStatusLine: $latest
    }'
}

# Sets JUDGE to the judge's answer for this wake.
run_judge() {  # <previous-outcome-json>
  local input output rc=0 answer
  input=$(mktemp "$STATE/.supervision-gate-in.XXXXXX") || { JUDGE=other; return 0; }
  output=$(mktemp "$STATE/.supervision-gate-out.XXXXXX") || { rm -f "$input"; JUDGE=other; return 0; }
  if ! judge_input "$1" > "$input"; then
    rm -f "$input" "$output"
    JUDGE=other
    return 0
  fi
  # The redirect lives inside the timed command: an external timeout runs as a
  # background job, whose stdin a non-interactive shell points at /dev/null.
  # shellcheck disable=SC2016  # Expanded by the child shell.
  fm_run_timed "$JUDGE_TIMEOUT" bash -c 'exec "$1" < "$2"' _ "$JUDGE_BIN" "$input" > "$output" 2>/dev/null || rc=$?
  answer=$(head -n 1 "$output" 2>/dev/null | head -c 64 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  rm -f "$input" "$output"
  if fm_timed_out "$rc"; then
    JUDGE=timeout
  elif [ "$rc" -ne 0 ]; then
    JUDGE="exit-$rc"
  else
    case "$answer" in skip|turn) JUDGE=$answer ;; *) JUDGE=other ;; esac
  fi
}

decide() {
  local previous fields seq epoch prev_verdict silent unchanged skips age now summary
  rows_plain_stale || verdict turn "not only plain stale rows"
  if [ "$POSTURE" = attended ]; then
    [ "$MIRROR_SET" -eq 1 ] && [ -f "$MIRROR" ] && [ -r "$MIRROR" ] \
      || verdict turn "the dialog-mirror feed could not be read"
    ! grep -q '^\[captain\]' "$MIRROR" 2>/dev/null || verdict turn "the captain spoke since the last turn"
  fi
  previous=$("$SCRIPT_DIR/fm-branch-outcome.sh" latest --task "$TASK" 2>/dev/null) \
    || verdict turn "the outcome store could not be read"
  [ -n "$previous" ] || verdict turn "no previous outcome"
  fields=$(printf '%s\n' "$previous" | jq -r --arg re "$SKIP_SUMMARY_RE" '[.seq, .epoch, .verdict, (.silent // false),
      .statusUnchanged, ((.summary // "" | capture($re).n) // "0")] | @tsv' 2>/dev/null) \
    || verdict turn "the previous outcome could not be read"
  IFS=$(printf '\t') read -r seq epoch prev_verdict silent unchanged skips <<EOF
$fields
EOF
  [ "$unchanged" = true ] || verdict turn "the status log changed since the previous outcome"
  [ "$prev_verdict" = routine ] && [ "$silent" = true ] || verdict turn "the previous outcome was not a silent no-op"
  now=$(date +%s)
  age=$((now - epoch))
  [ "$age" -le "$WINDOW" ] || verdict turn "the previous outcome is older than ${WINDOW}s"
  PRIOR_SKIPS=$((10#$skips))
  [ "$PRIOR_SKIPS" -lt "$CAP" ] || verdict turn "the cap of $CAP skips in a row is reached"
  summary="No supervision turn: the repeat bound found $TASK unchanged since outcome $seq ($((age / 60)) min ago), skip $((PRIOR_SKIPS + 1)) of at most $CAP in a row; still the same situation, no action."
  [ -e "$JUDGE_FILE" ] || verdict skip "unchanged since outcome $seq" "$summary"
  if ! judge_config; then
    JUDGE=invalid
    verdict turn "config/supervision-judge names no usable judge"
  fi
  run_judge "$previous"
  if [ "$JUDGE_MODE" = shadow ]; then
    if [ "$JUDGE" = skip ]; then
      verdict turn "shadow judge: would skip"
    fi
    verdict turn "shadow judge: would turn"
  fi
  [ "$JUDGE" = skip ] || verdict turn "the judge did not answer skip"
  verdict skip "unchanged since outcome $seq; the judge agreed" "$summary"
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || usage ;;
    --posture) POSTURE=${2:-}; shift 2 || usage ;;
    --rows) ROWS=${2:-}; shift 2 || usage ;;
    --mirror-file) MIRROR=${2:-}; MIRROR_SET=1; shift 2 || usage ;;
    *) usage ;;
  esac
done
case "$TASK" in ''|*[!A-Za-z0-9._-]*) usage ;; esac

case "$CMD" in
  decide)
    case "$POSTURE" in attended|away) ;; *) usage ;; esac
    case "$ROWS" in *[!0-9\ ]*) usage ;; esac
    decide
    ;;
  -h|--help) usage ;;
  *) usage ;;
esac
