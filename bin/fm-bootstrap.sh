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
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "MAIN_DIVERGED: <remediation>",
#                 "SELF_UPDATE: <ff_target detail>; re-read AGENTS.md now",
#                 "SELF_UPDATE_BLOCKED: <ff_target detail>; <consequence>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged fm-<id> with '<message>'",
#                 "SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#                 "SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)",
#                 "MISSION_CONTROL_STALE: board last rendered <timestamp> (age <seconds>s, threshold <seconds>s); refresh its local generator",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          When a RUNNING local secondmate worktree is fast-forwarded to
#          firstmate's own current default-branch commit, that update is a
#          purely local fast-forward and never an origin fetch. Remote routes
#          instead converge the persistent home to their configured remote code
#          root. If either placement changes its loaded instruction surface
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
#          A MAIN_DIVERGED line means the firstmate primary checkout's local default
#          branch carries commits origin/<default> does not - typically a shared fix
#          landed directly on it instead of through the normal PR path - so the
#          fast-forward-only self-update path (/updatefirstmate) can no longer
#          reconcile it and declines to advance it, which is reported only to
#          whoever runs that update; reconcile manually per the line. Like TANGLE
#          it is scoped to the primary checkout by branch state, so detached-HEAD
#          worktrees and secondmate homes never trip it even though they read the
#          same shared refs, and a tangled primary defers to TANGLE.
#          The check function itself never fetches (it reads the already-known
#          origin/<default> ref) and stays silent for a missing origin, a missing
#          origin/<default> ref, or a local default branch that is merely behind
#          origin, so a local-only or offline install never false-alarms. The
#          non-detect-only line's remediation does instruct a `git fetch origin`
#          refresh, so - like TANGLE's own repair command - a detect-only,
#          lock-refused session gets advisory-only wording with no such command
#          instead, leaving refresh and reconciliation to the session holding the
#          fleet lock.
#          The primary checkout itself is fast-forwarded here the same way
#          /updatefirstmate does (bin/fm-update.sh's same ff_target call), so a
#          firstmate PR merged on origin reaches this home - and anything it
#          locally serves, such as a Mission Control board - without waiting for
#          the captain to run that update by hand. It runs first among the
#          mutating sweeps below so a live secondmate's own local-HEAD
#          fast-forward (secondmate_sync) already sees the newly-advanced primary
#          commit in the same pass; secondmate homes are never touched here
#          directly - the same .fm-secondmate-home marker check
#          startup_memory_budget_setup already uses keeps a secondmate home,
#          including a standalone clone that is not detached and does have an
#          origin remote, out of this step entirely. A clean, fast-forwardable
#          primary checkout advances
#          silently unless its instruction surface (AGENTS.md, bin/, or
#          .agents/skills/) changed, in which case a SELF_UPDATE line asks the
#          running agent to re-read AGENTS.md. A dirty or diverged checkout is
#          left untouched - never forced, stashed, or reset - and reports
#          SELF_UPDATE_BLOCKED so the captain is not left guessing why a merged
#          PR never showed up locally. This mutating step never runs in
#          detect-only mode, since it fetches. This cadence trigger runs on
#          every session start, so a merge landing between sessions is always
#          caught; bin/fm-pr-merge.sh separately calls the identical
#          primary_self_update() once, immediately, right after it confirms a
#          merge is this repo's own, so a merge landing mid-session (with
#          nothing prompting a fresh session start) is not left stale until
#          the next one - see bin/fm-ff-lib.sh's primary_self_update header
#          for the full mechanism shared by both trigger points.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
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
#          A regular non-symlinked config/mission-control-board file optionally
#          enables a read-only stale-board check. Its one line is either an
#          absolute regular-file path or an http://127.0.0.1 URL (with an
#          optional port). File reads and loopback GETs are capped at 8 MiB, and
#          GETs have a two-second bound with proxies disabled. The board must
#          contain its rendered ISO-8601 UTC footer timestamp. Missing,
#          unreadable, malformed, future, or otherwise unprovable targets stay
#          silent. FM_MISSION_CONTROL_STALE_SECS overrides the 300-second
#          threshold only with a positive decimal integer.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the six MUTATING sweeps
#          (PR-check migration, secondmate_sync, secondmate_liveness_sweep,
#          secondmate_handoff_resume, x_mode_setup, fleet_sync) while still
#          printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          PR-check artifacts, secondmate homes, pending handoff outboxes,
#          X-mode artifacts, project clones, or repair instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
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
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-main-divergence-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-main-divergence-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
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

