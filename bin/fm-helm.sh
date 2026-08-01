#!/usr/bin/env bash
# fm-helm.sh - move the control plane between the machines of one fleet.
#
# Usage:
#   fm-helm.sh status [--refresh] [--brief]  who holds the helm, and do the copies agree
#   fm-helm.sh handover <machine>            give the helm to <machine> (run on the holder)
#   fm-helm.sh claim [--force]               take the helm (only when nobody holds it)
#   fm-helm.sh demote                        give the helm up so nobody holds it
#   fm-helm.sh adopt                         pick up the tasks already running on the peers
#   fm-helm.sh audit                         read every machine's lease and compare
#
# THERE IS NO AUTOMATIC TAKEOVER AND THIS FILE IS NOT WHERE ONE WOULD BE ADDED.
# The captain decided on 2026-08-01 that changing control machines is a human
# action, so the unified-env design's evidence-based seizure - liveness probes,
# grace periods, heartbeats, the DEAD/UNREACHABLE judgement - is not built. What
# is built is the part explicit handover needs to be correct on its own:
# a lease, a monotonic epoch used as a fencing token, and a gate in front of
# every command that changes something (bin/fm-helm-lib.sh states why each of
# those is not arbitration in disguise).
#
# HANDOVER MOVES SUPERVISION, NOT WORK. A crewmate is a live process in a
# particular worktree in a particular session on a particular machine. It cannot
# be carried and rebuilding it would throw away its context. So the new control
# plane DISCOVERS what is already running (`adopt`) instead of receiving a
# transfer, and the truth about a task stays on the machine running it. Nothing
# is restarted by a handover, and nothing has to be, which is the property that
# makes this safer than packaging work up and shipping it.
#
# WRITE ORDER. The anchor machine's lease is authoritative because the anchor is
# the always-on machine, so every write goes to the anchor FIRST and the other
# machines after. An interrupted handover therefore leaves the anchor already
# moved and some cache behind, which reads as "that machine is not the holder" -
# nobody acts. The reverse order would leave two machines each believing they
# hold the helm, which is the one outcome worth engineering against.
#
# The compare-and-swap on the anchor is what makes two simultaneous handovers
# safe: both read epoch N, both send expect=N, exactly one swap lands, the loser
# is told who won, and the epoch advances by exactly one.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-relay-lib.sh
. "$SCRIPT_DIR/fm-relay-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

CMD=${1:-status}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
esac
shift || true

# --- fleet resolution --------------------------------------------------------

if ! fm_helm_fleet_load "$FM_HOME"; then
  if [ -n "$FM_HELM_ERR" ]; then
    die "$FM_HELM_ERR"
  fi
  cat >&2 <<EOF
error: this home is not part of a fleet, so there is no helm to hold.
A fleet is declared by $FM_HOME/config/fleet.json; docs/helm.md owns that
schema and the two-machine setup it describes. Until that file exists nothing
in firstmate consults the helm at all.
EOF
  exit 1
fi

# The other machines of THIS fleet, which is a narrower set than "every relay
# host registered here". A Phase 1/2 task host that never joined a fleet must
# not be written to: installing a lease on it would switch its fencing on and
# every dispatch to it would then need an epoch it was never told about.
fleet_peers() {
  local h
  for h in $(fm_relay_hosts_list "$FM_HOME"); do
    fm_relay_host_load "$FM_HOME" "$h" >/dev/null 2>&1 || continue
    [ "$FM_RELAY_FLEET" = "$FM_HELM_FLEET" ] || continue
    printf '%s\n' "$h"
  done
}

PEERS=$(fleet_peers)

machine_known() {  # <machine>
  [ "$1" = "$FM_HELM_MACHINE" ] && return 0
  local p
  for p in $PEERS; do [ "$p" = "$1" ] && return 0; done
  return 1
}

machine_known "$FM_HELM_ANCHOR" \
  || die "the anchor '$FM_HELM_ANCHOR' is neither this machine nor a registered member of fleet $FM_HELM_FLEET"

