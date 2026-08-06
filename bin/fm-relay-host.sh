#!/usr/bin/env bash
# fm-relay-host.sh - the control side of a relay task host.
#
# Usage:
#   fm-relay-host.sh ping <host>
#   fm-relay-host.sh preflight <host>       ask whether it can take work right now
#   fm-relay-host.sh task-list <host>
#   fm-relay-host.sh spawn <host> <id> <project> [--scout] [--harness N] [--model N] [--effort N]
#   fm-relay-host.sh spawn <host> <id> --secondmate [--harness N] [--model N] [--effort N]
#   fm-relay-host.sh home-seed <host> <id> {<project>...|--no-projects}
#   fm-relay-host.sh home-config <id> [--force]   converge inherited local material
#   fm-relay-host.sh backlog-mv <id> <fragment>   land a staged backlog fragment
#   fm-relay-host.sh agent-alive <id>       alive|dead|unknown, from the host's own probe
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
#   fm-relay-host.sh teardown <id> [--force]  gated remote teardown, then local cleanup
#
# Every subcommand after `spawn` finds its host through state/<id>.meta's host=
# line, so callers name the task, never the machine. A persistent secondmate is
# the one thing that can be addressed before it has any metadata here, so
# `home-seed` names the machine and `home-config`/`backlog-mv` fall back to the
# `machine:` field of that secondmate's data/secondmates.md entry.
#
# The SECONDMATE subcommands are all the same shape as the task ones: this side
# stages long or arbitrary input as a file and asks the peer to run its own
# bin/fm-home-seed.sh, bin/fm-config-inherit-apply.sh, or
# bin/fm-backlog-handoff.sh. Nothing about the secondmate contract - the
# transactional seed and its rollback, the home validation and identity marker,
# the inheritance guards and quarantine, the queued-only backlog rule - is
# reimplemented here or on the wire (the secondmate-provisioning skill owns it).
#
# `teardown --force` carries the captain's explicit discard authority across the
# link, as the extra verb token `force`. It is the answer to a hole this layer
# had: the host's own teardown refuses dirty or unlanded work, correctly, and
# until this existed there was no way to say "the captain has authorized
# discarding it" to a machine with no inbound SSH - so a remote task that ran off
# the rails could never be cleaned up from anywhere. The judgement itself does not
# move: the host still runs its own bin/fm-teardown.sh --force against the
# worktree that actually holds the work. It needs no new credential either,
# because `teardown` is already epoch-fenced, so a caller that may send it may
# already spawn and steer on that machine.
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
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-relay-lib.sh
. "$SCRIPT_DIR/fm-relay-lib.sh"
# For secondmate_registry_field: data/secondmates.md is where a secondmate's
# machine is recorded, and this is the one parser for that file.
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

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

