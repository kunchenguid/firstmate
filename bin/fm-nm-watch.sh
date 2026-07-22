#!/usr/bin/env bash
# Arm a no-mistakes escalate-only watch run on a direct-PR task's PR/MR.
#
# direct-PR ships without the no-mistakes pipeline, so nothing ever watched the
# PR it produced: a watch run's only birth path used to be a COMPLETED gate run
# plus the PR URL that gate recorded, and a direct-PR task never runs a gate.
# `no-mistakes watch --pr <url>` is the direct entry for exactly that shape - a
# branch pushed and a PR opened outside the pipeline - so this script wires it
# into firstmate's ship lifecycle.
#
# What the watch run buys over bin/fm-pr-check.sh's poll: the daemon polls the
# PR's CI checks, UNRESOLVED REVIEW THREADS, approval state, and mergeability
# until it merges or closes, and parks (escalates) on anything that needs a
# person. The poll does none of that reviewing; it stays armed as the
# orchestration-layer backstop and asks, for this task's run id only, whether
# the PR merged, whether the run parked, and whether the run is still alive - so
# a watch that dies takes firstmate's attention with it instead of going quiet.
# bin/fm-poll-lib.sh's header owns that contract.
#
# Ownership: the watch run belongs to the DAEMON, not to whoever armed it and
# not to a worktree. It uses no worktree and calls no agent, so it survives crew
# teardown, needs no gateway auth or session quota, and re-arms itself across a
# daemon restart. That is why firstmate arms it (from bin/fm-pr-check.sh, at the
# one point every ready PR already passes through) instead of the crewmate doing
# it as its last act: arming is deterministic there rather than dependent on a
# worker remembering a step, and the parks it produces are firstmate's to answer
# after the crew is gone. Answering needs no checkout either - the park record's
# respond commands target the run by id (`axi respond --run <id>`).
#
# Escalate-only is enforced by no-mistakes itself for an externally opened PR:
# a `fix` answer is refused with "fix the branch yourself and respond with
# approve or skip", whatever auto_fix.ci says. Answering a park ENDS the watch
# run, so re-run this script to re-arm after answering while the PR is open.
# Re-running is the supported idempotent path: the new run replaces the branch's
# previous watcher.
#
# Refuses any mode other than direct-PR. A no-mistakes-mode task gets its watch
# run from its own gate/watch handoff, and re-arming over it would replace that
# pipeline-owned watcher (with its QA node and fix rounds) with an escalate-only
# external one.
#
# Usage: fm-nm-watch.sh <task-id> <pr-url> [--branch <name>]
#   --branch  source branch of the PR; defaults to the task worktree's current
#             branch, then to fm/<task-id>. The branch keys the watcher's
#             supersede scope, so it is always passed explicitly.
#
# Prints one line either way and exits 0 when armed, 1 when it is not, so a
# caller can relay the outcome without deciding whether the PR record failed.
# On success it appends nm_watch_run=<id> to state/<task-id>.meta.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NM_BIN="${FM_NM_BIN:-no-mistakes}"
# The durable per-home ledger of run ids this home armed. It outlives the task
# meta, which teardown deletes, so bin/fm-nm-orphan-scan.sh can still tell one
# home's orphaned park from the captain's own runs and from another home's.
LEDGER="$DATA/nm-armed-runs"

usage() {
  cat <<'EOF'
Usage: fm-nm-watch.sh <task-id> <pr-url> [--branch <name>]

Arm a no-mistakes escalate-only watch run on a direct-PR task's PR/MR.

  --branch <name>  source branch of the PR (default: the task worktree's
                   current branch, then fm/<task-id>)

Exit 0 and print "watch armed: ..." when the run started; exit 1 and print
"watch not armed: <reason>" otherwise. Re-run to re-arm (the new run replaces
the branch's previous watcher), which is also how a watch is restored after a
park is answered.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi

ID=$1
URL=$2
shift 2
BRANCH=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      [ "$#" -ge 2 ] || { echo "fm-nm-watch.sh: --branch needs a value" >&2; exit 2; }
      BRANCH=$2
      shift 2
      ;;
    *)
      echo "fm-nm-watch.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"

not_armed() {
  echo "watch not armed: $1"
  exit 1
}

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Append "<epoch> <run-id> <task-id> <branch>" to the per-home ledger, unless
# the run is already recorded. Best effort: a failure here never fails the arm,
# because the meta's nm_watch_run and the poll still cover a live task; the
# ledger only matters after the task is gone, and the next arm re-records it.
record_armed_run() {  # <run-id>
  local run=$1 now
  [ -n "$run" ] || return 0
  mkdir -p "$DATA" 2>/dev/null || return 0
  if [ -f "$LEDGER" ] && awk -v r="$run" '$2 == r { found = 1 } END { exit found ? 0 : 1 }' "$LEDGER"; then
    return 0
  fi
  now=$(date +%s 2>/dev/null || echo 0)
  printf '%s %s %s %s\n' "$now" "$run" "$ID" "$BRANCH" >> "$LEDGER" 2>/dev/null || true
}

fm_scm_parse_pr_url "$URL" >/dev/null 2>&1 || not_armed "not a PR/MR URL: $URL"

META="$STATE/$ID.meta"
[ -f "$META" ] || not_armed "no state/$ID.meta to read the task's delivery mode from"

MODE=$(meta_field "$META" mode)
case "$MODE" in
  direct-PR) ;;
  '') not_armed "state/$ID.meta records no delivery mode" ;;
  *) not_armed "task mode is $MODE, not direct-PR (a no-mistakes-mode task gets its watch run from its own pipeline handoff)" ;;
esac

WT=$(meta_field "$META" worktree)
PROJECT=$(meta_field "$META" project)
DIR=
for candidate in "$WT" "$PROJECT"; do
  [ -n "$candidate" ] || continue
  [ -d "$candidate" ] || continue
  git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  DIR=$candidate
  break
done
[ -n "$DIR" ] || not_armed "neither the task worktree nor its project clone is a readable git checkout"

if [ -z "$BRANCH" ]; then
  BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
fi
# A detached or default-branch checkout says nothing about the PR's source
# branch; the task's own branch name is the better answer than a wrong one.
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  BRANCH="fm/$ID"
fi

command -v "$NM_BIN" >/dev/null 2>&1 || not_armed "$NM_BIN is not on PATH"

out=$(cd "$DIR" && "$NM_BIN" watch --pr "$URL" --branch "$BRANCH" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  case "$out" in
    *'unknown command "watch"'*)
      not_armed "the installed $NM_BIN has no 'watch' command; update it to a build that carries the external watch entry"
      ;;
  esac
  detail=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -1)
  not_armed "${detail:-$NM_BIN watch exited $rc}"
fi

# `watch` prints "  <mark> Watching <pr-url> <run-id>"; take the run id from the
# Watching line rather than the whole output, which also carries the branch and
# the escalate-only notice.
RUN=$(printf '%s\n' "$out" | awk '/Watching/ { print $NF; exit }')
case "$RUN" in
  ''|*[!A-Za-z0-9]*) RUN= ;;
esac

if [ -n "$RUN" ]; then
  if [ "$(meta_field "$META" nm_watch_run)" != "$RUN" ]; then
    echo "nm_watch_run=$RUN" >> "$META"
  fi
  record_armed_run "$RUN"
  echo "watch armed: run $RUN on $BRANCH watching $URL (escalate-only)"
else
  echo "watch armed: $BRANCH watching $URL (escalate-only; run id not reported, so state/$ID.meta records none)"
fi