# Read one machine's lease. Prints "<epoch> <holder>"; empty output means the
# machine could not be asked at all, which is NOT the same as "no lease".
lease_of() {  # <machine>
  local m=$1 out epoch holder
  out=$(fm_helm_verb "$FM_HOME" "$m" helm-read 2>/dev/null) || return 1
  case "${out%%$'\n'*}" in OK\ *) ;; *) return 1 ;; esac
  epoch=$(fm_helm_header_field "$out" epoch)
  holder=$(fm_helm_header_field "$out" holder)
  printf '%s %s\n' "${epoch:-0}" "${holder:-none}"
}

ANCHOR_EPOCH=; ANCHOR_HOLDER=
read_anchor() {
  local pair
  pair=$(lease_of "$FM_HELM_ANCHOR") || return 1
  ANCHOR_EPOCH=${pair%% *}
  ANCHOR_HOLDER=${pair##* }
  return 0
}

# Write one machine's lease through its own verb. Returns non-zero and leaves
# FM_HELM_ERR set on refusal, so the caller can tell a lost race from a machine
# it could not reach.
set_lease() {  # <machine> <expect-epoch> <next-epoch> <holder> [force]
  local m=$1 expect=$2 next=$3 holder=$4 force=${5:-0} out rc=0
  out=$(fm_helm_verb "$FM_HOME" "$m" helm-set \
    "fleet=$FM_HELM_FLEET" "expect=$expect" "next=$next" "holder=$holder" \
    "by=$FM_HELM_MACHINE" "force=$force" 2>&1) || rc=$?
  case "${out%%$'\n'*}" in
    OK\ *) return 0 ;;
  esac
  FM_HELM_ERR=${out%%$'\n'*}
  [ "$rc" -ne 0 ] || FM_HELM_ERR="${FM_HELM_ERR:-the lease write on $m did not report success}"
  return 1
}

# Bring every machine that is NOT the anchor to the epoch the anchor just
# reached. Prints one line per machine it could not reach; the caller decides how
# loud that is. force=1 because the anchor has already decided - a cache that
# disagrees is being corrected, not raced.
propagate() {  # <epoch> <holder>
  local epoch=$1 holder=$2 m failed=0
  for m in $FM_HELM_MACHINE $PEERS; do
    [ "$m" = "$FM_HELM_ANCHOR" ] && continue
    if ! set_lease "$m" "$epoch" "$epoch" "$holder" 1; then
      printf 'unreachable: %s still carries an out-of-date copy of the lease (%s)\n' \
        "$m" "${FM_HELM_ERR:-no reason given}"
      failed=1
    fi
  done
  return "$failed"
}

