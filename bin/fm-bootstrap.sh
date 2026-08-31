#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "HOME_SUMMARY: <ledger never published|not republished since
#                 <stamp>>; <n> failed attempt(s) ... last: <recorded failure>",
#                 "BACKLOG_RECONCILE: <id>: <what this home could not reconcile>",
#                 "TANGLE: <remediation>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged fm-<id> with '<message>'",
#                 "SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#                 "SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          When a RUNNING secondmate home is fast-forwarded, its target is
#          firstmate's own current default-branch commit. A local worktree uses
#          a purely local fast-forward with no origin fetch; a remote route hands
#          the same commit to its host, which imports that commit into the home
#          without moving the host's Firstmate copy. If either placement changes
#          its loaded instruction surface
#          (AGENTS.md, bin/, or .agents/skills/), bootstrap immediately nudges it
#          via FM_HOME=<active-home> bin/fm-send.sh fm-<id> so meta resolves the
#          current route and the standard from-firstmate marker is applied. A
#          successful send prints one BOOTSTRAP_INFO line with the exact target
#          and message sent; a failed send leaves an idempotent retry marker
#          under state/.secondmate-nudge-pending/ and prints an actionable
#          NUDGE_SECONDMATES line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The secondmate sweep also propagates declared inherited local material
#          into each validated live secondmate home.
#          SECONDMATE_SYNC lines report actionable skipped placement-specific
#          syncs or inheritance failures for live secondmate homes, plus
#          quarantine diagnostics for divergent shared captain-preference
#          copies; no-op/current and successful updates stay quiet.
#          SECONDMATE_LIVENESS lines report only actionable failures from the
#          recovery-grade state owned by bin/fm-backend.sh's
#          fm_backend_agent_state: skipped distinguishes an existing ambiguous
#          process, an unreadable target, and an unverified backend; respawn
#          failed names whether the endpoint was missing or agent-less.
#          Already-live and successfully relaunched secondmates are silent
#          unless FM_BOOTSTRAP_VERBOSE_FACTS=1 requests BOOTSTRAP_INFO facts.
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.46.0 (structured pipeline attestation floor; see CONTRIBUTING.md).
#          The AXI-family floor policy is owned beside GH_AXI_MIN and
#          LAVISH_AXI_MIN below; the per-tool owners point there. An installed
#          build below its floor reports MISSING like no-mistakes, so the operator
#          is asked to upgrade rather than silently running an older tool.
#          tasks-axi feature probes remain a separate defense-in-depth check.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). A compatible tasks-axi default backend is silent.
#          quota-axi is required for the agent-owned dispatch-profile array
#          procedure in AGENTS.md section 4 and
#          .agents/skills/quota-array-dispatch/SKILL.md.
#          On a primary home, the locked mutable path materializes the visible
#          default config/startup-memory-budget=7500 when absent. It never
#          guesses at malformed or unsafe existing files, and secondmate homes
#          await the primary-authoritative inherited value instead of creating
#          their own.
#          X mode is OPTIONAL and inert unless FM_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          BACKLOG_RECONCILE lines report what backlog_record_reconcile could not
#          settle in THIS home. Every ordinary dispatch and completion now moves
#          the backlog row inside the script that moves the task's record
#          (bin/fm-backlog-transition-lib.sh), so this sweep exists for the
#          crash window inside those scripts and for drift a home was already
#          carrying: it finishes the authoritative close or captain-call
#          retention an interrupted cleanup recorded, and marks In flight any
#          item this home already owns a worker for. The worker-record sweep
#          never starts a captain-held or closed item, and reconciliation never
#          reads or writes another home; the fleet snapshot's classifier and
#          bin/fm-secondmate-reconcile.sh's nudge stay as backstops. Replayed
#          transitions and restored In-flight rows print BOOTSTRAP_INFO facts.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the six MUTATING sweeps
#          (backlog_record_reconcile, secondmate_sync,
#          secondmate_liveness_sweep, secondmate_handoff_resume, x_mode_setup,
#          fleet_sync) while still
#          printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          secondmate homes, pending handoff outboxes,
#          X-mode artifacts, project clones, or repair instructions.
#          Unset/0 (the default) runs all six sweeps - this flag is purely
#          additive.
#          Set FM_BOOTSTRAP_NETWORK to split this run by whether a step talks to
#          the network, so a session start can print its digest from local reads
#          alone and run the network half off the digest's blocking path:
#            all  (default, and any unrecognized value) - every local and network
#                 step. Unrecognized values fall back here on purpose: a typo
#                 must never silently skip a safety sweep.
#            skip - every LOCAL step, and none of the network ones. Skips
#                 `gh auth status`, secondmate_liveness_sweep, secondmate_sync,
#                 secondmate_handoff_resume, and fleet_sync.
#            only - ONLY those network steps and nothing else. No tool detection,
#                 no version floors, no tangle check, no backlog
#                 reconciliation, no x_mode_setup: those already ran on the
#                 local pass.
#          FM_BOOTSTRAP_DETECT_ONLY composes with it unchanged, so `only` plus
#          detect-only is the read-only `gh auth status` probe on its own.
#          bin/fm-startup-network.sh owns the deferral: it runs the `only` phase
#          in a detached bounded worker and publishes the result. This file stays
#          the single owner of every sweep, and the split changes only WHEN each
#          runs, never WHETHER. During the network phase, project clone refresh
#          overlaps the independent secondmate work. Per-secondmate remote
#          liveness workers run concurrently and finish before per-secondmate
#          remote convergence workers run concurrently, because convergence
#          consumes respawned ids. Worker output is captured separately and
#          replayed in spawn order; failure to create that private capture
#          directory selects the sequential fallback.
#          A relaunch that the liveness sweep performs during an `only` run is
#          always reported, because a digest composed before that run already
#          printed the superseded endpoint record.
#          Set FM_BOOTSTRAP_LOCKED=1 alongside it when the sweeps are skipped
#          because THIS session already ran them while holding the fleet lock,
#          rather than because it has no lock at all. The two cases differ in
#          exactly one place: repair ownership. A locked session is told to
#          restore a tangled primary checkout itself, while an unlocked one is
#          told to leave that work to the lock holder. Unset/0 (the default)
#          keeps detect-only meaning unlocked, exactly as before.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# fm-timing-lib.sh is inert unless FM_TIMING_LOG names a file, which only the
# deferred network stage sets, so an ordinary bootstrap run records nothing.
# shellcheck source=bin/fm-timing-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timing-lib.sh"

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${FM_BOOTSTRAP_NETWORK:-all}" in
  skip|only) FM_BOOTSTRAP_NETWORK_PHASE=${FM_BOOTSTRAP_NETWORK:-all} ;;
  *) FM_BOOTSTRAP_NETWORK_PHASE=all ;;
