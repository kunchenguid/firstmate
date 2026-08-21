#!/usr/bin/env bash
# One bounded poll of the inbound WhatsApp inbox for this home.
#
# Inert by default: a HARD no-op (exit 0, no output) unless the channel is
# configured via a non-empty FM_WA_CAPTAIN in config/whatsapp.env.
# The one cycle that finds the configuration definitively gone retires its own
# artifacts, stops the listener this home started, clears the captain's stashed
# messages with them, and speaks only when that listener cannot be stopped. A
# configuration that is still there but yields no captain - unreadable,
# truncated, blanked or commented out - is not an opt-out: nothing is torn down,
# and the configuration that names nobody is reported instead.
# The watcher runs it through the ordinary registered-custom-check path
# (state/wa-watch.check.sh, bound by bin/fm-check-register.sh), so nothing in
# the supervision loop itself changes: its contract is "output => wake
# firstmate, silence => keep sleeping", and the no-op keeps a home that never
# opted in behaving exactly as before.
#
# This poll never talks to WhatsApp. bin/fm-wa-listen.sh runs the one long-lived
# connection that stashes messages; this is a local directory read plus a
# liveness nudge, so it finishes in milliseconds, far inside FM_CHECK_TIMEOUT.
#
# Behavior when the channel is on:
#   empty inbox                      -> print nothing, exit 0 (no wake)
#   an inbox set already announced   -> print nothing, exit 0
#   a new or changed inbox set       -> print one line
#                                       "wa-message <n> pending, including <id>"
#   an inbox that stayed pending past FM_WA_REANNOUNCE seconds
#                                    -> re-announce once, so a message firstmate
#                                       failed to drain is not lost silently
#   listener down, or alive with a
#   connection that is not working   -> restart it in the background, rate-limited
#   a configuration or listener fault -> one rate-limited "wa-channel-error ..."
#
# It is also the channel's janitor, silently: the listener log is capped, and
# long-expired per-message markers and outbound digests are pruned on the way
# through.
#
# Exactly one line is ever printed. A cycle that reports a channel fault stops
# there rather than also announcing the inbox, because the two lines mean
# different things to the wa-respond skill and the watcher folds them into one
# wake. The fault is deduped, so the next cycle announces any pending messages.
#
# The announcement marker is a digest of the pending id set, not a per-message
# claim: one wake covers everything waiting, and draining the inbox is what
# clears it. A check that printed on every cycle would wake firstmate constantly.

# shellcheck disable=SC2030,SC2031 # bin/fm-wa-lib.sh reads a process identity
# inside a subshell that sources bin/fm-wake-lib.sh, and that library assigns its
# own FM_HOME, FM_ROOT and STATE. The subshell IS the containment, so this file's
# own values are unaffected and every later read of them is the value it always had.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wa-lib.sh
. "$SCRIPT_DIR/fm-wa-lib.sh"

# Hard no-op when the channel is off: this is what keeps the check shim inert.
#
# Removing config/whatsapp.env is the documented opt-out, and it has to mean
# what it says. Once an armed shim counts as a reason to keep a watcher running,
# a shim left behind after the config is gone would keep this home supervised
# and sweeping every 30s for a poll that can no longer do anything. So the poll
# retires its own generated artifacts on the first cycle after the config
# disappears, the way Relay's bootstrap drops its shim and cadence when the
# pairing token goes. It removes ONLY the three files bin/fm-wa-setup.sh
# generates, never anything else under state/ or config/, and it is idempotent:
# with the artifacts already gone it does nothing and says nothing.
self_disarm() {
  local state config
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  rm -f -- "$state/wa-watch.check.sh" "$state/wa-watch.check-trust" "$config/wa-mode.env" 2>/dev/null || true
}

# Retiring the shim is only half of switching the channel off. The listener is a
# live linked device on the captain's own personal account, and once the shim is
# gone nothing polls this home again, so a listener left behind would hold that
# device forever with nothing watching it. This cycle is therefore the one that
# stops it, which is what makes the channel self-clean however it is switched
# off - config removed first, the commands run first, or neither.
#
# Only a listener this home owns is ever signalled: fm_wa_stop_listener proves
# the pid against the identity binding recorded at start, and a live process it
# cannot claim is reported rather than killed on a guess. The report has to go
# out on this cycle, because it is the last one there will be.
#
# Returns 0 only when nothing is left running, so the caller can tell whether it
# is safe to clear the records a still-live listener would keep writing to.
retire_listener() {
  local rc=0
  fm_wa_stop_listener 3 || rc=$?
  case "$rc" in
    1) printf 'wa-channel-error %s\n' "the WhatsApp channel was switched off, but the recorded listener pid is a live process this home cannot prove is its own listener; check it by hand" ;;
    2) printf 'wa-channel-error %s\n' "the WhatsApp channel was switched off, but its listener would not stop; check state/wa-listener.pid by hand" ;;
  esac
  [ "$rc" -eq 0 ]
}

