#!/usr/bin/env bash
# fm-liveness-guardian.sh - session-independent fleet supervision backstop.
#
# Every firstmate home keeps its own watcher (bin/fm-watch.sh) alive through a
# harness-owned continuity mechanism: Claude's Stop auto-arm, Cursor's stop park,
# Pi/OpenCode extensions, or a persistent tracked arm (docs/watcher-continuity.md).
# Each of those depends on a LIVE session in that home. When a director's session
# stops taking turns while its armed watcher dies (observed 2026-08-15: several
# homes' beacons stale for thousands of seconds while the panes stayed open), the
# harness has no Stop to re-arm on, so supervision stays down and incoming wakes
# (new Telegram-routed tasks, crew status) are never surfaced or handled until a
# human notices. This guardian is the layer BELOW every session: it runs from a
# systemd user timer with no session in the loop, and for each guarded home it
# classifies supervision and repairs a genuine lapse through the SANCTIONED paths
# only - never by faking a beacon, never with a fire-and-forget shell `&`.
#
# What it does NOT do, on purpose:
#   - It never touches state/.last-watcher-beat directly. A fresh beacon is
#     produced ONLY by launching a real watcher (docs/watcher-continuity.md's
#     invariant "no helper process can make a wedged watcher appear healthy").
#   - It never double-arms: a home whose model-aware verdict is already healthy
#     is left completely alone, and the watcher singleton lock plus fm-watch-arm's
#     own attach make a concurrent arm converge on one watcher.
#   - It never kills live crew, discards unlanded work, force-tears-down, or
#     touches the shared no-mistakes daemon. Its only repair verbs are re-arm
#     (launch a real watcher self-survivingly), relaunch a genuinely dead LOCAL
#     secondmate director through the sanctioned spawn path, and escalate.
#   - It does not put directors into unattended sub-supervisor daemon mode. That
#     is the only design that makes wakes SELF-HANDLE with zero session, and it is
#     a fleet-behavior change (the /afk daemon; AGENTS.md section 8). This guardian
#     deliberately leaves that choice to the captain (docs/liveness-guardian.md
#     "Boundary and the unattended-handling decision").
#
# Repair is HANDLING-honest, not just beacon-honest. Re-arming restores the
# beacon and captures every wake durably in state/.wake-queue (fm-watch.sh
# enqueues before advancing suppression), so nothing is lost; but a surfaced wake
# is HANDLED by the home's own live session. So the guardian relaunches a dead
# local director (restoring a handler) and escalates a home it cannot restore
# rather than masking it behind a fresh beacon.
#
# systemd-timer environment. Runs under `env -i` from the timer with a bare
# environment, so it exports XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS before
# any `systemctl --user`/`systemd-run --user` call (see
# ~/.claude/rules/shell-failure-patterns.md #9), sets FM_HOME per guarded home,
# and uses absolute paths throughout.
#
# Usage:
#   fm-liveness-guardian.sh                one repair pass over every guarded home
#   fm-liveness-guardian.sh --list         classify every home and print the plan;
#                                          repairs nothing (safe dry run)
#   fm-liveness-guardian.sh --home <path>  guard exactly one home (repair pass)
#   fm-liveness-guardian.sh --help
#
# Homes to guard: the MAIN home (FM_GUARDIAN_MAIN_HOME, else FM_HOME) plus every
# LOCAL secondmate discovered from the main home's state/*.meta records with
# kind=secondmate (their recorded home=), with data/secondmates.md as the fallback
# for a missing home=. Remote secondmates (remote_host set) are reported and
# skipped: a local timer cannot repair another host. FM_GUARDIAN_HOMES (a
# colon- or newline-separated list of absolute home paths) overrides discovery.
#
# Environment knobs (all optional):
#   FM_GUARDIAN_MAIN_HOME   main home to guard and to discover secondmates from
#                           (default: FM_HOME, else error - it cannot be guessed)
#   FM_GUARDIAN_HOMES       explicit ':'/newline home list; overrides discovery
#   FM_GUARDIAN_GRACE       beacon-staleness threshold, seconds (default: the same
#                           FM_GUARD_GRACE the fleet uses, 300)
#   FM_GUARDIAN_RELAUNCH_MIN_INTERVAL  min seconds between relaunches of one home
#                           (crash-loop backstop; default 900)
#   FM_GUARDIAN_ESCALATE_MIN_INTERVAL  min seconds between escalations of one home
#                           (default 1800)
#   FM_GUARDIAN_WEDGE_ESCALATE_SECS  how long a live session must stay
#                           continuously unsupervised before it is escalated as a
#                           possible wedge (default 1800; larger than any
#                           legitimate long turn, so a busy session is never
#                           mislabeled)
#   FM_GUARDIAN_LOG         append-only log path (default
#                           $XDG_STATE_HOME/fm-liveness-guardian.log, i.e.
#                           ~/.local/state/fm-liveness-guardian.log)
#   FM_GUARDIAN_STATE_DIR   guardian's own rate-limit/confirmation state dir
#                           (default $XDG_STATE_HOME/fm-liveness-guardian)
#   FM_GUARDIAN_MAIN_MODEL  supervision model for the main home when it cannot be
#                           read from durable state (default: autoarm - the safe
#                           choice: fresh beacon = healthy, so it never disturbs a
#                           healthy home and only ever acts on a genuinely stale
#                           beacon)
#   FM_GUARDIAN_ARM_LAUNCHER  test/override seam. A command invoked as
#                           `<launcher> <unit> <home> <arm-script>` that must
#                           launch <arm-script> (with FM_HOME=<home>) in a way
#                           that SURVIVES this process. Default: an internal
#                           `systemd-run --user` transient unit named <unit>.
#   FM_GUARDIAN_RELAUNCH_CMD  test/override seam for the dead-director relaunch.
#                           Invoked as `<cmd> <home> <task-id> <main-home>`.
#                           Default: the sanctioned `<main>/bin/fm-spawn.sh <id>
#                           --secondmate` (the same relaunch bootstrap uses).
#   FM_GUARDIAN_ESCALATE_CMD  test/override seam for escalation. Invoked as
#                           `<cmd> <home> <summary>`. Default: append a captain
#                           signal line to the main home's backlog-adjacent escalation
#                           log and the guardian log (a human path, never a merge).
#   FM_GUARDIAN_DRY_RUN     1 = classify and PRINT the planned repair commands
#                           (including the exact self-surviving systemd-run) but
#                           execute none. --list implies this.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The guardian's own predicates come from its own tracked libs; each is called
# with an explicit per-home <state>/<watch> argument, so guarding a home never
# depends on the guardian's own FM_HOME.
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# Resolve the main home BEFORE sourcing the libs (which default FM_HOME/STATE and
# mkdir the state dir at source time). Pointing the guardian's own lib state at
# the main home keeps sourcing from creating a stray state/ in the repo checkout.
GUARDIAN_MAIN="${FM_GUARDIAN_MAIN_HOME:-${FM_HOME:-}}"
export FM_HOME="${GUARDIAN_MAIN:-$FM_ROOT}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

