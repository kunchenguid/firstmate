#!/usr/bin/env bash
# No Mistake adapter: normalised inputs → axi run → packet report.
# Usage: fm-phase2-no-mistake.sh <task-id> [--repo-path <dir>] [--intent <text>] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
TID="${1:?task-id}"; shift || true
REPO=""; INTENT=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-path) REPO="${2:?}"; shift 2 ;;
    --intent) INTENT="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) shift ;;
  esac
done

PKT="$FM_HOME/data/$TID/packet"
mkdir -p "$PKT"
REPORT="$PKT/NO-MISTAKE.md"
REG="$FM_HOME/bin/fm-phase2-registry.sh"

if ! command -v no-mistakes >/dev/null 2>&1; then
  cat > "$REPORT" <<EOF
# No Mistake report
Status: UNAVAILABLE
Reason: no-mistakes binary not on PATH
Policy: do not pretend the gate ran.
EOF
  "$REG" set "$TID" --field "no_mistake=unavailable"
  echo "no-mistakes unavailable" >&2
  exit 3
fi

if [ -z "$REPO" ]; then
  # try meta worktree
  META="$FM_HOME/state/$TID.meta"
  if [ -f "$META" ]; then
    REPO=$(awk -F= '/^worktree=/{print $2; exit}' "$META")
  fi
fi
[ -n "$REPO" ] || { echo "--repo-path required (or state meta worktree=)" >&2; exit 2; }
[ -d "$REPO" ] || { echo "repo path missing: $REPO" >&2; exit 2; }

if [ -z "$INTENT" ] && [ -f "$PKT/TASK.md" ]; then
  INTENT=$(head -n 40 "$PKT/TASK.md" | tr '\n' ' ')
fi
INTENT=${INTENT:-"Validate task $TID"}

# Collect adapter inputs into a sidecar for the report
{
  echo "# No Mistake adapter input"
  echo "- task: $TID"
  echo "- repo: $REPO"
  echo "- intent: $INTENT"
  echo "- acceptance: $PKT/ACCEPTANCE.md"
  echo "- changed files:"
  git -C "$REPO" diff --name-only HEAD~1..HEAD 2>/dev/null || git -C "$REPO" status --porcelain
} > "$PKT/NO-MISTAKE-INPUT.md"

if [ "$DRY" -eq 1 ]; then
  echo "dry-run: would run: no-mistakes axi run --intent ..."
  exit 0
fi

cd "$REPO"
set +e
OUT=$(no-mistakes axi run --intent "$INTENT" 2>&1)
RC=$?
set -e

{
  echo "# No Mistake report"
  echo "Status: $( [ $RC -eq 0 ] && echo PASS || echo FAIL_OR_GATE )"
  echo "Exit: $RC"
  echo
  echo '```'
  printf '%s\n' "$OUT" | head -n 200
  echo '```'
  echo
  echo "## Severity policy"
  echo "- Critical: block completion"
  echo "- High: block unless proven false with evidence"
  echo "- Medium: fix or explicitly document"
  echo "- Low: record"
  echo "- Unverified acceptance criteria: task incomplete"
} > "$REPORT"

"$REG" set "$TID" --field "no_mistake=$REPORT"
"$FM_HOME/bin/fm-phase2-event.sh" no_mistake_completed --task "$TID" --dedupe "nm-$TID-$RC" \
  --payload "{\"exit\":$RC,\"report\":\"$REPORT\"}"

# Heuristic: critical/high language in output without success → keep incomplete
if [ $RC -ne 0 ]; then
  "$REG" transition "$TID" changes_requested --reason "no_mistake_gate" || true
  exit "$RC"
fi
exit 0