esac
local_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != only ]; }
network_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != skip ]; }

network_mutation_authorized() {
  local expected=${FM_BOOTSTRAP_NETWORK_LOCK_PID:-} current
  [ -n "$expected" ] || return 0
  case "$expected" in *[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

network_sweep_authorized() {
  local label=$1
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: fleet lock ownership changed before $label, so this stale worker skipped that sweep"
  return 1
}

# Concurrent per-item runner for the deferred network sweeps. Each worker's
# stdout and stderr are captured to private files and replayed in original
# order after every worker finishes, so concurrent probes cannot interleave
# or mis-attribute SECONDMATE_LIVENESS / SECONDMATE_SYNC lines. Respawned ids
# are collected from per-id files because background workers cannot mutate
# the parent's SECONDMATE_RESPAWNED_IDS.
bootstrap_parallel_begin() {
  BOOTSTRAP_PAR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-bootstrap-par.XXXXXX") || return 1
  BOOTSTRAP_PAR_N=0
  FM_BOOTSTRAP_PARALLEL_DIR=$BOOTSTRAP_PAR_DIR
  export FM_BOOTSTRAP_PARALLEL_DIR
}

bootstrap_parallel_spawn() {
  BOOTSTRAP_PAR_N=$((BOOTSTRAP_PAR_N + 1))
  (
    "$@"
  ) >"$BOOTSTRAP_PAR_DIR/$BOOTSTRAP_PAR_N.out" 2>"$BOOTSTRAP_PAR_DIR/$BOOTSTRAP_PAR_N.err" &
  printf '%s\n' "$!" > "$BOOTSTRAP_PAR_DIR/$BOOTSTRAP_PAR_N.pid"
}

bootstrap_parallel_finish() {
  local i pid f
  i=1
  while [ "$i" -le "$BOOTSTRAP_PAR_N" ]; do
    pid=$(cat "$BOOTSTRAP_PAR_DIR/$i.pid")
    wait "$pid" || true
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le "$BOOTSTRAP_PAR_N" ]; do
    cat "$BOOTSTRAP_PAR_DIR/$i.out"
    cat "$BOOTSTRAP_PAR_DIR/$i.err" >&2
    i=$((i + 1))
  done
  for f in "$BOOTSTRAP_PAR_DIR"/respawned.*; do
    [ -f "$f" ] || continue
    SECONDMATE_RESPAWNED_IDS="$SECONDMATE_RESPAWNED_IDS $(tr -d '\n' < "$f")"
  done
  rm -rf "$BOOTSTRAP_PAR_DIR"
  unset FM_BOOTSTRAP_PARALLEL_DIR BOOTSTRAP_PAR_DIR BOOTSTRAP_PAR_N
}

secondmate_note_respawned() {  # <id>
  SECONDMATE_RESPAWNED_IDS="$SECONDMATE_RESPAWNED_IDS $1"
  [ -n "${FM_BOOTSTRAP_PARALLEL_DIR:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_BOOTSTRAP_PARALLEL_DIR/respawned.$1"
}

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

secondmate_sync() {
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # Placement-specific secondmate sync: EVERY home, local or remote, follows the
  # primary checkout's current default-branch commit. The local path is purely
  # LOCAL - no fetch, no origin dependency: a linked-worktree home already holds
  # the primary's commit (fm-ff-lib.sh), while a standalone clone without it is
  # skipped until /updatefirstmate refreshes it from origin. A remote home is on
  # another machine, so its host is handed that same commit and imports it there
  # (bin/fm-remote-secondmate-control.sh); this side still fetches nothing.
  # Startup sends reread nudges only for RUNNING secondmates whose instruction
  # surface (AGENTS.md, bin/, or .agents/skills/) actually changed, so a secondmate already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Unlike
  # /updatefirstmate, startup owns the live-convergence send itself because it is
  # a deterministic locked sweep and can report success as BOOTSTRAP_INFO while
  # preserving failed sends as NUDGE_SECONDMATES retry markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$FM_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "SECONDMATE_SYNC: secondmate $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  SECOND_MATE_NUDGE_MESSAGE=$FM_SECOND_MATE_NUDGE_MESSAGE
  REMOTE_SECOND_MATE_NUDGE_MESSAGE=$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE
  SECOND_MATE_NUDGE_PENDING_DIR="$STATE/.secondmate-nudge-pending"

  secondmate_nudge_marker_path() {
    fm_secondmate_nudge_marker_path "$STATE" "$1"
  }

  secondmate_write_nudge_marker() {
    local id=$1 home=$2 commit=$3 instr=$4 message=${5:-$SECOND_MATE_NUDGE_MESSAGE} remote=${6:-0}
    fm_secondmate_nudge_write "$STATE" "$id" "$home" "$commit" "$instr" "$message" "$remote"
  }

  secondmate_send_nudge() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker out
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || {
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: unsafe id"
      return 0
    }
    if ! secondmate_write_nudge_marker "$id" "$home" "$commit" "$instr"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record retry marker"
      return 0
    fi
    if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
      rm -f "$marker"
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
    fi
  }

  fm_ff_after_instruction_update() {
    local id=$1 home=$2 _window=$3 instr=$4
    secondmate_send_nudge "$id" "$home" "$primary_head" "$instr"
  }

  secondmate_retry_pending_nudges() {
    local marker id selector home commit message remote expected_marker meta meta_home home_real head out
    [ -d "$SECOND_MATE_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$SECOND_MATE_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      id=$(fm_meta_get "$marker" id)
      if ! expected_marker=$(secondmate_nudge_marker_path "$id"); then
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$(fm_meta_get "$marker" selector)
      home=$(fm_meta_get "$marker" home)
      commit=$(fm_meta_get "$marker" commit)
      message=$(fm_meta_get "$marker" message)
      remote=$(fm_meta_get "$marker" remote)
      [ -n "$remote" ] || remote=0
      [ "$selector" = "fm-$id" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      case "$remote" in
        0) [ "$message" = "$SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker message mismatch"
          continue
        } ;;
        1) [ "$message" = "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: remote retry marker message mismatch"
          continue
        } ;;
        *)
          echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker placement is invalid"
          continue
          ;;
      esac
      [ "$remote" -ne 1 ] || continue
      meta="$STATE/$id.meta"
      [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = secondmate ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry target has no live secondmate metadata"
        continue
      }
      meta_home=$(fm_meta_get "$meta" home)
      [ -n "$meta_home" ] || meta_home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home || true)
      if ! validate_secondmate_home "$id" "$meta_home"; then
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      [ "$home_real" = "$home" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home changed"
        continue
      }
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$marker"
        echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
      else
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
      fi
    done
  }

  local tmp line
  secondmate_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes "$DATA/secondmates.md" >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_SECONDMATES:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  unset -f fm_ff_after_instruction_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live secondmate home swept above.
  # FF_SEEN_HOMES is exactly that set, and fm-config-inherit-lib.sh owns the
  # declared config items plus data/captain-shared.md.
  # After a successful push that changes allowlisted config/* for an already-
  # running home, send its literal-content reread instruction pointer so the
  # live agent does not keep applying stale defaults. Spawn/respawn already
  # re-reads at launch and needs no redundant nudge unless files changed after launch.
  local id home home_real home_lock propagated_homes report reread_out reread_skip_pending
  propagated_homes=""
  SECONDMATE_RESPAWNED_IDS=${SECONDMATE_RESPAWNED_IDS:-}
  while IFS='|' read -r id home _window _meta; do
    validate_secondmate_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    mkdir -p "$home_real/state" || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not create state directory"
      continue
    }
    home_lock=$(fm_config_inherit_lock_path "$home_real") || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not resolve per-home lock"
      continue
    }
    fm_lock_acquire_wait "$home_lock" || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not acquire per-home lock"
      continue
    }
    reread_skip_pending=0
    case " $SECONDMATE_RESPAWNED_IDS " in
      *" $id "*) reread_skip_pending=1 ;;
    esac
    if [ "$reread_skip_pending" -eq 0 ] \
      && fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
      fm_config_reread_retry_pending "$id" "$home_real" || true
      if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
        echo "CONFIG_REREAD: secondmate $id: send failed: retry instruction queue is full"
        fm_lock_release "$home_lock" || true
        continue
      fi
    fi
    report=$(mktemp "${TMPDIR:-/tmp}/fm-bootstrap-inherit.XXXXXX" 2>/dev/null) || {
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
      fm_lock_release "$home_lock" || true
      continue
    }
    if FM_CONFIG_INHERIT_REPORT="$report" FM_CONFIG_INHERIT_LIVE=1 \
      propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
      :
    else
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
    fi
    if ! reread_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_CONFIG_REREAD_SKIP_PENDING="$reread_skip_pending" \
      fm_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
      if [ -n "$reread_out" ]; then
        printf '%s\n' "$reread_out"
      else
        echo "CONFIG_REREAD: secondmate $id: send failed: unknown error"
      fi
    elif [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    fi
    rm -f "$report"
    fm_lock_release "$home_lock" || true
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")

  # One remote secondmate's convergence, split out of the loop so each host is
  # individually timed; every `return` here was a `continue` and still means
  # "move on to the next secondmate".
  secondmate_sync_remote_one() {  # <id> <home> <remote-host>
    local id=$1 _home=$2 remote_host=$3
    local sync_out sync_rc inherit_out nudge_needed remote_marker remote_pending converged out remote_lock remote_generation
    remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_lock" ] || ! fm_lock_acquire_wait "$remote_lock"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot lock remote inheritance transaction"
      return 0
    fi
    if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$id" >/dev/null 2>&1; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote reply source could not be registered"
    fi
    remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_generation" ]; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote inheritance generation could not be published"
      fm_lock_release "$remote_lock" || true
      return 0
    fi
    remote_marker=$(secondmate_nudge_marker_path "$id" 2>/dev/null || true)
    remote_pending=0
    if [ -f "$remote_marker" ] && [ "$(fm_meta_get "$remote_marker" remote)" = 1 ]; then remote_pending=1; fi
    if ! secondmate_write_nudge_marker "$id" "$_home" "" remote \
      "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record remote retry marker"
      fm_lock_release "$remote_lock" || true
      return 0
    fi
    nudge_needed=0
    converged=1
    if sync_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh sync "$id" \
      "$primary_head" < /dev/null 2>&1); then
      case "$sync_out" in synced:*) nudge_needed=1 ;; esac
    else
      sync_rc=$?
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote tracked-file sync failed on $remote_host: $(remote_sync_failure_reason "$sync_rc" "$sync_out")"
      converged=0
    fi
    if inherit_out=$(FM_CONFIG_INHERIT_LIVE=1 \
      "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$id" "$remote_generation" 2>&1); then
      if printf '%s\n' "$inherit_out" | grep -Eq '^(pushed|removed):'; then nudge_needed=1; fi
    else
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote inheritance failed on $remote_host: $(first_line "$inherit_out")"
      converged=0
    fi
    [ "$remote_pending" -eq 0 ] || nudge_needed=1
    if [ "$converged" -eq 1 ] && [ "$nudge_needed" -eq 1 ]; then
      if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-send.sh" "fm-$id" "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$remote_marker"
        [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: nudged remote fm-$id after convergence"
      else
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
      fi
    elif [ "$converged" -eq 1 ]; then
      rm -f "$remote_marker"
    fi
    fm_lock_release "$remote_lock" || true
    return 0
  }

  secondmate_sync_remote_one_timed() {  # <id> <home> <remote-host>
    local id=$1 home=$2 remote_host=$3 __fm_timing_stamp
    __fm_timing_stamp=$(fm_timing_now_ms)
    secondmate_sync_remote_one "$id" "$home" "$remote_host"
    fm_timing_record secondmate convergence "$__fm_timing_stamp" "$id@$remote_host"
  }

  # Remote routes converge through the generic transport. The primary commit is
  # authoritative for tracked files, while inherited files come from this
  # primary home; no local path probe or local fast-forward is attempted for
  # either remote surface.
  local remote_host __fm_timing_stamp parallel=0
  if bootstrap_parallel_begin; then
    parallel=1
  fi
  while IFS='|' read -r id _home _window meta; do
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -n "$remote_host" ] || continue
    if [ "$parallel" -eq 1 ]; then
      bootstrap_parallel_spawn secondmate_sync_remote_one_timed "$id" "$_home" "$remote_host"
    else
      secondmate_sync_remote_one_timed "$id" "$_home" "$remote_host"
    fi
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  [ "$parallel" -eq 0 ] || bootstrap_parallel_finish
  return 0
}

