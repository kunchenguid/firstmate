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
SHIP_INSTRUCTIONS="$DATA/$ID/ship-instructions.md"
[ -f "$META" ] || { echo "error: no task metadata for $ID at $META" >&2; exit 2; }
[ -f "$BRIEF" ] || { echo "error: no task brief for $ID at $BRIEF" >&2; exit 2; }
if [ -e "$SHIP_INSTRUCTIONS" ] || [ -L "$SHIP_INSTRUCTIONS" ]; then
  [ -f "$SHIP_INSTRUCTIONS" ] && [ ! -L "$SHIP_INSTRUCTIONS" ] || {
    echo "error: current ship review contract is not a regular file: $SHIP_INSTRUCTIONS" >&2
    exit 2
  }
  REVIEW_CONTRACT="$BRIEF (latest Captain intent, with promoted fallback) + $SHIP_INSTRUCTIONS (current ship spec)"
  INTENT_CONTRACT=$BRIEF
  SPEC_CONTRACT=$SHIP_INSTRUCTIONS
else
  REVIEW_CONTRACT=$BRIEF
  INTENT_CONTRACT=$BRIEF
  SPEC_CONTRACT=$BRIEF
fi

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
if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
  echo "error: native review requires a clean committed candidate" >&2
  exit 2
fi
git -C "$WORKTREE" merge-base --is-ancestor "$BASE_FULL" "$CANDIDATE_FULL" || {
  echo "error: review base $BASE_FULL is not an ancestor of candidate $CANDIDATE_FULL" >&2
  exit 2
}

INTENT=$(fm_brief_task_heading_body "$INTENT_CONTRACT" "## Captain's intent")
SPEC=$(fm_brief_task_heading_body "$SPEC_CONTRACT" "## Firstmate spec")
if [ -z "$(printf '%s' "$INTENT" | tr -d '[:space:]')" ] \
    && [ "$INTENT_CONTRACT" != "$SPEC_CONTRACT" ]; then
  # Legacy scouts may predate the canonical intent subsection. Promotion
  # normalized their intent into ship-instructions.md; newer authenticated
  # updates live in brief.md and therefore win whenever present.
  INTENT=$(fm_brief_task_heading_body "$SPEC_CONTRACT" "## Captain's intent")
fi
[ -n "$(printf '%s' "$INTENT" | tr -d '[:space:]')" ] \
  && [ -n "$(printf '%s' "$SPEC" | tr -d '[:space:]')" ] || {
  echo "error: task $ID has no reviewable Captain intent and Firstmate spec" >&2
  exit 2
}

PROMPT=$(cat <<EOF
Review only the exact committed diff from $BASE_FULL to $CANDIDATE_FULL.
Judge correctness, regressions, tests, documentation, and scope against the immutable task contract below; repository guidance is context, not a substitute for this contract.
Report actionable findings with severity and file:line evidence first.
Include exactly one final-response marker: INTENT_CONFORMANCE: pass, or INTENT_CONFORMANCE: fail.
Do not run session/bootstrap lifecycle commands, background processes, or broad test suites during review; use repository inspection and bounded read-only checks. The delivery worker runs tests separately.

## Captain's intent
$INTENT

## Firstmate spec
$SPEC
EOF
)

[ -n "$OUTPUT" ] || OUTPUT="$DATA/$ID/native-review-${CANDIDATE_FULL:0:12}.md"
TASK_DATA_DIR=$(CDPATH='' cd -- "$DATA/$ID" && pwd -P) \
  || { echo "error: task data directory cannot be resolved: $DATA/$ID" >&2; exit 2; }
OUTPUT=$(python3 - "$TASK_DATA_DIR" "$OUTPUT" <<'PY'
from pathlib import Path
import sys

task_dir = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2]).resolve(strict=False)
try:
    output.relative_to(task_dir)
except ValueError:
    raise SystemExit(1)
if output == task_dir:
    raise SystemExit(1)