GRACE=${FM_GUARDIAN_GRACE:-${FM_GUARD_GRACE:-300}}
case "$GRACE" in ''|*[!0-9]*) GRACE=300 ;; esac
RELAUNCH_MIN_INTERVAL=${FM_GUARDIAN_RELAUNCH_MIN_INTERVAL:-900}
case "$RELAUNCH_MIN_INTERVAL" in ''|*[!0-9]*) RELAUNCH_MIN_INTERVAL=900 ;; esac
ESCALATE_MIN_INTERVAL=${FM_GUARDIAN_ESCALATE_MIN_INTERVAL:-1800}
case "$ESCALATE_MIN_INTERVAL" in ''|*[!0-9]*) ESCALATE_MIN_INTERVAL=1800 ;; esac
# How long a live session must stay continuously unsupervised before the guardian
# calls it a wedge. Larger than any legitimate long turn (a slow build, a
# no-mistakes run), so a busy session is never mislabeled a wedge.
WEDGE_ESCALATE_SECS=${FM_GUARDIAN_WEDGE_ESCALATE_SECS:-1800}
case "$WEDGE_ESCALATE_SECS" in ''|*[!0-9]*) WEDGE_ESCALATE_SECS=1800 ;; esac
MAIN_MODEL=${FM_GUARDIAN_MAIN_MODEL:-autoarm}

XDG_STATE_HOME_DEFAULT="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG=${FM_GUARDIAN_LOG:-$XDG_STATE_HOME_DEFAULT/fm-liveness-guardian.log}
GSTATE=${FM_GUARDIAN_STATE_DIR:-$XDG_STATE_HOME_DEFAULT/fm-liveness-guardian}