# A relaunch replaces the endpoint record a digest may already have printed. On
# the local pass that digest has not been composed yet, so the fact stays behind
# FM_BOOTSTRAP_VERBOSE_FACTS as before; on the deferred network pass the digest
# is already out, so reporting it is what keeps the superseded record from being
# acted on.
report_relaunch() {  # <id> <cause> <where>
  [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] || ! local_phase || return 0
  echo "BOOTSTRAP_INFO: secondmate $1 relaunched after $2 ($3)"
}

secondmate_liveness_sweep() {
  # Idempotent secondmate liveness guarantee - SESSION START ONLY. The detailed
  # state machine and its only recovery-authorizing states are owned by
  # fm_backend_agent_state. A missing tmux pane is not enough: tmux must prove
  # the window or session absent. This preserves duplicate prevention for
  # existing ambiguous processes and every transiently unreadable target while
  # adding the missing-session path the original bare-shell and Herdr-husk sweep
  # lacked.
  # A meta with no window remains owned by secondmate-provisioning recovery.
  # Secondmate homes never contain kind=secondmate meta, so this is naturally a
  # primary-only no-op there. Mid-session liveness remains explicitly out of
  # scope and requires a separate periodic signal.
  [ -d "$STATE" ] || return 0
  local meta id remote_host label __fm_timing_stamp parallel=0
  SECONDMATE_RESPAWNED_IDS=""
  if bootstrap_parallel_begin; then
    parallel=1
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    # Identity for the timing record is read here, in the loop, so the per-meta
    # body below keeps its single-exit-per-outcome shape.
    id=$(basename "$meta" .meta)
    remote_host=$(fm_meta_get "$meta" remote_host)
    label=$id
    [ -z "$remote_host" ] || label="$id@$remote_host"
    if [ "$parallel" -eq 1 ]; then
      bootstrap_parallel_spawn secondmate_liveness_one_timed "$meta" "$id" "$label"
    else
      secondmate_liveness_one_timed "$meta" "$id" "$label"
    fi
  done
  [ "$parallel" -eq 0 ] || bootstrap_parallel_finish
  return 0
}