# Record that this machine was removed as the control plane while it was
# running. It is written only on that surprise, never on a handover this machine
# performed itself, because a handover this machine performed is not news.
mark_helm_lost() {  # <epoch> <holder>
  local lost
  lost=$(fm_helm_lost_file "$FM_HOME")
  mkdir -p "$(dirname "$lost")"
  {
    printf 'The helm of fleet %s is held by %s at epoch %s.\n' "$FM_HELM_FLEET" "$2" "$1"
    printf 'This machine (%s) believed it was the holder and was not.\n' "$FM_HELM_MACHINE"
    printf 'detected_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$lost"
}

# Reconcile this machine's copy with the anchor's, which is the only copy that
# decides anything. Prints what changed, and nothing when they already agreed.
reconcile_local() {
  fm_helm_lease_load
  [ "$ANCHOR_EPOCH" = "$FM_HELM_EPOCH" ] && [ "$ANCHOR_HOLDER" = "$FM_HELM_HOLDER" ] && return 0
  local was_holder=$FM_HELM_HOLDER
  if [ "$FM_HELM_ANCHOR" != "$FM_HELM_MACHINE" ]; then
    set_lease "$FM_HELM_MACHINE" "$ANCHOR_EPOCH" "$ANCHOR_EPOCH" "$ANCHOR_HOLDER" 1 \
      || printf 'warning: could not update this machine local copy of the lease (%s)\n' "$FM_HELM_ERR"
  fi
  if [ "$was_holder" = "$FM_HELM_MACHINE" ] && [ "$ANCHOR_HOLDER" != "$FM_HELM_MACHINE" ]; then
    mark_helm_lost "$ANCHOR_EPOCH" "$ANCHOR_HOLDER"
    printf 'LOST THE HELM: %s holds it at epoch %s; this machine is read-only until the captain resolves it\n' \
      "$ANCHOR_HOLDER" "$ANCHOR_EPOCH"
  else
    printf 'reconciled: this machine copy now reads epoch %s holder %s\n' \
      "$ANCHOR_EPOCH" "$ANCHOR_HOLDER"
  fi
  fm_helm_lease_load
}

require_holder() {  # <what>
  fm_helm_lease_load
  [ "$FM_HELM_HOLDER" = "$FM_HELM_MACHINE" ] && return 0
  echo "error: this machine ($FM_HELM_MACHINE) does not hold the helm, so it cannot $1" >&2
  echo "The lease here reads epoch $FM_HELM_EPOCH holder $FM_HELM_HOLDER." >&2
  echo "Run bin/fm-helm.sh status --refresh to re-read the authoritative copy." >&2
  exit 1
}

# What a handover is walking away from, stated before it happens rather than
# discovered afterwards. This is the quiesce step: it does not block, because
# none of these are unsafe - the tasks keep running and the new control plane
# adopts them - but the captain should see them.
quiesce_report() {
  local meta id live=0 queued=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    [ "$(grep '^kind=' "$meta" | cut -d= -f2- | head -1)" = secondmate ] && continue
    live=$((live + 1))
  done
  if [ -s "$STATE/.wake-queue" ]; then
    queued=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  fi
  printf 'handing over with %s task(s) recorded here and %s queued notification(s).\n' "$live" "$queued"
  [ "$queued" -eq 0 ] || printf 'Those queued notifications are local to this machine: read them before you leave it.\n'
  # A dispatch a host refused - asleep, locked, no desktop session - is held on
  # the CONTROL side, which is the one piece of in-flight state with nothing on
  # any other machine for the new control plane to discover. So it is named
  # here rather than quietly stranded.
  local p n=0
  for p in "$STATE"/*.relay-pending; do
    [ -f "$p" ] || continue
    n=$((n + 1))
    id=${p##*/}; id=${id%.relay-pending}
    printf 'NOT MOVING: %s is queued for %s and has not started; it lives only on this machine.\n' \
      "$id" "$(fm_relay_pending_field "$p" host)"
  done
  [ "$n" -eq 0 ] || printf 'Re-queue those on the machine taking over, or come back to this one.\n'
}

# PR monitoring and remote wake checks are control-plane assets, not task assets.
# Leaving them armed on a machine that just gave the helm away means two machines
# polling the same PR - and, with routine merges delegated, two machines that
# might each decide to merge it. The new control plane rebuilds them in `adopt`.
disarm_control_assets() {
  local meta id removed=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    if grep -q '^host=' "$meta" || grep -q '^pr=' "$meta"; then
      rm -f "$STATE/$id.check.sh" "$STATE/$id.check-trust" \
        "$STATE/$id.pr-poll" "$STATE/$id.pr-poll-registration"
      removed=$((removed + 1))
    fi
  done
  [ "$removed" -eq 0 ] || printf 'stood down %s monitor(s) here; the new control plane rebuilds them with adopt.\n' "$removed"
}

# --- subcommands -------------------------------------------------------------

