#!/usr/bin/env bash
# tests/fm-backlog-next.test.sh - the durable queue-advance selector: pick the
# first SAFE, dependency-free Queued backlog item, skipping held/parked/captain-
# gated items and items whose blocked-by dependency has not landed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEXT="$ROOT/bin/fm-backlog-next.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-next-tests)

write_backlog() {  # <file> <<<content
  mkdir -p "$TMP_ROOT"
  cat > "$1"
}

test_picks_first_free_item() {
  local f; f="$TMP_ROOT/b1.md"
  write_backlog "$f" <<'EOF'
## In flight
- [ ] running-1 - a running ship (kind: ship)
## Queued
- [ ] parked-1 - a parked item (kind: ship) (hold: awaiting captain) (hold-kind: captain)
- [ ] blocked-1 - waits on the running ship (kind: ship) blocked-by: running-1 - after it
- [ ] free-1 - dependency-free and unheld (kind: ship)
## Done
- [x] old-done - finished earlier (kind: ship)
EOF
  local out rc
  out=$("$NEXT" "$f"); rc=$?
  expect_code 0 "$rc" "a safe item exists so the selector must succeed"
  [ "$out" = "free-1" ] || fail "expected free-1 (parked skipped, blocked skipped), got '$out'"
  pass "selector skips a held item and one blocked by in-flight work, picking the first free item"
}

test_dependency_cleared_by_done_is_dispatchable() {
  local f; f="$TMP_ROOT/b2.md"
  write_backlog "$f" <<'EOF'
## Queued
- [ ] after-done - runs once its blocker lands (kind: ship) blocked-by: old-done - cleared
## Done
- [x] old-done - finished (kind: ship)
EOF
  local out
  out=$("$NEXT" "$f") || fail "an item whose blocker is Done must be dispatchable"
  [ "$out" = "after-done" ] || fail "expected after-done (blocker is Done), got '$out'"
  pass "an item whose blocked-by dependency is already Done is dispatchable"
}

test_no_safe_item_exits_nonzero() {
  local f; f="$TMP_ROOT/b3.md"
  write_backlog "$f" <<'EOF'
## In flight
- [ ] running-1 - a running ship (kind: ship)
## Queued
- [ ] parked-1 - parked (kind: ship) (hold: re-scope) (hold-kind: parked)
- [ ] blocked-1 - waits on running (kind: ship) blocked-by: running-1 - later
## Done
EOF
  local out rc
  out=$("$NEXT" "$f"); rc=$?
  expect_code 1 "$rc" "no safe item means a non-zero exit"
  [ -z "$out" ] || fail "no safe item must print nothing, got '$out'"
  pass "when every queued item is held or blocked, the selector advances nothing (exit 1)"
}

test_captain_gated_item_is_never_autodispatched() {
  local f; f="$TMP_ROOT/b4.md"
  write_backlog "$f" <<'EOF'
## Queued
- [ ] decide-1 - needs a captain decision (kind: ship) (hold: awaiting captain decision) (hold-kind: captain)
- [ ] safe-1 - free (kind: ship)
EOF
  local out
  out=$("$NEXT" "$f") || fail "a free item exists after the gated one"
  [ "$out" = "safe-1" ] || fail "a captain-gated item must never be auto-dispatched, got '$out'"
  pass "a captain/decision-gated item is skipped so it stays escalated, not auto-dispatched"
}

test_missing_backlog_exits_nonzero() {
  local rc
  "$NEXT" "$TMP_ROOT/does-not-exist.md" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a missing backlog file must exit non-zero, not crash"
  pass "a missing backlog file exits non-zero without error"
}

test_picks_first_free_item
test_dependency_cleared_by_done_is_dispatchable
test_no_safe_item_exits_nonzero
test_captain_gated_item_is_never_autodispatched
test_missing_backlog_exits_nonzero