# Read here, acted on further down. The channel-off paths can only speak through
# emit_error_once, which is declared below with the markers it dedupes against,
# and everything between here and there needs the paths this load sets whether
# it succeeded or not.
CONFIG_OK=1
fm_wa_load_config || CONFIG_OK=

RESTART_MARKER="$FM_WA_STATE/wa-listener.restart"
RESTART_INTERVAL=120
LISTENER_ERROR="$FM_WA_STATE/wa-listener.error"
LISTENER_STATUS="$FM_WA_STATE/wa-listener.status"
LISTENER_BEAT="$FM_WA_STATE/wa-listener.beat"
RESTART_FAILS="$FM_WA_STATE/wa-listener.restarts"
# A listener that dies this many times in a row is not going to heal itself.
RESTART_FAIL_LIMIT=3
# ...but "not going to heal itself" must not mean "off until a human notices".
# The restart history is refreshed on every attempt, so once it has gone this
# long untouched the poll tries once more. The channel therefore recovers on its
# own from a transient cause (no network at boot, a host that was asleep) while
# a genuinely broken one still reports rather than respawning every cycle.
LATCH_RETRY_INTERVAL=3600
# One live observation is not proof the channel is stable: a listener dying on a
# period longer than the check interval is seen alive on some cycles, which
# would zero the restart history before it ever reached the limit and let the
# channel flap forever while every cycle reported health. The history is only
# cleared once no restart has been needed for this long.
STABLE_INTERVAL=3600
# The listener touches its beat only while the connection is actually open, so a
# beat this stale means an alive process with a channel that is not working.
STALL_INTERVAL=900
# Housekeeping bounds. The listener logs a line per message and per reconnect,
# and keeps a durable marker per handled message, so both need a ceiling.
LOG_MAX_BYTES=262144
LOG_KEEP_LINES=2000
# Well behind any watermark a redelivery could still clear, so pruning a marker
# can never let an old message back into the inbox.
SEEN_TTL_DAYS=30
# Past the listener's ten-minute echo window an outbound digest is dead by
# definition, so nothing it could still suppress is lost by sweeping it.
SENT_TTL_MINUTES=60
# Dry-run records are evidence to read back, not durable state, and a home can
# run dry for good. Kept long enough to inspect a test, like Relay's contexts.
OUTBOX_TTL_DAYS=7

# Set when this cycle has already spoken, so the check keeps its one-line
# contract.
EMITTED=

# One diagnostic per distinct problem, not one per cycle. Every fault keeps its
# own marker - each listener fault as much as the poll's own - so clearing one
# never re-fires another, and a fault that is still true is still reported in
# its own words after a different one has spoken.
# Returns 0 when it printed, 1 when the same fault was already reported.
#
# A cycle speaks at most once, whatever it finds. Repair paths deliberately
# report and then continue - a stalled listener is stopped and the restart
# budget is consulted in the same cycle - so without this guard two faults
# could print together AND share one marker, the second overwriting the first,
# which would defeat the hour-long dedupe and re-wake firstmate on every
# subsequent cycle. The fault that loses the race is not lost: its condition is
# still there next cycle, and the marker it did not write means it is reported
# in full then.
emit_error_once() {
  local marker=$1 base=$2 msg=$3
  [ -z "$EMITTED" ] || return 1
  if [ "$(cat "$marker" 2>/dev/null)" = "$msg" ] \
    && [ "$(fm_wa_age_of "$marker")" -lt 3600 ]; then
    return 1
  fi
  printf '%s\n' "$msg" | fm_wa_publish_stdin "$FM_WA_STATE" "$base" 2>/dev/null || true
  printf 'wa-channel-error %s\n' "$msg"
  EMITTED=1
  return 0
}

