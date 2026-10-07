#!/usr/bin/env bash
# fm-resident-agents.sh - report which of this home's direct-report agent
# sessions are resident, how much memory each holds, and which are safe to
# release.
#
# Why this exists: a finished task keeps a full agent session resident for as
# long as nobody stops it, and every existing check calls such a session healthy
# because it is idle. On a small machine the quiet sessions silently take the
# memory a running worker then cannot get. This command makes the answer one
# command away instead of a backwards investigation from a refused memory gate.
#
# REPORT ONLY. It never stops, exits, relaunches, or tears down anything, never
# touches a worktree, commit, or uncommitted change, and writes nothing. Releasing
# a session stays a deliberate act through bin/fm-control.sh.
#
# Scope: only this home's own state/<id>.meta records (FM_HOME) are read. No
# shared endpoint namespace is swept and no other home is read.
#
# Per task it prints: task id, recorded kind, resident memory (RSS of the agent
# process(es) whose working directory is the task's recorded worktree), time
# running, the current state from bin/fm-crew-state.sh (never a raw status line),
# and a flag. Rows are ordered by resident memory, largest first.
#
# Flags, derived only from the reconciled state:
#   SAFE TO RELEASE (work delivered)  - a ship task whose state is done: its work
#       reached a pull request or ready branch and is waiting on a human.
#   SAFE TO RELEASE (run not retried) - a ship or scout task whose state is
#       failed: the run is recorded as failed and nothing will retry it.
#   unknown                            - state or memory could not be read; an
#       unreadable state is not a terminal one, so it is never flagged safe.
# A running, parked, blocked, or paused task and every secondmate carries no
# flag. A release preserves every local copy and commit.
#
# Memory is read from the process table of this machine, matching an agent
# process (fm_agent_process_classify_name) whose cwd is the recorded worktree.
# Remote secondmates have no local process and are listed as remote, unflagged.
#
# usage: fm-resident-agents.sh
# Test seams: FM_RESIDENT_PROC_TABLE (a file of "<pid> <rss-kb> <elapsed-secs>
# <cwd>" lines replacing the process scan) and FM_RESIDENT_CREW_STATE (the
# command used instead of fm-crew-state.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "usage: fm-resident-agents.sh" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"

meta_value() {  # <file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Prints "<pid> <rss-kb> <elapsed-secs> <cwd>" for each agent process.
process_table() {
  if [ -n "${FM_RESIDENT_PROC_TABLE:-}" ]; then
    cat "$FM_RESIDENT_PROC_TABLE" 2>/dev/null
    return 0
  fi
  local pid rss etimes comm cwd
  LC_ALL=C ps -A -o pid=,rss=,etimes=,comm= 2>/dev/null \
    | while read -r pid rss etimes comm; do
        [ -n "$comm" ] || continue
        [ "$(fm_agent_process_classify_name "$comm")" = agent ] || continue
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=$(
          lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
        [ -n "$cwd" ] || continue
        printf '%s %s %s %s\n' "$pid" "$rss" "$etimes" "$cwd"
      done
}

fmt_mem() {  # <kb>
  awk -v kb="$1" 'BEGIN { printf "%.0f MB", kb / 1024 }'
}

fmt_age() {  # <seconds>
  local s=$1
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

TABLE=$(process_table)
CREW_STATE=${FM_RESIDENT_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
ROWS=""

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  wt=$(meta_value "$meta" worktree)
  [ -n "$wt" ] || wt=$(meta_value "$meta" home)

  if [ -n "$(meta_value "$meta" remote_host)" ]; then
    ROWS="$ROWS$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' -1 "$id" "$kind" "remote" "-" "remote secondmate: no local process" "")
"
    continue
  fi

  rss=""; age=""
  if [ -n "$wt" ]; then
    read -r rss age <<EOF || true
$(printf '%s\n' "$TABLE" | awk -v wt="${wt%/}" '
  { cwd = $4; for (i = 5; i <= NF; i++) cwd = cwd " " $i
    if (cwd == wt || index(cwd, wt "/") == 1) { kb += $2; if ($3 > max) max = $3; n++ } }
  END { if (n) print kb, max }')
EOF
  fi

  line=$("$CREW_STATE" "$id" 2>/dev/null | head -1) || line=""
  state=$(printf '%s\n' "$line" | sed -n 's/^state: \([a-z-]*\).*/\1/p')
  [ -n "$state" ] || state=unknown
  detail=$(printf '%s\n' "$line" | sed 's/^state: [a-z-]*//')

  flag=""
  case "$kind:$state" in
    ship:done)
      flag="SAFE TO RELEASE: work delivered, its pull request or ready branch is waiting on a human; releasing keeps every local copy and commit" ;;
    ship:failed|scout:failed)
      flag="SAFE TO RELEASE: the run failed and is recorded as not being retried; releasing keeps every local copy and commit" ;;
    *:unknown)
      flag="unknown: state could not be read, so this is not flagged safe to release" ;;
  esac

  if [ -z "$rss" ]; then
    memkb=-1; mem="not found"; ageout="-"
    # Nothing is resident to release, so a safe-to-release flag would mislead.
    [ "$state" = unknown ] || flag=""
  else
    memkb=$rss; mem=$(fmt_mem "$rss"); ageout=$(fmt_age "${age:-0}")
  fi
  ROWS="$ROWS$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$memkb" "$id" "$kind" "$mem" "$ageout" "$state$detail" "$flag")
"
done

[ -n "$ROWS" ] || { echo "no recorded direct reports in this home"; exit 0; }

echo "Resident agent sessions in this home, largest memory first (report only; nothing is stopped)."
printf '%s' "$ROWS" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | while IFS="$(printf '\t')" read -r _ id kind mem age state flag; do
  printf '%s  kind=%s  memory=%s  running=%s\n    state: %s\n' "$id" "$kind" "$mem" "$age" "$state"
  [ -z "$flag" ] || printf '    >> %s\n' "$flag"
done
