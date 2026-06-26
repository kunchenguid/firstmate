#!/usr/bin/env bash
# Append a structured entry to a firstmate registry and queue an evaluation.
# Backs the captain-invocable propose-tool and report-problem skills so every
# entry lands in the tracked registry with the exact, consistent schema instead
# of being hand-written (and drifting) per submission.
#   propose-tool  -> appends a "Proposed tools" entry to CAPABILITIES.md
#   report-problem -> appends a problem entry to PROBLEMS.md
# Both also append a line to the fleet-local evaluation queue (data/, gitignored)
# so firstmate later dispatches the evaluation that closes the loop: problem or
# proposal recorded -> candidate evaluated -> capability added -> manifest +
# playbook updated. The tracked registries are repo files (FM_ROOT); the queue is
# operational (FM_HOME/data), matching the rest of bin/.
# Usage:
#   fm-registry.sh propose-tool   --tool NAME --replaces WHAT --why TEXT [--notes TEXT]
#   fm-registry.sh report-problem --problem TITLE --symptom TEXT --impact TEXT --cause TEXT [--fix TEXT]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

CAP="$FM_ROOT/CAPABILITIES.md"
PROB="$FM_ROOT/PROBLEMS.md"
QUEUE="$DATA/evaluation-queue.md"

today="$(date '+%Y-%m-%d')"
stamp="$(date '+%Y%m%d-%H%M%S')"

die() { echo "fm-registry: $*" >&2; exit 1; }

slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-32 | sed -E 's/-+$//')
  # A title that is entirely punctuation or non-ASCII slugifies to empty; keep
  # the id well-formed with a stable fallback rather than emitting a trailing dash.
  [ -n "$s" ] || s=entry
  printf '%s' "$s"
}

# Resolve a collision-free id by appending -2, -3, ... when a heading with the
# same base id already exists in the target registry, so two submissions in the
# same second (the timestamp resolution) cannot overwrite or duplicate an id.
unique_id() {
  local base=$1 file=$2 id=$1 n=1
  while [ -f "$file" ] && grep -qF "### $id - " "$file"; do
    n=$((n + 1))
    id="$base-$n"
  done
  printf '%s' "$id"
}

ensure_queue() {
  [ -d "$DATA" ] || mkdir -p "$DATA"
  if [ ! -f "$QUEUE" ]; then
    {
      echo "# Evaluation queue (fleet-local)"
      echo
      echo "Proposals and problems filed by the propose-tool and report-problem skills, awaiting firstmate evaluation."
      echo "Each line names the tracked-registry entry it came from; resolve one by dispatching a scout or ship task, then update that entry's Status in CAPABILITIES.md / PROBLEMS.md."
      echo "This file is fleet-local (under data/, gitignored); the registries it points at are tracked."
      echo
    } > "$QUEUE"
  fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  propose-tool)
    tool=""; replaces=""; why=""; notes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --tool)     [ $# -ge 2 ] || die "--tool needs a value";     tool="$2";     shift 2;;
        --replaces) [ $# -ge 2 ] || die "--replaces needs a value"; replaces="$2"; shift 2;;
        --why)      [ $# -ge 2 ] || die "--why needs a value";      why="$2";      shift 2;;
        --notes)    [ $# -ge 2 ] || die "--notes needs a value";    notes="$2";    shift 2;;
        *) die "unknown flag: $1";;
      esac
    done
    [ -n "$tool" ]     || die "missing required --tool"
    [ -n "$replaces" ] || die "missing required --replaces"
    [ -n "$why" ]      || die "missing required --why"
    [ -f "$CAP" ]      || die "registry not found: $CAP"
    id="$(unique_id "T-$stamp-$(slug "$tool")" "$CAP")"
    # Preflight the queue first: if data/ cannot be created we die here, before
    # the tracked registry is mutated, so we never leave a recorded entry with no
    # queued evaluation.
    ensure_queue
    {
      echo
      echo "### $id - $tool"
      echo "- **Tool:** $tool"
      echo "- **Replaces:** $replaces"
      echo "- **Why better:** $why"
      [ -n "$notes" ] && echo "- **Notes:** $notes"
      echo "- **Status:** proposed"
      echo "- **Proposed:** $today"
    } >> "$CAP"
    echo "- [ ] evaluate tool proposal $id ($tool, replaces $replaces) -> CAPABILITIES.md (filed $today)" >> "$QUEUE"
    echo "recorded $id in CAPABILITIES.md and queued its evaluation in $QUEUE"
    ;;
  report-problem)
    problem=""; symptom=""; impact=""; cause=""; fix=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --problem) [ $# -ge 2 ] || die "--problem needs a value"; problem="$2"; shift 2;;
        --symptom) [ $# -ge 2 ] || die "--symptom needs a value"; symptom="$2"; shift 2;;
        --impact)  [ $# -ge 2 ] || die "--impact needs a value";  impact="$2";  shift 2;;
        --cause)   [ $# -ge 2 ] || die "--cause needs a value";   cause="$2";   shift 2;;
        --fix)     [ $# -ge 2 ] || die "--fix needs a value";     fix="$2";     shift 2;;
        *) die "unknown flag: $1";;
      esac
    done
    [ -n "$problem" ] || die "missing required --problem"
    [ -n "$symptom" ] || die "missing required --symptom"
    [ -n "$impact" ]  || die "missing required --impact"
    [ -n "$cause" ]   || die "missing required --cause"
    [ -f "$PROB" ]    || die "registry not found: $PROB"
    id="$(unique_id "P-$stamp-$(slug "$problem")" "$PROB")"
    # Preflight the queue first: if data/ cannot be created we die here, before
    # the tracked registry is mutated, so we never leave a recorded entry with no
    # queued evaluation.
    ensure_queue
    {
      echo
      echo "### $id - $problem"
      echo "- **Problem:** $problem"
      echo "- **Symptom:** $symptom"
      echo "- **Impact:** $impact"
      echo "- **Suspected root cause:** $cause"
      echo "- **Candidate fix / tool:** ${fix:-TBD - to be evaluated}"
      echo "- **Status:** reported"
      echo "- **Reported:** $today"
    } >> "$PROB"
    echo "- [ ] evaluate problem $id ($problem) -> PROBLEMS.md (filed $today)" >> "$QUEUE"
    echo "recorded $id in PROBLEMS.md and queued its evaluation in $QUEUE"
    ;;
  ""|-h|--help)
    sed -n '13,15p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "unknown subcommand: $cmd (expected propose-tool or report-problem)"
    ;;
esac