# Each distinct listener fault keeps its own marker, so the specific report the
# captain can act on is never replaced by a later, more generic one: a deaf
# listener that is being replaced every couple of minutes eventually trips the
# restart block too, and sharing one marker would leave him holding only "will
# not stay healthy after restart" - which names a remedy that cannot fix a hook
# the listener program can no longer attach.
emit_listener_error() { emit_error_once "$LISTENER_ERROR.$1" "wa-listener.error.$1" "$2"; }
emit_poll_error() { emit_error_once "$FM_WA_ERROR" wa-poll.error "$1"; }
# A configuration fault keeps its own marker, and must: the quiet cycles below
# clear $FM_WA_ERROR whenever the inbox is empty and healthy, so a fault that is
# permanent until an operator edits the file would be reported, forgotten and
# reported again every other cycle - a wake storm out of one bad line, which is
# the opposite of saying it once. This one is cleared only when the
# configuration reads cleanly again.
CONFIG_ERROR_MARKER="$FM_WA_ERROR.config"
emit_config_error() { emit_error_once "$CONFIG_ERROR_MARKER" wa-poll.error.config "$1"; }

# The channel is off, and which KIND of off decides everything that follows.
#
# A configuration that is definitively gone is the documented opt-out, and this
# cycle is the last one there will ever be: it stops the listener, clears the
# captain's stashed messages and the records of them, and retires the artifacts
# that keep this home supervised. The clearing waits on the stop, because a
# listener still running would only write the inbox straight back.
#
# A configuration that is present but yields no captain is not an opt-out and
# must never be treated as one. A permission failure, the instant an editor has
# truncated the file to rewrite it, a blanked value and a commented-out key all
# land here, and only the last two could even be an attempt to switch the
# channel off - which is why none of them may. Acting on them would take the
# whole channel down for what may be a non-reason, and nothing would bring it
# back on its own within this cycle, so the captain would be left messaging a
# home that cannot answer and cannot say why. Everything is therefore left
# exactly as it is and reported through the ordinary deduped fault path, so a
# transient blip costs one line an hour rather than a wake every cycle. The
# report names the deliberate off switches instead, because the file reading
# perfectly well and simply naming nobody is the commonest way here. It speaks
# only when this home has something armed or running to lose: a home that never
# opted in stays the hard no-op it has always been.
if [ -z "$CONFIG_OK" ]; then
  if fm_wa_config_confirmed_absent; then
    if retire_listener; then
      fm_wa_purge_channel_state
    fi
    self_disarm
  elif [ -f "$FM_WA_STATE/wa-watch.check.sh" ] || fm_wa_listener_pid >/dev/null 2>&1; then
    # A line that could not be read names its own cause, and says it instead of
    # the generic report: "no captain could be read" beside a file that plainly
    # names one reads as a contradiction the operator cannot act on.
    if [ -n "${FM_WA_CONFIG_ERROR:-}" ]; then
      emit_config_error "$FM_WA_CONFIG_ERROR - the channel is left armed and running untouched"
    else
      emit_poll_error "no captain could be read from the WhatsApp channel configuration, so the channel is left armed and running untouched; blanking or commenting FM_WA_CAPTAIN is not the off switch - remove ${FM_WA_CONFIG_FILE:-config/whatsapp.env} or run bin/fm-wa-setup.sh disarm"
    fi
  fi
  exit 0
fi

# The channel is usable, but something in its configuration still is not: a
# device list that is not a list, a dry-run switch that is neither on nor off, a
# line whose quoting cannot be read. Every one of those has a documented default
# behind it, and taking that default without a word is how a home ends up
# behaving the opposite of what the file says - the operator reading
# `FM_WA_DRY_RUN=1` while replies go live to the captain's phones. Reported on
# the ordinary deduped fault path, so it costs one line an hour rather than a
# wake per cycle, and the next cycle goes on to announce his messages.
if [ -n "${FM_WA_CONFIG_ERROR:-}" ]; then
  emit_config_error "$FM_WA_CONFIG_ERROR"
else
  rm -f -- "$CONFIG_ERROR_MARKER" 2>/dev/null || true
fi

# The listener's own last reported connection state, or empty when it never
# wrote one. Read as data: the file is JSON this home wrote itself.
listener_state() {
  [ -f "$LISTENER_STATUS" ] || return 0
  sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([A-Za-z-]*\)".*/\1/p' \
    "$LISTENER_STATUS" 2>/dev/null | tail -n 1
}

# The listener reports this only while its sender-device filter has no raw
# stanza hook to feed it. The connection is healthy and the beat is fresh, so
# nothing else in this poll would notice that every inbound message is being
# rejected.
listener_device_hook() {
  [ -f "$LISTENER_STATUS" ] || return 0
  sed -n 's/.*"deviceHook"[[:space:]]*:[[:space:]]*"\([A-Za-z-]*\)".*/\1/p' \
    "$LISTENER_STATUS" 2>/dev/null | tail -n 1
}

