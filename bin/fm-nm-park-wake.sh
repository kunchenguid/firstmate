#!/usr/bin/env bash
# Turn a no-mistakes park/unpark event into a firstmate wake.
#
# no-mistakes announces a parked run three ways: an EDGE hook
# (notify.on_park / notify.on_unpark), a durable RECORD (<NM_HOME>/parked.json,
# which `no-mistakes parked` reads without the daemon), and a level-triggered
# REMINDER cascade (10m, 40m, 100m, then hourly, forever). Without the edge hook
# wired to anything, a parked run is only ever found by someone thinking to
# poll: two runs sat parked for over a day here, re-notified 31 and 25 times,
# with nobody woken. This script is the hook that closes that gap for every
# lane, not only direct-PR.
#
# It is a hook, not a firstmate entrypoint: no-mistakes runs it as `sh -c` with
# the wait in the environment (NM_EVENT, NM_RUN_ID, NM_REPO, NM_BRANCH, NM_STEP,
# NM_GATE, NM_SINCE, NM_FINDINGS, NM_ACTIONS, NM_RESPOND, NM_REMINDER,
# NM_PARKED_FILE, NM_PARK_SUMMARY - names owned by no-mistakes, not by this
# repo), bounded to 30s, with a failing hook logged and otherwise ignored. See
# docs/configuration.md "Park wake hook" for the exact config block to install.
#
# It wakes firstmate through the mechanism that already exists: one line
# appended to state/<id>.status, which the watcher sees as a signal. It invents
# no second channel. The line carries a decision key (nm-park-<run-id>) so the
# park OPENS a durable keyed decision and the unpark CLOSES it, per the status
# fold in bin/fm-classify-lib.sh - a park that is answered stops being an open
# thread by itself.
#
# Which task the park belongs to is resolved from the run id first
# (nm_watch_run=<id> in a meta, written by bin/fm-nm-watch.sh), then from the
# branch, since firstmate task branches are fm/<task-id>. The main home is
# searched first, then each live secondmate home, so a secondmate's park wakes
# the secondmate that owns the work. A park that maps to no task still wakes the
# main home through state/nm-park.status: an unattributable park is exactly the
# one nobody would otherwise find.
#
# What it says depends on who owns the answer:
#   - step "watch"  - a post-delivery watch run, which firstmate owns (the crew
#                     is gone or going). Opens needs-decision immediately.
#   - any other step - a gate run the crew drives. Its parks are normal and
#                     answered in minutes, so this stays SILENT until the
#                     reminder count shows nobody is answering, then opens
#                     blocked, which is firstmate's cue to steer the worker back
#                     to its gate - never to answer a crew-owned run itself.
# Repeat notifications are rate-limited per run (FM_NM_PARK_REWAKE_SECS) so the
# hourly reminder tail cannot spend a firstmate turn per re-send, while a park
# nobody has cleared still re-surfaces instead of going quiet forever.
#
# Usage: fm-nm-park-wake.sh          (as the notify.on_park / on_unpark command)
#        fm-nm-park-wake.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# Seconds before the same run may wake firstmate again. The reminder cascade
# backs off to hourly, so this default lets at most one wake through per hour and
# keeps the rest as the record no-mistakes already keeps.
REWAKE_SECS="${FM_NM_PARK_REWAKE_SECS:-3600}"
# Reminders a crew-owned gate park must survive before firstmate is told nobody
# answered it. With the default cadence, 2 reminders is ~50 minutes.
CREW_REMINDERS="${FM_NM_PARK_CREW_REMINDERS:-2}"
# Longest status line this writes; the detail beyond it lives in `no-mistakes
# parked` and the run's own log.
MAX_LINE="${FM_NM_PARK_MAX_LINE:-260}"

# A hook that dies on a mistyped knob is a hook that drops the wake, so each one
# falls back to its default rather than failing the comparison it feeds.
case "$REWAKE_SECS" in ''|*[!0-9]*) REWAKE_SECS=3600 ;; esac
case "$CREW_REMINDERS" in ''|*[!0-9]*) CREW_REMINDERS=2 ;; esac
case "$MAX_LINE" in ''|0|*[!0-9]*) MAX_LINE=260 ;; esac

usage() {
  cat <<'EOF'
Usage: fm-nm-park-wake.sh

The no-mistakes notify.on_park / notify.on_unpark hook. Reads the wait from the
NM_* environment no-mistakes provides and appends one keyed status line to the
owning task's state/<id>.status (or state/nm-park.status when the park maps to
no task), which wakes firstmate through the normal watcher signal path.

Install it with the config block in docs/configuration.md "Park wake hook".

Environment:
  FM_HOME                     firstmate home to wake (default: the repo root
                              this script lives in)
  FM_NM_PARK_REWAKE_SECS      min seconds between wakes for one run (3600)
  FM_NM_PARK_CREW_REMINDERS   reminders a crew-driven gate park must survive
                              before it is reported unanswered (2)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "fm-nm-park-wake.sh: unexpected argument: $1" >&2; exit 2 ;;
esac

EVENT="${NM_EVENT:-park}"
RUN="${NM_RUN_ID:-}"
REPO="${NM_REPO:-}"
BRANCH="${NM_BRANCH:-}"
STEP="${NM_STEP:-}"
GATE="${NM_GATE:-}"
FINDINGS="${NM_FINDINGS:-}"
REMINDER="${NM_REMINDER:-0}"
case "$REMINDER" in
  ''|*[!0-9]*) REMINDER=0 ;;
