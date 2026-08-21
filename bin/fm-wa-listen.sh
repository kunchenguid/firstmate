#!/usr/bin/env bash
# Supervise the inbound WhatsApp listener for this home.
#
# Usage:
#   fm-wa-listen.sh start        launch the listener in the background (idempotent)
#   fm-wa-listen.sh stop         stop it
#   fm-wa-listen.sh restart      stop then start
#   fm-wa-listen.sh status       report pairing and liveness
#   fm-wa-listen.sh pair [num] [--rounds N]
#                                pair a NEW linked device and print the code the
#                                captain types into WhatsApp on his phone; each
#                                code lives a couple of minutes, so --rounds
#                                keeps issuing a fresh one when the last expires
#   fm-wa-listen.sh unpair       delete this listener's credentials; with the
#                                channel already off it is the last step of
#                                switching it off, so it clears the captain's
#                                stashed messages and channel records too
#   fm-wa-listen.sh logs [n]     tail the listener log
#
# The listener holds its OWN linked-device credentials in state/wa-auth, which
# is deliberately NOT mudslide's folder: WhatsApp allows one live connection per
# credential folder, so sharing mudslide's would break `mudslide send`. Sending
# stays entirely on mudslide (bin/fm-wa-send.sh) and is never touched by this
# script. docs/whatsapp-channel.md owns that decision in full.
#
# start and pair are a hard no-op with a clear message when the channel is off,
# because they act as the captain and need the identity that is gone. stop,
# unpair, logs and status deliberately keep working without it: a listener
# outlives the config that started it, and a cleanup path that needs the thing
# it is cleaning up is not a cleanup path. Whether the channel is off is also
# what tells a re-pair from a teardown, which is why only unpair reads it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wa-lib.sh
. "$SCRIPT_DIR/fm-wa-lib.sh"

LISTENER="$SCRIPT_DIR/fm-wa-listen.mjs"

