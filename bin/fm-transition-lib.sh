#!/usr/bin/env bash
# Shared, backend-neutral agent-state transition shape and supervision policy.
#
# This library owns THREE contracts, deliberately backend-independent so any
# push-capable session backend (herdr and rex today) reuses them instead
# of re-deriving a private, per-status escalation hack:
#
#   1. The NORMALIZED TRANSITION RECORD - the ONE shape every backend's event
#      stream is normalized into before any policy runs. A single TAB-separated
#      line:
#          <pane_id>\t<workspace_id>\t<from_status>\t<to_status>\t<agent>\t<detail>
#      Only `to_status` is authoritative for the policy below; the other fields
#      are identity/telemetry and MAY be empty when a backend cannot supply
#      them. `detail` is the backend's human-readable reason for the edge (Rex
#      reports a blocked kind such as permission|question|auth and a message),
#      carried into the supervisor's wake reason and never parsed. `from_status` in particular is empty for backends whose event
#      carries only the new status (herdr's `pane.agent_status_changed` does
#      not report the previous status, and its stream is edge-triggered, so
#      each `to_status` IS itself a fresh edge); it exists in the shape for
#      backends that DO report the prior state and for future edge diagnostics.
#      Statuses use the shared agent-state vocabulary
#      (idle|working|blocked|done|unknown), the same enum herdr's `agent get`
#      and `pane.agent_status_changed` report, plus `gone` for an endpoint
#      whose program exited or whose pane closed (Rex reports both as events).
#
#   2. The STATUS -> ACTION POLICY TABLE (fm_transition_policy) - the SINGLE
#      OWNER of the mapping from a normalized `to_status` to the supervision
#      action a consumer must take. Every consumer READS this table; no
#      consumer re-encodes the mapping. Adding or changing a status's action is
#      a one-line edit here, and it changes every backend at once.
#
#   3. The PER-PANE ESCALATION DEDUPE (fm_transition_apply, _commit, _clear) -
#      one marker file per window under the state dir, set once a fresh
#      actionable edge has been handled and cleared by the next `working` edge
#      or the task's cleanup, so exactly one wake fires per ->blocked edge and a
#      reconnect level-reconcile never re-delivers a still-blocked pane. Each
#      backend passes its own marker prefix so the two never collide.
#
# The split is what keeps the escalation general rather than a herdr blocked
# hack: a backend contributes only a wire->record normalizer and a stream
# reader; the shape, the policy, and the dedupe are shared. See
# bin/backends/herdr.sh and bin/backends/rex.sh (fm_backend_<name>_wait_transition)
# for the producers and bin/fm-watch.sh (the watcher's event-wait splice) for
# the consumer.

# Field separator for the normalized record. A literal TAB; every field is
# scrubbed of TAB/newline by the producer so the record is exactly six fields.
FM_TRANSITION_FIELD_SEP=$'\t'

# fm_transition_record: THE constructor for a normalized transition record.
# Both a backend's stream normalizer and its level-reconcile read MUST build
# records through this one function, so the record's field order and separator
# have a single owner. Fields are TAB/newline-scrubbed here.
fm_transition_record() {  # <pane_id> <workspace_id> <from_status> <to_status> <agent> [detail]
  local pane_id ws from to agent detail
  pane_id=$(fm_transition_clean_field "${1:-}")
  ws=$(fm_transition_clean_field "${2:-}")
  from=$(fm_transition_clean_field "${3:-}")
  to=$(fm_transition_clean_field "${4:-}")
  agent=$(fm_transition_clean_field "${5:-}")
  detail=$(fm_transition_clean_field "${6:-}")
  printf '%s\t%s\t%s\t%s\t%s\t%s' "$pane_id" "$ws" "$from" "$to" "$agent" "$detail"
}

