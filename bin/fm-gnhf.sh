#!/usr/bin/env bash
# fm-gnhf.sh - launch a GNHF overnight run under firstmate's safety boundaries.
#
# Usage:
#   fm-gnhf.sh --project <name> [wrapper options] -- <gnhf arguments...>
#   fm-gnhf.sh --project <name> [wrapper options] <gnhf arguments...>
#   fm-gnhf.sh --help
#
# Wrapper options (consumed here; everything else reaches gnhf unchanged):
#   --project <name>      registered project name; the checkout defaults to
#                         <FM_HOME>/projects/<name>
#   --project-dir <dir>   use this git checkout instead of the default clone
#   --task <id>           also append each run status line to <state>/<id>.status
#   --print-plan          resolve and print the launch plan, then exit without
#                         creating a run record or launching gnhf
#   -h, --help            print this help
#
# A thin guard, not an orchestrator: gnhf owns its loop, and this wrapper only
# refuses the launches that would cross firstmate's boundaries, records the run,
# and hands gnhf the arguments verbatim.
#
# Safety boundaries
# -----------------
# 1. Isolated copy only. The wrapper adds gnhf's `--worktree`, so a run works in
#    its own git worktree rather than the project's primary checkout.
#    `--current-branch` and `--push` are refused unless this one invocation
#    carries the matching token in FM_GNHF_RUN_AUTH:
#        FM_GNHF_RUN_AUTH=push bin/fm-gnhf.sh --project demo -- ...
#        FM_GNHF_RUN_AUTH=current-branch,push bin/fm-gnhf.sh --project ...
#    Tokens are exact, comma-separated, and read from that single invocation's
#    environment only - never from config - so authorizing one run never
#    authorizes the next. Firstmate sets it after the captain's explicit word
#    for that run. An authorized `--current-branch` run happens in the project
#    checkout itself; that is the boundary the token deliberately opens.
# 2. Telemetry off by default: GNHF_TELEMETRY defaults to 0 and is exported.
#    An explicit caller value is preserved.
# 3. Delivery posture is resolved and recorded before gnhf starts, from
#    bin/fm-project-mode.sh. An unregistered project resolves to no-mistakes
#    with merge authority off; an unresolvable project checkout stops the run.
# 4. A durable run record. Every run gets
#    <state>/gnhf/<run-id>.env      resolved project, posture, arguments, run mode
#    <state>/gnhf/<run-id>.status   working, then done or failed
#    and, with --task, the same status lines also go to <state>/<id>.status so
#    the owning task's supervisor sees the live run and its exit.
#
# Delivery alignment
# ------------------
# GNHF's output - its `gnhf/<slug>` branch or the preserved worktree it prints -
# is unlanded work. It is reviewed through the project's registered delivery
# mode and merge authority exactly like any other unlanded change (AGENTS.md
# section 7): no-mistakes or direct-PR produces a PR, local-only stops at a
# reviewed local branch. `gnhf --push` publishes a branch but is never a
# substitute for that review path. This wrapper never merges, pushes, or cleans
# anything up itself.
#
# Exit status: 2 for a refusal or usage error, gnhf's own status otherwise.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
PROJECT_MODE="$SCRIPT_DIR/fm-project-mode.sh"

die() {
  echo "fm-gnhf: $*" >&2
  exit 2
}

usage() {
  awk '
    /^# Usage:/ { on = 1 }
    on && /^# Safety boundaries$/ { exit }
    on { sub(/^# ?/, ""); print }
  ' "$0"
}

PROJECT=
PROJECT_DIR=
TASK=
PRINT_PLAN=0
RUN_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || die "--project needs a project name"
      PROJECT=$2
      shift 2
      ;;
    --project=*)
      PROJECT=${1#--project=}
      shift
      ;;
    --project-dir)
      [ "$#" -ge 2 ] || die "--project-dir needs a directory"
      PROJECT_DIR=$2
      shift 2
      ;;
    --project-dir=*)
      PROJECT_DIR=${1#--project-dir=}
      shift
      ;;
    --task)
      [ "$#" -ge 2 ] || die "--task needs a task id"
      TASK=$2
      shift 2
      ;;
    --task=*)
      TASK=${1#--task=}
      shift
      ;;
    --print-plan)
      PRINT_PLAN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      RUN_ARGS=("$@")
      break
      ;;
    *)
      RUN_ARGS=("$@")
      break
      ;;
  esac
