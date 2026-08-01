# shellcheck shell=bash
# fm-helm-lib.sh - which machine is the control plane, and who may act like it.
#
# WHAT THIS IS NOT. There is no automatic takeover here, and none is coming
# through this file: no liveness probe, no grace period, no heartbeat, no
# evidence-based seizure of the helm from a machine that looks dead. The captain
# decided (2026-08-01) that changing control machines is a human action. The
# unified-env design's §4.2 auto-takeover half is therefore not implemented, and
# the lease deliberately carries no `beat_at` field: a heartbeat's only consumer
# was that takeover judgement, so writing one would be building the hook and
# calling it something else.
#
# WHAT REMAINS, and why it is not the same thing. An explicit handover still
# produces a STALE control plane - the machine that just gave the helm up is
# still running, still holds task metadata, and can still be told to do
# something. Correctness therefore rests on two mechanisms that have nothing to
# do with arbitration:
#
#   1. EPOCH FENCING (the load-bearing one). Every verb that changes a peer's
#      state carries the caller's epoch, and the PEER checks it against its own
#      lease. A stale control plane is refused by the machine it is trying to
#      command, so nothing depends on the stale side being honest, on its clock,
#      or on its view of the network. bin/fm-relay-lib.sh attaches the token;
#      control-root/verbs/fmr-verb.sh enforces it.
#   2. THE LOCAL GATE. fm_helm_assert sits in front of spawn, send, merge,
#      local merge, and teardown, so a demoted machine cannot mutate anything -
#      not the peer's state, and not its own projects either.
#
# WHERE THE TRUTH LIVES. One lease per machine, under that machine's control
# root, written only through a verb - the peer cannot reach it with `remote file
# write` because the control root sits outside the file roots (measured, Phase
# 1). The ANCHOR machine's copy is authoritative. That choice is physical, not
# aesthetic: the anchor is the always-on machine, so the truth is anchored where
# it can always be read. Two rules follow, and both are enforced below:
# write the anchor first and the other machine second, and on disagreement the
# anchor wins.
#
# WHY NOT REUSE THE SESSION LOCK. bin/fm-lock.sh writes a local PID and judges
# liveness with kill -0 plus a process-name match. That is only meaningful on
# the machine that wrote it; carried to another machine the PID lands on some
# unrelated live process. The two are orthogonal and both apply: the session
# lock stops two sessions on ONE machine, the helm lease decides which of TWO
# machines is the control plane.
#
# SINGLE-MACHINE USERS. This whole file is inert without <home>/config/fleet.json.
# That is one stat() on the fast path - no jq, no lease read, no network, and
# not one byte of output. tests/fm-helm-fleetless-probe.sh pins that down against
# a transcript captured before the gate existed.

[ -n "${FM_HELM_LIB_SOURCED:-}" ] && return 0
FM_HELM_LIB_SOURCED=1

# Set by fm_helm_fleet_load; read by this library's callers.
# shellcheck disable=SC2034  # consumed by bin/fm-helm.sh and bin/fm-session-start.sh
FM_HELM_FLEET=
FM_HELM_MACHINE=
FM_HELM_CONTROL_ROOT=
FM_HELM_ANCHOR=
# Set by fm_helm_lease_load.
FM_HELM_EPOCH=
FM_HELM_HOLDER=
FM_HELM_FORCED=
FM_HELM_ERR=

FM_HELM_NAME_RE='^[A-Za-z0-9._-]{1,64}$'

fm_helm_fleet_file() {  # <home>
  printf '%s/config/fleet.json' "$1"
}

fm_helm_lost_file() {  # <home>
  printf '%s/.helm-lost' "${FM_STATE_OVERRIDE:-$1/state}"
}

fm_helm_name_valid() {  # <name>
  [[ "$1" =~ $FM_HELM_NAME_RE ]]
}

# True when this home belongs to a fleet at all. Deliberately the cheapest
# possible question: every gated command asks it on every run, and the answer on
# a single-machine home has to cost one stat and produce no output.
fm_helm_in_fleet() {  # <home>
  [ -f "$(fm_helm_fleet_file "$1")" ]
}