# fm_transition_clean_field: collapse any TAB/CR/LF in a field value to spaces
# so a stray control char can never desync the fixed six-field record.
fm_transition_clean_field() {  # <value>
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

# Field accessors (1-based), so consumers never hardcode the column layout.
fm_transition_field() {  # <record> <n>
  printf '%s' "$1" | cut -d"$FM_TRANSITION_FIELD_SEP" -f"$2"
}

fm_transition_pane_id()      { fm_transition_field "$1" 1; }
fm_transition_workspace_id() { fm_transition_field "$1" 2; }
fm_transition_from_status()  { fm_transition_field "$1" 3; }
fm_transition_to_status()    { fm_transition_field "$1" 4; }
fm_transition_agent()        { fm_transition_field "$1" 5; }
fm_transition_detail()       { fm_transition_field "$1" 6; }

# fm_transition_policy: THE single-owner status -> supervision-action table.
# Given a normalized `to_status`, print exactly one action token:
#
#   actionable - escalate to the supervisor IMMEDIATELY (a fresh edge here is a
#                durable wake now). `blocked` is the only immediately-actionable
#                status today: herdr reports it precisely when a harness is
#                waiting on the human (a permission/trust dialog, an interactive
#                menu, a wedged prompt) - the cases that write no status file
#                and otherwise sit until the stale-pane wedge timer.
#   absorb     - do NOT wake, but CLEAR this pane's per-pane escalation dedupe
#                marker so a later `->blocked` edge re-escalates. `working`
#                (a crew resumed/started a turn) is the clearing edge.
#   defer      - do NOTHING on the fast path; leave it to the existing
#                status/turn-end completion semantics and the poll backstop.
#                `idle`/`done` blip transiently between tool calls, so
#                fast-pathing them would be a false-positive firehose - they are
#                already covered by the debounced signal/stale machinery.
#   rescan     - the endpoint is `gone` (its program exited or its pane closed):
#                end the wait now so the watcher's poll cycle reconciles that
#                task at once through its own liveness checks. Never a wake by
#                itself, because a routine cleanup closes panes too.
#   fallback   - the status is unknown/unrecognized: fall back to polling for
#                this pane (the permanent fail-closed backstop), taking no fast
#                action from an ambiguous read.
#
# Consumers act on `actionable`, mutate dedupe state on `absorb`, end the wait
# on `rescan`, and ignore `defer`/`fallback` on the fast path. Subscribing to ALL statuses (not just
# `blocked`) is deliberate: `working`/`idle`/`done` carry the dedupe-clear and
# reconnect/level-reconcile state; only THIS policy makes `blocked` the sole
# immediate action.
fm_transition_policy() {  # <to_status> -> actionable|absorb|defer|rescan|fallback
  case "$1" in
    blocked) printf 'actionable' ;;
    working) printf 'absorb' ;;
    idle|done) printf 'defer' ;;
    gone) printf 'rescan' ;;
    *) printf 'fallback' ;;
  esac
}

# fm_transition_marker: the per-pane dedupe marker path for <window>
# ("<session>:<pane_id>"), keyed like the watcher's own .stale-<key>
# (tr ':/.' '___'), under <state_dir> with the backend's <prefix>.
fm_transition_marker() {  # <state_dir> <prefix> <window>
  local key
  key=$(printf '%s' "$3" | tr ':/.' '___')
  printf '%s/%s%s' "$1" "$2" "$key"
}

# fm_transition_apply: route one normalized record through the policy table,
# maintaining the per-pane dedupe marker. On a fresh `actionable` edge (no
# marker yet) it prints the record and returns 0; the caller commits the marker
# only after handling it. `absorb` clears the marker and returns 1. `rescan`
# returns 3 with no output. `defer`, `fallback`, and an already-marked
# `actionable` return 1 with no output. <session> reconstructs the window
# ("<session>:<pane_id>") for the marker key.
fm_transition_apply() {  # <state_dir> <prefix> <session> <record>
  local state=$1 prefix=$2 session=$3 record=$4 pane_id marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  marker=$(fm_transition_marker "$state" "$prefix" "$session:$pane_id")
  case "$(fm_transition_policy "$(fm_transition_to_status "$record")")" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      rm -f "$marker" 2>/dev/null || true
      ;;
    rescan)
      return 3
      ;;
  esac
  return 1
}

fm_transition_commit() {  # <state_dir> <prefix> <session> <record>
  local pane_id
  pane_id=$(fm_transition_pane_id "$4")
  [ -n "$pane_id" ] || return 1
  : > "$(fm_transition_marker "$1" "$2" "$3:$pane_id")"
}

fm_transition_clear() {  # <state_dir> <prefix> <window>
  [ -n "$3" ] || return 0
  rm -f "$(fm_transition_marker "$1" "$2" "$3")" 2>/dev/null || true
}