restart_failures() {
  local n
  n=$(cat "$RESTART_FAILS" 2>/dev/null) || n=0
  case "$n" in
    ''|*[!0-9]*) n=0 ;;
  esac
  printf '%s' "$n"
}

# The restart MUST leave this check's process group, because the watcher signals
# the whole group once the check returns and would otherwise reap the listener it
# just started. setsid does that; macOS has no setsid, so fall back to perl's own
# setpgrp exactly as bin/fm-watch.sh does for the same reason. nohup is not a
# substitute: it only ignores SIGHUP and leaves the process in this group.
# The wrapper's own refusals - no node, not paired, an unusable state directory,
# an immediate exit - are raised before the listener ever opens its log, so they
# go to that same log rather than to /dev/null. The fault line this poll prints
# after three failed restarts names that log, and it must actually answer why.
# FM_WA_FORCE_SPAWN_FALLBACK=1 drives the fallback on a host that has setsid, so
# the branch a macOS host depends on is testable here, as FM_CHECK_FORCE_FALLBACK
# does for the watcher's own timeout path.
spawn_listener() {
  if [ ! -e "$FM_WA_LOG" ]; then
    ( umask 077; : >> "$FM_WA_LOG" ) 2>/dev/null || true
  fi
  if [ "${FM_WA_FORCE_SPAWN_FALLBACK:-0}" != 1 ] && command -v setsid >/dev/null 2>&1; then
    FM_HOME="$FM_HOME" FM_WA_AUTOSTART=1 setsid \
      "$SCRIPT_DIR/fm-wa-listen.sh" start >>"$FM_WA_LOG" 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # single quotes are deliberate: perl expands its own variables.
    FM_HOME="$FM_HOME" FM_WA_AUTOSTART=1 perl -e 'setpgrp(0, 0); exec @ARGV' \
      "$SCRIPT_DIR/fm-wa-listen.sh" start >>"$FM_WA_LOG" 2>&1 </dev/null &
  else
    # Spawning into this group would only feed the listener to the watcher's
    # own tidy-up, so refuse and say so rather than burning the restart budget.
    return 1
  fi
  disown 2>/dev/null || true
}

# This poll is the channel's only regular janitor, and it must stay silent while
# it works: neither branch below ever prints. The log is rewritten in place so
# the running listener's append handle keeps writing to the same file.
prune_state() {
  local size
  if [ -f "$FM_WA_LOG" ]; then
    size=$(wc -c < "$FM_WA_LOG" 2>/dev/null | tr -d '[:space:]') || size=0
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
      if ( umask 077; tail -n "$LOG_KEEP_LINES" "$FM_WA_LOG" > "$FM_WA_LOG.trim" ) 2>/dev/null; then
        cat "$FM_WA_LOG.trim" > "$FM_WA_LOG" 2>/dev/null || true
      fi
      rm -f -- "$FM_WA_LOG.trim" 2>/dev/null || true
    fi
  fi
  if [ -d "$FM_WA_SEEN" ]; then
    find "$FM_WA_SEEN" -maxdepth 1 -name '*.seen' -type f -mtime "+$SEEN_TTL_DAYS" \
      -exec rm -f -- {} + 2>/dev/null || true
  fi
  # The listener only sweeps outbound digests while handling an inbound message,
  # so a home that replies and hears nothing back never sweeps at all. This is
  # the third growth surface and it is bounded here with the other two.
  if [ -d "$FM_WA_OUTBOX" ]; then
    find "$FM_WA_OUTBOX" -maxdepth 1 -name '*.json' -type f -mtime "+$OUTBOX_TTL_DAYS" \
      -exec rm -f -- {} + 2>/dev/null || true
  fi
  if [ -d "$FM_WA_SENT" ]; then
    find "$FM_WA_SENT" -maxdepth 1 -name '*.sent' -type f -mmin "+$SENT_TTL_MINUTES" \
      -exec rm -f -- {} + 2>/dev/null || true
  fi
  # A standing dry-run home records a reply per send and never reads most of
  # them back, so the outbox is the fourth growth surface and is bounded here
  # with the rest rather than being the one the janitor skips.
}

