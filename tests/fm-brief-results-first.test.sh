#!/usr/bin/env bash
# Results-first brief contract tests for bin/fm-brief.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIEF="$ROOT/bin/fm-brief.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data/testtask" "$HOME_DIR/state"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
- firstmate [direct-PR +yolo] - Firstmate/OMX (added 2026-07-22)
- dotfiles [local-only] - machine config (added 2026-07-22)
- legacy [no-mistakes] - old path (added 2026-07-22)
EOF

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

run_brief() { FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$BRIEF" "$@"; }

# --- direct-PR brief includes results-first path ---
run_brief testtask firstmate >/dev/null || fail "direct-PR brief failed"
grep -q "validated delivery receipt" "$HOME_DIR/data/testtask/brief.md" || fail "direct-PR brief missing receipt DOD"
grep -q "fm-evidence-run.sh" "$HOME_DIR/data/testtask/brief.md" || fail "direct-PR brief missing evidence runner"
grep -q "fm-delivery-phase.sh" "$HOME_DIR/data/testtask/brief.md" || fail "direct-PR brief missing phase tool"
rm "$HOME_DIR/data/testtask/brief.md"
pass "direct-PR brief includes results-first tools"

# --- local-only brief includes results-first path ---
run_brief testtask dotfiles >/dev/null || fail "local-only brief failed"
grep -q "validated delivery receipt" "$HOME_DIR/data/testtask/brief.md" || fail "local-only brief missing receipt DOD"
grep -q "data/testtask/delivery-receipt.json" "$HOME_DIR/data/testtask/brief.md" || fail "local-only brief missing receipt path"
rm "$HOME_DIR/data/testtask/brief.md"
pass "local-only brief includes results-first path"

# --- no-mistakes brief mentions receipt after legacy run ---
run_brief testtask legacy >/dev/null || fail "no-mistakes brief failed"
grep -q "validated delivery receipt" "$HOME_DIR/data/testtask/brief.md" || fail "no-mistakes brief missing receipt DOD"
rm "$HOME_DIR/data/testtask/brief.md"
pass "no-mistakes brief mentions results-first receipt"

pass "all fm-brief-results-first tests passed"