case "$CMD" in

  status)
    REFRESH=0; BRIEF=0
    for a in "$@"; do
      case "$a" in
        --refresh) REFRESH=1 ;;
        --brief) BRIEF=1 ;;
        *) die "unexpected argument '$a'" ;;
      esac
    done
    fm_helm_lease_load
    LOST=$(fm_helm_lost_file "$FM_HOME")
    if [ "$REFRESH" -eq 1 ]; then
      if read_anchor; then
        reconcile_local
      else
        # An unreachable anchor does not change who holds the helm. With no
        # automatic takeover in the system, the only way the helm can move is a
        # command the captain ran, so a machine that cannot see the anchor keeps
        # working rather than stopping - the alternative bricks a laptop every
        # time it leaves the network, and buys nothing.
        printf 'note: the authoritative copy on %s could not be read (%s); using this machine copy.\n' \
          "$FM_HELM_ANCHOR" "${FM_HELM_ERR:-unreachable}"
      fi
    fi
    # In brief mode the VERDICT is the exit status - 0 this machine is the
    # control plane, 1 it is not - so bin/fm-session-start.sh does not have to
    # pattern-match a sentence to decide what to tell the session.
    if [ "$BRIEF" -eq 1 ]; then
      if [ -f "$LOST" ]; then
        printf 'HELM: this machine lost the helm of fleet %s while running; it is read-only until resolved (state/.helm-lost)\n' \
          "$FM_HELM_FLEET"
        exit 1
      fi
      if [ "$FM_HELM_HOLDER" = "$FM_HELM_MACHINE" ]; then
        printf 'HELM: this machine (%s) is the control plane of fleet %s at epoch %s\n' \
          "$FM_HELM_MACHINE" "$FM_HELM_FLEET" "$FM_HELM_EPOCH"
        exit 0
      fi
      if [ "$FM_HELM_HOLDER" = none ]; then
        printf 'HELM: no machine holds the helm of fleet %s (epoch %s); this session is read-only until bin/fm-helm.sh claim\n' \
          "$FM_HELM_FLEET" "$FM_HELM_EPOCH"
      else
        printf 'HELM: %s is the control plane of fleet %s at epoch %s; this machine (%s) is read-only\n' \
          "$FM_HELM_HOLDER" "$FM_HELM_FLEET" "$FM_HELM_EPOCH" "$FM_HELM_MACHINE"
      fi
      exit 1
    fi
    printf 'fleet:   %s\n' "$FM_HELM_FLEET"
    printf 'machine: %s%s\n' "$FM_HELM_MACHINE" \
      "$(fm_helm_is_anchor && printf ' (anchor)' || printf '')"
    printf 'anchor:  %s\n' "$FM_HELM_ANCHOR"
    printf 'peers:   %s\n' "$(printf '%s' "$PEERS" | tr '\n' ' ')"
    printf 'lease:   epoch %s holder %s%s\n' "$FM_HELM_EPOCH" "$FM_HELM_HOLDER" \
      "$([ "$FM_HELM_FORCED" = 1 ] && printf ' (taken by force)' || printf '')"
    if [ "$FM_HELM_HOLDER" = "$FM_HELM_MACHINE" ]; then
      printf 'verdict: this machine is the control plane and may change fleet state.\n'
    else
      printf 'verdict: this machine is read-only; spawn, steer, merge, and cleanup all refuse here.\n'
    fi
    [ -f "$LOST" ] && { printf 'ALERT:\n'; sed 's/^/  /' "$LOST"; }
    exit 0
    ;;

  audit)
    fm_helm_lease_load
    printf 'fleet %s, anchor %s\n' "$FM_HELM_FLEET" "$FM_HELM_ANCHOR"
    RC=0
    ANCHOR_LINE=$(lease_of "$FM_HELM_ANCHOR" 2>/dev/null || true)
    for m in $FM_HELM_MACHINE $PEERS; do
      if LINE=$(lease_of "$m" 2>/dev/null); then
        MARK=''
        [ "$m" = "$FM_HELM_ANCHOR" ] && MARK=' <- authoritative'
        if [ -n "$ANCHOR_LINE" ] && [ "$LINE" != "$ANCHOR_LINE" ] && [ "$m" != "$FM_HELM_ANCHOR" ]; then
          MARK=' <- DISAGREES with the anchor; bin/fm-helm.sh status --refresh on that machine'
          RC=1
        fi
        printf '  %-16s epoch %s holder %s%s\n' "$m" "${LINE%% *}" "${LINE##* }" "$MARK"
      else
        printf '  %-16s could not be read from here\n' "$m"
        RC=1
      fi
    done
    exit "$RC"
    ;;

  handover)
    TARGET=${1:-}
    [ -n "$TARGET" ] || die "usage: fm-helm.sh handover <machine>"
    fm_helm_name_valid "$TARGET" || die "invalid machine name '$TARGET'"
    machine_known "$TARGET" || die "'$TARGET' is not a member of fleet $FM_HELM_FLEET"
    [ "$TARGET" != "$FM_HELM_MACHINE" ] || die "this machine already holds the helm"
    require_holder "hand the helm to $TARGET"
    # The helm can only be given away by whoever holds it. Taking it from the
    # far side would mean writing a lease for a machine that is not taking part,
    # and if that machine is unreachable its own copy would keep telling it that
    # it is still the control plane. `claim --force` is the deliberate,
    # captain-authorized exception, and it says so out loud.
    read_anchor || die "the authoritative copy on $FM_HELM_ANCHOR cannot be read (${FM_HELM_ERR:-unreachable}); a handover that cannot reach the anchor is not safe to make"
    if [ "$ANCHOR_HOLDER" != "$FM_HELM_MACHINE" ]; then
      reconcile_local
      die "the authoritative copy says $ANCHOR_HOLDER holds the helm at epoch $ANCHOR_EPOCH, not this machine"
    fi
    quiesce_report
    NEXT=$((ANCHOR_EPOCH + 1))
    if ! set_lease "$FM_HELM_ANCHOR" "$ANCHOR_EPOCH" "$NEXT" "$TARGET" 0; then
      echo "REFUSED: the helm did not move. $FM_HELM_ERR" >&2
      read_anchor && reconcile_local
      exit 1
    fi
    printf 'helm moved: %s -> %s, fleet %s, epoch %s -> %s\n' \
      "$FM_HELM_MACHINE" "$TARGET" "$FM_HELM_FLEET" "$ANCHOR_EPOCH" "$NEXT"
    PROP_RC=0
    propagate "$NEXT" "$TARGET" || PROP_RC=$?
    disarm_control_assets
    fm_helm_lease_load
    if [ "$PROP_RC" -ne 0 ]; then
      printf 'The helm HAS moved - the authoritative copy on %s says so. A machine listed\n' "$FM_HELM_ANCHOR"
      printf 'above still holds an old copy and will treat itself as read-only until it runs\n'
      printf 'bin/fm-helm.sh status --refresh, which is the safe direction.\n'
    fi
    printf 'Next, on %s: bin/fm-helm.sh adopt - it picks up the tasks still running here.\n' "$TARGET"
    exit 0
    ;;

  claim)
    FORCE=0
    for a in "$@"; do
      case "$a" in
        --force) FORCE=1 ;;
        *) die "unexpected argument '$a'" ;;
      esac
    done
    if ! read_anchor; then
      cat >&2 <<EOF