# The beat is the listener's proof that its connection is up, so its age is how
# long the channel has been down. A listener that has never connected writes no
# beat at all, which is the same fault seen from the start rather than from a
# working connection, so the pid file's own age stands in for it.
listener_down_age() {
  if [ -f "$LISTENER_BEAT" ]; then
    fm_wa_age_of "$LISTENER_BEAT"
  else
    fm_wa_age_of "$FM_WA_PIDFILE"
  fi
}

# A wedged listener holds its pid forever, so reporting it is not enough: only
# a replacement process can bring the channel back. The stale beat, the stale
# reported state and the identity bound to the dead pid all go with it, because
# they belong to the process that stopped writing them and would otherwise make
# the fresh listener look wedged, or deaf, from its first cycle - the pid file
# appears the instant that replacement forks, well before it has loaded enough
# to claim the status file itself.
#
# The kill itself is fm_wa_stop_listener's, not a second copy of it: it proves
# ownership before signalling anything, and it waits for a SIGKILLed process to
# actually leave the process table instead of reading `kill -0` in the next
# command and concluding from a still-terminating pid that the stop failed. A
# wedged listener is exactly the one that reaches the SIGKILL, so a repair with
# its own kill sequence would be the one place that answer is always wrong. The
# grace is short because a check cycle has far less room than a typed command.
stop_wedged_listener() {
  fm_wa_stop_listener 3 || return 1
  rm -f -- "$LISTENER_BEAT" "$LISTENER_STATUS" 2>/dev/null || true
  return 0
}

# Keep the one long-lived connection up without ever blocking this check: the
# start is a detached background spawn and its outcome is reported next cycle.
# A pid alone is not health, so a live listener is still judged by the state it
# reports and by its beat.
ensure_listener() {
  local state fails
  state=$(listener_state)
  if fm_wa_listener_pid >/dev/null 2>&1; then
    if [ "$(listener_down_age)" -ge "$STALL_INTERVAL" ]; then
      # Reported AND repaired: the restart below runs on the same budget that
      # bounds a crash loop, so a channel that cannot recover still latches
      # instead of respawning forever.
      if [ -f "$LISTENER_BEAT" ]; then
        emit_listener_error stalled "WhatsApp listener is running but its connection is down; restarting it, see state/wa-listener.log"
      else
        emit_listener_error never-up "WhatsApp listener is running but its connection has never come up; restarting it, see state/wa-listener.log"
      fi
      stop_wedged_listener || return 1
    elif [ "$(listener_device_hook)" = unavailable ]; then
      # The hook is attached once per connection, so only a replacement process
      # can pick it up: a listener holding a healthy socket would otherwise
      # reject every message the captain sends for as long as that socket
      # lasts. Reported AND repaired, on the same budget as a stalled one.
      emit_listener_error device-hook "WhatsApp listener cannot read message sender devices, so every message from the captain would be rejected; restarting it, see state/wa-listener.log"
      stop_wedged_listener || return 1
    else
      return 0
    fi
  fi
  # A pid file naming a live process this home cannot claim is not a stale one,
  # and the difference matters most here. Every other path - stop, unpair,
  # disarm, status, and the retiring cycle - reports it rather than acting,
  # because signalling a stranger is not this home's to do; spawning past it
  # would instead put a SECOND connection on the one credential folder WhatsApp
  # allows, which is the failure the whole design is built to avoid, and would
  # then overwrite the pid file so the first listener is untracked as well. This
  # is the only unattended path, so it is the one place that must not be the
  # exception: it says so and starts nothing.
  if fm_wa_listener_pid_foreign; then
    emit_listener_error foreign "the recorded WhatsApp listener pid is a live process this home cannot prove is its own listener, so nothing was started or signalled; check state/wa-listener.pid by hand"
    return 1
  fi
  if [ "$state" = "logged-out" ]; then
    emit_listener_error logged-out "WhatsApp listener was logged out; re-pair with bin/fm-wa-listen.sh unpair then pair"
    return 1
  fi
  if ! fm_wa_paired; then
    emit_listener_error unpaired "WhatsApp listener is not paired; run bin/fm-wa-listen.sh pair"
    return 1
  fi
  fails=$(restart_failures)
  if [ "$fails" -ge "$RESTART_FAIL_LIMIT" ] \
    && [ "$(fm_wa_age_of "$RESTART_FAILS")" -lt "$LATCH_RETRY_INTERVAL" ]; then
    emit_listener_error restart-latch "WhatsApp listener will not stay healthy after restart; see state/wa-listener.log, then run bin/fm-wa-listen.sh restart"
    return 1
  fi
  if [ "$(fm_wa_age_of "$RESTART_MARKER")" -lt "$RESTART_INTERVAL" ]; then
    return 1
  fi
  if ! spawn_listener; then
    emit_listener_error no-detach "WhatsApp listener cannot be restarted: this host has neither setsid nor perl to detach it"
    return 1
  fi
  : | fm_wa_publish_stdin "$FM_WA_STATE" "wa-listener.restart" 2>/dev/null || true
  printf '%s\n' "$(( fails + 1 ))" \
    | fm_wa_publish_stdin "$FM_WA_STATE" "wa-listener.restarts" 2>/dev/null || true
  return 1
}

