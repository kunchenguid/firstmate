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
# bin/fm-poll-extra.sh's header owns that contract.
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
# The other thing that ends the run is the PR landing, and that one is
# firstmate's own doing: no-mistakes never ends a watch on merge, so
# bin/fm-poll-lib.sh's fm_poll_end_watch_run ends it at the merge the armed poll
# observes and bin/fm-teardown.sh backstops the merge that poll never saw. Only
# re-arm while the PR is genuinely still open.
#
# Refuses any mode other than direct-PR. A no-mistakes-mode task gets its watch
# run from its own gate/watch handoff, and re-arming over it would replace that
# pipeline-owned watcher (with its QA node and fix rounds) with an escalate-only
# external one.
#
# `no-mistakes watch` needs the repo it runs in to be initialized, so a direct-PR
# project has to be initialized too even though it never runs the pipeline. The
# project-management skill owns that rule and the reason it is not a contradiction.
#
# ARMED IS NOT WATCHING, and this script must never report the first as the
# second. On 2026-07-28 `watch` returned run 01KYJY370CPPE9DRV9NPEPFKAD on MR 43
# and the run ended 2ms later - `axi status --run` shows its one step as
# `watch,skipped,0,2` with `outcome: passed` - while that MR's CI was red and it
# had neither merged nor closed. A false "armed" is worse than no watch at all:
# it tells firstmate the PR is covered. Every arm is therefore verified against
# the run's own record before it is reported or recorded, and only a confident
# not-watching reading demotes it; an unreadable verification says so in the line
# rather than being resolved either way.
#
# Usage: fm-nm-watch.sh <task-id> <pr-url> [--branch <name>]
#   --branch  source branch of the PR; defaults to the task worktree's current
#             branch, then to fm/<task-id>. The branch keys the watcher's
#             supersede scope, so it is always passed explicitly.
#
# Prints one line either way and exits 0 when armed, 1 when it is not, so a
# caller can relay the outcome without deciding whether the PR record failed.
# On success it records nm_watch_run=<id> in state/<task-id>.meta and clears any
# nm_watch_unarmed=. A direct-PR task left with no watch records the reason as
# nm_watch_unarmed=<reason> instead, because the printed line scrolls past inside
# a PR-record run and nothing else would ever re-surface an unmonitored PR;
# bin/fm-bootstrap.sh reads that field back as its NM_UNWATCHED diagnostic.
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

Exit 0 and print "watch armed: ..." when the run started AND its own record
confirms it is watching. Exit 1 otherwise: "watch not armed - this PR has no CI
monitoring: <reason>" when a direct-PR task's PR is left unmonitored (also
recorded as nm_watch_unarmed= in the task meta), or plain "watch not armed:
<reason>" for a by-design refusal that costs no monitoring, such as a task whose
own pipeline already owns a watcher.

