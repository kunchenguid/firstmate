#!/usr/bin/env bash
# Tests for bin/fm-evidence-run.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EV="$ROOT/bin/fm-evidence-run.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data/t1"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# --- successful evidence run ---
out=$(FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 1 deterministic-local-validation '["printf","hello"]')
path=$(printf '%s\n' "$out" | head -1)
hash=$(printf '%s\n' "$out" | grep '^manifestSha256=' | cut -d= -f2-)
[ -d "$path" ] || fail "evidence dir not created: $path"
[ -f "$path/stdout.txt" ] || fail "stdout missing"
[ -f "$path/stderr.txt" ] || fail "stderr missing"
[ -f "$path/meta.json" ] || fail "meta.json missing"
[ -f "$path/MANIFEST.sha256" ] || fail "manifest missing"
[ "$(cat "$path/stdout.txt")" = "hello" ] || fail "stdout content mismatch"
[ "${#hash}" -eq 64 ] || fail "manifest hash length wrong"
pass "successful evidence run creates hashed write-once record"

# --- refuses overwrite ---
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 1 deterministic-local-validation '["true"]' 2>/dev/null && fail "overwrite allowed"
pass "evidence sequence refuses overwrite"

# --- failed command records exit code ---
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 2 deterministic-local-validation '["false"]' 2>/dev/null; code=$?
[ "$code" -ne 0 ] || fail "failed command should return non-zero"
[ -f "$HOME_DIR/data/t1/evidence/2-deterministic-local-validation/meta.json" ] || fail "meta missing for failed run"
grep -q '"exitCode": 1' "$HOME_DIR/data/t1/evidence/2-deterministic-local-validation/meta.json" || fail "exitCode not recorded as 1"
pass "failed command records non-zero exit code"

# --- volatile provider fields refused ---
FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EV" run t1 implementing 3 deterministic-local-validation '["printf","session_pct=50"]' 2>/dev/null && fail "volatile provider field allowed"
pass "volatile provider percentage fields are refused"

pass "all fm-evidence-run tests passed"
