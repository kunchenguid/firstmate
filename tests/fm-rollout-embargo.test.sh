#!/usr/bin/env bash
# Tests for bin/fm-rollout-embargo.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ER="$ROOT/bin/fm-rollout-embargo.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state"

run_er() { FM_HOME="$HOME_DIR" "$ER" "$@"; }

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# --- generation is write-once ---
run_er set-generation cutover-1 >/dev/null || fail "set generation failed"
run_er set-generation cutover-1 >/dev/null || fail "idempotent set generation failed"
run_er set-generation cutover-2 2>/dev/null && fail "generation overwrite allowed"
pass "generation is write-once"

# --- permit/forbid/check ---
run_er permit firstmate-cutover >/dev/null || fail "permit failed"
run_er permit dotfiles-support >/dev/null || fail "permit support failed"
run_er forbid hotsites-resume >/dev/null || fail "forbid failed"
out=$(run_er status)
echo "$out" | grep -q "firstmate-cutover" || fail "status missing firstmate-cutover"
echo "$out" | grep -q "dotfiles-support" || fail "status missing dotfiles-support"
echo "$out" | grep -q "hotsites-resume" || fail "status missing hotsites-resume"
run_er check firstmate-cutover >/dev/null || fail "check permitted failed"
run_er check hotsites-resume 2>/dev/null && fail "check allowed forbidden task"
pass "permit/forbid/check enforce embargo lists"

pass "all fm-rollout-embargo tests passed"