secondmate_liveness_one_timed() {  # <meta> <id> <label>
  local meta=$1 id=$2 label=$3 __fm_timing_stamp
  __fm_timing_stamp=$(fm_timing_now_ms)
  secondmate_liveness_one "$meta" "$id"
  fm_timing_record secondmate liveness "$__fm_timing_stamp" "$label"
}

# One secondmate's liveness check. Split out of the sweep so each is individually
# timed; every `return` here was a `continue` in the loop and means exactly the
# same thing - move on to the next secondmate. Respawned ids are recorded through
# secondmate_note_respawned so a concurrent sweep can collect them after wait.
secondmate_liveness_one() {  # <meta> <id>
  local meta=$1 id=$2
  local window harness backend target agent_state out cause remote_host remote_rc readiness_reason route_out remote_backend
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 0
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    remote_rc=0
    fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || remote_rc=$?
    if [ "$remote_rc" -eq 255 ]; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      readiness_reason=$(printf '%s\n' "$FM_REMOTE_READINESS_OUT" \
        | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
      [ -n "$readiness_reason" ] || readiness_reason=$(first_line "$FM_REMOTE_READINESS_OUT")
      [ -n "$readiness_reason" ] || readiness_reason="unknown readiness failure"
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote readiness failed on $remote_host: $readiness_reason"
      return 0
    fi
    if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 255 ]; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint probe unreadable on $remote_host"
      return 0
    fi
    agent_state=$(printf '%s\n' "$out" | tail -1)
    case "$agent_state" in
      alive)
        if route_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh route "$id" < /dev/null 2>/dev/null); then
          remote_rc=0
        else
          remote_rc=$?
        fi
        if [ "$remote_rc" -eq 255 ]; then
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint route unknown; route preserved on $remote_host"
          return 0
        fi
        if [ "$remote_rc" -ne 0 ]; then
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
          return 0
        fi
        remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
        if [ "$remote_backend" != herdr ]; then
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
          return 0
        fi
        [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: remote secondmate $id already live (host=$remote_host)"
        ;;
      dead|missing)
        cause="remote endpoint $agent_state on its configured host"
        if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1); then
          secondmate_note_respawned "$id"
          report_relaunch "$id" "$cause" "host=$remote_host"
        else
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed after $cause: $(first_line "$out")"
        fi
        ;;
      ambiguous|unreadable|unverified)
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint state is $agent_state on $remote_host"
        ;;
      *) echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint returned an invalid state" ;;
    esac
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="$window"
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi) ;;
    *)
      case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
      ;;
  esac
  case "$agent_state" in
    alive)
      if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
        echo "BOOTSTRAP_INFO: secondmate $id already live (backend=$backend)"
      fi
      ;;
    dead|missing)
      if [ "$agent_state" = dead ]; then
        cause="confirmed agent absence on existing endpoint"
        fm_backend_kill "$backend" "$target" 2>/dev/null || true
      else
        cause="recorded endpoint confidently missing"
      fi
      if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1); then
        secondmate_note_respawned "$id"
        report_relaunch "$id" "$cause" "backend=$backend"
      else
        echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed after $cause: $(first_line "$out")"
      fi
      ;;
    ambiguous)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: existing endpoint has ambiguous agent process (backend=$backend)"
      ;;
    unreadable)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: endpoint probe unreadable (backend=$backend)"
      ;;
    unverified-harness)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: recorded harness '$harness' is unverified for recovery (backend=$backend)"
      ;;
    *)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: agent recovery classifier unverified (backend=$backend)"
      ;;
  esac
  return 0
}