DRY_RUN=0
case "${FM_GUARDIAN_DRY_RUN:-0}" in 1|true|TRUE|yes|YES) DRY_RUN=1 ;; esac

# --- systemd user-bus environment (bare env from the timer) -------------------
# Harmless when already set from an interactive shell; required from cron/timer.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

now() { date +%s; }

# One machine-scannable, human-scannable line per real event. Silent for healthy
# and idle homes: a quiet log means a healthy fleet.
log_line() {  # <level> <home> <class> <action> <detail>
  local level=$1 home=$2 class=$3 action=$4 detail=$5 ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || now)
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '%s\t%s\thome=%s\tclass=%s\taction=%s\t%s\n' \
    "$ts" "$level" "$home" "$class" "$action" "$detail" >> "$LOG" 2>/dev/null || true
}

# Stable, filesystem- and unit-name-safe key for a home path.
home_key() {  # <home>
  printf 'fm-fleet-%s' "$(printf '%s' "$1" | cksum | tr -cd '0-9')"
}

# --- rate limiting ------------------------------------------------------------
# A stamp file per (home,kind) records the last action time. rate_ok returns 0
# when at least <min> seconds have elapsed since the last stamp (or none exists).
rate_stamp_path() {  # <home> <kind>
  printf '%s/%s.%s' "$GSTATE" "$(home_key "$1")" "$2"
}

rate_ok() {  # <home> <kind> <min-seconds>
  local stamp last age
  stamp=$(rate_stamp_path "$1" "$2")
  [ -f "$stamp" ] || return 0
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( $(now) - last ))
  [ "$age" -ge "$3" ]
}

rate_touch() {  # <home> <kind>
  local stamp
  stamp=$(rate_stamp_path "$1" "$2")
  mkdir -p "$GSTATE" 2>/dev/null || true
  printf '%s\n' "$(now)" > "$stamp" 2>/dev/null || true
}

rate_clear() {  # <home> <kind>
  rm -f "$(rate_stamp_path "$1" "$2")" 2>/dev/null || true
}

# Age of a stamp in seconds, or a large sentinel when it does not exist (so a
# first observation never reads as "long ago").
stamp_age() {  # <home> <kind>
  local stamp last
  stamp=$(rate_stamp_path "$1" "$2")
  [ -f "$stamp" ] || { echo -1; return; }
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) echo -1; return ;; esac
  echo $(( $(now) - last ))
}

