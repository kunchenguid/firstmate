#!/usr/bin/env bash
# fm-relay-host.sh - the control side of a relay task host.
#
# Usage:
#   fm-relay-host.sh ping <host>
#   fm-relay-host.sh task-list <host>
#   fm-relay-host.sh spawn <host> <id> <project> [--scout] [--harness N] [--model N] [--effort N]
#   fm-relay-host.sh send <id> <text...>
#   fm-relay-host.sh key <id> <Enter|Escape|C-c>
#   fm-relay-host.sh crew-state <id>
#   fm-relay-host.sh peek <id> [lines]
#   fm-relay-host.sh events <id>            print everything not yet acknowledged
#   fm-relay-host.sh ack <id> [offset]      record what has been presented
#   fm-relay-host.sh report-pull <id>       fetch + verify the scout report
#   fm-relay-host.sh teardown <id>          gated remote teardown, then local cleanup
#
# Every subcommand after `spawn` finds its host through state/<id>.meta's host=
# line, so callers name the task, never the machine.
#
# Cursors. state/<id>.relay-ack mirrors the offset the HOST records as presented,
# and state/<id>.relay-seen is what the wake check has already reported. They are
# deliberately different: `events` replays from the ack so nothing unpresented is
# ever skipped, while the check advances only `seen` so one event batch produces
# one wake instead of one every check interval. Nothing advances the ack except a
# caller that has actually surfaced the events.
#
# Text never travels as a shell argument. A steer is written into the exchange
# directory, hash-verified, and the verb receives only a short reference; that is
# what lets the host's shell allowlist stay narrow enough to reject every
# injection shape (docs/relay-host.md).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-relay-lib.sh
. "$SCRIPT_DIR/fm-relay-lib.sh"

CMD=${1:-}
case "$CMD" in
  -h|--help|'') usage; exit 0 ;;
esac
shift || true

die() { echo "error: $*" >&2; exit 1; }

load_host_for_task() {  # <id>
  local id=$1 host
  fm_relay_id_valid "$id" || die "invalid task id '$id'"
  [ -f "$STATE/$id.meta" ] || die "no metadata for task $id in $STATE"
  host=$(fm_relay_meta_host "$STATE/$id.meta")
  [ -n "$host" ] || die "task $id has no host= line; it is not a relay task"
  fm_relay_host_load "$FM_HOME" "$host"
}

