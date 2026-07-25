#!/usr/bin/env bash
# Scaffold a durable task packet under data/<task-id>/packet/.
# Usage: fm-phase2-packet.sh <task-id> [--title "..."] [--objective "..."]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ID="${1:?task-id required}"
shift || true
TITLE="$ID"
OBJECTIVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:?}"; shift 2 ;;
    --objective) OBJECTIVE="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

PKT="$FM_HOME/data/$ID/packet"
mkdir -p "$PKT"

cat > "$PKT/TASK.md" <<EOF
# Task: $TITLE

## Objective
${OBJECTIVE:-TBD}

## Non-goals
- Unrelated refactors
- Production deploys
- Live Stripe/Gelato actions

## Dependencies
(see STATE.json and programme registry)

## Stop conditions
- Acceptance criteria unmet
- Secret or production boundary crossed
- Third consecutive worker failure
EOF

cat > "$PKT/CONTEXT.md" <<EOF
# Context
Populate with only the files, APIs, and constraints needed for this task.
Do not load the full Epic Northscapes programme.
EOF

cat > "$PKT/ACCEPTANCE.md" <<EOF
# Acceptance criteria

- [ ] AC-001: TBD
- [ ] AC-002: TBD
EOF

cat > "$PKT/FILE-OWNERSHIP.md" <<EOF
# File ownership

## Allowed
- (paths or globs)

## Prohibited
- .env
- production secrets
- unrelated repositories
- Docker socket access
EOF

cat > "$PKT/TEST-PLAN.md" <<EOF
# Test plan

1. Focused unit/integration tests for changed behaviour
2. Lint / typecheck as applicable
3. Browser evidence if UI-facing
EOF

cat > "$PKT/RESULT.md" <<EOF
# Result
Status: NOT STARTED

## Summary
(worker fills)

## Commits
(worker fills)

## Evidence
(worker fills)
EOF

cat > "$PKT/REVIEW.md" <<EOF
# Independent review
Status: NOT STARTED

| Criterion | Verdict | Notes |
|-----------|---------|-------|
| AC-001 | NOT TESTED | |
EOF

cat > "$PKT/STATE.json" <<EOF
{
  "task_id": "$ID",
  "title": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TITLE"),
  "status": "planned",
  "updated_at": "$(date -Is)"
}
EOF

echo "packet: $PKT"