prune_state

if ensure_listener; then
  rm -f -- "$LISTENER_ERROR" "$LISTENER_ERROR".* 2>/dev/null || true
  if [ "$(fm_wa_age_of "$RESTART_MARKER")" -ge "$STABLE_INTERVAL" ]; then
    rm -f -- "$RESTART_FAILS" 2>/dev/null || true
  fi
fi

# A fault line and an inbox line mean different things to wa-respond, and the
# watcher would fold both into one wake, so a cycle that reported a fault stops.
[ -z "$EMITTED" ] || exit 0

[ -d "$FM_WA_INBOX" ] || exit 0

# Sorted so the digest depends on the pending set, not on readdir order. The
# named id is just the first in that order - WhatsApp ids are not chronological,
# so the wake line names one for traceability and the skill drains them all.
# `find -printf` is a GNU extension, so the basename is taken with sed instead.
FOUND=$(find "$FM_WA_INBOX" -maxdepth 1 -name '*.json' -type f 2>/dev/null \
  | sed 's#.*/##' | LC_ALL=C sort) || exit 0

# An entry whose stem cannot be used as an id is dropped from the set rather
# than aborting the announcement: total silence is the one outcome this channel
# exists to prevent, and the messages behind it are real. It is still reported,
# on the first cycle that has no announcement to make, so it cannot outlive
# every drain unseen. The listener's own id check keeps this unreachable through
# the normal path.
PENDING=
UNUSABLE=
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if fm_wa_id_safe "${entry%.json}"; then
    PENDING=${PENDING}${entry}$'\n'
  else
    UNUSABLE=1
  fi
done <<EOF
$FOUND
EOF
PENDING=${PENDING%$'\n'}

if [ -z "$PENDING" ]; then
  if [ -n "$UNUSABLE" ]; then
    emit_poll_error "inbox holds an unusable message id"
  else
    rm -f -- "$FM_WA_ERROR" "$FM_WA_OFFERED" 2>/dev/null
  fi
  exit 0
fi

COUNT=$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')
FIRST=$(printf '%s\n' "$PENDING" | head -n 1)
FIRST=${FIRST%.json}

# Without a digest the announcement marker cannot be written, so the cycle can
# neither announce nor dedupe. Exiting quietly there would leave the captain's
# messages piling up with firstmate never woken and never told why, which is the
# total silence this channel exists to prevent, so it is reported like every
# other fault on this path instead. fm_wa_sha256 fails only on a host with
# neither sha256sum nor shasum, and bin/fm-wa-send.sh already names that cause.
SIG=$(printf '%s\n' "$PENDING" | fm_wa_sha256) || SIG=
if [ -z "$SIG" ]; then
  emit_poll_error "cannot announce the WhatsApp inbox: this host has neither sha256sum nor shasum to digest it"
  exit 0
fi

# Same pending set as the last announcement, and not yet stale enough to repeat.
if [ "$(cat "$FM_WA_OFFERED" 2>/dev/null)" = "$SIG" ] \
  && [ "$(fm_wa_age_of "$FM_WA_OFFERED")" -lt "$FM_WA_REANNOUNCE" ]; then
  # An announcement always wins the cycle it is made on, so a skipped entry is
  # reported here instead: an otherwise quiet cycle is the only place a second
  # line can go without burying the messages, and the fault is deduped for an
  # hour so it is said once rather than every cycle.
  [ -z "$UNUSABLE" ] || emit_poll_error "inbox holds an unusable message id"
  exit 0
fi

printf '%s\n' "$SIG" | fm_wa_publish_stdin "$FM_WA_STATE" "wa-poll.offered" 2>/dev/null \
  || { emit_poll_error "cannot record the WhatsApp inbox announcement"; exit 0; }

rm -f -- "$FM_WA_ERROR" 2>/dev/null || true
printf 'wa-message %s pending, including %s\n' "$COUNT" "$FIRST"
