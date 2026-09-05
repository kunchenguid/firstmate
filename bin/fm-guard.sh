#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode whenever session-lock ownership was not verified.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if a task is in flight (a state/<id>.meta exists) or X-mode relay
# polling is active (state/x-watch.check.sh exists) and supervision is not
# healthy, prints a loud, clearly delimited banner so the agent cannot skim past
# it in the tool output of whatever it was doing - the one channel every harness
# has. Supervision health is MODEL-AWARE (fm_watcher_supervision_verdict in
# bin/fm-wake-lib.sh), and so is what this guard DOES about it:
# under the Claude Stop auto-arm model the watcher runs only between turns, so
# an aged beacon mid-turn is the ordinary state and there is no passive banner at
# all; instead, an auto-arm ledger that has gone quiet past a generous bound
# while supervision is needed triggers a bounded mid-turn self-heal of the
# Stop-owned owner path, and the guard prints one line only when that self-heal
# fails (fm_guard_autoarm_self_heal below owns the evidence, the repair, and why
# the beacon is not the question for this model). Under the Pi
# extension model the extension tears the watcher down and respawns it on every
# actionable wake, so a fresh beacon with a genuinely unheld lock is healthy
# while that live Pi session provably owns continuity; any held but unhealthy
# lock is down; under every
# persistent-watcher harness a live identity-matched watcher with a fresh beacon
# is required. For those two models the banner names the true failing condition
# (a missing live watcher process vs a genuinely stale beacon). The full banner is emitted once
# per distinct down-episode in this FM_HOME (keyed to the failing condition, not
# the beacon mtime, which a healthy between-turns watcher advances every poll);
# later guarded commands in the same episode print a one-line reminder instead.
# Episode state lives only under state/.guard-watcher-stale-banner (volatile,
# bounded). Independent alarms (queued wakes, worktree tangle) are never
# suppressed by that dedup. Normal wake handling (watcher briefly down between a
# wake and the next supervision resume) stays inside the grace window and stays
# silent. The queued-wakes warning stays silent for the supervision branch
# actor (FM_SUPERVISION_ACTOR=branch), because that actor runs guarded commands
# while handling exactly the queued rows its grant covers and can drain nothing
# else. Always exits 0: the guard warns, it never blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WATCH="$SCRIPT_DIR/fm-watch.sh"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
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
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

# The current actor (fm_lease_actor is the one owner of that identity); a
# malformed value is a wiring bug elsewhere, so the guard just warns as main.
GUARD_ACTOR=$(fm_lease_actor 2>/dev/null) || GUARD_ACTOR=main