# A persistent secondmate is addressable before it is running - inherited config
# can be pushed to a seeded-but-not-yet-launched home, and backlog items can be
# handed to it the moment it is seeded - so its machine is read from the durable
# routing entry when there is no runtime record yet.
load_host_for_secondmate() {  # <id>
  local id=$1 host=""
  fm_relay_id_valid "$id" || die "invalid secondmate id '$id'"
  if [ -f "$STATE/$id.meta" ]; then
    host=$(fm_relay_meta_host "$STATE/$id.meta")
  fi
  [ -n "$host" ] || host=$(secondmate_registry_field "$DATA/secondmates.md" "$id" machine || true)
  [ -n "$host" ] || die "secondmate $id is not registered on another machine; its home is on this one"
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
    KIND=ship; HARNESS=default; MODEL=default; EFFORT=default
    # A secondmate takes no project: its home already exists on that machine
    # with its charter in it, so `-` fills the slot rather than a second verb.
    PROJECT=
    case "${1:-}" in
      --secondmate) KIND=secondmate; PROJECT='-'; shift ;;
      '') die "usage: fm-relay-host.sh spawn <host> <id> <project> ..." ;;
      *) PROJECT=$1; shift ;;
    esac
    want=
    for a in "$@"; do
      if [ -n "$want" ]; then
        case "$want" in harness) HARNESS=$a ;; model) MODEL=$a ;; effort) EFFORT=$a ;; esac
        want=; continue
      fi
      case "$a" in
        --scout) KIND=scout ;;
        --secondmate) KIND=secondmate; PROJECT='-' ;;
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
    if [ "$KIND" = secondmate ]; then
      # No brief to check and no existing-metadata refusal. A secondmate reads
      # data/charter.md from its own home, and RESPAWNING a live-metadata
      # secondmate is the documented recovery action rather than a mistake -
      # refusing it here would break exactly the call recovery has to make.
      :
    else
      BRIEF="$DATA/$ID/brief.md"
      [ -f "$BRIEF" ] || die "no brief at $BRIEF; scaffold it before dispatching"
      grep -q '{TASK}' "$BRIEF" && die "brief at $BRIEF still contains the {TASK} placeholder"
      [ -f "$STATE/$ID.meta" ] && die "task $ID already has metadata in $STATE; tear it down before re-dispatching"
    fi
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
    [ "$KIND" = secondmate ] || [ -f "$BRIEF" ] || die "no brief at $BRIEF; scaffold it before dispatching"

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

    BRIEFREF='-'
    if [ "$KIND" != secondmate ]; then
      fm_relay_put "$BRIEF" "tasks/$ID/in/brief.md" || die "could not stage the brief: $FM_RELAY_ERR"
      BRIEFREF=brief.md
    fi
    SPAWN_RC=0
    fm_relay_exec spawn "$ID" "$KIND" "$PROJECT" "$BRIEFREF" "$HARNESS" "$MODEL" "$EFFORT" || SPAWN_RC=$?
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

  home-seed)
    HOST=${1:?usage: fm-relay-host.sh home-seed <host> <id> {<project>...|--no-projects\}}; shift
    ID=${1:?usage: fm-relay-host.sh home-seed <host> <id> {<project>...|--no-projects\}}; shift
    NO_PROJECTS=0
    PROJECTS=()
    for a in "$@"; do
      case "$a" in
        --no-projects) NO_PROJECTS=1 ;;
        --*) die "unexpected argument '$a'" ;;
        *) PROJECTS+=("$a") ;;
      esac
    done
    fm_relay_id_valid "$ID" || die "invalid secondmate id '$ID'"
    fm_relay_host_load "$FM_HOME" "$HOST"
    BRIEF="$DATA/$ID/brief.md"
    [ -f "$BRIEF" ] || die "no charter at $BRIEF; scaffold and fill it before seeding"
    grep -q '{TASK}' "$BRIEF" && die "charter at $BRIEF still contains the {TASK} placeholder"
    if [ "$NO_PROJECTS" -eq 1 ]; then
      [ "${#PROJECTS[@]}" -eq 0 ] || die "--no-projects cannot be combined with a project list"
    else
      [ "${#PROJECTS[@]}" -gt 0 ] \
        || die "a secondmate needs at least one project name on $HOST, or --no-projects"
    fi
    # Validate before opening the spec, so no failure path has to reach back into
    # a file that is being written.
    if [ "$NO_PROJECTS" -eq 0 ]; then
      for p in "${PROJECTS[@]}"; do
        fm_relay_ref_valid "$p" || die "invalid project name '$p'"
      done
    fi
    SPEC=$(mktemp)
    {
      printf 'fmseed-v1\n'
      printf 'home=-\n'
      if [ "$NO_PROJECTS" -eq 1 ]; then
        printf 'no_projects=1\n'
      else
        for p in "${PROJECTS[@]}"; do
          printf 'project=%s\n' "$p"
        done
      fi
    } > "$SPEC"
    REF="seed$(date -u +%Y%m%d%H%M%S)-$$"
    if ! fm_relay_put "$BRIEF" "tasks/$ID/in/charter.md"; then
      rm -f "$SPEC"
      die "could not stage the charter on $HOST: $FM_RELAY_ERR"
    fi
    if ! fm_relay_put "$SPEC" "tasks/$ID/in/$REF"; then
      rm -f "$SPEC"
      die "could not stage the seed spec on $HOST: $FM_RELAY_ERR"
    fi
    rm -f "$SPEC"
    fm_relay_exec home-seed "$ID" charter.md "$REF" \
      || { printf '%s\n' "$FM_RELAY_ERR" >&2; exit 1; }
    FIRST=${FM_RELAY_OUT%%$'\n'*}
    case "$FIRST" in
      OK\ *) ;;
      *) printf '%s\n' "$FM_RELAY_OUT" >&2; exit 1 ;;
    esac
    HOMEPATH=$(printf '%s' "$FIRST" | sed -n 's/.*home=\([^ ]*\).*/\1/p')
    [ -n "$HOMEPATH" ] || die "$HOST seeded $ID but reported no home path"
    printf 'seeded: %s on %s\n' "$ID" "$HOST"
    printf 'home=%s\n' "$HOMEPATH"
    printf '%s\n' "$FM_RELAY_OUT" | sed -n '2,$p'
    ;;

  home-config)
    ID=${1:?usage: fm-relay-host.sh home-config <id> [--force]}; shift
    FORCE=0
    for a in "$@"; do
      case "$a" in
        --force) FORCE=1 ;;
        *) die "unexpected argument '$a'" ;;
      esac
    done
    load_host_for_secondmate "$ID"
    LOCAL_DIGEST=$(fm_config_inherit_surface_digest "$CONFIG" "$DATA") \
      || die "cannot digest this home's inheritance surface"
    # Ask before shipping. Convergence is the steady state, so the ordinary cost
    # of this at every session start is ONE round trip rather than one transfer
    # per declared item. --force skips the question, for the case where the
    # destination bytes are suspect rather than merely equal.
    if [ "$FORCE" -eq 0 ] && fm_relay_exec home-config "$ID"; then
      REMOTE_DIGEST=$(printf '%s\n' "$FM_RELAY_OUT" | sed -n 's/^digest=//p' | tail -1)
      if [ -n "$REMOTE_DIGEST" ] && [ "$REMOTE_DIGEST" = "$LOCAL_DIGEST" ]; then
        printf 'unchanged: %s on %s already holds this home inherited material\n' \
          "$ID" "$FM_RELAY_HOST"
        exit 0
      fi
    fi
    # A SOURCE-HOME SKELETON, not a diff: an item this home does not set is
    # simply absent from it, and the peer's own propagation mirrors that absence
    # downstream exactly as a local push does (bin/fm-config-inherit-lib.sh).
    REF="inh$(date -u +%Y%m%d%H%M%S)-$$"
    MANIFEST=$(mktemp)
    fm_config_inherit_declared_manifest > "$MANIFEST"
    if ! fm_relay_put "$MANIFEST" "tasks/$ID/in/$REF/manifest"; then
      rm -f "$MANIFEST"
      die "could not stage the inheritance manifest on $FM_RELAY_HOST: $FM_RELAY_ERR"
    fi
    rm -f "$MANIFEST"
    for item in $FM_INHERITABLE_CONFIG; do
      [ -f "$CONFIG/$item" ] || continue
      fm_relay_put "$CONFIG/$item" "tasks/$ID/in/$REF/config/$item" \
        || die "could not stage config/$item on $FM_RELAY_HOST: $FM_RELAY_ERR"
    done
    if [ -f "$DATA/$FM_SHARED_CAPTAIN_FILE" ]; then
      fm_relay_put "$DATA/$FM_SHARED_CAPTAIN_FILE" "tasks/$ID/in/$REF/$FM_SHARED_CAPTAIN_REL" \
        || die "could not stage $FM_SHARED_CAPTAIN_REL on $FM_RELAY_HOST: $FM_RELAY_ERR"
    fi
    fm_relay_verb_ok home-config "$ID" "$REF" || die "$FM_RELAY_ERR"
    ;;

  backlog-mv)
    ID=${1:?usage: fm-relay-host.sh backlog-mv <id> <fragment-file>}
    FRAG=${2:?usage: fm-relay-host.sh backlog-mv <id> <fragment-file>}
    [ -f "$FRAG" ] || die "no backlog fragment at $FRAG"
    load_host_for_secondmate "$ID"
    REF="bl$(date -u +%Y%m%d%H%M%S)-$$"
    fm_relay_put "$FRAG" "tasks/$ID/in/$REF" \
      || die "could not stage the backlog fragment on $FM_RELAY_HOST: $FM_RELAY_ERR"
    fm_relay_verb_ok backlog-mv "$ID" "$REF" || die "$FM_RELAY_ERR"
    ;;

  agent-alive)
    ID=${1:?usage: fm-relay-host.sh agent-alive <id>}
    load_host_for_task "$ID"
    fm_relay_exec agent-alive "$ID" || { printf '%s\n' "$FM_RELAY_ERR" >&2; exit 1; }
    FIRST=${FM_RELAY_OUT%%$'\n'*}
    case "$FIRST" in
      OK\ alive=*) printf '%s\n' "${FIRST#OK alive=}" ;;
      *) printf '%s\n' "$FM_RELAY_OUT" >&2; exit 1 ;;
    esac
    ;;

  teardown)
    ID=${1:?usage: fm-relay-host.sh teardown <id> [--force]}; shift
    FORCE=0
    for a in "$@"; do
      case "$a" in
        --force) FORCE=1 ;;
        *) die "unexpected argument '$a'" ;;
      esac
    done
    load_host_for_task "$ID"
    KIND=$(grep '^kind=' "$STATE/$ID.meta" | cut -d= -f2- | head -1 || true)
    [ -n "$KIND" ] || KIND=ship
    HASH=none
    # Without discard authority the report copy is a hard local precondition, and
    # staying that way is the point: the host refuses anyway, and refusing here
    # saves a round trip and names the fix. With it, there may be no report to
    # copy at all - a worker that died before writing one is exactly the task that
    # could otherwise never be cleaned up - so this side sends none and the host
    # skips the matching gate.
    if [ "$KIND" = scout ] && [ "$FORCE" -eq 0 ]; then
      [ -f "$DATA/$ID/report.md" ] \
        || die "no local report copy at $DATA/$ID/report.md; run report-pull first"
      HASH=$(fm_relay_sha256 "$DATA/$ID/report.md") || die "cannot hash the local report copy"
    fi
    TD_ARGS=("$ID" "$HASH")
    [ "$FORCE" -eq 1 ] && TD_ARGS+=(force)
    fm_relay_exec teardown "${TD_ARGS[@]}" || { printf '%s\n' "$FM_RELAY_ERR"; exit 1; }
    printf '%s\n' "$FM_RELAY_OUT"
    rm -f "$STATE/$ID.meta" "$STATE/$ID.relay-ack" "$STATE/$ID.relay-seen" \
      "$STATE/$ID.check.sh" "$STATE/$ID.check-trust" "$STATE/$ID.status"
    # A retired secondmate's ROUTE is a control-side record too, and the only
    # one the host cannot clear: its own teardown removed its own registry entry
    # over there, and this side's data/secondmates.md is what intake reads.
    # Leaving it would keep routing work to a home that no longer exists.
    if [ "$KIND" = secondmate ] && [ -f "$DATA/secondmates.md" ]; then
      REG_TMP="$DATA/secondmates.md.tmp.$$"
      REG_RC=0
      grep -vE "^- $ID( |$)" "$DATA/secondmates.md" > "$REG_TMP" || REG_RC=$?
      # grep exits 1 when it selected nothing, which is the ordinary result of
      # retiring the only registered secondmate; only a real read error is a
      # failure to report.
      if [ "$REG_RC" -le 1 ]; then
        mv -f "$REG_TMP" "$DATA/secondmates.md"
      else
        rm -f "$REG_TMP"
        echo "warning: $ID was retired on $FM_RELAY_HOST but its route could not be removed from $DATA/secondmates.md" >&2
      fi
    fi
    printf 'cleaned: control-side records for %s\n' "$ID"
    ;;

  *)
    usage
    exit 2
    ;;
esac