# Read <home>/config/fleet.json into the FM_HELM_* globals.
#
# Returns 1 with FM_HELM_ERR empty when the home is simply not in a fleet - the
# ordinary single-machine case, which is not an error and must stay silent.
# Returns 1 with FM_HELM_ERR set when the home DID opt in and the record cannot
# be used; that is a real problem and the caller must refuse rather than assume
# the machine still holds the helm.
fm_helm_fleet_load() {  # <home>
  local home=$1 file raw
  FM_HELM_FLEET=; FM_HELM_MACHINE=; FM_HELM_CONTROL_ROOT=; FM_HELM_ANCHOR=
  FM_HELM_ERR=
  file=$(fm_helm_fleet_file "$home")
  [ -f "$file" ] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    FM_HELM_ERR="jq is required to read $file"
    return 1
  fi
  # Same line-per-field parse as the relay host registry, and for the same
  # reason: a tab-separated row collapses adjacent empties and shifts every
  # later field left. The trailing sentinel keeps command substitution from
  # eating a trailing empty field.
  raw=$(jq -r '[ (.fleet // ""), (.machine // ""), (.control_root // ""),
                 (.anchor // ""), "." ] | .[]' "$file" 2>/dev/null) || {
    FM_HELM_ERR="$file is not valid JSON"
    return 1
  }
  { read -r FM_HELM_FLEET; read -r FM_HELM_MACHINE; read -r FM_HELM_CONTROL_ROOT
    read -r FM_HELM_ANCHOR
  } <<< "$raw"
  local f
  for f in FM_HELM_FLEET FM_HELM_MACHINE FM_HELM_CONTROL_ROOT FM_HELM_ANCHOR; do
    [ -n "${!f}" ] || { FM_HELM_ERR="$file is missing ${f#FM_HELM_}"; return 1; }
  done
  for f in FM_HELM_FLEET FM_HELM_MACHINE FM_HELM_ANCHOR; do
    fm_helm_name_valid "${!f}" \
      || { FM_HELM_ERR="$file has an unusable ${f#FM_HELM_} value '${!f}'"; return 1; }
  done
  case "$FM_HELM_CONTROL_ROOT" in
    /*) ;;
    *) FM_HELM_ERR="$file control_root must be an absolute path"; return 1 ;;
  esac
  return 0
}

fm_helm_is_anchor() { [ "$FM_HELM_MACHINE" = "$FM_HELM_ANCHOR" ]; }

fm_helm_lease_path() {  # (after fm_helm_fleet_load)
  printf '%s/helm/lease' "$FM_HELM_CONTROL_ROOT"
}

fm_helm_lease_field() {  # <lease-file> <key>
  [ -f "$1" ] || return 1
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Read this machine's own lease copy into FM_HELM_EPOCH / FM_HELM_HOLDER.
# An absent lease is epoch 0 with no holder: a fleet that has been declared but
# never had its helm claimed. Nobody may act as the control plane in that state,
# which is the safe direction.
fm_helm_lease_load() {  # (after fm_helm_fleet_load)
  local file
  FM_HELM_EPOCH=0; FM_HELM_HOLDER=none; FM_HELM_FORCED=0
  file=$(fm_helm_lease_path)
  [ -f "$file" ] || return 0
  FM_HELM_EPOCH=$(fm_helm_lease_field "$file" epoch)
  FM_HELM_HOLDER=$(fm_helm_lease_field "$file" holder)
  FM_HELM_FORCED=$(fm_helm_lease_field "$file" forced)
  case "$FM_HELM_EPOCH" in ''|*[!0-9]*) FM_HELM_EPOCH=0 ;; esac
  [ -n "$FM_HELM_HOLDER" ] || FM_HELM_HOLDER=none
  case "$FM_HELM_FORCED" in ''|*[!0-9]*) FM_HELM_FORCED=0 ;; esac
  return 0
}

# The epoch to send with a state-changing verb, or nothing at all.
#
# bin/fm-relay-lib.sh calls this on every verb dispatch, so "nothing at all" is
# the load-bearing answer: a Phase 1/2 home that never declared a fleet gets an
# argument list identical to the one it sent before this file existed.
fm_helm_epoch_for_home() {  # <home>
  fm_helm_in_fleet "$1" || return 0
  fm_helm_fleet_load "$1" >/dev/null 2>&1 || return 0
  fm_helm_lease_load
  [ "$FM_HELM_EPOCH" = 0 ] && return 0
  printf '%s' "$FM_HELM_EPOCH"
}

# THE GATE. Called by fm-spawn, fm-send, fm-teardown, fm-pr-merge, and
# fm-merge-local before they change anything.
#
# Order matters and is chosen so the cheap answer comes first:
#   1. running as a task host under an already-fenced verb -> allow. The verb
#      validated the caller's epoch against this machine's own lease before it
#      got here, so the authority question is already answered; asking again
#      here would refuse every relay dispatch, because a task host is by
#      definition not the holder.
#   2. no fleet -> allow, silently, having touched nothing.
#   3. unreadable fleet record, or the helm was taken from under this machine
#      -> refuse.
#   4. holder is this machine -> allow. No network call: the local copy is
#      correct unless the peer moved the helm without this machine taking part,
#      and handover refuses to do that (bin/fm-helm.sh).
fm_helm_assert() {  # <home> <what-is-being-attempted>
  local home=$1 what=$2 lost
  [ "${FM_HELM_HOST_EXEC:-0}" = 1 ] && return 0
  fm_helm_in_fleet "$home" || return 0
  lost=$(fm_helm_lost_file "$home")
  if [ -f "$lost" ]; then
    printf 'REFUSED: %s\n' "$what" >&2
    printf 'This machine was removed as the control plane while it was running:\n' >&2
    sed 's/^/  /' "$lost" >&2
    printf 'Resolve that with the captain before this machine acts again. Once it is\n' >&2
    printf 'settled, %s/bin/fm-helm.sh claim on the machine that should hold the helm\n' "${FM_ROOT:-.}" >&2
    printf 'clears this state.\n' >&2
    return 1
  fi
  if ! fm_helm_fleet_load "$home"; then
    printf 'REFUSED: %s\n' "$what" >&2
    printf 'This machine declares fleet membership but the record cannot be used: %s\n' \
      "${FM_HELM_ERR:-unknown problem}" >&2
    return 1
  fi
  fm_helm_lease_load
  [ "$FM_HELM_HOLDER" = "$FM_HELM_MACHINE" ] && return 0
  printf 'REFUSED: %s\n' "$what" >&2
  if [ "$FM_HELM_HOLDER" = none ]; then
    printf 'No machine currently holds the helm of fleet %s (epoch %s), so nothing here\n' \
      "$FM_HELM_FLEET" "$FM_HELM_EPOCH" >&2
    printf 'may change fleet state. Take it with bin/fm-helm.sh claim.\n' >&2
  else
    printf '%s holds the helm of fleet %s (epoch %s); this machine is %s and is\n' \
      "$FM_HELM_HOLDER" "$FM_HELM_FLEET" "$FM_HELM_EPOCH" "$FM_HELM_MACHINE" >&2
    printf 'read-only. Ask %s to run bin/fm-helm.sh handover %s, or run\n' \
      "$FM_HELM_HOLDER" "$FM_HELM_MACHINE" >&2
    printf 'bin/fm-helm.sh status here to re-read the authoritative lease.\n' >&2
  fi
  return 1
}

# Run one helm verb, on this machine or on a peer, through the SAME entry point.
#
# The lease is only ever written by control-root/verbs/fmr-verb.sh, including on
# the machine the command is running on. Executing the local control root's own
# verb rather than writing the file here is what keeps one implementation of the
# compare-and-swap instead of two that drift.
#
# Prints the verb's output. Returns its exit status.
fm_helm_verb() {  # <home> <machine> <verb> [arg...]
  local home=$1 machine=$2
  shift 2
  if [ "$machine" = "$FM_HELM_MACHINE" ]; then
    local verb_path="$FM_HELM_CONTROL_ROOT/verbs/fmr-verb.sh"
    if [ ! -x "$verb_path" ]; then
      FM_HELM_ERR="this machine has no deployed control root at $verb_path"
      return 1
    fi
    "$verb_path" "$@"
    return $?
  fi
  if ! command -v fm_relay_host_load >/dev/null 2>&1; then
    FM_HELM_ERR="the relay client library is not loaded, so $machine cannot be reached"
    return 1
  fi
  fm_relay_host_load "$home" "$machine" >/dev/null 2>&1 || {
    FM_HELM_ERR="$machine is not a registered relay host in this home"
    return 1
  }
  # helm verbs are never epoch-fenced: reading the lease must work from a
  # demoted machine, and helm-set carries its own expect= guard.
  FM_HELM_NO_FENCE=1 fm_relay_exec "$@"
  local rc=$?
  printf '%s\n' "$FM_RELAY_OUT"
  [ "$rc" -eq 0 ] || FM_HELM_ERR=${FM_RELAY_ERR%%$'\n'*}
  return "$rc"
}

# Pull one `key=value` out of a verb's `OK ...` header line.
fm_helm_header_field() {  # <verb-output> <key>
  printf '%s' "${1%%$'\n'*}" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}
