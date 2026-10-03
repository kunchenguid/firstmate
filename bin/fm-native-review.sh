#!/usr/bin/env bash
# Run the selected worker harness's native review against an exact committed
# base/candidate pair and the task's actual immutable intent snapshot.
#
# Usage: fm-native-review.sh <task-id> --base <commit> --candidate <commit> [--output <path>]
#
# The task's recorded harness is authoritative. Codex and TraeX expose native
# `review --base`; Pi does not currently expose a native review command and is
# refused with an actionable diagnostic. The worktree must be clean and its
# HEAD must equal the candidate, so the vendor cannot silently review a moving
# or uncommitted target. The output is accepted only when the reviewer states
# an explicit intent-conformance conclusion.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

usage() {
  echo "usage: fm-native-review.sh <task-id> --base <commit> --candidate <commit> [--output <path>]" >&2
}

ID=${1:-}
[ -n "$ID" ] || { usage; exit 2; }
shift
BASE=
CANDIDATE=
OUTPUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || { usage; exit 2; }; BASE=$2; shift 2 ;;
    --candidate) [ $# -ge 2 ] || { usage; exit 2; }; CANDIDATE=$2; shift 2 ;;
    --output) [ $# -ge 2 ] || { usage; exit 2; }; OUTPUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$BASE" ] && [ -n "$CANDIDATE" ] || { usage; exit 2; }

META="$STATE/$ID.meta"
BRIEF="$DATA/$ID/brief.md"
[ -f "$META" ] || { echo "error: no task metadata for $ID at $META" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "error: no task brief for $ID at $BRIEF" >&2; exit 2; }

WORKTREE=$(sed -n 's/^worktree=//p' "$META" | tail -1)
HARNESS=$(sed -n 's/^harness=//p' "$META" | tail -1)
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || { echo "error: task $ID has no usable worktree" >&2; exit 2; }
[ -n "$HARNESS" ] || { echo "error: task $ID has no recorded harness" >&2; exit 2; }

BASE_FULL=$(git -C "$WORKTREE" rev-parse --verify "$BASE^{commit}" 2>/dev/null) \
  || { echo "error: review base does not resolve to a commit: $BASE" >&2; exit 2; }
CANDIDATE_FULL=$(git -C "$WORKTREE" rev-parse --verify "$CANDIDATE^{commit}" 2>/dev/null) \
  || { echo "error: review candidate does not resolve to a commit: $CANDIDATE" >&2; exit 2; }
HEAD_FULL=$(git -C "$WORKTREE" rev-parse HEAD)
[ "$HEAD_FULL" = "$CANDIDATE_FULL" ] || {
  echo "error: task worktree HEAD $HEAD_FULL does not equal review candidate $CANDIDATE_FULL" >&2
  exit 2
}
if ! git -C "$WORKTREE" diff --quiet -- || ! git -C "$WORKTREE" diff --cached --quiet --; then
  echo "error: native review requires a clean committed candidate" >&2
  exit 2
fi
git -C "$WORKTREE" merge-base --is-ancestor "$BASE_FULL" "$CANDIDATE_FULL" || {
  echo "error: review base $BASE_FULL is not an ancestor of candidate $CANDIDATE_FULL" >&2
  exit 2
}

INTENT=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
SPEC=$(fm_brief_task_heading_body "$BRIEF" "## Firstmate spec")
[ -n "$(printf '%s%s' "$INTENT" "$SPEC" | tr -d '[:space:]')" ] || {
  echo "error: task $ID has no reviewable Captain intent and Firstmate spec" >&2
  exit 2
}

PROMPT=$(cat <<EOF
Review only the exact committed diff from $BASE_FULL to $CANDIDATE_FULL.
Judge correctness, regressions, tests, documentation, and scope against the immutable task contract below; repository guidance is context, not a substitute for this contract.
Report actionable findings with severity and file:line evidence first.
Conclude with exactly one line: INTENT_CONFORMANCE: pass, or INTENT_CONFORMANCE: fail.

## Captain's intent
$INTENT

## Firstmate spec
$SPEC
EOF
)

[ -n "$OUTPUT" ] || OUTPUT="$DATA/$ID/native-review-${CANDIDATE_FULL:0:12}.md"
case "$OUTPUT" in
  "$DATA/$ID"/*) ;;
  *) echo "error: review output must stay under $DATA/$ID" >&2; exit 2 ;;
esac
mkdir -p "$(dirname "$OUTPUT")"
TMP=$(mktemp "$(dirname "$OUTPUT")/.native-review.XXXXXX")
trap 'rm -f "$TMP"' EXIT HUP INT TERM

case "$HARNESS" in
  codex) COMMAND=codex ;;
  traex) COMMAND=traex ;;
  pi)
    echo "error: harness pi has no verified native review command; select codex or traex for review-PR" >&2
    exit 3
    ;;
  *)
    echo "error: harness $HARNESS has no supported native review route; select codex or traex" >&2
    exit 3
    ;;
esac
command -v "$COMMAND" >/dev/null 2>&1 || {
  echo "error: native review executable is unavailable for harness $HARNESS: $COMMAND" >&2
  exit 3
}

VERSION=$($COMMAND --version 2>&1 | head -1)
PROMPT_CONFIG=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<<"$PROMPT")
RESULT=$(mktemp "$(dirname "$OUTPUT")/.native-review-result.XXXXXX")
trap 'rm -f "$TMP" "$RESULT"' EXIT HUP INT TERM
# Current Codex and TraeX review CLIs make the target selector and positional
# prompt mutually exclusive. Pass the immutable contract through the supported
# invocation-local developer-instructions setting while retaining --base as the
# native diff selector. JSON string syntax is valid TOML basic-string syntax and
# preserves newlines without shell evaluation.
if ! (cd "$WORKTREE" && "$COMMAND" review \
  -c "developer_instructions=$PROMPT_CONFIG" --base "$BASE_FULL") >"$RESULT" 2>&1; then
  cat "$RESULT" >&2
  echo "error: $HARNESS native review failed for $BASE_FULL..$CANDIDATE_FULL" >&2
  exit 1
fi
CONCLUSIONS=$(grep -E '^INTENT_CONFORMANCE: (pass|fail)$' "$RESULT" || true)
[ "$(printf '%s\n' "$CONCLUSIONS" | grep -c .)" -eq 1 ] || {
  cat "$RESULT" >&2
  echo "error: native review must return exactly one explicit intent-conformance conclusion" >&2
  exit 1
}
LAST_NONEMPTY=$(awk 'NF { line=$0 } END { print line }' "$RESULT")
[ "$LAST_NONEMPTY" = "$CONCLUSIONS" ] || {
  cat "$RESULT" >&2
  echo "error: native review intent-conformance conclusion must be its final nonempty line" >&2
  exit 1
}

CONTRACT_SHA=$(printf '%s' "$PROMPT" | sha256sum | awk '{print $1}')
{
  printf '# Native review evidence\n\n'
  printf -- "- Task: \`%s\`\n" "$ID"
  printf -- "- Harness: \`%s\`\n" "$HARNESS"
  printf -- "- Runtime: \`%s\`\n" "$VERSION"
  printf -- "- Base: \`%s\`\n" "$BASE_FULL"
  printf -- "- Candidate: \`%s\`\n" "$CANDIDATE_FULL"
  printf -- "- Intent snapshot SHA-256: \`%s\`\n\n" "$CONTRACT_SHA"
  printf '## Immutable review contract\n\n%s\n\n' "$PROMPT"
  printf '## Native review result\n\n```text\n'
  cat "$RESULT"
  printf '\n```\n'
} >"$TMP"
mv "$TMP" "$OUTPUT"
trap 'rm -f "$RESULT"' EXIT HUP INT TERM
printf 'native review evidence: %s\n' "$OUTPUT"
[ "$CONCLUSIONS" = 'INTENT_CONFORMANCE: pass' ] || {
  echo "error: native review found the candidate does not conform to the accepted intent; preserve $OUTPUT and resolve or escalate its findings" >&2
  exit 1
}