done

[ -n "$PROJECT" ] || {
  usage >&2
  die "--project is required"
}
case "$TASK" in
  *[!A-Za-z0-9._-]*) die "--task must be a plain task id: $TASK" ;;
esac
[ "${#RUN_ARGS[@]}" -gt 0 ] || die "no gnhf arguments or prompt given; put them after --"
command -v gnhf >/dev/null 2>&1 || die "gnhf is not on PATH; install it first (the gnhf skill's Launch section points at its own CLI help)"

[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PROJECTS/$PROJECT"
[ -d "$PROJECT_DIR" ] || die "project '$PROJECT' cannot be resolved: no checkout at $PROJECT_DIR (clone or register it, or pass --project-dir)"
git -C "$PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1 || die "project '$PROJECT' cannot be resolved: $PROJECT_DIR is not a git checkout"

# The registry is the captain's standing posture; bin/fm-project-mode.sh owns its
# grammar and its unregistered fallback.
posture=$("$PROJECT_MODE" "$PROJECT") || die "cannot resolve the registered delivery posture for project '$PROJECT'; refusing to launch"
MODE=${posture%% *}
YOLO=${posture##* }
[ "$MODE" != "$posture" ] || die "unexpected delivery-posture output for '$PROJECT': $posture"

HAS_WORKTREE=0
HAS_CURRENT=0
HAS_PUSH=0
for arg in ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}; do
  case "$arg" in
    --worktree) HAS_WORKTREE=1 ;;
    --current-branch) HAS_CURRENT=1 ;;
    --push) HAS_PUSH=1 ;;
  esac
done

