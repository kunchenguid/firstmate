#!/usr/bin/env bash
# tests/fm-project-register.test.sh - the registration gate (gflow-02): a project
# cannot be registered without declaring a production branch. Refuses fail-closed
# with no write when --production is missing; on success writes an entry that
# carries the (home, repo)-scoped branch fields fm-project-mode.sh --branches
# reads back.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-register)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"
REG="$DATA/projects.md"

reg() { FM_DATA_OVERRIDE="$DATA" "$ROOT/bin/fm-project-register.sh" "$@"; }
branches() { FM_DATA_OVERRIDE="$DATA" "$ROOT/bin/fm-project-mode.sh" --branches "$@" 2>/dev/null; }
mode() { FM_DATA_OVERRIDE="$DATA" "$ROOT/bin/fm-project-mode.sh" "$@" 2>/dev/null; }

# --- Refusal: no --production -> exit non-zero, nothing written. ---
out=$(reg --mode direct-PR alpha "some project" 2>&1) && fail "registration without --production should refuse"
assert_contains "$out" "production" "refusal message should name the missing production branch"
[ ! -f "$REG" ] && : # no registry created is fine; if created it must not carry alpha
if [ -f "$REG" ]; then
  grep -qE '^- alpha ' "$REG" && fail "refused registration must not write a partial entry"
fi

# Empty production value is also refused.
reg --production "" --mode direct-PR alpha "x" >/dev/null 2>&1 && fail "empty --production should refuse"

# --- Success: production only. ---
reg --production main --mode local-only alpha "the alpha project" >/dev/null || fail "valid registration should succeed"
[ "$(branches alpha)" = "main " ] || fail "alpha should register production=main, empty staging, got '$(branches alpha)'"
[ "$(mode alpha)" = "local-only off" ] || fail "alpha mode should be local-only off"

# --- Success: production + staging + yolo. ---
reg --production master --staging release --mode no-mistakes --yolo beta "the beta project" >/dev/null || fail "prod+staging+yolo registration should succeed"
[ "$(branches beta)" = "master release" ] || fail "beta should be master/release, got '$(branches beta)'"
[ "$(mode beta)" = "no-mistakes on" ] || fail "beta mode should be no-mistakes on"

# --- Default mode is no-mistakes when --mode omitted. ---
reg --production main gamma "gamma project" >/dev/null || fail "default-mode registration should succeed"
[ "$(mode gamma)" = "no-mistakes off" ] || fail "gamma default mode should be no-mistakes off"
[ "$(branches gamma)" = "main " ] || fail "gamma should be production=main"

# --- Duplicate name is refused (no second conflicting entry). ---
reg --production dev alpha "dup" >/dev/null 2>&1 && fail "duplicate registration should refuse"
[ "$(grep -cE '^- alpha ' "$REG")" -eq 1 ] || fail "duplicate refusal must leave exactly one alpha entry"

# --- Branch tokens with whitespace/brackets are rejected (parser safety). ---
reg --production "bad branch" delta "d" >/dev/null 2>&1 && fail "whitespace in branch should refuse"
reg --production "ok" "bad name" "d" >/dev/null 2>&1 && fail "whitespace in name should refuse"

pass "registration refuses without --production (fail-closed, no partial write) and otherwise records branch fields fm-project-mode.sh --branches reads"
echo "ALL TESTS PASSED"