Re-run to re-arm (the new run replaces the branch's previous watcher), which is
also how a watch is restored after a park is answered.
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
# For fm_poll_watch_state, the single owner of "is this run still watching".
# shellcheck source=bin/fm-poll-lib.sh
. "$SCRIPT_DIR/fm-poll-lib.sh"

# A refusal that costs no monitoring: bad input, or a task whose own pipeline
# already owns a watcher. Nothing is lost, so nothing is recorded.
not_armed() {
  echo "watch not armed: $1"
  exit 1
}

# A direct-PR task's PR left with NO CI monitoring at all. Distinct from
# not_armed because the two read identically and the difference is the whole
# point: this one is a hole in the fleet's coverage, so it is stated as such and
# recorded durably for bin/fm-bootstrap.sh to re-surface at every session start.
unwatched() {
  record_unarmed "$1"
  echo "watch not armed - this PR has no CI monitoring: $1"
  exit 1
}

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Replace <key>= in the task meta, or drop the key when the value is empty.
# Rewrites through a temp file beside it so a crash cannot leave a half-written
# meta, and stays best effort: a meta this cannot rewrite must not fail the arm,
# which is the part that actually protects the PR.
meta_set() {  # <key> <value-or-empty>
  local key=$1 value=$2 tmp
  [ -f "$META" ] || return 0
  tmp=$(mktemp "$STATE/.fm-nm-watch.XXXXXX" 2>/dev/null) || return 0
  chmod 0600 "$tmp" 2>/dev/null || true
  grep -v "^$key=" "$META" >> "$tmp" 2>/dev/null || true
  if [ -n "$value" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  fi
  mv -f "$tmp" "$META" 2>/dev/null || rm -f "$tmp"
}

# Record why this task's PR has no watch, on one line so the meta stays parseable.
record_unarmed() {  # <reason>
  meta_set nm_watch_unarmed "$(printf '%s' "$1" | tr '\t\r\n' '   ')"
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
  '') unwatched "state/$ID.meta records no delivery mode" ;;
  *) not_armed "task mode is $MODE, not direct-PR (a no-mistakes-mode task gets its watch run from its own pipeline handoff)" ;;
esac

# Every checkout worth trying, in preference order. `watch --pr <url>` targets
# the PR by URL, so the checkout only decides whose no-mistakes config answers -
# which makes the project clone a real second chance rather than a duplicate
# attempt, and a disposable task worktree the likelier of the two to be missing
# initialization. The old code picked the first READABLE candidate and stopped,
# so a failure in the task copy ended the arm without the project clone ever
# being asked.
WT=$(meta_field "$META" worktree)
PROJECT=$(meta_field "$META" project)
DIRS=()
for candidate in "$WT" "$PROJECT"; do
  [ -n "$candidate" ] || continue
  [ -d "$candidate" ] || continue
  git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  # Only two candidates, so the only possible duplicate is the first one.
  if [ "${#DIRS[@]}" -gt 0 ] && [ "${DIRS[0]}" = "$candidate" ]; then
    continue
  fi
  DIRS+=("$candidate")
done
[ "${#DIRS[@]}" -gt 0 ] || unwatched "neither the task worktree nor its project clone is a readable git checkout"

if [ -z "$BRANCH" ]; then
  BRANCH=$(git -C "${DIRS[0]}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
fi
# A detached or default-branch checkout says nothing about the PR's source
# branch; the task's own branch name is the better answer than a wrong one.
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  BRANCH="fm/$ID"
fi

command -v "$NM_BIN" >/dev/null 2>&1 || unwatched "$NM_BIN is not on PATH"

# One candidate's failure reason, normalized to a single line.
arm_failure_reason() {  # <output> <exit-code>
  local out=$1 rc=$2 detail
  case "$out" in
    *'unknown command "watch"'*)
      printf 'the installed %s has no '"'"'watch'"'"' command; update it to a build that carries the external watch entry\n' "$NM_BIN"
      return 0
      ;;
  esac
  detail=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -1)
  printf '%s\n' "${detail:-$NM_BIN watch exited $rc}"
}

out=
rc=0
DIR=
REASONS=
for candidate in "${DIRS[@]}"; do
  out=$(cd "$candidate" && "$NM_BIN" watch --pr "$URL" --branch "$BRANCH" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    DIR=$candidate
    break
  fi
  reason=$(arm_failure_reason "$out" "$rc")
  case "$REASONS" in
    '') REASONS=$reason ;;
    *"$reason"*) ;;
    *) REASONS="$REASONS; $reason" ;;
  esac
done
[ -n "$DIR" ] || unwatched "$REASONS"

# `watch` prints "  <mark> Watching <pr-url> <run-id>"; take the run id from the
# Watching line rather than the whole output, which also carries the branch and
# the escalate-only notice.
RUN=$(printf '%s\n' "$out" | awk '/Watching/ { print $NF; exit }')
case "$RUN" in
  ''|*[!A-Za-z0-9]*) RUN= ;;
esac

# No run id means no way to ask the run whether it is watching, and no way for
# the poll to ask later either - so the PR is unmonitored in every way firstmate
# can observe. This used to be reported as armed.
[ -n "$RUN" ] || unwatched "$NM_BIN watch reported no run id, so nothing can be verified or polled for this PR"

# Verify against the run's own record before claiming the PR is covered.
# fm_poll_watch_state owns the alive/gone vocabulary (including the skipped
# watch step that produced the 2026-07-28 false green); a lookup that cannot
# answer is left undecided here exactly as it is there.
VERIFY_NOTE=
if watch_state=$(fm_poll_watch_state "$RUN" "$DIR"); then
  case "$watch_state" in
    gone\|*) unwatched "run $RUN is not watching: ${watch_state#gone|} (re-arm once the repo can start a real watch)" ;;
    alive) ;;
    *) VERIFY_NOTE="; not verified: run $RUN reported no status this script recognizes" ;;
  esac
else
  VERIFY_NOTE="; not verified: could not read run $RUN back from $NM_BIN"
fi

meta_set nm_watch_run "$RUN"
meta_set nm_watch_unarmed ""
record_armed_run "$RUN"
echo "watch armed: run $RUN on $BRANCH watching $URL (escalate-only$VERIFY_NOTE)"