usage() {
  sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Starting and pairing act AS the captain, so they genuinely need his identity.
require_config() {
  if ! fm_wa_load_config; then
    if [ -n "${FM_WA_CONFIG_ERROR:-}" ]; then
      echo "WhatsApp channel is off: $FM_WA_CONFIG_ERROR" >&2
    else
      echo "WhatsApp channel is off: no FM_WA_CAPTAIN in ${FM_WA_CONFIG_FILE:-config/whatsapp.env}" >&2
    fi
    return 1
  fi
  command -v node >/dev/null 2>&1 || { echo "error: node is required for the WhatsApp listener" >&2; return 1; }
  [ -f "$LISTENER" ] && [ ! -L "$LISTENER" ] || { echo "error: listener program is unavailable" >&2; return 1; }
}

# Stopping, unpairing, reading the log and reporting must NEVER require the
# thing they are tearing down or inspecting: a cleanup path that only works
# while the config is present is not a cleanup path. A listener outlives the
# config that started it, so these load what configuration there is and carry on
# without it. fm_wa_load_config sets this home's paths before it decides the
# channel is off, so the pid file, the credentials and the log are all reachable
# either way. Returns 0 when the channel is on and 1 when it is off, so the one
# caller that words itself differently can tell; the rest ignore it.
optional_config() {
  fm_wa_load_config
}

listener_env() {
  FM_WA_STATE="$FM_WA_STATE" \
  FM_WA_AUTH_DIR="$FM_WA_AUTH_DIR" \
  FM_WA_CAPTAIN="$(fm_wa_captains_wire "$FM_WA_CAPTAIN")" \
  FM_WA_ALLOW_DEVICES="$FM_WA_ALLOW_DEVICES" \
  FM_WA_HISTORY_HORIZON="$FM_WA_HISTORY_HORIZON" \
  FM_WA_BAILEYS_DIR="${FM_WA_BAILEYS_DIR:-}" \
  node "$LISTENER" "$@"
}

# Pairing state changed, so every record of the OLD link's health is stale.
# Left behind, they make the poll report a fault that has just been repaired and
# suppress the restart that would bring the new link up.
clear_listener_health() {
  rm -f -- \
    "$FM_WA_STATE/wa-listener.status" \
    "$FM_WA_STATE/wa-listener.beat" \
    "$FM_WA_STATE/wa-listener.error" \
    "$FM_WA_STATE"/wa-listener.error.* \
    "$FM_WA_STATE/wa-listener.restart" \
    "$FM_WA_STATE/wa-listener.restarts" 2>/dev/null || true
}

cmd_start() {
  local started_pid waited
  require_config || return 1
  if fm_wa_listener_pid >/dev/null; then
    echo "listener already running (pid $(fm_wa_listener_pid))"
    return 0
  fi
  # A live pid this home cannot claim is not a stale record to write over. Every
  # path that stops the listener refuses to signal one, and starting past it is
  # the mirror image of the same mistake: it would put a second connection on the
  # one credential folder WhatsApp allows and then overwrite the pid file, so the
  # first process is left running and untracked. This is also the only place the
  # pid file is ever written, so the refusal belongs here as well as in the
  # poll's own restart path, which reaches the spawn through this command.
  if fm_wa_listener_pid_foreign; then
    echo "error: state/wa-listener.pid names a live process this home cannot prove is its own listener; nothing was started, check it by hand" >&2
    return 1
  fi
  if ! fm_wa_paired; then
    echo "not paired: run bin/fm-wa-listen.sh pair and have the captain enter the code" >&2
    return 1
  fi
  fm_wa_private_dir "$FM_WA_STATE" || { echo "error: state directory is unavailable" >&2; return 1; }
  fm_wa_private_dir "$FM_WA_AUTH_DIR" || { echo "error: credential directory is unavailable" >&2; return 1; }
  # The beat and the reported connection state belong to the process that wrote
  # them, and so does the identity bound to the old pid. Left behind, the
  # previous listener's records make this one look wedged, or deaf, or like a
  # pid that is not ours, from its very first cycle - and the poll would stop it
  # again before it ever connected. The pid file appears the instant the process
  # is forked, well before the listener has loaded enough to claim the status
  # file itself, so clearing them here is what closes that window.
  rm -f -- \
    "$FM_WA_STATE/wa-listener.beat" \
    "$FM_WA_STATE/wa-listener.status" \
    "$FM_WA_PIDFILE_IDENTITY" 2>/dev/null || true
  ( umask 077
    FM_WA_STATE="$FM_WA_STATE" \
    FM_WA_AUTH_DIR="$FM_WA_AUTH_DIR" \
    FM_WA_CAPTAIN="$(fm_wa_captains_wire "$FM_WA_CAPTAIN")" \
    FM_WA_ALLOW_DEVICES="$FM_WA_ALLOW_DEVICES" \
    FM_WA_HISTORY_HORIZON="$FM_WA_HISTORY_HORIZON" \
    FM_WA_BAILEYS_DIR="${FM_WA_BAILEYS_DIR:-}" \
    nohup node "$LISTENER" listen >> "$FM_WA_LOG" 2>&1 &
    echo $! > "$FM_WA_PIDFILE"
  )
  chmod 600 "$FM_WA_PIDFILE" "$FM_WA_LOG" 2>/dev/null || true
  # Bind the pid to this process now, while it is still unambiguously the one we
  # just started, so a later stop can prove what it is signalling. The forked
  # pid does not name the listener until nohup has handed it to node by exec,
  # and the identity carries the command, so this waits for that handoff first;
  # a pid that never reaches it is bound to nothing and falls back to the
  # command check rather than carrying a binding that is already wrong.
  started_pid=$(cat "$FM_WA_PIDFILE" 2>/dev/null) || started_pid=
  waited=0
  while [ "$waited" -lt 20 ] && ! fm_wa_process_is_listener "$started_pid"; do
    kill -0 "$started_pid" 2>/dev/null || break
    sleep 0.1 2>/dev/null || sleep 1
    waited=$(( waited + 1 ))
  done
  if fm_wa_process_is_listener "$started_pid"; then
    fm_wa_record_listener_identity "$started_pid" 2>/dev/null || true
  fi
  sleep 1
  if fm_wa_listener_pid >/dev/null; then
    # A start run by hand is the operator's own repair, so it releases the
    # poll's restart history and the block it holds. An automatic restart the
    # poll spawned must not, or a listener that dies slowly would erase the very
    # history that proves it is flapping.
    if [ -z "${FM_WA_AUTOSTART:-}" ]; then
      rm -f -- \
        "$FM_WA_STATE/wa-listener.restarts" \
        "$FM_WA_STATE/wa-listener.restart" \
        "$FM_WA_STATE/wa-listener.error" \
        "$FM_WA_STATE"/wa-listener.error.* 2>/dev/null || true
    fi
    echo "listener started (pid $(fm_wa_listener_pid))"
  else
    echo "error: listener exited immediately; see state/wa-listener.log" >&2
    return 1
  fi
}

cmd_stop() {
  local running='' rc=0
  optional_config || true
  fm_wa_listener_pid >/dev/null 2>&1 && running=1
  fm_wa_stop_listener 10 || rc=$?
  case "$rc" in
    1)
      echo "refusing to stop: the recorded listener pid names a live process this home cannot prove is its own listener" >&2
      return 1
      ;;
    2)
      echo "error: the listener did not exit; see state/wa-listener.pid" >&2
      return 1
      ;;
  esac
  if [ -n "$running" ]; then
    echo "listener stopped"
  else
    echo "listener is not running"
  fi
  if [ -f "$FM_WA_STATE/wa-watch.check.sh" ]; then
    echo "note: the armed check restarts it within a couple of minutes;"
    echo "      run bin/fm-wa-setup.sh disarm to keep it down - it stops the listener too"
  fi
}

