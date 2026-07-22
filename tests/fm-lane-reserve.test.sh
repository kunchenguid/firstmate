#!/usr/bin/env bash
# Tests for bin/fm-lane-reserve.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LR="$ROOT/bin/fm-lane-reserve.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state"

run_lr() { FM_HOME="$HOME_DIR" FM_LANE_OWNER=tester "$LR" "$@"; }

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# --- primary acquire/refuse second primary ---
run_lr acquire primary firstmate-cutover >/dev/null || fail "primary acquire failed"
run_lr acquire primary another-task 2>/dev/null && fail "second primary allowed"
pass "only one primary lease is allowed"

# --- support requires linked primary ---
run_lr acquire support dotfiles-support --supports nonexistent 2>/dev/null && fail "support allowed without valid primary"
run_lr acquire support dotfiles-support --supports firstmate-cutover >/dev/null || fail "valid support acquire failed"
pass "support lease links to an existing primary"

# --- release and status ---
out=$(run_lr status)
echo "$out" | grep -q "primary firstmate-cutover" || fail "status missing primary"
echo "$out" | grep -q "support dotfiles-support" || fail "status missing support"
run_lr release firstmate-cutover >/dev/null || fail "release failed"
run_lr release dotfiles-support >/dev/null || fail "support release failed"
out=$(run_lr status)
echo "$out" | grep -q "no active leases" || fail "leases still active after release"
pass "release clears leases and status reflects it"

# --- renew and stale reconciliation ---
run_lr acquire primary firstmate-cutover >/dev/null || fail "re-acquire failed"
run_lr renew firstmate-cutover >/dev/null || fail "renew failed"
# Simulate stale owner by editing owner to a fake dead value.
python3 -c "import json,sys; d=json.load(sys.stdin); d['owner']='dead-owner'; print(json.dumps(d))" < "$HOME_DIR/state/.delivery-leases/firstmate-cutover.json" > "$TMP/stale.json"
mv "$TMP/stale.json" "$HOME_DIR/state/.delivery-leases/firstmate-cutover.json"
run_lr reconcile >/dev/null || fail "reconcile failed"
[ ! -f "$HOME_DIR/state/.delivery-leases/firstmate-cutover.json" ] || fail "stale lease not removed"
pass "stale-owner reconciliation removes dead leases"

pass "all fm-lane-reserve tests passed"
