#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode whenever session-lock ownership was not verified.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if a task is in flight (a state/<id>.meta exists) or X-mode relay
# polling is active (state/x-watch.check.sh exists), it reports one of three
# supervision states through fm_watcher_healthy / fm_watcher_clean_handoff
# (bin/fm-wake-lib.sh):
#   healthy  - an identity-matched watcher holds the lock with a beacon
#              (state/.last-watcher-beat, touched every poll cycle) fresh within
#              FM_GUARD_GRACE seconds. Silent.
#   handoff  - the watcher completed a cycle, delivered its wake and exited, and
#              a re-arm is owed. fm-watch.sh is built to cycle and exit, so this
#              is the normal state for the whole wake-handling window. One
#              concise notice per episode; it is not a failure and never claims
#              supervision is off.
#   down     - supervision is genuinely absent. Prints a loud, clearly delimited
#              banner so the agent cannot skim past it in the tool output of
#              whatever it was doing - the one channel every harness has.
# The banner and the notice both state the condition the health check ACTUALLY
# rejected on, never an explanation rendered from some other field.
# Each is emitted once per distinct episode in this FM_HOME (keyed to the state
# plus the beacon mtime or its absence, so a handoff whose re-arm never came
# still escalates to the full banner once the beacon goes stale); later guarded
# commands in the same episode print a one-line reminder or nothing.
# Episode state lives only under state/.guard-watcher-stale-banner (volatile,
# bounded). Independent alarms (queued wakes, worktree tangle) are never
# suppressed by that dedup. Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WATCH="$SCRIPT_DIR/fm-watch.sh"
GRACE=${FM_GUARD_GRACE:-300}
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# Volatile, home-scoped episode marker: one line = the current stale-episode key.
# Cleared when the home leaves the unhealthy state so a later episode re-arms.
STALE_BANNER_MARKER="$STATE/.guard-watcher-stale-banner"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Deterministic episode key from the reported state plus beacon state: same
# state over the same continuous beacon (or continuous absence) shares a key; a
# recovered-then-restale beacon gets a new mtime and therefore a new episode.
# The state class is part of the key because a handoff can outlive its grace
# window without the beacon ever changing, and that escalation to a genuine
# watcher-down alarm must not be swallowed as "already announced".
fm_guard_stale_episode_key() {
  local state=$1 class=$2 beat m
  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    printf '%s:beat:%s\n' "$class" "${m:-unknown}"
  else
    printf '%s:beat:absent\n' "$class"
  fi
}

