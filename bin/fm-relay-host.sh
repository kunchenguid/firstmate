#!/usr/bin/env bash
# fm-relay-host.sh - the control side of a relay task host.
#
# Usage:
#   fm-relay-host.sh ping <host>
#   fm-relay-host.sh preflight <host>       ask whether it can take work right now
#   fm-relay-host.sh task-list <host>
#   fm-relay-host.sh spawn <host> <id> <project> [--scout] [--harness N] [--model N] [--effort N]
#   fm-relay-host.sh dispatch <id>          retry a dispatch the host held off
#   fm-relay-host.sh queued [<id>]          show what is waiting to dispatch
#   fm-relay-host.sh cancel <id>            drop a queued dispatch
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
#
# `spawn` is `queue` then `dispatch`, and `dispatch` is the ONLY code that starts
# a remote task. A host that refuses - a locked screen, a downed desktop host
# session, a machine that is asleep and cannot answer at all - leaves the queued
# record in place and exits 3, and the task's wake check runs this same
# `dispatch` until it takes. First attempt and last retry are therefore the same
# code, which is the only way they cannot drift
# (bin/fm-relay-lib.sh, docs/relay-gui-host.md).
#
# Exit codes from `spawn` and `dispatch`:
#   0  the task is live on the host
#   3  the host declined for a reason that passes; the dispatch is still queued
#   1  it failed for a reason waiting will not fix
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

  preflight)
    HOST=${1:?usage: fm-relay-host.sh preflight <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    fm_relay_verb_ok preflight || die "$FM_RELAY_ERR"
    ;;

  spawn|queue)
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
    # Load the host record here so an unregistered host, a malformed record, or
    # an unusable brief is refused BEFORE anything durable is written.
    fm_relay_host_load "$FM_HOME" "$HOST"
    BRIEF="$DATA/$ID/brief.md"
    [ -f "$BRIEF" ] || die "no brief at $BRIEF; scaffold it before dispatching"
    grep -q '{TASK}' "$BRIEF" && die "brief at $BRIEF still contains the {TASK} placeholder"
    [ -f "$STATE/$ID.meta" ] && die "task $ID already has metadata in $STATE; tear it down before re-dispatching"
    mkdir -p "$STATE"
    PENDING=$(fm_relay_pending_file "$STATE" "$ID")
    {
      printf 'host=%s\n' "$HOST"
      printf 'project=%s\n' "$PROJECT"
      printf 'kind=%s\n' "$KIND"
      printf 'harness=%s\n' "$HARNESS"
      printf 'model=%s\n' "$MODEL"
      printf 'effort=%s\n' "$EFFORT"
      printf 'queued_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$PENDING"
    [ "$CMD" = queue ] && { printf 'queued: %s for %s\n' "$ID" "$HOST"; exit 0; }
    exec "$0" dispatch "$ID"
    ;;

  dispatch)
    ID=${1:?usage: fm-relay-host.sh dispatch <id>}
    fm_relay_id_valid "$ID" || die "invalid task id '$ID'"
    PENDING=$(fm_relay_pending_file "$STATE" "$ID")
    [ -f "$PENDING" ] || die "no queued dispatch for $ID at $PENDING"
    HOST=$(fm_relay_pending_field "$PENDING" host)
    PROJECT=$(fm_relay_pending_field "$PENDING" project)
    KIND=$(fm_relay_pending_field "$PENDING" kind)
    HARNESS=$(fm_relay_pending_field "$PENDING" harness)
    MODEL=$(fm_relay_pending_field "$PENDING" model)
    EFFORT=$(fm_relay_pending_field "$PENDING" effort)
    [ -n "$HOST" ] || die "the queued dispatch for $ID names no host"
    fm_relay_host_load "$FM_HOME" "$HOST"
    BRIEF="$DATA/$ID/brief.md"
    [ -f "$BRIEF" ] || die "no brief at $BRIEF; scaffold it before dispatching"

    # Ask first on a GUI host. This is the courteous half - it keeps a refused
    # dispatch from pushing a brief onto a machine that will not use it, and it
    # produces the reason in the host's own words. It is NOT the gate: the verb
    # asks again in the same process as its claim, so nothing can slip between
    # the answer here and the claim there.
    if fm_relay_host_is_gui; then
      if ! fm_relay_exec preflight; then
        CLASS=$(fm_relay_dispatch_class "$FM_RELAY_OUT" "$FM_RELAY_RC")
        case "$CLASS" in
          retry\ *)
            fm_relay_pending_set_reason "$PENDING" "${CLASS#retry }"
            printf 'held: %s is queued for %s - %s\n' "$ID" "$HOST" "${CLASS#retry }"
            exit 3 ;;
        esac
        fm_relay_pending_set_reason "$PENDING" "${CLASS#fail }"
        printf '%s\n' "${CLASS#fail }" >&2
        exit 1
      fi
    fi

    fm_relay_put "$BRIEF" "tasks/$ID/in/brief.md" || die "could not stage the brief: $FM_RELAY_ERR"
    SPAWN_RC=0
    fm_relay_exec spawn "$ID" "$KIND" "$PROJECT" brief.md "$HARNESS" "$MODEL" "$EFFORT" || SPAWN_RC=$?
    CLASS=$(fm_relay_dispatch_class "$FM_RELAY_OUT" "$SPAWN_RC")
    case "$CLASS" in
      ok) ;;
      retry\ *)
        fm_relay_pending_set_reason "$PENDING" "${CLASS#retry }"
        printf 'held: %s is queued for %s - %s\n' "$ID" "$HOST" "${CLASS#retry }"
        exit 3 ;;
      *)
        # The queued record STAYS. A retry runs from the wake check, where no
        # supervisor is watching in real time, so dropping it here would lose
        # work silently. The caller decides: bin/fm-spawn.sh clears it because it
        # reported the failure synchronously and armed nothing, while the check
        # keeps it and alerts once.
        fm_relay_pending_set_reason "$PENDING" "${CLASS#fail }"
        printf '%s\n' "$FM_RELAY_OUT" >&2
        exit 1 ;;
    esac
    # The host answers with its own state/<id>.meta after the OK line. Recording
    # it verbatim plus host= keeps every control-side reader pointed at the
    # machine that actually owns the task instead of probing a local endpoint
    # that is not there.
    META_RC=0
    {
      printf '%s\n' "$FM_RELAY_OUT" | sed -n '2,$p'
      printf 'host=%s\n' "$HOST"
    } > "$STATE/$ID.meta" || META_RC=$?
    if [ "$META_RC" -ne 0 ] || ! grep -q '^worktree=' "$STATE/$ID.meta"; then
      echo "error: the host did not return usable metadata for $ID; it may be running unsupervised" >&2
      exit 1
    fi
    rm -f "$PENDING" "$STATE/$ID.relay-queue-fails" "$STATE/$ID.relay-queue-alert"
    printf '%s\n' "$FM_RELAY_OUT" | sed -n '1p'
    ;;

  queued)
    ID=${1:-}
    if [ -n "$ID" ]; then
      fm_relay_id_valid "$ID" || die "invalid task id '$ID'"
      PENDING=$(fm_relay_pending_file "$STATE" "$ID")
      [ -f "$PENDING" ] || die "no queued dispatch for $ID"
      cat "$PENDING"
    else
      found=0
      for PENDING in "$STATE"/*.relay-pending; do
        [ -f "$PENDING" ] || continue
        found=1
        base=${PENDING##*/}
        printf '%s host=%s project=%s kind=%s queued_at=%s\n' "${base%.relay-pending}" \
          "$(fm_relay_pending_field "$PENDING" host)" \
          "$(fm_relay_pending_field "$PENDING" project)" \
          "$(fm_relay_pending_field "$PENDING" kind)" \
          "$(fm_relay_pending_field "$PENDING" queued_at)"
      done
      [ "$found" -eq 1 ] || echo "no queued dispatches"
    fi
    ;;

  cancel)
    ID=${1:?usage: fm-relay-host.sh cancel <id>}
    fm_relay_id_valid "$ID" || die "invalid task id '$ID'"
    PENDING=$(fm_relay_pending_file "$STATE" "$ID")
    [ -f "$PENDING" ] || die "no queued dispatch for $ID"
    rm -f "$PENDING" "$STATE/$ID.relay-queue-fails" "$STATE/$ID.relay-queue-alert" \
      "$STATE/$ID.check.sh" "$STATE/$ID.check-trust"
    printf 'cancelled: the queued dispatch for %s and its wake check are gone\n' "$ID"
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
