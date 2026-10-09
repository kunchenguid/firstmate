#!/usr/bin/env bash
# Run a configured native reviewer against an exact committed base/candidate
# pair and the task's actual immutable intent snapshot.
#
# Usage: fm-native-review.sh <task-id> --base <commit> --candidate <commit>
#          [--output <path>]
#          [--review-harness codex --model <name> --effort <level>]
#
# Normal operation reads config/native-review.json from the effective home.
# A task may instead provide all three explicit reviewer axes for a bounded
# invocation. The coding worker's recorded harness remains evidence only and
# never selects the reviewer. The worktree must be clean and its HEAD must
# equal the candidate, so the vendor cannot silently review a moving or
# uncommitted target. The output is accepted only when the reviewer states an
# explicit intent-conformance conclusion. Each original task may launch at
# most two native-review attempts; task-local attempt records make retries and
# candidate changes consume the same bounded history.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

usage() {
  echo "usage: fm-native-review.sh <task-id> --base <commit> --candidate <commit> [--output <path>] [--review-harness codex --model <name> --effort <level>]" >&2
}

ID=${1:-}
[ -n "$ID" ] || { usage; exit 2; }
shift
BASE=
CANDIDATE=
OUTPUT=
REVIEW_HARNESS=
MODEL=
EFFORT=
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || { usage; exit 2; }; BASE=$2; shift 2 ;;
    --candidate) [ $# -ge 2 ] || { usage; exit 2; }; CANDIDATE=$2; shift 2 ;;
    --output) [ $# -ge 2 ] || { usage; exit 2; }; OUTPUT=$2; shift 2 ;;
    --review-harness) [ $# -ge 2 ] || { usage; exit 2; }; REVIEW_HARNESS=$2; shift 2 ;;
    --model) [ $# -ge 2 ] || { usage; exit 2; }; MODEL=$2; shift 2 ;;
    --effort) [ $# -ge 2 ] || { usage; exit 2; }; EFFORT=$2; shift 2 ;;
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

explicit_axes=0
[ -z "$REVIEW_HARNESS$MODEL$EFFORT" ] || explicit_axes=1
if [ "$explicit_axes" -eq 1 ]; then
  [ -n "$REVIEW_HARNESS" ] && [ -n "$MODEL" ] && [ -n "$EFFORT" ] || {
    echo "error: explicit native review selection requires --review-harness, --model, and --effort together" >&2
    exit 2
  }
else
  REVIEW_CONFIG="$CONFIG/native-review.json"
  [ -f "$REVIEW_CONFIG" ] && [ ! -L "$REVIEW_CONFIG" ] && [ -r "$REVIEW_CONFIG" ] || {
    echo "error: native review configuration is missing or unsafe: $REVIEW_CONFIG" >&2
    exit 3
  }
  REVIEW_HARNESS=$(jq -er '
      if keys == ["effort", "harness", "model", "schema"]
         and .schema == "fm-native-review-config.v1"
         and (.harness | type == "string" and length > 0)
         and (.model | type == "string" and length > 0)
         and (.effort | type == "string" and length > 0)
      then .harness else error("invalid native review config") end
    ' "$REVIEW_CONFIG" 2>/dev/null) \
      || { echo "error: invalid native review configuration: $REVIEW_CONFIG" >&2; exit 3; }
  MODEL=$(jq -r '.model' "$REVIEW_CONFIG")
  EFFORT=$(jq -r '.effort' "$REVIEW_CONFIG")
fi

[ "$REVIEW_HARNESS" = codex ] || {
  echo "error: unsupported configured native review harness: $REVIEW_HARNESS; supported: codex" >&2
  exit 3
}
case "$EFFORT" in
  low | medium | high | xhigh | max | ultra) ;;
  *) echo "error: unsupported Codex native review effort: $EFFORT" >&2; exit 3 ;;
esac

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
for CONTRACT_INPUT in "$BRIEF" "$SHIP_INSTRUCTIONS"; do
  [ -e "$CONTRACT_INPUT" ] || continue
  CONTRACT_INPUT_REAL=$(CDPATH='' cd -- "$(dirname "$CONTRACT_INPUT")" && pwd -P)/$(basename "$CONTRACT_INPUT")
  [ "$OUTPUT" != "$CONTRACT_INPUT_REAL" ] || {
    echo "error: review output must not replace task contract input $CONTRACT_INPUT_REAL" >&2
    exit 2
  }
done
mkdir -p "$(dirname "$OUTPUT")"
TMP=$(mktemp "$(dirname "$OUTPUT")/.native-review.XXXXXX")
trap 'rm -f "$TMP"' EXIT HUP INT TERM

COMMAND=codex
command -v "$COMMAND" >/dev/null 2>&1 || {
  echo "error: native review executable is unavailable for reviewer $REVIEW_HARNESS: $COMMAND" >&2
  exit 3
}

VERSION=$($COMMAND --version 2>&1 | head -1)
CODEX_HELP=$($COMMAND --help 2>&1) || {
  echo "error: Codex native review capability check failed: codex --help" >&2
  exit 3
}
REVIEW_HELP=$($COMMAND review --help 2>&1) || {
  echo "error: Codex native review capability check failed: codex review --help" >&2
  exit 3
}
case "$CODEX_HELP" in *--model*) ;; *) echo "error: installed Codex does not advertise --model" >&2; exit 3 ;; esac
case "$REVIEW_HELP" in *--base*) ;; *) echo "error: installed Codex review does not advertise --base" >&2; exit 3 ;; esac