# --- home discovery -----------------------------------------------------------
# Enumerate absolute home paths, one per line, deduplicated in first-seen order.
# Each line is "<home>\t<role>" where role is main|secondmate|remote:<host>.
discover_homes() {
  local main data meta id home host seen
  seen=""

  if [ -n "${FM_GUARDIAN_HOMES:-}" ]; then
    printf '%s\n' "$FM_GUARDIAN_HOMES" | tr ':' '\n' | while IFS= read -r home; do
      [ -n "$home" ] || continue
      printf '%s\tmain\n' "$home"
    done
    return 0
  fi

  main=$GUARDIAN_MAIN
  if [ -z "$main" ]; then
    echo "error: no home to guard - set FM_GUARDIAN_MAIN_HOME, FM_HOME, or FM_GUARDIAN_HOMES" >&2
    return 2
  fi
  printf '%s\tmain\n' "$main"
  seen="|$main|"

  data="$main/data"
  # Live homes come from the main home's kind=secondmate meta records; the
  # registry is only a fallback for a missing home= (fm-config-push.sh contract).
  for meta in "$main"/state/*.meta; do
    [ -e "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    host=$(sed -n 's/^remote_host=//p' "$meta" 2>/dev/null | head -1)
    home=$(sed -n 's/^home=//p' "$meta" 2>/dev/null | head -1)
    if [ -z "$home" ] && [ -f "$data/secondmates.md" ]; then
      home=$(secondmate_registry_field "$data/secondmates.md" "$id" home 2>/dev/null || true)
    fi
    [ -n "$home" ] || continue
    case "$seen" in *"|$home|"*) continue ;; esac
    seen="$seen$home|"
    if [ -n "$host" ]; then
      printf '%s\tremote:%s\n' "$home" "$host"
    else
      printf '%s\tsecondmate:%s\n' "$home" "$id"
    fi
  done
}

# --- per-home supervision model ----------------------------------------------
# Resolve the supervision model for a home from durable evidence, so the
# guardian's verdict matches how that home is actually supervised even though the
# guardian itself runs under no harness.
resolve_model() {  # <home> <role>
  local home=$1 role=$2 harness lock_role meta id
  # A secondmate records its launch harness in the main home's meta.
  case "$role" in
    secondmate:*)
      id=${role#secondmate:}
      meta="$GUARDIAN_MAIN/state/$id.meta"
      harness=$(sed -n 's/^harness=//p' "$meta" 2>/dev/null | head -1)
      ;;
  esac
  if [ -z "${harness:-}" ]; then
    # The last watcher's lock role is durable evidence of the auto-arm model.
    lock_role=$(cat "$home/state/.watch.lock/role" 2>/dev/null || true)
    [ "$lock_role" = autoarm ] && { printf 'autoarm\n'; return 0; }
  fi
  case "${harness:-}" in
    claude|cursor) printf 'autoarm\n'; return 0 ;;
    pi|pi-signed) printf 'extension\n'; return 0 ;;
    '') ;;
    *) printf 'persistent\n'; return 0 ;;
  esac
  # Main home (or unresolved): the configured safe default.
  printf '%s\n' "$MAIN_MODEL"
}

# --- session liveness ---------------------------------------------------------
# A home's director session is alive when its session lock (state/.lock) names a
# live harness process. env-i friendly: only ps/kill, no backend needed.
session_alive() {  # <home>
  local lock_pid
  lock_pid=$(cat "$1/state/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_harness_pid_alive "$lock_pid"
}

# --- repair primitives --------------------------------------------------------
# Re-arm a real watcher for <home> through a SELF-SURVIVING systemd transient
# unit, never a shell `&`. Idempotent: a still-active unit means an arm is
# already running, and fm-watch-arm.sh attaches to an already-healthy watcher
# instead of starting a second one.
systemd_run_arm() {  # <unit> <home> <arm-script>
  local unit=$1 home=$2 arm=$3
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN arm: systemd-run --user --unit=%s --property=CollectMode=inactive-or-failed --setenv=FM_HOME=%s %s\n' \
      "$unit" "$home" "$arm"
    return 0
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "systemd-run unavailable" >&2
    return 1
  fi
  # Clear any lingering failed unit of this name so the transient can be reused.
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  # An already-active unit (systemd-run exits non-zero on name collision) means a
  # watcher is already armed for this home - treat as success, do not double-arm.
  if systemctl --user is-active "$unit" >/dev/null 2>&1; then
    return 0
  fi
  systemd-run --user \
    --unit="$unit" \
    --property=CollectMode=inactive-or-failed \
    --property=Restart=no \
    --setenv=FM_HOME="$home" \
    --setenv=FM_GUARD_GRACE="$GRACE" \
    "$arm" >/dev/null 2>&1
}

arm_watcher() {  # <home>
  local home=$1 arm unit
  arm="$home/bin/fm-watch-arm.sh"
  [ -x "$arm" ] || arm="$SCRIPT_DIR/fm-watch-arm.sh"
  unit=$(home_key "$home")
  # A dry run only ever PRINTS the plan, never consulting a live launcher seam.
  if [ "$DRY_RUN" -eq 0 ] && [ -n "${FM_GUARDIAN_ARM_LAUNCHER:-}" ]; then
    "$FM_GUARDIAN_ARM_LAUNCHER" "$unit" "$home" "$arm"
    return $?
  fi
  systemd_run_arm "$unit" "$home" "$arm"
}

# Relaunch a genuinely dead LOCAL secondmate director through the sanctioned
# spawn path (the same relaunch the bootstrap secondmate-liveness sweep uses),
# never by discarding its unlanded work.
relaunch_director() {  # <home> <task-id> <main-home>
  local home=$1 id=$2 main=$3 cmd
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN relaunch: %s/bin/fm-spawn.sh %s --secondmate  (FM_HOME=%s)\n' "$main" "$id" "$main"
    return 0
  fi
  if [ -n "${FM_GUARDIAN_RELAUNCH_CMD:-}" ]; then
    "$FM_GUARDIAN_RELAUNCH_CMD" "$home" "$id" "$main"
    return $?
  fi
  cmd="$main/bin/fm-spawn.sh"
  [ -x "$cmd" ] || { echo "spawn script missing: $cmd" >&2; return 1; }
  FM_HOME="$main" "$cmd" "$id" --secondmate >/dev/null 2>&1
}

# Escalate to the captain: a human path (log ERROR + optional signal command),
# never a merge or any irreversible action.
escalate() {  # <home> <summary>
  local home=$1 summary=$2
  if [ -n "${FM_GUARDIAN_ESCALATE_CMD:-}" ] && [ "$DRY_RUN" -eq 0 ]; then
    "$FM_GUARDIAN_ESCALATE_CMD" "$home" "$summary" || true
  fi
  log_line ERROR "$home" - escalate "detail=$summary"
}

# --- classification + repair --------------------------------------------------
# Returns via stdout one classification token for --list; performs repair in a
# normal pass. <home> <role>
guard_home() {
  local home=$1 role=$2 state watch model verdict_ok verdict_reason id detail

  state="$home/state"
  watch="$home/bin/fm-watch.sh"

  # A remote secondmate's state lives on another host, so this check precedes the
  # local-state-dir check: a local timer cannot repair another host.
  case "$role" in
    remote:*)
      printf 'home=%s\tclass=remote-skip\taction=none\treason=remote-host-%s\n' "$home" "${role#remote:}"
      return 0
      ;;
  esac

  if [ ! -d "$state" ]; then
    printf 'home=%s\tclass=skip\taction=none\treason=no-state-dir\n' "$home"
    return 0
  fi

  # Does this home need a watcher at all? (in-flight meta / x-watch / event source)
  if ! fm_supervision_needed "$state" "$GRACE"; then
    [ "$DRY_RUN" -eq 1 ] || rate_clear "$home" lapse-since
    printf 'home=%s\tclass=idle\taction=none\treason=no-supervision-needed\n' "$home"
    return 0
  fi

  # Model-aware "is supervision healthy right now" verdict, using the home's own
  # model so a between-turns auto-arm home reads healthy while a genuinely stale
  # beacon reads as a lapse.
  model=$(resolve_model "$home" "$role")
  FM_SUPERVISION_MODEL="$model" fm_watcher_supervision_verdict "$state" "$watch" "$GRACE" "$home" "$home"
  verdict_ok=$FM_WATCHER_VERDICT_OK
  verdict_reason=$FM_WATCHER_VERDICT_REASON

  if [ "$verdict_ok" = true ]; then
    # Recovery resets the wedge-confirmation clock for the next episode.
    [ "$DRY_RUN" -eq 1 ] || rate_clear "$home" lapse-since
    printf 'home=%s\tclass=healthy\taction=none\treason=watcher-fresh-model-%s\n' "$home" "$model"
    return 0
  fi

  # Genuinely lapsed. Decide the repair by whether a director session is alive.
  if session_alive "$home"; then
    # A live session whose supervision lapsed is EITHER a legitimate long turn
    # (a slow build, a no-mistakes run) that will re-arm itself at its next turn
    # boundary, OR an asleep/wedged session whose watcher died with no Stop left to
    # re-arm on. The guardian deliberately does NOT re-arm here: a guardian-owned
    # watcher would freshen the beacon and mask the wedge (and defeat the very
    # confirmation clock below), while re-arm gives an asleep session no handler
    # anyway - only its own harness or a relaunch can. Wakes are not lost: their
    # signal/status files persist and a watcher scans them once the session resumes
    # or is relaunched. So the guardian starts a confirmation clock and, only when a
    # live session stays continuously unsupervised past WEDGE_ESCALATE_SECS (longer
    # than any legitimate long turn), escalates it as a likely wedge rather than
    # relaunching a live session out from under in-flight work.
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'home=%s\tclass=lapsed\taction=confirm-wedge\treason=%s-model-%s-session-alive\n' "$home" "$verdict_reason" "$model"
      return 0
    fi
    if [ "$(stamp_age "$home" lapse-since)" -lt 0 ]; then
      rate_touch "$home" lapse-since
      log_line INFO "$home" lapsed confirm-wedge "reason=$verdict_reason model=$model session=alive note=clock-started"
    elif [ "$(stamp_age "$home" lapse-since)" -ge "$WEDGE_ESCALATE_SECS" ] \
      && rate_ok "$home" escalate "$ESCALATE_MIN_INTERVAL"; then
      escalate "$home" "director session alive but supervision has stayed lapsed for over ${WEDGE_ESCALATE_SECS}s (reason=$verdict_reason); likely wedged - nudge or relaunch it"
      rate_touch "$home" escalate
    fi
    return 0
  fi

  # Session is DEAD. Clear any stale lapse-since confirmation from a prior live
  # episode so it does not carry into this dead one.
  [ "$DRY_RUN" -eq 1 ] || rate_clear "$home" lapse-since

  case "$role" in
    secondmate:*)
      id=${role#secondmate:}
      if [ "$DRY_RUN" -eq 1 ]; then
        printf 'home=%s\tclass=dead\taction=relaunch\treason=%s-session-dead-id-%s\n' "$home" "$verdict_reason" "$id"
        relaunch_director "$home" "$id" "$GUARDIAN_MAIN" | sed "s#^#  #"
        return 0
      fi
      # Crash-loop backstop: do not hammer a home that keeps dying. Escalate instead.
      if ! rate_ok "$home" relaunch "$RELAUNCH_MIN_INTERVAL"; then
        if rate_ok "$home" escalate "$ESCALATE_MIN_INTERVAL"; then
          escalate "$home" "dead director $id relaunched too recently (< ${RELAUNCH_MIN_INTERVAL}s); not relaunching again - investigate the crash loop"
          rate_touch "$home" escalate
        fi
        log_line WARN "$home" dead relaunch-suppressed "id=$id reason=rate-limited"
        return 0
      fi
      rate_touch "$home" relaunch
      if relaunch_director "$home" "$id" "$GUARDIAN_MAIN"; then
        log_line INFO "$home" dead relaunch "id=$id reason=$verdict_reason"
      else
        escalate "$home" "sanctioned relaunch of dead director $id FAILED (reason=$verdict_reason)"
      fi
      ;;
    *)
      # Main home with no live session: the guardian must not spawn a competing
      # firstmate (a fleet-behavior/architecture choice). Capture wakes durably by
      # re-arming a watcher, and escalate so a human starts a session.
      detail="reason=$verdict_reason"
      if [ "$DRY_RUN" -eq 1 ]; then
        printf 'home=%s\tclass=dead\taction=rearm+escalate\treason=%s-main-no-session\n' "$home" "$verdict_reason"
        arm_watcher "$home" | sed "s#^#  #"
        return 0
      fi
      if arm_watcher "$home"; then
        log_line INFO "$home" dead rearm "$detail note=main-home-no-session-wakes-captured-durably"
        rate_touch "$home" rearm
      fi
      if rate_ok "$home" escalate "$ESCALATE_MIN_INTERVAL"; then
        escalate "$home" "main firstmate home needs supervision but no session is running; start a session to handle queued work ($detail)"
        rate_touch "$home" escalate
      fi
      ;;
  esac
}

usage() {
  cat <<'EOF'
fm-liveness-guardian.sh - session-independent fleet supervision backstop.

Runs from a systemd user timer. For each guarded home (main + local secondmates)
it classifies supervision and repairs a genuine lapse through sanctioned paths
only: re-arm a real watcher self-survivingly, relaunch a dead local director, or
escalate. It never fakes a beacon, never double-arms, never disturbs in-flight
work, and never touches the no-mistakes daemon.

usage:
  fm-liveness-guardian.sh                one repair pass over every guarded home
  fm-liveness-guardian.sh --list         classify + print the plan; repairs nothing
  fm-liveness-guardian.sh --home <path>  guard exactly one home (repair pass)
  fm-liveness-guardian.sh --help

Homes: the main home (FM_GUARDIAN_MAIN_HOME, else FM_HOME) plus every local
secondmate discovered from the main home's kind=secondmate meta records. Remote
secondmates are reported and skipped. FM_GUARDIAN_HOMES overrides discovery.

See the script header and docs/liveness-guardian.md for the full environment
knobs, the classification matrix, and the install step.
EOF
}

main() {
  local one_home=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --list|--dry-run) DRY_RUN=1 ;;
      --home) shift; one_home=${1:-} ; [ -n "$one_home" ] || { echo "error: --home needs a path" >&2; exit 2; } ;;
      *) echo "error: unknown argument: $1 (valid: --list, --home <path>, --help)" >&2; exit 2 ;;
    esac
    shift
  done

  if [ -n "$one_home" ]; then
    guard_home "$one_home" main
    return 0
  fi

  local homes rc
  homes=$(discover_homes) || { rc=$?; return "$rc"; }
  printf '%s\n' "$homes" | while IFS=$'\t' read -r home role; do
    [ -n "$home" ] || continue
    guard_home "$home" "$role"
  done
}

main "$@"