# Claim the full banner for this episode. Exit 0 = print full banner (this call
# owns the first announcement). Exit 1 = same episode already announced (print
# reminder). The shared wake lock helper owns the race-safety mechanics; the
# re-check under the lock makes concurrent claims idempotent.
fm_guard_claim_stale_banner() {
  local state=$1 key=$2
  local marker="$state/.guard-watcher-stale-banner"
  local lock="$state/.guard-watcher-stale-banner.lock"
  local seen i

  seen=$(cat "$marker" 2>/dev/null || true)
  # Strip a single trailing newline so key comparison is line-content based.
  seen=${seen%$'\n'}
  if [ "$seen" = "$key" ]; then
    return 1
  fi

  i=0
  while [ "$i" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      seen=$(cat "$marker" 2>/dev/null || true)
      seen=${seen%$'\n'}
      if [ "$seen" = "$key" ]; then
        fm_lock_release "$lock" 2>/dev/null || true
        return 1
      fi
      # Bounded write: one line, no growth across episodes (overwrite).
      printf '%s\n' "$key" > "$marker" || true
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    seen=$(cat "$marker" 2>/dev/null || true)
    seen=${seen%$'\n'}
    if [ "$seen" = "$key" ]; then
      return 1
    fi
    # Brief yield; 0.02s is fine on macOS/Linux sleep, fall back to 1s.
    sleep 0.02 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  # Contended past the spin budget: stay loud rather than dropping the alarm.
  return 0
}

fm_guard_stale_banner_seen() {
  local state=$1 key=$2
  local marker="$state/.guard-watcher-stale-banner"
  local seen

  seen=$(cat "$marker" 2>/dev/null || true)
  seen=${seen%$'\n'}
  [ "$seen" = "$key" ]
}

fm_guard_clear_stale_banner() {
  rm -f "$STALE_BANNER_MARKER" 2>/dev/null || true
}

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to a session with verified fleet-lock ownership.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Compute supervision need and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Act when work, an event
# source, or an X-mode relay poll needs supervision.
fm_supervision_status "$STATE" "$GRACE"
in_flight=$FM_SUP_IN_FLIGHT
sources=$FM_SUP_SOURCES
needed=$FM_SUP_NEEDED
beacon_desc=$FM_SUP_BEACON_DESC
# One health call decides the state; fm_watcher_clean_handoff then reads that
# same call's recorded rejection reason to separate a completed cycle from a
# watcher that broke.
watcher_state=down
if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  watcher_state=healthy
elif fm_watcher_clean_handoff "$STATE" "$GRACE"; then
  watcher_state=handoff
fi
# The banner blames the condition the health check actually rejected on. The
# default covers only an unset reason, and names the beacon the banner prints
# rather than inventing a condition that was never tested.
watcher_reason_detail=${FM_WATCHER_UNHEALTHY_DETAIL:-no watcher has a fresh beacon}
if [ "$needed" = false ]; then
  # Leave the unhealthy state (nothing riding on the watcher): clear so a later
  # work or X-mode need + stale combination is a fresh episode even if the
  # beacon is still absent with the same key string.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
  exit 0
fi

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# A completed cycle awaiting re-arm is not absent supervision: say so once, in
# words that do not send firstmate chasing a watcher failure that did not happen.
if [ "$watcher_state" = handoff ]; then
  episode_key=$(fm_guard_stale_episode_key "$STATE" handoff)
  episode_key=${episode_key%$'\n'}
  print_handoff_notice=0
  if [ "$READ_ONLY" -eq 1 ]; then
    fm_guard_stale_banner_seen "$STATE" "$episode_key" || print_handoff_notice=1
  elif fm_guard_claim_stale_banner "$STATE" "$episode_key"; then
    print_handoff_notice=1
  fi
  if [ "$print_handoff_notice" -eq 1 ]; then
    if [ "$READ_ONLY" -eq 1 ]; then
      printf 'NOTICE: watcher handed off - it delivered a wake and exited cleanly (last beat: %s); a session with verified fleet-lock ownership re-arms it.\n' \
        "$beacon_desc" >&2
    else
      printf 'NOTICE: watcher handed off - it delivered a wake and exited cleanly (last beat: %s); the emitted supervision protocol re-arms it as part of ordinary wake handling.\n' \
        "$beacon_desc" >&2
    fi
  fi
# No watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line. Later
# calls in the same episode get a one-line reminder only.
elif [ "$watcher_state" = down ]; then
  episode_key=$(fm_guard_stale_episode_key "$STATE" down)
  episode_key=${episode_key%$'\n'}
  print_full_banner=0
  if [ "$READ_ONLY" -eq 1 ]; then
    fm_guard_stale_banner_seen "$STATE" "$episode_key" || print_full_banner=1
  elif fm_guard_claim_stale_banner "$STATE" "$episode_key"; then
    print_full_banner=1
  fi
  if [ "$print_full_banner" -eq 1 ]; then
    afk=0
    [ -e "$STATE/.afk" ] && afk=1
    queue_arg=0
    "$queue_pending" && queue_arg=1
    x_mode=0
    [ -f "$CONFIG/x-mode.env" ] && x_mode=1
    fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
      --read-only "$READ_ONLY" \
      --afk "$afk" \
      --x-mode "$x_mode" \
      --queue-pending "$queue_arg" \
      --repair-line 2>/dev/null || printf '%s\n' 'Repair missing watcher supervision according to the session-start operating block.')
    rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    {
      printf '●%s\n' "$rule"
      printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
      if [ "$in_flight" -gt 0 ]; then
        printf '●  %s task(s) in flight, but %s (last beat: %s, grace %ss).\n' "$in_flight" "$watcher_reason_detail" "$beacon_desc" "$GRACE"
      elif [ "$sources" -gt 0 ]; then
        printf '●  %s process-event source(s) registered, but %s (last beat: %s, grace %ss).\n' "$sources" "$watcher_reason_detail" "$beacon_desc" "$GRACE"
      else
        printf '●  X-mode relay polling needs supervision, but %s (last beat: %s, grace %ss).\n' "$watcher_reason_detail" "$beacon_desc" "$GRACE"
      fi
      if [ "$READ_ONLY" -eq 1 ]; then
        printf '●  This read-only session should report the lapse, not repair it.\n'
      else
        printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
      fi
      printf '●  %s\n' "$CONTINUE_LINE"
      printf '●  %s\n' "$fix"
      printf '●%s\n' "$rule"
    } >&2
  else
    printf 'WARNING: watcher still down (same stale episode; last beat: %s, grace %ss) - full banner already printed this episode.\n' \
      "$beacon_desc" "$GRACE" >&2
  fi
else
  # Healthy again while work is still in flight: end the episode so a later
  # handoff or lapse announces itself afresh.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
# Dedup of the watcher-down banner never suppresses this warning.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership." >&2
  else
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