error: the authoritative copy on $FM_HELM_ANCHOR cannot be read (${FM_HELM_ERR:-unreachable}).
Claiming the helm without it would mean two machines could each believe they
hold it. If $FM_HELM_ANCHOR is genuinely gone and the captain has decided this
machine must take over anyway, re-run with --force and read what it prints.
EOF
      exit 1
    fi
    if [ "$ANCHOR_HOLDER" = "$FM_HELM_MACHINE" ] && [ "$FORCE" -eq 0 ]; then
      reconcile_local
      rm -f "$(fm_helm_lost_file "$FM_HOME")"
      printf 'already held: this machine is the control plane of fleet %s at epoch %s\n' \
        "$FM_HELM_FLEET" "$ANCHOR_EPOCH"
      exit 0
    fi
    if [ "$ANCHOR_HOLDER" != none ] && [ "$FORCE" -eq 0 ]; then
      cat >&2 <<EOF
REFUSED: $ANCHOR_HOLDER holds the helm of fleet $FM_HELM_FLEET at epoch $ANCHOR_EPOCH.
The helm is given away by whoever holds it, not taken: run
  bin/fm-helm.sh handover $FM_HELM_MACHINE
on $ANCHOR_HOLDER. If that machine is gone for good, --force is the captain's
escape hatch and states exactly what it cannot check.
EOF
      exit 1
    fi
    if [ "$FORCE" -eq 1 ]; then
      cat <<EOF