cmd_status() {
  local channel_on=''
  optional_config && channel_on=1
  if [ -n "$channel_on" ]; then
    echo "channel: on (captain $FM_WA_CAPTAIN, accepted devices ${FM_WA_ALLOW_DEVICES})"
    if [ -n "$FM_WA_DRY_RUN" ]; then
      echo "dry-run: on"
    else
      echo "dry-run: off"
    fi
  else
    # Off is not the end of the report. A listener started while the channel was
    # on outlives the config, so the lines below still have to be printed or an
    # operator cannot even see that one is still holding a linked device.
    echo "channel: off (no FM_WA_CAPTAIN in ${FM_WA_CONFIG_FILE:-config/whatsapp.env})"
  fi
  # Both branches above report a default as though it were a choice when a key
  # could not be read, so the reason is printed beside them either way.
  [ -z "${FM_WA_CONFIG_ERROR:-}" ] || echo "config problem: $FM_WA_CONFIG_ERROR"
  if ! fm_wa_paired; then
    echo '{"paired": false}'
  elif command -v node >/dev/null 2>&1 && [ -f "$LISTENER" ] && [ ! -L "$LISTENER" ]; then
    listener_env status
  else
    echo '{"paired": true}'
  fi
  if fm_wa_listener_pid >/dev/null; then
    echo "listener: running (pid $(fm_wa_listener_pid))"
  elif fm_wa_listener_pid_foreign; then
    echo "listener: unknown - the recorded pid is a live process this home cannot prove is its own listener"
  else
    echo "listener: not running"
  fi
  local pending=0
  if [ -d "$FM_WA_INBOX" ]; then
    pending=$(find "$FM_WA_INBOX" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "inbox: $pending pending"
  if [ -f "$FM_WA_STATE/wa-listener.status" ]; then
    printf 'last connection event: '
    cat "$FM_WA_STATE/wa-listener.status"
  fi
  # A live pid is not a live channel, so say plainly when the connection has
  # never come up rather than leaving the beat line out.
  if [ -f "$FM_WA_STATE/wa-listener.beat" ]; then
    echo "last connected beat: $(fm_wa_age_of "$FM_WA_STATE/wa-listener.beat")s ago"
  else
    echo "last connected beat: never"
  fi
}

cmd_pair() {
  require_config || return 1
  local number='' rounds=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rounds) rounds=${2-1}; shift 2 || return 2 ;;
      *) number=$1; shift ;;
    esac
  done
  case "$rounds" in
    ''|*[!0-9]*) rounds=1 ;;
  esac
  # Pairing links ONE account, so it takes ONE number. FM_WA_CAPTAIN is a list
  # when the captain carries more than one phone, and handing the whole list to
  # the pairer strips the separator and asks WhatsApp for a code for the two
  # numbers run together - a value that matches no phone but is long enough to
  # look like one. The listener is a linked device on his first number; the
  # others reach it as ordinary inbound messages and need no device of their own.
  number=${number:-${FM_WA_CAPTAIN%% *}}
  if fm_wa_paired; then
    echo "already paired; run 'unpair' first to link a fresh device" >&2
    return 1
  fi
  fm_wa_private_dir "$FM_WA_AUTH_DIR" || { echo "error: credential directory is unavailable" >&2; return 1; }
  echo "Requesting a pairing code for +$number."
  echo "On the captain's phone: WhatsApp > Settings > Linked Devices >"
  echo "Link a Device > Link with phone number instead, then enter the code below."
  [ "$rounds" -gt 1 ] && echo "A fresh code is issued automatically for up to $rounds windows."
  listener_env pair "$number" "$rounds" || return 1
  clear_listener_health
}

cmd_unpair() {
  local channel_on=''
  optional_config && channel_on=1
  # Credentials must never be pulled out from under a process that is still
  # using them, and a stop this cannot prove it owns is a stop that did not
  # happen, so an unprovable pid stops the unpair rather than being worked
  # around.
  if ! cmd_stop >/dev/null; then
    echo "refusing to unpair while a listener may still be holding these credentials" >&2
    return 1
  fi
  clear_listener_health
  if [ -d "$FM_WA_AUTH_DIR" ] && [ ! -L "$FM_WA_AUTH_DIR" ]; then
    rm -rf -- "$FM_WA_AUTH_DIR"
    echo "removed this listener's credentials; mudslide's session is untouched"
  else
    echo "no listener credentials to remove"
  fi
  # Unpair is two commands wearing one name: the middle step of a re-pair, and
  # the last step of switching the channel off. Only the second may take the
  # captain's stashed messages with it. Clearing them during a re-pair would
  # destroy instructions he has sent and firstmate has not read yet, and drop
  # the watermark that stops WhatsApp's own redelivery from replaying old
  # messages as new ones. The channel being off is what tells the two apart, so
  # this is a teardown only once the configuration is gone.
  if [ -z "$channel_on" ]; then
    fm_wa_purge_channel_state
    echo "cleared this home's stashed WhatsApp messages and channel records"
  fi
}

cmd_logs() {
  optional_config || true
  local n=${1:-40}
  case "$n" in
    ''|*[!0-9]*) n=40 ;;
  esac
  [ -f "$FM_WA_LOG" ] && tail -n "$n" "$FM_WA_LOG" || echo "no listener log yet"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  restart) shift; cmd_stop >/dev/null || exit 1; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  pair) shift; cmd_pair "$@" ;;
  unpair) shift; cmd_unpair "$@" ;;
  logs) shift; cmd_logs "$@" ;;
  ''|-h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