# primary_self_update() itself now lives in bin/fm-ff-lib.sh (already sourced
# above), since bin/fm-pr-merge.sh calls the exact same function right after
# a firstmate-repo merge; see its header comment there for the full
# mechanism and both trigger points.

secondmate_sync() {
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # Placement-specific secondmate sync: local homes fast-forward to the primary
  # checkout's current default-branch commit. That path is purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (fm-ff-lib.sh), while a standalone clone without it is skipped until
  # /updatefirstmate refreshes it from origin. Startup sends reread nudges only
  # for RUNNING secondmates whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a secondmate already on the primary's
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

  # Remote routes converge through the generic transport. Their code root and
  # inherited files are authoritative on that host; no local path probe or
  # local fast-forward is attempted for them.
  local remote_host sync_out inherit_out nudge_needed remote_marker remote_pending converged out remote_lock remote_generation
  while IFS='|' read -r id _home _window meta; do
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -n "$remote_host" ] || continue
    remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_lock" ] || ! fm_lock_acquire_wait "$remote_lock"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot lock remote inheritance transaction"
      continue
    fi
    if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$id" >/dev/null 2>&1; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote reply source could not be registered"
    fi
    remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_generation" ]; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote inheritance generation could not be published"
      fm_lock_release "$remote_lock" || true
      continue
    fi
    remote_marker=$(secondmate_nudge_marker_path "$id" 2>/dev/null || true)
    remote_pending=0
    if [ -f "$remote_marker" ] && [ "$(fm_meta_get "$remote_marker" remote)" = 1 ]; then remote_pending=1; fi
    if ! secondmate_write_nudge_marker "$id" "$_home" "" remote \
      "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record remote retry marker"
      fm_lock_release "$remote_lock" || true
      continue
    fi
    nudge_needed=0
    converged=1
    if sync_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh sync "$id" < /dev/null 2>&1); then
      case "$sync_out" in synced:*) nudge_needed=1 ;; esac
    else
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote tracked-file sync failed on $remote_host: $(first_line "$sync_out")"
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
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  return 0
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
  local meta id window harness backend target agent_state out cause remote_host remote_rc readiness_reason route_out remote_backend remote_control_arg
  SECONDMATE_RESPAWNED_IDS=""
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    harness=$(fm_meta_get "$meta" harness)
    remote_host=$(fm_meta_get "$meta" remote_host)
    # Carry a Remote-Control-enabled secondmate's setting across an automatic
    # recovery respawn: fm-spawn.sh itself never replays remote_control= from a
    # prior meta (a plain respawn re-resolves harness/model/effort from config
    # or explicit flags only), so this is the one caller that reads it back.
    remote_control_arg=""
    [ "$(fm_meta_get "$meta" remote_control)" != 1 ] || remote_control_arg="--remote-control"
    if [ -n "$remote_host" ]; then
      remote_rc=0
      fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || remote_rc=$?
      if [ "$remote_rc" -eq 255 ]; then
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
        continue
      fi
      if [ "$remote_rc" -ne 0 ]; then
        readiness_reason=$(printf '%s\n' "$FM_REMOTE_READINESS_OUT" \
          | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
        [ -n "$readiness_reason" ] || readiness_reason=$(first_line "$FM_REMOTE_READINESS_OUT")
        [ -n "$readiness_reason" ] || readiness_reason="unknown readiness failure"
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote readiness failed on $remote_host: $readiness_reason"
        continue
      fi
      if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
        remote_rc=0
      else
        remote_rc=$?
      fi
      if [ "$remote_rc" -eq 255 ]; then
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
        continue
      fi
      if [ "$remote_rc" -ne 0 ]; then
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint probe unreadable on $remote_host"
        continue
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
            continue
          fi
          if [ "$remote_rc" -ne 0 ]; then
            echo "SECONDMATE_LIVENESS: secondmate $id: skipped: alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
            continue
          fi
          remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
          if [ "$remote_backend" != herdr ]; then
            echo "SECONDMATE_LIVENESS: secondmate $id: skipped: alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
            continue
          fi
          [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: remote secondmate $id already live (host=$remote_host)"
          ;;
        dead|missing)
          cause="remote endpoint $agent_state on its configured host"
          if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate ${remote_control_arg:+"$remote_control_arg"} 2>&1); then
            SECONDMATE_RESPAWNED_IDS="$SECONDMATE_RESPAWNED_IDS $id"
          else
            echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed after $cause: $(first_line "$out")"
          fi
          ;;
        ambiguous|unreadable|unverified)
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint state is $agent_state on $remote_host"
          ;;
        *) echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint returned an invalid state" ;;
      esac
      continue
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
        if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate ${remote_control_arg:+"$remote_control_arg"} 2>&1); then
          SECONDMATE_RESPAWNED_IDS="$SECONDMATE_RESPAWNED_IDS $id"
          if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
            echo "BOOTSTRAP_INFO: secondmate $id relaunched after $cause (backend=$backend)"
          fi
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
  done
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
NO_MISTAKES_MIN=1.31.2
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, captain-bumped periodically to keep the whole fleet on the
# newest axi tools. It is NOT the minimum feature-introduced version. These floors
# are expected to drift upward as new versions ship. Never lower a floor to the
# earliest release that happens to satisfy some depended-on behavior. The
# tasks-axi feature probes are an independent defense-in-depth concern, not part
# of its floor.
GH_AXI_MIN=0.1.29
LAVISH_AXI_MIN=0.1.45

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
  err=$("$SCRIPT_DIR/fm-crew-dispatch.sh" validate "$file" 2>&1) || {
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  }
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end)
      + (if ($p.provider? != null) then "@" + ($p.provider | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]?
         | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)
           + (if has("fallback") then " | outage fallback " + profile_set(.fallback; null) else "" end)
           + (if (.independent? == true) then " | independent review required" else "" end)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end)
      + (if has("default_fallback") then ["BOOTSTRAP_INFO: crew dispatch default outage fallback: " + profile_set(.default_fallback; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

mission_control_rendered_stamp() {
  LC_ALL=C perl -e '
    my $limit = 8388608;
    my $total = 0;
    my $tail = "";
    my $stamp;
    while (1) {
      my $want = $limit + 1 - $total;
      $want = 65536 if $want > 65536;
      my $read = read STDIN, my $chunk, $want;
      exit 1 if !defined $read;
      last if $read == 0;
      $total += $read;
      exit 1 if $total > $limit || index($chunk, "\0") >= 0;
      my $scan = $tail . $chunk;
      $stamp = $1 if !defined $stamp && $scan =~ /rendered ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)/;
      $tail = length($scan) > 64 ? substr($scan, -64) : $scan;
    }
    print $stamp if defined $stamp;
  ' 2>/dev/null
}

mission_control_board_staleness_check() {
  local config_file target line_count size stamp timestamp_epoch now threshold age
  config_file="$CONFIG/mission-control-board"
  [ -f "$config_file" ] && [ ! -L "$config_file" ] || return 0
  line_count=$(wc -l < "$config_file" 2>/dev/null) || return 0
  line_count=${line_count//[[:space:]]/}
  [ "$line_count" = 1 ] || return 0
  IFS= read -r target < "$config_file" || return 0
  [ -n "$target" ] || return 0
  command -v perl >/dev/null 2>&1 || return 0

  case "$target" in
    /*)
      [ -f "$target" ] && [ ! -L "$target" ] || return 0
      size=$(wc -c < "$target" 2>/dev/null) || return 0
      size=${size//[[:space:]]/}
      case "$size" in ''|*[!0-9]*) return 0 ;; esac
      [ "$size" -le 8388608 ] || return 0
      stamp=$(mission_control_rendered_stamp < "$target") || return 0
      ;;
    http://*)
      [[ "$target" =~ ^http://127[.]0[.]0[.]1(:[0-9]+)?([/?#][^[:space:]]*)?$ ]] || return 0
      command -v curl >/dev/null 2>&1 || return 0
      stamp=$(
        set -o pipefail
        curl --disable --fail --silent --noproxy '*' --proto '=http' --proto-redir '=http' --max-filesize 8388608 --max-time 2 "$target" 2>/dev/null |
          mission_control_rendered_stamp
      ) || return 0
      ;;
    *) return 0 ;;
  esac

  [ -n "$stamp" ] || return 0
  timestamp_epoch=$(TZ=UTC perl -MTime::Piece -e 'my $s = $ARGV[0]; my $t = eval { Time::Piece->strptime($s, "%Y-%m-%dT%H:%M:%SZ") }; exit 1 if $@ || !defined $t || $t->strftime("%Y-%m-%dT%H:%M:%SZ") ne $s; print $t->epoch' "$stamp" 2>/dev/null) || return 0
  case "$timestamp_epoch" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s 2>/dev/null) || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  threshold=${FM_MISSION_CONTROL_STALE_SECS:-300}
  threshold=$(perl -MConfig -e '
    my $value = $ARGV[0];
    exit 1 if $value !~ /\A[0-9]+\z/;
    $value =~ s/\A0+//;
    exit 1 if $value eq "";
    my $maximum = $Config{ivsize} >= 8 ? "9223372036854775807" : "2147483647";
    exit 1 if length($value) > length($maximum);
    exit 1 if length($value) == length($maximum) && $value gt $maximum;
    print $value;
  ' "$threshold" 2>/dev/null) || threshold=300
  [ "$now" -ge "$timestamp_epoch" ] || return 0
  age=$((now - timestamp_epoch))
  [ "$age" -gt "$threshold" ] || return 0
  echo "MISSION_CONTROL_STALE: board last rendered $stamp (age ${age}s, threshold ${threshold}s); refresh its local generator"
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

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched watcher, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  "$SCRIPT_DIR/fm-pr-check-migrate.sh" || true
  startup_memory_budget_setup
fi

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
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
# default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and secondmate homes never trip it.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
  else
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
  fi
fi
# Origin-divergence check: the firstmate primary checkout's local default branch
# must remain an ancestor of origin/<default> so the fast-forward-only self-update
# path (/updatefirstmate) can still reconcile it (see fm-main-divergence-lib.sh).
# Scoped to the primary checkout on its default branch by the same branch-state
# discriminator TANGLE uses, so linked worktrees and secondmate homes stay silent.
# Never mutates; the check function itself never fetches in either mode, but the
# non-detect-only remediation below does instruct a fetch, so - like TANGLE - a
# read-only detect-only session gets advisory-only wording with no such command.
diverged_default=$(fm_primary_diverged_branch "$FM_ROOT" 2>/dev/null || true)
if [ -n "$diverged_default" ]; then
  if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    echo "MAIN_DIVERGED: primary checkout's '$diverged_default' carries commits origin/$diverged_default did not have as of the last refresh; fast-forward self-update may no longer be able to reconcile it - this check never fetches, so the comparison may be stale; read-only session must leave refreshing and reconciling to the session holding the fleet lock"
  else
    echo "MAIN_DIVERGED: primary checkout's '$diverged_default' carries commits origin/$diverged_default does not; fast-forward self-update can no longer reconcile it - this check never fetches, so refresh the stale ref first with: git -C $FM_ROOT fetch origin, which alone can clear it; if it persists, inspect with: git -C $FM_ROOT log origin/$diverged_default..$diverged_default --oneline, then reconcile manually (rebase/merge onto origin/$diverged_default, or push the local commits) before rerunning /updatefirstmate"
  fi
fi
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
  echo "BOOTSTRAP_INFO: crew harness override active: $crew"
fi
crew_dispatch_validate
mission_control_board_staleness_check
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
  && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
  echo "BOOTSTRAP_INFO: tasks-axi available"
fi
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  primary_self_update
  secondmate_liveness_sweep
  secondmate_sync
  secondmate_handoff_resume
  x_mode_setup
  fleet_sync
fi
secondmate_handoff_detect
exit 0