# Deterministic episode key from the qualitative down-state (the failing
# condition), NOT the beacon mtime: under the auto-arm model a healthy
# between-turns watcher advances that mtime every poll, which made the "same
# episode" key change every turn and re-print the full banner. Keying on the
# failing condition keeps one continuous down-episode stable, while positive
# recovery clears the marker (below) and re-arms the next episode.
fm_guard_stale_episode_key() {
  printf '%s\n' "$1"
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

# --- auto-arm model: mid-turn self-heal instead of a passive banner ----------
# Under the Stop auto-arm model the watcher runs only BETWEEN turns, so mid-turn
# there is legitimately no watcher and the beacon ages. Printing "SUPERVISION IS
# OFF" for that was a false alarm in essentially every printing (2026-09-04
# investigation: 2 banners and 19 reminders in one session, and 72 of that
# session's 179 commands had been wrapped in a grep filter to hide them, which
# also hid the independent queued-wakes and worktree-tangle alarms). The beacon
# cannot answer the only question worth asking here, so this branch does not ask
# it: it asks whether the ARM MECHANISM is still running, and if it is not, it
# repairs what it can and speaks only when the repair fails.
#
# The auto-arm ledger (state/.claude-autoarm-epoch) advances at every turn end
# while supervision is needed, so its age - not the beacon's - is the evidence
# that the Stop hook has stopped arming. The bound is deliberately generous: a
# single long working turn advances nothing, and that must stay silent.
# Fixed, not configurable: this bound exists to stay far clear of any single
# working turn, which is a property of the model rather than a local preference.
AUTOARM_LEDGER_GRACE=7200

# Claim one auto-arm generation, launch its arm in the backend-owned non-visible
# terminal lifecycle, and bound only the wait for the watcher's first beat.
# Prints the reason on failure; silent and 0 once a watcher is verified.
fm_guard_autoarm_accept_heal() {
  local gen=$1
  if [ -e "$FAILURE_ALARM" ] || [ -L "$FAILURE_ALARM" ]; then
    rm -f "$FAILURE_ALARM" 2>/dev/null || true
    if [ -e "$FAILURE_ALARM" ] || [ -L "$FAILURE_ALARM" ]; then
      printf 'a spent supervision failure episode could not be cleared'
      return 1
    fi
  fi
  if ! fm_autoarm_write_owned "$STATE" "$gen" healthy >/dev/null 2>&1; then
    printf 'the healthy supervision generation could not be published'
    return 1
  fi
}

fm_guard_autoarm_self_heal() {
  local claim_rc gen launch_out launch_status wait_secs attempts=0 beacon_before beacon_after delivery_before delivery_after
  if fm_autoarm_claim_open "$STATE" "$GRACE"; then
    return 0
  fi
  if fm_lock_role "$OWNER_LOCK" >/dev/null 2>&1; then
    fm_autoarm_release_abandoned "$STATE" "$GRACE" || {
      printf 'a stalled supervision claim could not be released'
      return 1
    }
  fi
  fm_autoarm_claim_next "$STATE" "$GRACE"
  claim_rc=$?
  [ "$claim_rc" -ne 2 ] || return 0
  if [ "$claim_rc" -ne 0 ]; then
    printf 'a supervision generation could not be claimed'
    return 1
  fi
  gen=$FM_AUTOARM_MY_GEN
  beacon_before=$(fm_path_mtime "$STATE/.last-watcher-beat" 2>/dev/null || true)
  delivery_before=$(tail -n 1 "$STATE/.watch-deliveries.log" 2>/dev/null || true)
  if ! launch_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-afk-launch.sh" start-watcher 2>&1); then
    fm_autoarm_write_owned "$STATE" "$gen" failed >/dev/null 2>&1 || true
    launch_out=$(printf '%s\n' "$launch_out" | tail -n 1)
    printf '%s' "${launch_out:-the tracked watcher owner could not launch}"
    return 1
  fi
  launch_status=$(printf '%s\n' "$launch_out" | tail -n 1)
  case "$launch_status" in
    'watcher-owner: preserved '*) fm_guard_autoarm_accept_heal "$gen"; return $? ;;
  esac
  wait_secs=$(fm_watcher_phase_timeout 10 "$GRACE")
  while [ "$attempts" -lt $((wait_secs * 10)) ]; do
    if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
      fm_guard_autoarm_accept_heal "$gen"
      return $?
    fi
    beacon_after=$(fm_path_mtime "$STATE/.last-watcher-beat" 2>/dev/null || true)
    delivery_after=$(tail -n 1 "$STATE/.watch-deliveries.log" 2>/dev/null || true)
    if { [ -z "$beacon_before" ] && [ -n "$beacon_after" ]; } \
      || { [ -n "$beacon_before" ] && [ -n "$beacon_after" ] && [ "$beacon_after" -gt "$beacon_before" ]; } \
      || { [ -n "$delivery_after" ] && [ "$delivery_after" != "$delivery_before" ]; }; then
      fm_guard_autoarm_accept_heal "$gen"
      return $?
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  fm_autoarm_write_owned "$STATE" "$gen" failed >/dev/null 2>&1 || true
  printf 'the tracked watcher owner produced no first beat'
  return 1
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
fm_watcher_supervision_verdict "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$FM_ROOT"
watcher_healthy=$FM_WATCHER_VERDICT_OK
watcher_down_reason=$FM_WATCHER_VERDICT_REASON
if [ "$needed" = false ]; then
  # Leave the unhealthy state (nothing riding on the watcher): clear so a later
  # work or X-mode need + stale combination is a fresh episode even if the
  # beacon is still absent with the same key string.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
  exit 0
fi

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line. Later
# calls in the same episode get a one-line reminder only.
supervision_model=$(fm_supervision_model)
if [ "$watcher_healthy" = false ] && [ "$supervision_model" = autoarm ] && [ "$READ_ONLY" -ne 1 ]; then
  # No passive banner for this model: see fm_guard_autoarm_self_heal above.
  # A ledger that is still advancing means the Stop-owned mechanism is arming at
  # every turn end, so the aged beacon is the expected mid-turn state and this
  # guard says nothing at all. Only a ledger that has gone quiet past its
  # generous bound, with supervision still needed, is evidence the mechanism has
  # stopped - and even then the guard repairs first and speaks only if it cannot.
  # in_flight, not the broader supervision need: a process-event source or an
  # X-mode relay poll with no task in flight must not let a stale ledger mutate
  # auto-arm state or surface a failure outside the authorized gate.
  if [ "$in_flight" -gt 0 ] \
    && [ "$(fm_path_age "$STATE/.claude-autoarm-epoch")" -ge "$AUTOARM_LEDGER_GRACE" ]; then
    self_heal_rc=0
    self_heal_reason=$(fm_guard_autoarm_self_heal) || self_heal_rc=$?
    if [ "$self_heal_rc" -eq 0 ]; then
      # A successful self-heal is silent, and it ends any earlier failure
      # episode so a later genuine one announces again.
      fm_guard_clear_stale_banner
    else
      episode_key=$(fm_guard_stale_episode_key autoarm-self-heal-failed)
      episode_key=${episode_key%$'\n'}
      if fm_guard_claim_stale_banner "$STATE" "$episode_key"; then
        printf 'WARNING: supervision could not re-arm: %s. %s\n' \
          "$self_heal_reason" "$CONTINUE_LINE" >&2
      fi
    fi
  fi
elif [ "$watcher_healthy" = false ]; then
  episode_key=$(fm_guard_stale_episode_key "$watcher_down_reason")
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
      if [ "$watcher_down_reason" = no-watcher ]; then
        watcher_cause=$(printf 'no live watcher process holds this home lock (last beat: %s)' "$beacon_desc")
      else
        watcher_cause=$(printf 'no watcher has a fresh beacon (last beat: %s, grace %ss)' "$beacon_desc" "$GRACE")
      fi
      if [ "$in_flight" -gt 0 ]; then
        printf '●  %s task(s) in flight, but %s.\n' "$in_flight" "$watcher_cause"
      elif [ "$sources" -gt 0 ]; then
        printf '●  %s process-event source(s) registered, but %s.\n' "$sources" "$watcher_cause"
      else
        printf '●  X-mode relay polling needs supervision, but %s.\n' "$watcher_cause"
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
  # restale re-prints the full banner.
  [ "$READ_ONLY" -eq 1 ] || fm_guard_clear_stale_banner
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
# Dedup of the watcher-down banner never suppresses this warning.
# The supervision branch is the exception: it runs guarded commands (fm-peek,
# fm-crew-state) in the middle of handling the very rows that are queued, and
# "drain them before anything else" mid-handling reads as "an earlier wake is
# still pending", which is what made it re-run a previous acknowledgement in a
# loop. The branch can act on nothing outside its grant anyway, so for that
# actor the guard stays silent about queued rows.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership." >&2
  elif [ "$GUARD_ACTOR" != branch ]; then
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