MODEL_CACHE="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
[ -f "$MODEL_CACHE" ] && [ ! -L "$MODEL_CACHE" ] && [ -r "$MODEL_CACHE" ] || {
  echo "error: Codex model capability cache is missing or unsafe: $MODEL_CACHE" >&2
  exit 3
}
jq -e --arg model "$MODEL" --arg effort "$EFFORT" '
  any(.models[]?; .slug == $model and any(.supported_reasoning_levels[]?; .effort == $effort))
' "$MODEL_CACHE" >/dev/null 2>&1 || {
  echo "error: Codex model capability cache does not advertise model=$MODEL effort=$EFFORT: $MODEL_CACHE" >&2
  exit 3
}
AUTH_STATUS=$($COMMAND login status 2>&1) || {
  echo "error: Codex authentication is unavailable; codex login status failed: $AUTH_STATUS" >&2
  exit 3
}
QUOTA_RC=0
QUOTA=$(node "$SCRIPT_DIR/fm-quota.mjs" --json --provider codex 2>&1) || QUOTA_RC=$?
if [ "$QUOTA_RC" -ne 0 ]; then
  QUOTA_DETAIL=$(printf '%s\n' "$QUOTA" | jq -r '.providers.codex.error // empty' 2>/dev/null || true)
  [ -n "$QUOTA_DETAIL" ] || QUOTA_DETAIL=$QUOTA
  echo "error: Codex quota is unavailable: $QUOTA_DETAIL" >&2
  exit 3
fi
printf '%s\n' "$QUOTA" | jq -e '.providers.codex.status == "ok" and .providers.codex.ordinary_usage_allowed == true' >/dev/null 2>&1 || {
  echo "error: Codex quota does not currently allow ordinary usage" >&2
  exit 3
}

# Reserve one of the task's two review attempts immediately before invoking the
# vendor. The per-attempt files are the durable native-review record: changing
# candidate, output name, or brief title cannot reset them. For tasks that
# predate these records, completed evidence files establish the conservative
# historical floor. noclobber makes concurrent reservations converge without a
# separate review-control plane.
review_attempt_floor() {
  local path base number highest=0 evidence=0 first
  for path in "$TASK_DATA_DIR"/native-review-attempt-*.record; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    base=${path##*/native-review-attempt-}
    number=${base%.record}
    case "$number" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$number" -le "$highest" ] || highest=$number
  done
  if [ "$highest" -eq 0 ]; then
    for path in "$TASK_DATA_DIR"/*; do
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      IFS= read -r first < "$path" || first=
      [ "$first" = '# Native review evidence' ] || continue
      evidence=$((evidence + 1))
      [ "$evidence" -lt 2 ] || break
    done
    highest=$evidence
  fi
  printf '%s\n' "$highest"
}

ATTEMPT_RECORD=
while [ -z "$ATTEMPT_RECORD" ]; do
  ATTEMPT_FLOOR=$(review_attempt_floor)
  if [ "$ATTEMPT_FLOOR" -ge 2 ]; then
    echo "error: native review attempt limit reached for original task $ID (2/2); do not start another automatic review. Preserve residual findings and ask MAIN to decide only a severe correctness, security, data-loss, or intent-blocking issue." >&2
    exit 4
  fi
  ATTEMPT=$((ATTEMPT_FLOOR + 1))
  ATTEMPT_RECORD="$TASK_DATA_DIR/native-review-attempt-$ATTEMPT.record"
  if ! (set -C; umask 077; {
    printf 'schema=fm-native-review-attempt.v1\n'
    printf 'task=%s\n' "$ID"
    printf 'attempt=%s\n' "$ATTEMPT"
    printf 'base=%s\n' "$BASE_FULL"
    printf 'candidate=%s\n' "$CANDIDATE_FULL"
    printf 'coding_harness=%s\n' "$HARNESS"
    printf 'review_harness=%s\n' "$REVIEW_HARNESS"
    printf 'model=%s\n' "$MODEL"
    printf 'effort=%s\n' "$EFFORT"
    printf 'output=%s\n' "$OUTPUT"
  } > "$ATTEMPT_RECORD") 2>/dev/null; then
    ATTEMPT_RECORD=
  fi
done

PROMPT_CONFIG=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<<"$PROMPT")
RESULT=$(mktemp "$(dirname "$OUTPUT")/.native-review-result.XXXXXX")
TRACE=$(mktemp "$(dirname "$OUTPUT")/.native-review-trace.XXXXXX")
trap 'rm -f "$TMP" "$RESULT" "$TRACE"' EXIT HUP INT TERM
# The current Codex review CLI makes the target selector and positional prompt
# mutually exclusive. Pass the immutable contract through the supported
# invocation-local developer-instructions setting while retaining --base as the
# native diff selector. JSON string syntax is valid TOML basic-string syntax and
# preserves newlines without shell evaluation.
REVIEW_RC=0
(cd "$WORKTREE" && "$COMMAND" --model "$MODEL" \
  -c "model_reasoning_effort=\"$EFFORT\"" review \
  -c "developer_instructions=$PROMPT_CONFIG" --base "$BASE_FULL") >"$RESULT" 2>"$TRACE" \
  || REVIEW_RC=$?
if [ "$REVIEW_RC" -ne 0 ]; then
  cat "$RESULT" >&2
  cat "$TRACE" >&2
  echo "error: $REVIEW_HARNESS native review failed for $BASE_FULL..$CANDIDATE_FULL" >&2
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
  printf -- "- Coding harness: \`%s\`\n" "$HARNESS"
  printf -- "- Reviewer harness: \`%s\`\n" "$REVIEW_HARNESS"
  printf -- "- Reviewer model: \`%s\`\n" "$MODEL"
  printf -- "- Reviewer effort: \`%s\`\n" "$EFFORT"
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
