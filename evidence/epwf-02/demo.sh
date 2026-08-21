#!/usr/bin/env bash
# evidence/epwf-02/demo.sh - hermetic proof of the epwf-02 plan-workflow: the
# epic-story dispatch brief carries the refresh/commit/gate/promote/escalate
# contract, and a worker's committed task-time plan promotes over the canonical
# design-time draft so a downstream story reads the fresh, HEAD-bound plan.
#
# Everything runs in a throwaway home under $TMPDIR; nothing here touches a real
# project. Regenerate transcript.txt with:  evidence/epwf-02/demo.sh
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/epwf-02-demo.XXXXXX")"
trap 'rm -rf "$HOME_DIR"' EXIT
EPIC="$HOME_DIR/data/plans/260101-epic-demo"

say() { printf '\n=== %s ===\n' "$*"; }

# --- fixture epic: svc-01 (gate, STALE upfront plan) + svc-02 (downstream) -----
mkdir -p "$EPIC/stories/svc-01-plan" "$HOME_DIR/projects/svc/plans/svc-01-plan"
cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects
- svc [direct-PR production=main] - fixture repo (added 260101)
EOF
cat > "$EPIC/epic.md" <<'EOF'
---
epic: demo
title: Demo epic
repos: [svc]
signed_off: 2026-01-02
status: active
---
# Epic demo
EOF
cat > "$EPIC/stories/svc-01.md" <<'EOF'
---
id: svc-01
epic: demo
repo: svc
pr_base: main
depends: []
kind: ship
gate: true
---
# Story svc-01

## Implementation plan
_Pointer: `stories/svc-01-plan/`._
EOF
printf 'STALE design-time draft, anchored to an old HEAD (Button importers: 35)\n' \
  > "$EPIC/stories/svc-01-plan/plan.md"
cat > "$EPIC/stories/svc-02.md" <<'EOF'
---
id: svc-02
epic: demo
repo: svc
pr_base: epic/demo
depends: [svc-01]
kind: ship
gate: false
---
# Story svc-02
EOF
# The worker's committed, plan-review-approved REFRESHED plan, in the clone.
cat > "$HOME_DIR/projects/svc/plans/svc-01-plan/plan.md" <<'EOF'
# svc-01 REFRESHED task-time plan
Re-bound to current HEAD; anchors re-verified (Button importers: 16, not 35).
EOF

# --- 1. the epic-story dispatch brief carries the plan workflow ----------------
say "1. epic ship brief (fm-brief.sh --base) carries the refresh/commit/gate contract"
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  "$ROOT/bin/fm-brief.sh" svc-01 svc --mode direct-PR --base epic/demo >/dev/null
sed -n '/# Epic plan workflow/,/^# Rules/p' "$HOME_DIR/data/svc-01/brief.md" | sed '/^# Rules/d'

# --- 2. before promotion: canonical holds the STALE draft ----------------------
say "2. BEFORE promotion - canonical plan is the stale design-time draft"
cat "$EPIC/stories/svc-01-plan/plan.md"

# --- 3. promote the worker's committed task-time plan into canonical -----------
say "3. promote the approved task-time plan (fm-epic-plan-promote.sh)"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-epic-plan-promote.sh" demo svc-01

# --- 4. after promotion: canonical holds the REFRESHED plan --------------------
say "4. AFTER promotion - canonical plan is the fresh HEAD-bound plan"
cat "$EPIC/stories/svc-01-plan/plan.md"

# --- 5. downstream dispatch reads a valid promoted plan: epic still lints green -
say "5. downstream story svc-02 (depends on svc-01) reads a green epic"
FM_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/fm-epic-lint.sh" "$EPIC"

# --- 6. an ordinary (non-epic) brief carries none of the plan workflow ---------
say "6. an ordinary brief (no --base) does NOT carry the epic plan workflow"
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  "$ROOT/bin/fm-brief.sh" ord-01 svc --mode direct-PR >/dev/null
if grep -q '# Epic plan workflow' "$HOME_DIR/data/ord-01/brief.md"; then
  echo "UNEXPECTED: ordinary brief carried the epic plan workflow"; exit 1
fi
echo "confirmed: ordinary brief has no '# Epic plan workflow' section"

say "demo complete - all epwf-02 Definition-of-done cases shown"
