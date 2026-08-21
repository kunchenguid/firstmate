#!/usr/bin/env bash
# fm-wayfinder-parent.sh - Firstmate parent map-owner check for a consuming
# project's Wayfinder lifecycle command.
#
# Firstmate does not own the resolution-triple policy. When a child names a
# Wayfinder ticket, this script invokes that project's public
# `bin/wayfinder-lifecycle-gate` and merges Firstmate local completions into
# the snapshot so a report or captain-call inventory cannot stand in for
# tracker resolution.
#
# Usage:
#   fm-wayfinder-parent.sh accept-child --project <dir> --state <file> \
#     --child <number-or-title> [--task <id>]
#   fm-wayfinder-parent.sh handoff --project <dir> --state <file> [--task <id>]
#
#   accept-child
#     Refuse to treat the named child as Wayfinder-resolved until the project
#     command's accept-child verification passes.
#   handoff
#     Refuse map-dependent implementation dispatch until the project command's
#     handoff verification passes.
#
#   --project  Consuming project directory that publishes
#              bin/wayfinder-lifecycle-gate. Required.
#   --state    GitHub snapshot JSON for that command, or - for stdin.
#              Required. This script does not fetch GitHub.
#   --child    Child issue number or exact ticket title. Required for
#              accept-child.
#   --task     Firstmate task id whose local report and captain-call
#              completion records are merged into the snapshot. Optional.
#              Completing bin/fm-captain-hold.sh or bin/fm-decision-hold.sh
#              is not tracker resolution; those records are supplied so the
#              project command can reject them as the triple.
#
# Exit codes: 0 success, 2 project-gate failure (stdout/stderr passed
# through), 1 usage or missing project command.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-wayfinder-parent: %s\n' "$*" >&2
  exit 1
}

COMMAND=
PROJECT=
STATE_FILE=
CHILD=
TASK=
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) fail "--$want_value requires a value" ;;
    esac
    case "$want_value" in
      project) PROJECT=$a ;;
      state) STATE_FILE=$a ;;
      child) CHILD=$a ;;
      task) TASK=$a ;;
      *) fail "internal parser state for --$want_value" ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --project) want_value=project ;;
    --project=*) PROJECT=${a#--project=} ;;
    --state) want_value=state ;;
    --state=*) STATE_FILE=${a#--state=} ;;
    --child) want_value=child ;;
    --child=*) CHILD=${a#--child=} ;;
    --task) want_value=task ;;
    --task=*) TASK=${a#--task=} ;;
    --*) fail "unknown flag $a" ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || fail "--$want_value requires a value"

if [ "${#POS[@]}" -ge 1 ]; then
  COMMAND=${POS[0]}
fi
[ -n "$COMMAND" ] || { usage >&2; exit 1; }
case "$COMMAND" in
  accept-child|handoff) ;;
  *) fail "unknown command $COMMAND (expected accept-child or handoff)" ;;
esac
[ -n "$PROJECT" ] || fail "--project is required"
[ -n "$STATE_FILE" ] || fail "--state is required"
if [ "$COMMAND" = accept-child ]; then
  [ -n "$CHILD" ] || fail "accept-child requires --child <number-or-title>"
else
  [ -z "$CHILD" ] || fail "handoff does not take --child"
fi
[ -z "$TASK" ] || case "$TASK" in
  *[!A-Za-z0-9._-]*) fail "--task must be a non-empty privacy-safe slug" ;;
esac

if [ ! -d "$PROJECT" ]; then
  fail "project is not a directory: $PROJECT"
fi
PROJECT=$(cd "$PROJECT" && pwd)
GATE="$PROJECT/bin/wayfinder-lifecycle-gate"
if [ ! -f "$GATE" ]; then
  fail "project has no bin/wayfinder-lifecycle-gate; invoke the consuming project's public lifecycle command rather than duplicating its policy"
fi
if [ ! -x "$GATE" ]; then
  fail "bin/wayfinder-lifecycle-gate exists but is not executable: $GATE"
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is required to merge local completions into the project snapshot"