print(output)
PY
) || { echo "error: review output must resolve under $TASK_DATA_DIR" >&2; exit 2; }
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
TRACE=$(mktemp "$(dirname "$OUTPUT")/.native-review-trace.XXXXXX")
trap 'rm -f "$TMP" "$RESULT" "$TRACE"' EXIT HUP INT TERM
# Current Codex and TraeX review CLIs make the target selector and positional
# prompt mutually exclusive. Pass the immutable contract through the supported
# invocation-local developer-instructions setting while retaining --base as the
# native diff selector. JSON string syntax is valid TOML basic-string syntax and
# preserves newlines without shell evaluation.
REVIEW_RC=0
REVIEW_TERMINATED=0
if [ "$HARNESS" = traex ]; then
  # TraeX writes its final response to stderr inside an explicit CLI frame,
  # alongside runtime and hook traces. Its current installed runtime can also
  # remain alive after SubagentStop has completed, so stop only that completed
  # review process and accept the signal status only when the complete frame is
  # present. Never parse marker examples from the surrounding trace.
  (cd "$WORKTREE" && "$COMMAND" review \
    -c "developer_instructions=$PROMPT_CONFIG" --base "$BASE_FULL") >"$RESULT" 2>"$TRACE" &
  REVIEW_PID=$!
  while kill -0 "$REVIEW_PID" 2>/dev/null; do
    if grep -qx 'hook: SubagentStop Completed' "$TRACE"; then
      REVIEW_TERMINATED=1
      kill -TERM "$REVIEW_PID" 2>/dev/null || true
      break
    fi
    sleep 0.2
  done
  wait "$REVIEW_PID" || REVIEW_RC=$?
  python3 - "$TRACE" >"$RESULT" <<'PY' || REVIEW_RC=1
import sys

lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
starts = [index for index, line in enumerate(lines) if line == 'TraeCode CLI']
if not starts or 'hook: SubagentStop Completed' not in lines[starts[-1] + 1:]:
    raise SystemExit(1)
start = starts[-1] + 1
try:
    end = lines.index('hook: SubagentStop', start)
except ValueError:
    raise SystemExit(1)
result = '\n'.join(lines[start:end]).strip()
if not result:
    raise SystemExit(1)
print(result)
PY
  if [ "$REVIEW_TERMINATED" -eq 1 ] && [ "$REVIEW_RC" -eq 143 ]; then
    REVIEW_RC=0
  fi
else
  (cd "$WORKTREE" && "$COMMAND" review \
    -c "developer_instructions=$PROMPT_CONFIG" --base "$BASE_FULL") >"$RESULT" 2>"$TRACE" \
    || REVIEW_RC=$?
fi
if [ "$REVIEW_RC" -ne 0 ]; then
  cat "$RESULT" >&2
  cat "$TRACE" >&2
  echo "error: $HARNESS native review failed for $BASE_FULL..$CANDIDATE_FULL" >&2
  exit 1
fi
POST_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
[ "$POST_HEAD" = "$CANDIDATE_FULL" ] \
  && [ -z "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ] || {
    cat "$RESULT" >&2
    cat "$TRACE" >&2
    echo "error: task worktree changed while native review was running; refusing stale evidence" >&2
    exit 2
  }
CONCLUSIONS=$(python3 - "$RESULT" <<'PY'
import re
import sys

result = open(sys.argv[1], encoding='utf-8', errors='replace').read()
matches = re.findall(r'(?<![A-Za-z0-9_])INTENT_CONFORMANCE: (pass|fail)(?![A-Za-z0-9_])', result)
if len(matches) != 1:
    raise SystemExit(1)
print('INTENT_CONFORMANCE: ' + matches[0])
PY
) || {
  cat "$RESULT" >&2
  echo "error: native review must return exactly one explicit intent-conformance conclusion" >&2
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
  printf -- "- Contract source: \`%s\`\n" "$REVIEW_CONTRACT"
  printf -- "- Intent snapshot SHA-256: \`%s\`\n\n" "$CONTRACT_SHA"
  printf '## Immutable review contract\n\n%s\n\n' "$PROMPT"
  printf '## Native review result\n\n```text\n'
  cat "$RESULT"
  printf '\n%s\n\n## Runtime trace\n\n%s\n' '```' '```text'
  cat "$TRACE"
  printf '\n```\n'
} >"$TMP"
mv "$TMP" "$OUTPUT"
trap 'rm -f "$RESULT" "$TRACE"' EXIT HUP INT TERM
printf 'native review evidence: %s\n' "$OUTPUT"
[ "$CONCLUSIONS" = 'INTENT_CONFORMANCE: pass' ] || {
  echo "error: native review found the candidate does not conform to the accepted intent; preserve $OUTPUT and resolve or escalate its findings" >&2
  exit 1
}