read_cursor() {  # <file>
  local v
  v=$(cat "$1" 2>/dev/null || true)
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# Stage arbitrary text into the exchange area under a fresh reference, so the
# shell allowlist only ever sees that reference.
stage_text() {  # <id> <text> -> prints ref
  local id=$1 text=$2 ref tmp
  ref="s$(date -u +%Y%m%d%H%M%S)-$$"
  tmp=$(mktemp)
  printf '%s\n' "$text" > "$tmp"
  if ! fm_relay_put "$tmp" "tasks/$id/in/$ref"; then
    rm -f "$tmp"
    die "could not stage the text on $FM_RELAY_HOST: $FM_RELAY_ERR"
  fi
  rm -f "$tmp"
  printf '%s' "$ref"
}

case "$CMD" in

  ping)
    HOST=${1:?usage: fm-relay-host.sh ping <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    fm_relay_exec ping || die "$FM_RELAY_ERR"
    printf '%s\n' "$FM_RELAY_OUT"
    ;;

  task-list)
    HOST=${1:?usage: fm-relay-host.sh task-list <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    fm_relay_verb_ok task-list || die "$FM_RELAY_ERR"
    ;;

  spawn)
    HOST=${1:?usage: fm-relay-host.sh spawn <host> <id> <project> ...}; shift
    ID=${1:?usage: fm-relay-host.sh spawn <host> <id> <project> ...}; shift
    PROJECT=${1:?usage: fm-relay-host.sh spawn <host> <id> <project> ...}; shift
    KIND=ship; HARNESS=default; MODEL=default; EFFORT=default
    want=
    for a in "$@"; do
      if [ -n "$want" ]; then
        case "$want" in harness) HARNESS=$a ;; model) MODEL=$a ;; effort) EFFORT=$a ;; esac
        want=; continue
      fi
      case "$a" in
        --scout) KIND=scout ;;
        --harness) want=harness ;;
        --harness=*) HARNESS=${a#--harness=} ;;
        --model) want=model ;;
        --model=*) MODEL=${a#--model=} ;;
        --effort) want=effort ;;
        --effort=*) EFFORT=${a#--effort=} ;;
        *) die "unexpected argument '$a'" ;;
      esac
    done
    [ -z "$want" ] || die "--$want requires a value"
    fm_relay_id_valid "$ID" || die "invalid task id '$ID'"
    fm_relay_host_load "$FM_HOME" "$HOST"
    BRIEF="$DATA/$ID/brief.md"
    [ -f "$BRIEF" ] || die "no brief at $BRIEF; scaffold it before dispatching"
    grep -q '{TASK}' "$BRIEF" && die "brief at $BRIEF still contains the {TASK} placeholder"
    fm_relay_put "$BRIEF" "tasks/$ID/in/brief.md" || die "could not stage the brief: $FM_RELAY_ERR"
    fm_relay_exec spawn "$ID" "$KIND" "$PROJECT" brief.md "$HARNESS" "$MODEL" "$EFFORT" \
      || die "remote spawn failed: $FM_RELAY_ERR"
    printf '%s\n' "$FM_RELAY_OUT"
    case "${FM_RELAY_OUT%%$'\n'*}" in
      OK\ *) ;;
      *) exit 1 ;;
    esac
    ;;

  send)
    ID=${1:?usage: fm-relay-host.sh send <id> <text...>}; shift
    [ "$#" -ge 1 ] || die "send needs text"
    load_host_for_task "$ID"
    REF=$(stage_text "$ID" "$*")
    fm_relay_exec send "$ID" "$REF" || { printf '%s\n' "$FM_RELAY_ERR"; exit 1; }
    printf '%s\n' "$FM_RELAY_OUT"
    ;;

  key)
    ID=${1:?usage: fm-relay-host.sh key <id> <key>}
    KEYNAME=${2:?usage: fm-relay-host.sh key <id> <key>}
    load_host_for_task "$ID"
    fm_relay_exec key "$ID" "$KEYNAME" || { printf '%s\n' "$FM_RELAY_ERR"; exit 1; }
    printf '%s\n' "$FM_RELAY_OUT"
    ;;

  crew-state)
    ID=${1:?usage: fm-relay-host.sh crew-state <id>}
    load_host_for_task "$ID"
    fm_relay_verb_ok crew-state "$ID" || die "$FM_RELAY_ERR"
    ;;

  peek)
    ID=${1:?usage: fm-relay-host.sh peek <id> [lines]}
    N=${2:-40}
    load_host_for_task "$ID"
    fm_relay_verb_ok peek "$ID" "$N" || die "$FM_RELAY_ERR"
    ;;

  events)
    ID=${1:?usage: fm-relay-host.sh events <id>}
    load_host_for_task "$ID"
    ACK=$(read_cursor "$STATE/$ID.relay-ack")
    fm_relay_exec events "$ID" "$ACK" || die "$FM_RELAY_ERR"
    printf '%s\n' "$FM_RELAY_OUT"
    ;;

  ack)
    ID=${1:?usage: fm-relay-host.sh ack <id> [offset]}
    OFF=${2:-}
    load_host_for_task "$ID"
    if [ -z "$OFF" ]; then
      fm_relay_exec events "$ID" 0 || die "$FM_RELAY_ERR"
      OFF=$(printf '%s' "${FM_RELAY_OUT%%$'\n'*}" | sed -n 's/.*offset=\([0-9]*\).*/\1/p')
      [ -n "$OFF" ] || die "could not read the host's current event offset"
    fi
    fm_relay_exec ack "$ID" "$OFF" || die "$FM_RELAY_ERR"
    printf '%s\n' "$OFF" > "$STATE/$ID.relay-ack"
    printf '%s\n' "$FM_RELAY_OUT"
    ;;

  report-pull)
    ID=${1:?usage: fm-relay-host.sh report-pull <id>}
    load_host_for_task "$ID"
    fm_relay_exec report-stage "$ID" || die "$FM_RELAY_ERR"
    WANT=$(printf '%s' "${FM_RELAY_OUT%%$'\n'*}" | sed -n 's/.*sha256=\([0-9a-f]*\).*/\1/p')
    [ -n "$WANT" ] || die "the host did not report a report hash"
    mkdir -p "$DATA/$ID"
    fm_relay_get "tasks/$ID/out/report.md" "$DATA/$ID/report.md" "$WANT" \
      || die "report transfer failed: $FM_RELAY_ERR"
    printf 'pulled: %s (sha256 %s, verified against the host copy)\n' "$DATA/$ID/report.md" "$WANT"
    ;;

  teardown)
    ID=${1:?usage: fm-relay-host.sh teardown <id>}
    load_host_for_task "$ID"
    KIND=$(grep '^kind=' "$STATE/$ID.meta" | cut -d= -f2- | head -1 || true)
    [ -n "$KIND" ] || KIND=ship
    HASH=none
    if [ "$KIND" = scout ]; then
      [ -f "$DATA/$ID/report.md" ] \
        || die "no local report copy at $DATA/$ID/report.md; run report-pull first"
      HASH=$(fm_relay_sha256 "$DATA/$ID/report.md") || die "cannot hash the local report copy"
    fi
    fm_relay_exec teardown "$ID" "$HASH" || { printf '%s\n' "$FM_RELAY_ERR"; exit 1; }
    printf '%s\n' "$FM_RELAY_OUT"
    rm -f "$STATE/$ID.meta" "$STATE/$ID.relay-ack" "$STATE/$ID.relay-seen" \
      "$STATE/$ID.check.sh" "$STATE/$ID.check-trust" "$STATE/$ID.status"
    printf 'cleaned: control-side records for %s\n' "$ID"
    ;;

  *)
    usage
    exit 2
    ;;
esac