FORCED CLAIM. What this cannot verify, stated plainly:
  - whether $ANCHOR_HOLDER is actually stopped. Nothing here probes it, by design.
  - whether it is mid-way through a merge, a validation gate, or a dispatch.
Its own copy of the lease will keep telling it that it holds the helm until it
can reach the anchor again, so until then BOTH machines can act on their own
work. Making sure that is not true is the captain's job, not this command's.
EOF
    fi
    NEXT=$((ANCHOR_EPOCH + 1))
    if ! set_lease "$FM_HELM_ANCHOR" "$ANCHOR_EPOCH" "$NEXT" "$FM_HELM_MACHINE" "$FORCE"; then
      echo "REFUSED: the helm did not move. $FM_HELM_ERR" >&2
      read_anchor && reconcile_local
      exit 1
    fi
    printf 'helm claimed: %s now holds fleet %s at epoch %s (was %s at %s)\n' \
      "$FM_HELM_MACHINE" "$FM_HELM_FLEET" "$NEXT" "$ANCHOR_HOLDER" "$ANCHOR_EPOCH"
    propagate "$NEXT" "$FM_HELM_MACHINE" || true
    rm -f "$(fm_helm_lost_file "$FM_HOME")"
    fm_helm_lease_load
    printf 'Next: bin/fm-helm.sh adopt - it picks up the tasks running on the other machines.\n'
    exit 0
    ;;

  demote)
    require_holder "give the helm up"
    read_anchor || die "the authoritative copy on $FM_HELM_ANCHOR cannot be read (${FM_HELM_ERR:-unreachable})"
    [ "$ANCHOR_HOLDER" = "$FM_HELM_MACHINE" ] \
      || { reconcile_local; die "the authoritative copy says $ANCHOR_HOLDER holds the helm, not this machine"; }
    NEXT=$((ANCHOR_EPOCH + 1))
    if ! set_lease "$FM_HELM_ANCHOR" "$ANCHOR_EPOCH" "$NEXT" none 0; then
      echo "REFUSED: the helm did not move. $FM_HELM_ERR" >&2
      exit 1
    fi
    propagate "$NEXT" none || true
    disarm_control_assets
    fm_helm_lease_load
    printf 'helm released: nobody holds fleet %s (epoch %s). Every machine is read-only\n' \
      "$FM_HELM_FLEET" "$NEXT"
    printf 'until one runs bin/fm-helm.sh claim.\n'
    exit 0
    ;;

  adopt)
    require_holder "adopt work from the other machines"
    ADOPTED=0; SKIPPED=0; FAILED=0
    for PEER in $PEERS; do
      [ "$PEER" = "$FM_HELM_MACHINE" ] && continue
      if ! LIST=$(fm_helm_verb "$FM_HOME" "$PEER" task-list 2>&1); then
        printf 'could not ask %s what it is running (%s)\n' "$PEER" "${FM_HELM_ERR:-unreachable}" >&2
        FAILED=$((FAILED + 1))
        continue
      fi
      case "${LIST%%$'\n'*}" in
        OK*) ;;
        *) printf 'could not ask %s what it is running: %s\n' "$PEER" "${LIST%%$'\n'*}" >&2
           FAILED=$((FAILED + 1)); continue ;;
      esac
      # The list is collected BEFORE the loop rather than piped into it. Each
      # iteration below runs another verb, and over a real relay that is a
      # `bifrost` process which may read stdin - which here would be the rest of
      # the task list. One task would adopt and the others would vanish.
      TASK_LINES=()
      while IFS= read -r LINE; do
        [ -n "$LINE" ] || continue
        TASK_LINES+=("$LINE")
      done <<< "$(printf '%s' "$LIST" | sed -n '2,$p')"
      for LINE in ${TASK_LINES[@]+"${TASK_LINES[@]}"}; do
        ID=${LINE%% *}
        fm_relay_id_valid "$ID" || continue
        ACK=$(printf '%s' "$LINE" | tr ' ' '\n' | sed -n 's/^ack=//p' | head -1)
        case "$ACK" in ''|*[!0-9]*) ACK=0 ;; esac
        if [ -f "$STATE/$ID.meta" ]; then
          # Already known here. A record with no host= line is a LOCAL task of
          # the same name, which is an id collision between two machines, not
          # something to overwrite: overwriting it would point every steer and
          # every cleanup for the local task at the peer's task instead.
          if grep -q '^host=' "$STATE/$ID.meta"; then
            SKIPPED=$((SKIPPED + 1))
          else
            printf 'REFUSED to adopt %s from %s: a DIFFERENT local task already uses that id here\n' \
              "$ID" "$PEER" >&2
            FAILED=$((FAILED + 1))
          fi
          continue
        fi
        if ! META_OUT=$(fm_helm_verb "$FM_HOME" "$PEER" task-meta "$ID" 2>&1); then
          printf 'could not read the record for %s on %s (%s)\n' "$ID" "$PEER" "${FM_HELM_ERR:-unreachable}" >&2
          FAILED=$((FAILED + 1)); continue
        fi
        case "${META_OUT%%$'\n'*}" in
          OK\ *) ;;
          *) printf 'could not read the record for %s on %s: %s\n' "$ID" "$PEER" "${META_OUT%%$'\n'*}" >&2
             FAILED=$((FAILED + 1)); continue ;;
        esac
        mkdir -p "$STATE"
        {
          printf '%s\n' "$META_OUT" | sed -n '2,$p' | grep -v '^host='
          printf 'host=%s\n' "$PEER"
        } > "$STATE/$ID.meta"
        if ! grep -q '^worktree=' "$STATE/$ID.meta"; then
          rm -f "$STATE/$ID.meta"
          printf 'REFUSED to adopt %s from %s: its record has no worktree line\n' "$ID" "$PEER" >&2
          FAILED=$((FAILED + 1)); continue
        fi
        # Start reading events from what the PEER recorded as presented, not
        # from zero and not from the end. That cursor is the reason a handover
        # neither replays a hundred old lines nor silently swallows the ones the
        # old control plane never got round to showing anyone.
        printf '%s\n' "$ACK" > "$STATE/$ID.relay-ack"
        printf '%s\n' "$ACK" > "$STATE/$ID.relay-seen"
        rm -f "$STATE/$ID.check.sh" "$STATE/$ID.check-trust"
        if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
          "$SCRIPT_DIR/fm-relay-check-make.sh" "$ID" >/dev/null 2>&1; then
          ADOPTED=$((ADOPTED + 1))
          printf 'adopted %s from %s (watching from event offset %s)\n' "$ID" "$PEER" "$ACK"
        else
          printf 'adopted %s from %s BUT could not arm its notifications; it is unobserved here\n' \
            "$ID" "$PEER" >&2
          FAILED=$((FAILED + 1))
        fi
        PR=$(grep '^pr=' "$STATE/$ID.meta" | cut -d= -f2- | head -1 || true)
        if [ -n "$PR" ]; then
          printf '%s carries an open change at %s - re-arm its checks here with:\n' "$ID" "$PR"
          printf '  bin/fm-pr-check.sh %s %s\n' "$ID" "$PR"
        fi
      done
    done
    printf 'adopt: %s picked up, %s already known, %s problem(s)\n' "$ADOPTED" "$SKIPPED" "$FAILED"
    [ "$FAILED" -eq 0 ] || exit 1
    exit 0
    ;;

  *)
    usage
    exit 2
    ;;
esac