secondmate_handoff_resume() {
  [ -d "$DATA/handoff" ] || return 0
  "$SCRIPT_DIR/fm-backlog-handoff.sh" --resume-pending >/dev/null 2>&1 || true
}

secondmate_handoff_detect() {
  local outbox id count
  [ -d "$DATA/handoff" ] || return 0
  for outbox in "$DATA/handoff"/*.outbox.md; do
    [ -e "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$id" in ''|*[!A-Za-z0-9._-]*) id=unknown ;; esac
    if [ ! -f "$outbox" ] || [ -L "$outbox" ]; then
      echo "SECONDMATE_HANDOFF: secondmate $id: pending delivery: unsafe outbox"
      continue
    fi
    count=$(awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$outbox" 2>/dev/null || printf unknown)
    echo "SECONDMATE_HANDOFF: secondmate $id: pending delivery: $count item(s)"
  done
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    cursor-agent) echo "https://cursor.com/cli" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN=1.46.0
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, captain-bumped periodically to keep the whole fleet on the
# newest axi tools. It is NOT the minimum feature-introduced version. These floors
# are expected to drift upward as new versions ship. Never lower a floor to the
# earliest release that happens to satisfy some depended-on behavior. The
# tasks-axi feature probes are an independent defense-in-depth concern, not part
# of its floor.
GH_AXI_MIN=0.1.29
LAVISH_AXI_MIN=0.1.46

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_at_least() {  # <tool> <min-version>
  local tool=$1 min=$2 output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/fm-x-poll.sh directly
#   config/x-mode.env      - exports FM_CHECK_INTERVAL=30, sourced by the watcher
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the watcher itself;
# applying a cadence transition to a running watcher is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing shim_home
  env_file="$FM_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing watcher supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  case "$FM_HOME" in
    /*) shim_home=$FM_HOME ;;
    *)
      shim_home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
        || { fmx_arm_failed; return 0; }
      ;;
  esac
  shim_body=$(fmx_poll_shim_content "$shim_home" "$FM_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$shim_home" "$FM_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","muse"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        elif (configured_profiles | map(.harness) | index("cursor")) then
          "cursor is ineligible here: these rules resolve the harness for crewmate and scout spawns, both of which are unattended, and cursor is refused for every unattended kind. A rule naming cursor can never be satisfied, so it would validate clean here and fail at spawn time. Name a harness verified for unattended work, such as codex or claude."
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

# Same-home record reconciliation. Every ordinary dispatch and completion now
# moves the backlog row inside the script that moves the task's record
# (bin/fm-backlog-transition-lib.sh), so remaining recovery cases include a
# process killed mid-transition and drift this home was already carrying. Heal
# this home's OWN books on its own
# restart rather than waiting for a parent's cross-home nudge; the fleet
# snapshot's classifier and bin/fm-secondmate-reconcile.sh's nudge stay as
# backstops for what this cannot see. Never reads or writes another home.
backlog_record_reconcile() {
  local marker meta control_lock meta_lock id row label has_record=0 gate_status
  # A fresh home with no state directory has no physical task records to pair.
  # Keep bootstrap diagnostics working without creating state just for a no-op.
  [ -e "$STATE" ] || [ -L "$STATE" ] || return 0
  if ! fm_backlog_directory_present "$STATE" "state directory"; then
    echo "error: backlog reconciliation refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  fi
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
    :
  else
    gate_status=$?
    if [ "$gate_status" -eq 2 ]; then
      echo "error: backlog reconciliation cannot access configured data directory $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 2
    fi
    return 0
  fi
  # Keep the wake/lock library's source-time state-directory creation inside
  # this mutating sweep, so FM_BOOTSTRAP_DETECT_ONLY remains read-only.
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"

  # Finish any close an interrupted cleanup recorded but never landed.
  for marker in "$STATE"/*.backlog-close; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    if ! fm_backlog_record_present "$marker" "pending-close record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe pending close refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    label=$(basename "$marker" .backlog-close)
    control_lock="$STATE/.control-$label.lock"
    meta_lock=$(fm_meta_lock_path "$STATE/$label.meta") || continue
    fm_lock_try_acquire "$control_lock" || continue
    if ! fm_lock_try_acquire "$meta_lock"; then
      fm_lock_release "$control_lock"
      continue
    fi
    if fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA"; then
      case "$FM_BACKLOG_CLOSE_REPLAY_RESULT" in
        closed)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label that an interrupted cleanup left open"
          ;;
        closed_incomplete)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        retained)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after an interrupted cleanup"
          ;;
        retained_incomplete)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        answered)
          echo "BOOTSTRAP_INFO: finished the interrupted cleanup for $label; the captain had already answered its call"
          ;;
      esac
    else
      echo "BACKLOG_RECONCILE: $label: recorded backlog close could not be replayed: $FM_BACKLOG_TRANSITION_ERROR"
    fi
    fm_lock_release "$meta_lock"
    fm_lock_release "$control_lock"
  done

  # A home that owns no records has nothing to pair, so it never pays for a
  # backlog read. A pending close remains authoritative even when replay failed:
  # the record sweep below must not start that item while its marker survives.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    has_record=1
    break
  done
  [ "$has_record" = 1 ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    id=$(basename "$meta" .meta)
    meta_lock=$(fm_meta_lock_path "$meta") || continue
    fm_lock_try_acquire "$meta_lock" || continue
    if [ -e "$STATE/$id.backlog-close" ] || [ -L "$STATE/$id.backlog-close" ]; then
      fm_lock_release "$meta_lock"
      continue
    fi
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: $id: post-lock worker record check refused: $FM_BACKLOG_TRANSITION_ERROR"
      fm_lock_release "$meta_lock"
      return 2
    fi
    if [ "$(fm_meta_get "$meta" kind)" != secondmate ] \
       && [ "$(fm_meta_get "$meta" cleanup_recovery)" != orca ]; then
      row=
      if fm_backlog_row_probe "$DATA" "$id"; then
        row=$FM_BACKLOG_ROW_STATE
      elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
        echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be read: $FM_BACKLOG_ROW_ERROR"
      fi
      # Heal only the unambiguous case: a queued row for a record this home
      # already owns. A held row is the captain's to move, and a closed row is a
      # contradiction this sweep must not resolve by resurrecting the item.
      if [ "$row" = "queued no no" ]; then
        if fm_backlog_start "$DATA" "$id"; then
          echo "BOOTSTRAP_INFO: marked $id in flight to match the worker this home already owns"
        else
          echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be moved to In flight: $FM_BACKLOG_TRANSITION_ERROR"
        fi
      fi
    fi
    fm_lock_release "$meta_lock"
  done
}

startup_memory_budget_setup() {
  # Primary bootstrap owns default publication. A secondmate is deliberately
  # passive here because its setting must converge from the primary through the
  # inherited-local-material contract rather than becoming a local authority.
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    return 0
  fi
  if ! fm_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. Detect-only
# sessions never touch state, and the deferred network pass never repeats it:
# the local pass that ran first already closed that window.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ] && local_phase; then
  BOOTSTRAP_BACKLOG_GATE_KIND=secondmate
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    if ! fm_backlog_directory_present "$STATE" "state directory"; then
      echo "error: bootstrap cannot reconcile task state ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    for BOOTSTRAP_BACKLOG_MARKER in "$STATE"/*.backlog-close; do
      [ -e "$BOOTSTRAP_BACKLOG_MARKER" ] || [ -L "$BOOTSTRAP_BACKLOG_MARKER" ] || continue
      if ! fm_backlog_record_present "$BOOTSTRAP_BACKLOG_MARKER" "pending-close record" "$STATE"; then
        echo "error: bootstrap refused unsafe pending close ($FM_BACKLOG_TRANSITION_ERROR)" >&2
        exit 1
      fi
      BOOTSTRAP_BACKLOG_GATE_KIND=ship
      break
    done
    if [ "$BOOTSTRAP_BACKLOG_GATE_KIND" = secondmate ]; then
      for BOOTSTRAP_BACKLOG_META in "$STATE"/*.meta; do
        [ -e "$BOOTSTRAP_BACKLOG_META" ] || [ -L "$BOOTSTRAP_BACKLOG_META" ] || continue
        if ! fm_backlog_record_present "$BOOTSTRAP_BACKLOG_META" "task record" "$STATE"; then
          echo "error: bootstrap refused unsafe worker record ($FM_BACKLOG_TRANSITION_ERROR)" >&2
          exit 1
        fi
        if [ "$(fm_meta_get "$BOOTSTRAP_BACKLOG_META" kind)" != secondmate ] \
           && [ "$(fm_meta_get "$BOOTSTRAP_BACKLOG_META" cleanup_recovery)" != orca ]; then
          BOOTSTRAP_BACKLOG_GATE_KIND=ship
          break
        fi
      done
    fi
  fi
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
    :
  else
    BOOTSTRAP_BACKLOG_GATE_STATUS=$?
    if [ "$BOOTSTRAP_BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: bootstrap cannot access configured backlog data directory $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
  fi
  startup_memory_budget_setup
  if backlog_record_reconcile; then
    :
  else
    BOOTSTRAP_BACKLOG_RECONCILE_STATUS=$?
    if [ "$BOOTSTRAP_BACKLOG_RECONCILE_STATUS" -eq 2 ]; then
      exit 1
    fi
  fi
fi

# Local detection: presence, version floors, and configuration. Nothing here
# leaves this machine, so it stays on the session-start critical path.
detect_local_tools() {
  if [ "$BACKEND_VALID" -eq 0 ]; then
    echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
  fi
  for t in $BACKEND_TOOLS; do
    fm_backend_required_tool_available "$BACKEND" "$t" \
      || missing_tool_diagnostic "$t"
  done
  for t in $COMMON_TOOLS; do
    command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
  done
  # The treehouse lease-support upgrade check is only relevant when the resolved
  # backend actually requires treehouse (every backend except orca, which owns its
  # own worktrees); an orca home must not be told to upgrade a provider it never uses.
  if fm_backend_list_contains "$TOOLS" treehouse \
    && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
    echo "MISSING: treehouse (install: $(install_cmd treehouse))"
  fi
  if command -v no-mistakes >/dev/null 2>&1 && ! tool_version_at_least no-mistakes "$NO_MISTAKES_MIN"; then
    echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
  fi
  if command -v gh-axi >/dev/null 2>&1 && ! tool_version_at_least gh-axi "$GH_AXI_MIN"; then
    echo "MISSING: gh-axi (install: $(install_cmd gh-axi))"
  fi
  if command -v lavish-axi >/dev/null 2>&1 && ! tool_version_at_least lavish-axi "$LAVISH_AXI_MIN"; then
    echo "MISSING: lavish-axi (install: $(install_cmd lavish-axi))"
  fi
  if command -v quota-axi >/dev/null 2>&1 && ! fm_quota_axi_compatible; then
    echo "MISSING: quota-axi (install: $(install_cmd quota-axi))"
  fi
  if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
    echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
  fi
}

detect_local_config() {
  # Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
  # default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
  # primary only; detached-HEAD worktrees and secondmate homes never trip it.
  tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
    if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && [ "${FM_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
    else
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
    fi
  fi
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
    echo "BOOTSTRAP_INFO: crew harness override active: $crew"
  fi
  # A configured cursor crew harness needs a cursor executable present, and
  # cursor ships under EITHER installed name. Resolution runs through the
  # verified owner rather than a bare `command -v`, so a home that merely has
  # some unrelated executable named `agent` on PATH is still reported missing
  # instead of failing at the first spawn.
  if [ "$crew" = cursor ] && ! fm_cursor_resolve_binary >/dev/null 2>&1; then
    echo "MISSING_MANUAL: cursor-agent (instructions: $(manual_install_url cursor-agent))"
  fi
  crew_dispatch_validate
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
    && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
    echo "BOOTSTRAP_INFO: tasks-axi available"
  fi
  detect_home_summary_publication
}

# This home's ledger publication is deliberately best-effort: every lifecycle
# trigger calls it with --best-effort so a failure can never change the result
# of a session start, a spawn, a teardown, or a watcher poll. That is correct,
# and it also means a home that never manages to publish says nothing at all -
# the failures land only in the bounded home-local record nobody reads.
#
# So read that same record here, where a session start already looks, and say so
# once when the evidence is a pattern rather than a blip: the ledger has not
# been (re)published, and at least FM_HOME_SUMMARY_FAILURE_REPORT attempts have
# failed since whenever it last was. No new record, no new state, no retry
# policy - just the existing evidence, surfaced.
detect_home_summary_publication() {
  local log="$STATE/.home-summary-refresh.log" ledger="$STATE/home-summary.json"
  local since='' counted failures last threshold
  threshold=${FM_HOME_SUMMARY_FAILURE_REPORT:-2}
  case "$threshold" in ''|*[!0-9]*|0) threshold=2 ;; esac
  [ -f "$log" ] && [ -r "$log" ] && [ ! -L "$log" ] || return 0
  if [ -f "$ledger" ] && [ -r "$ledger" ] && [ ! -L "$ledger" ]; then
    since=$(LC_ALL=C sed -n 's/.*"generated"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$ledger" 2>/dev/null | head -1)
  fi
  # Publication and failure stamps have whole-second precision, so failures in
  # the publication's own second remain quiet until a later failure advances
  # the record. That bounded delay avoids a precision dependency in bootstrap.
  counted=$(LC_ALL=C awk -v since="$since" '
    match($0, /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\]/) {
      stamp = substr($0, 2, RLENGTH - 2)
      if (since == "" || stamp > since) {
        n += 1
        last = substr($0, RLENGTH + 2)
      } else if (stamp == since) {
        same_second += 1
      }
    }
    END {
      if (since != "" && n > 0) n += same_second
      printf "%d\t%s", n + 0, last
    }' "$log" 2>/dev/null) || return 0
  failures=${counted%%$'\t'*}
  last=${counted#*$'\t'}
  case "$failures" in ''|*[!0-9]*) return 0 ;; esac
  [ "$failures" -ge "$threshold" ] || return 0
  last=$(printf '%s' "$last" | cut -c1-200)
  if [ -z "$since" ]; then
    echo "HOME_SUMMARY: this home has never published state/home-summary.json; $failures failed attempt(s) recorded in state/.home-summary-refresh.log, last: $last"
  else
    echo "HOME_SUMMARY: state/home-summary.json has not been republished since $since; $failures failed attempt(s) recorded in state/.home-summary-refresh.log, last: $last"
  fi
}

# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle. `gh auth status` sits between the two local blocks because that is
# where it has always been.
# Each network owner below is bracketed by an elapsed-time record, so a deferred
# stage that ran long can be attributed to the phase that spent the time.
# fm-timing-lib.sh discards the record unless the caller asked for timings, and
# every sweep is still called directly. Per-secondmate remote probes run
# concurrently; clone refresh overlaps them. Diagnostic lines are replayed in
# original order so attribution is unchanged.
# The stamp variable is named for the library rather than `start` on purpose:
# fleet_sync and others assign plain names like `start` without `local`, and
# bash's dynamic scoping would let them overwrite a stamp held by a caller.
local_phase && detect_local_tools
if network_phase; then
  __fm_timing_stamp=$(fm_timing_now_ms)
  gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
  fm_timing_record phase gh-auth "$__fm_timing_stamp"
fi
local_phase && detect_local_config

if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # secondmate_sync consumes SECONDMATE_RESPAWNED_IDS from the liveness sweep, so
  # those two always run together in the same phase. Clone refresh does not
  # depend on them, so it starts in the background and overlaps their wall clock.
  fleet_sync_pid=
  fleet_sync_out=
  if network_phase && network_sweep_authorized 'project clone refresh'; then
    fleet_sync_out=$(mktemp "${TMPDIR:-/tmp}/fm-bootstrap-fleet.XXXXXX") || fleet_sync_out=
    if [ -n "$fleet_sync_out" ]; then
      (
        __fm_timing_stamp=$(fm_timing_now_ms)
        fleet_sync
        fm_timing_record phase fleet-sync "$__fm_timing_stamp"
      ) >"$fleet_sync_out" 2>&1 &
      fleet_sync_pid=$!
    else
      __fm_timing_stamp=$(fm_timing_now_ms)
      fleet_sync
      fm_timing_record phase fleet-sync "$__fm_timing_stamp"
    fi
  fi
  if network_phase; then
    if network_sweep_authorized 'dead-secondmate relaunch'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      secondmate_liveness_sweep
      fm_timing_record phase secondmate-liveness "$__fm_timing_stamp"
    fi
    if network_sweep_authorized 'secondmate convergence'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      secondmate_sync
      fm_timing_record phase secondmate-sync "$__fm_timing_stamp"
    fi
    if network_sweep_authorized 'pending handoff delivery'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      secondmate_handoff_resume
      fm_timing_record phase handoff-delivery "$__fm_timing_stamp"
    fi
  fi
  # x_mode_setup writes local Relay artifacts only and never leaves the machine.
  local_phase && x_mode_setup
  if [ -n "$fleet_sync_pid" ]; then
    wait "$fleet_sync_pid" || true
    cat "$fleet_sync_out"
    rm -f "$fleet_sync_out"
  fi
fi
local_phase && secondmate_handoff_detect
exit 0