fm_gnhf_authorized() { # <token>
  case ",${FM_GNHF_RUN_AUTH:-}," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

if [ "$HAS_CURRENT" -eq 1 ] && ! fm_gnhf_authorized current-branch; then
  die "refusing --current-branch: it runs in the project's primary checkout, and only an explicit per-run authorization opens that (set FM_GNHF_RUN_AUTH to include 'current-branch' for this one run, after the captain's word for it)"
fi
if [ "$HAS_PUSH" -eq 1 ] && ! fm_gnhf_authorized push; then
  die "refusing --push: publishing a branch needs an explicit per-run authorization (set FM_GNHF_RUN_AUTH to include 'push' for this one run, after the captain's word for it)"
fi
if [ "$HAS_CURRENT" -eq 1 ] && [ "$HAS_WORKTREE" -eq 1 ]; then
  die "gnhf refuses --current-branch together with --worktree; pass only one"
fi
if [ "$HAS_CURRENT" -eq 0 ] && [ "$HAS_WORKTREE" -eq 0 ]; then
  RUN_ARGS=(--worktree ${RUN_ARGS[@]+"${RUN_ARGS[@]}"})
  HAS_WORKTREE=1
fi

export GNHF_TELEMETRY="${GNHF_TELEMETRY:-0}"

mkdir -p "$STATE/gnhf" || die "cannot create the run-record directory $STATE/gnhf"
SLUG=$(printf '%s' "$PROJECT" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//')
[ -n "$SLUG" ] || SLUG=project
RUN_ID="gnhf-$SLUG-$(date +%s)-$$"
RECORD="$STATE/gnhf/$RUN_ID.env"
STATUS_LOG="$STATE/gnhf/$RUN_ID.status"
GNHF_BIN=$(command -v gnhf)

if [ "$HAS_CURRENT" -eq 1 ]; then
  LOCATION="the project's current branch"
else
  LOCATION="an isolated worktree"
fi

if [ "$PRINT_PLAN" -eq 1 ]; then
  printf 'project=%s\nproject_dir=%s\nmode=%s\nyolo=%s\nlocation=%s\npush=%s\ntelemetry=%s\nrecord=%s\n' \
    "$PROJECT" "$PROJECT_DIR" "$MODE" "$YOLO" "$LOCATION" "$HAS_PUSH" "$GNHF_TELEMETRY" "$RECORD"
  exit 0
fi

{
  printf 'run_id=%q\n' "$RUN_ID"
  printf 'project=%q\n' "$PROJECT"
  printf 'project_dir=%q\n' "$PROJECT_DIR"
  printf 'mode=%q\n' "$MODE"
  printf 'yolo=%q\n' "$YOLO"
  printf 'task=%q\n' "$TASK"
  printf 'worktree_mode=%q\n' "$HAS_WORKTREE"
  printf 'current_branch=%q\n' "$HAS_CURRENT"
  printf 'push=%q\n' "$HAS_PUSH"
  printf 'telemetry=%q\n' "$GNHF_TELEMETRY"
  printf 'started_at=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'gnhf=%q\n' "$GNHF_BIN"
  i=0
  for arg in ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}; do
    i=$((i + 1))
    printf 'arg%s=%q\n' "$i" "$arg"
  done
} >"$RECORD" || die "cannot write the run record $RECORD"

fm_gnhf_status() { # <state> <message>
  local line
  line="$1 [at=$(date +%s)]: $2"
  printf '%s\n' "$line" >>"$STATUS_LOG" \
    || echo "fm-gnhf: warning: cannot append to $STATUS_LOG" >&2
  if [ -n "$TASK" ]; then
    printf '%s\n' "$line" >>"$STATE/$TASK.status" \
      || echo "fm-gnhf: warning: cannot append to $STATE/$TASK.status" >&2
  fi
}

fm_gnhf_status "working" "gnhf run $RUN_ID started for $PROJECT in $LOCATION (mode=$MODE, merge authority $YOLO)"

gnhf_rc=0
exec 3<&0
(
  cd "$PROJECT_DIR" || exit 1
  # The authorization covers this one run; the worker must not pass it on.
  unset FM_GNHF_RUN_AUTH
  exec "$GNHF_BIN" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}
) <&3 &
GNHF_PID=$!
exec 3<&-

# shellcheck disable=SC2329 # invoked via trap
fm_gnhf_terminate() { # <signal-name> <exit-code>
  trap '' TERM INT HUP
  kill -TERM "$GNHF_PID" 2>/dev/null
  wait "$GNHF_PID" 2>/dev/null
  fm_gnhf_status "failed" "gnhf run $RUN_ID stopped by SIG$1; inspect the run record and any preserved worktree"
  exit "$2"
}
trap 'fm_gnhf_terminate TERM 143' TERM
trap 'fm_gnhf_terminate INT 130' INT
trap 'fm_gnhf_terminate HUP 129' HUP

while :; do
  wait "$GNHF_PID" && gnhf_rc=0 || gnhf_rc=$?
  # A trapped signal interrupts wait with >128 while the child still runs.
  kill -0 "$GNHF_PID" 2>/dev/null || break
done
trap - TERM INT HUP

if [ "$gnhf_rc" -eq 0 ]; then
  fm_gnhf_status "done" "gnhf run $RUN_ID exited 0; its unlanded work awaits review through $MODE (merge authority $YOLO)"
else
  fm_gnhf_status "failed" "gnhf run $RUN_ID exited $gnhf_rc; inspect the run record and any preserved worktree"
fi

echo "fm-gnhf: run record: $RECORD"
echo "fm-gnhf: status log: $STATUS_LOG"
echo "fm-gnhf: gnhf output is unlanded work; review it through $MODE with merge authority $YOLO."
exit "$gnhf_rc"