esac

if [ -z "$RUN" ]; then
  echo "fm-nm-park-wake.sh: no NM_RUN_ID in the environment; nothing to key the wake on" >&2
  exit 2
fi
# The key goes into a status line the fold parses, and the same sanitized form
# names the dedup marker, so a run id can never reach either as a path or as a
# token that breaks the fold's key grammar.
RUN_SAFE=$(printf '%s' "$RUN" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
KEY="nm-park-$RUN_SAFE"

MARKER_DIR="$STATE/.nm-park"

one_line() {  # <text> [max] -> single-line, space-collapsed, truncated
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -s ' ' | cut -c "1-${2:-$MAX_LINE}"
}

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Homes to search, main first. A secondmate keeps its own state/ and its own
# watcher, so its parks must land there rather than in the main home's stream.
homes() {
  local id home _window _meta
  printf '%s\n' "$FM_HOME"
  # shellcheck source=bin/fm-ff-lib.sh
  . "$SCRIPT_DIR/fm-ff-lib.sh" 2>/dev/null || return 0
  live_secondmate_meta_records "$STATE" "$DATA/secondmates.md" 2>/dev/null |
    while IFS='|' read -r id home _window _meta; do
      [ -n "$home" ] || continue
      [ -d "$home/state" ] || continue
      printf '%s\n' "$home"
    done
}

# Status file of the task this park belongs to, or empty when it maps to none.
# Preference order is exact (the run id recorded when the watch was armed) before
# inferred (the fm/<task-id> branch convention).
target_status() {
  local home state meta id fallback=
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    state="$home/state"
    [ -d "$state" ] || continue
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      if [ "$(meta_field "$meta" nm_watch_run)" = "$RUN" ]; then
        printf '%s\n' "$state/$id.status"
        return 0
      fi
      if [ -n "$BRANCH" ] && [ "$BRANCH" = "fm/$id" ] && [ -z "$fallback" ]; then
        fallback="$state/$id.status"
      fi
    done
  done <<EOF
$(homes)
EOF
  [ -n "$fallback" ] && printf '%s\n' "$fallback"
  return 0
}

now=$(date +%s)
marker="$MARKER_DIR/$RUN_SAFE"
status=

if [ "$EVENT" = "unpark" ]; then
  # Close only what this hook opened: a park it stayed silent about (a crew gate
  # answered in minutes, the common case) must not produce a resolved line for a
  # decision nobody ever saw.
  [ -f "$marker" ] || exit 0
  status=$(grep '^status=' "$marker" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  rm -f "$marker" 2>/dev/null || true
  # A status file that is gone belongs to a task that was torn down; there is no
  # open decision left to close, and recreating the file would leave a status
  # stream with no task behind it.
  [ -f "$status" ] || exit 0
  line=$(one_line "resolved [key=$KEY]: no-mistakes run $RUN unparked (${STEP:-step} gate answered or ended)")
  printf '%s\n' "$line" >> "$status" 2>/dev/null || exit 1
  exit 0
fi

if [ "$STEP" = "watch" ]; then
  verb="needs-decision"
else
  # A gate park the crew is driving is answered in minutes; only an unanswered
  # one is firstmate's problem.
  [ "$REMINDER" -ge "$CREW_REMINDERS" ] || exit 0
  verb="blocked"
fi

# Rate-limit re-sends: the first notification for a run always gets through, and
# after that at most one per REWAKE_SECS, so the hourly reminder tail cannot cost
# a firstmate turn per re-send.
if [ -f "$marker" ]; then
  last=$(grep '^last=' "$marker" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  case "$last" in
    ''|*[!0-9]*) last=0 ;;
  esac
  if [ "$((now - last))" -lt "$REWAKE_SECS" ]; then
    exit 0
  fi
  status=$(grep '^status=' "$marker" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  # A recorded status file that has since been removed means the task was torn
  # down; re-resolve rather than resurrecting a status stream with no task.
  [ -f "$status" ] || status=
fi

if [ -z "$status" ]; then
  status=$(target_status)
fi
if [ -z "$status" ]; then
  status="$STATE/nm-park.status"
fi

detail=$(printf '%s' "$FINDINGS" | grep -v '^[[:space:]]*$' | head -1 || true)
[ -n "$detail" ] || detail="${STEP:-step}/${GATE:-gate} gate"
# Bound the finding before composing so the truncation eats the finding's tail,
# never the run id or the pointer at the durable record.
detail=$(one_line "$detail" 120)

if [ "$verb" = "needs-decision" ]; then
  what="PR watch parked"
else
  what="no-mistakes ${STEP:-step} gate unanswered after $REMINDER reminders"
fi
where=${BRANCH:-unknown branch}
# The repo only earns line budget when the park mapped to no task, where it is
# the only thing identifying where the wait is.
case "$status" in
  "$STATE/nm-park.status") [ -n "$REPO" ] && where="$where in $REPO" ;;
esac
line=$(one_line "$verb [key=$KEY]: $what on $where (run $RUN; details: no-mistakes parked): $detail")

mkdir -p "$MARKER_DIR" 2>/dev/null || true
printf '%s\n' "$line" >> "$status" 2>/dev/null || {
  echo "fm-nm-park-wake.sh: could not append the wake to $status" >&2
  exit 1
}
printf 'status=%s\nlast=%s\nreminder=%s\n' "$status" "$now" "$REMINDER" > "$marker" 2>/dev/null || true