REPORT=
META=
if [ -n "$TASK" ]; then
  REPORT="$DATA/$TASK/report.md"
  META="$STATE/$TASK.meta"
fi

MERGED=
STDIN_STATE=
trap 'rm -f -- ${MERGED:+"$MERGED"} ${STDIN_STATE:+"$STDIN_STATE"} 2>/dev/null || true' EXIT

if [ "$STATE_FILE" = - ]; then
  STDIN_STATE=$(mktemp "${TMPDIR:-/tmp}/fm-wayfinder-state.XXXXXX") || fail "could not create a snapshot tempfile"
  cat > "$STDIN_STATE" || fail "could not read snapshot JSON from stdin"
  STATE_FILE=$STDIN_STATE
fi
[ -f "$STATE_FILE" ] || fail "snapshot is not a file: $STATE_FILE"

MERGED=$(mktemp "${TMPDIR:-/tmp}/fm-wayfinder-merged.XXXXXX") || fail "could not create a merged snapshot tempfile"

if ! python3 - "$STATE_FILE" "$MERGED" "${CHILD:-}" "${REPORT:-}" "${META:-}" <<'PY'
import json
import sys
from pathlib import Path

state_path, out_path, child_ref, report_path, meta_path = sys.argv[1:]

try:
    payload = json.loads(Path(state_path).read_text(encoding="utf-8"))
except OSError as exc:
    raise SystemExit(f"cannot read snapshot: {exc}") from exc
except json.JSONDecodeError as exc:
    raise SystemExit(f"snapshot is not valid JSON: {exc}") from exc

if not isinstance(payload, dict):
    raise SystemExit("snapshot must be a JSON object")

children = payload.get("children") or []
if not isinstance(children, list):
    raise SystemExit("snapshot children must be a list")


def child_number(ref: str):
    if not ref:
        return None
    if ref.isdigit():
        number = int(ref)
        for raw in children:
            if isinstance(raw, dict) and raw.get("number") == number:
                return number
        return number
    for raw in children:
        if isinstance(raw, dict) and raw.get("title") == ref:
            number = raw.get("number")
            if isinstance(number, int) and not isinstance(number, bool):
                return number
    return None


number = child_number(child_ref)
extras = []
if number is not None:
    if report_path and Path(report_path).is_file():
        extras.append(
            {"child": number, "source": "report", "complete": True}
        )
    meta_text = ""
    if meta_path and Path(meta_path).is_file():
        meta_text = Path(meta_path).read_text(encoding="utf-8")
    reviewed = False
    keys = ""
    for line in meta_text.splitlines():
        if line.startswith("decisions_reviewed="):
            reviewed = line.split("=", 1)[1] == "1"
        elif line.startswith("decision_keys="):
            keys = line.split("=", 1)[1]
    if reviewed and keys.strip():
        extras.append(
            {
                "child": number,
                "source": "captain-hold",
                "complete": True,
                "id": keys.strip(),
            }
        )

local = payload.get("local")
if local is None:
    local = {}
    payload["local"] = local
if not isinstance(local, dict):
    raise SystemExit("snapshot local must be an object")
completions = local.get("completions")
if completions is None:
    completions = []
    local["completions"] = completions
if not isinstance(completions, list):
    raise SystemExit("snapshot local.completions must be a list")

seen = set()
for raw in completions:
    if not isinstance(raw, dict):
        continue
    seen.add(
        (
            raw.get("child"),
            raw.get("source"),
            raw.get("id") or raw.get("identifier") or "",
        )
    )
for extra in extras:
    key = (extra["child"], extra["source"], extra.get("id") or "")
    if key in seen:
        continue
    completions.append(extra)
    seen.add(key)

Path(out_path).write_text(
    json.dumps(payload, indent=2) + "\n", encoding="utf-8"
)
PY
then
  fail "could not merge local completions into the project snapshot"
fi

set +e
if [ "$COMMAND" = accept-child ]; then
  "$GATE" --state "$MERGED" accept-child "$CHILD"
  rc=$?
else
  "$GATE" --state "$MERGED" handoff
  rc=$?
fi
set -e
exit "$rc"
