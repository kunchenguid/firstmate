#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/fm-stall-check.sh"
GUARD="$ROOT/bin/fm-guard.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-stall-check-tests.XXXXXX")

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/data" "$fakebin"
  touch "$dir/state/.last-watcher-beat"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    target=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-t" ]; then
        target=$arg
        break
      fi
      prev=$arg
    done
    if [ -n "${FM_FAKE_TMUX_CAPTURE_DIR:-}" ] && [ -n "$target" ] && [ -f "$FM_FAKE_TMUX_CAPTURE_DIR/$target" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE_DIR/$target"
      exit 0
    fi
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

run_check() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" \
  FM_FAKE_TMUX_CAPTURE="${FM_FAKE_TMUX_CAPTURE:-}" \
  FM_FAKE_TMUX_CAPTURE_DIR="${FM_FAKE_TMUX_CAPTURE_DIR:-}" \
  FM_HOME="$dir" \
  FM_STALL_IDLE_SECS="${FM_STALL_IDLE_SECS:-600}" \
  FM_ADVISOR_IDLE_STALL_SECS="${FM_ADVISOR_IDLE_STALL_SECS:-1800}" \
    "$CHECK"
}

test_finished_but_not_advanced() {
  local dir out
  dir=$(make_case finished)
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight
- **ship-fix-a1** - fix the thing (repo: firstmate, since 2026-07-07)

## Queued

## Done
EOF
  printf '%s\n' 'working: tests' 'done: ready for validation' > "$dir/state/ship-fix-a1.status"

  out=$(run_check "$dir") || fail "finished check exited non-zero"
  printf '%s\n' "$out" | grep -F 'advance: ship-fix-a1 - done but still in-flight; next leg not triggered' >/dev/null \
    || fail "finished-but-not-advanced finding missing: $out"
  pass "detects terminal status still listed in In flight"
}

test_unblocked_parked_item() {
  local dir out
  dir=$(make_case unblocked)
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] next-leg-b2 - continue feature (repo: firstmate) blocked-by: base-task-a1 - waits for base

## Done
- [x] base-task-a1 - base work - https://github.com/lndshk/firstmate/pull/1 (merged 2026-07-07)
EOF

  out=$(run_check "$dir") || fail "unblocked check exited non-zero"
  printf '%s\n' "$out" | grep -F 'ready: next-leg-b2 - blocker base-task-a1 is done; dispatchable' >/dev/null \
    || fail "unblocked finding missing: $out"
  pass "detects queued blocked-by item whose blocker is Done"
}

test_unblocked_item_blocker_in_archive() {
  local dir out
  dir=$(make_case unblocked_archive)
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] next-leg-b3 - continue feature (repo: firstmate) blocked-by: old-base-a2 - waits for base

## Done
- [x] recent-z1 - unrelated recent work - https://github.com/lndshk/firstmate/pull/20 (merged 2026-07-07)
EOF
  cat > "$dir/data/done-archive.md" <<'EOF'
## Done
- [x] old-base-a2 - base work pruned long ago - https://github.com/lndshk/firstmate/pull/2 (merged 2026-06-01)
EOF

  out=$(run_check "$dir") || fail "archived-blocker check exited non-zero"
  printf '%s\n' "$out" | grep -F 'ready: next-leg-b3 - blocker old-base-a2 is done; dispatchable' >/dev/null \
    || fail "archived-blocker finding missing: $out"
  pass "detects queued item whose blocker was pruned to the done archive"
}

test_date_gate_ready() {
  local dir out
  dir=$(make_case dategate)
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] remind-c3 - run scheduled sweep (repo: firstmate) [REMIND 2000-01-01]

## Done
EOF

  out=$(run_check "$dir") || fail "date gate check exited non-zero"
  printf '%s\n' "$out" | grep -F 'ready: remind-c3 - date gate 2000-01-01 reached' >/dev/null \
    || fail "date-gate finding missing: $out"
  pass "detects queued date gate whose date has arrived"
}

test_idle_stall_candidate() {
  local dir out capture
  dir=$(make_case idle)
  capture="$dir/capture.txt"
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight
- [ ] idle-d4 - appears parked (repo: firstmate)

## Queued

## Done
EOF
  cat > "$dir/state/idle-d4.meta" <<'EOF'
window=fm-idle-d4
kind=ship
EOF
  printf '%s\n' 'working: started' > "$dir/state/idle-d4.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/idle-d4.status" 2>/dev/null || touch -t 200001010000 "$dir/state/idle-d4.status"
  printf '%s\n' 'all quiet' '> ' > "$capture"

  FM_FAKE_TMUX_CAPTURE="$capture" out=$(run_check "$dir") || fail "idle check exited non-zero"
  printf '%s\n' "$out" | grep -E 'stall\?: idle-d4 - idle [0-9]+s, no status advance' >/dev/null \
    || fail "idle-stall finding missing: $out"
  pass "detects old non-busy in-flight pane as idle-stall candidate"
}

test_silent_when_clear_and_secondmate_skip() {
  local dir out capture
  dir=$(make_case clear)
  capture="$dir/capture.txt"
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight
- [ ] active-e5 - still running (repo: firstmate)
- [ ] secondmate-s1 - domain supervisor (repo: firstmate)

## Queued
- [ ] future-f6 - later (repo: firstmate) [REMIND 2999-01-01]
- [ ] blocked-g7 - waits (repo: firstmate) blocked-by: open-h8 - reason

## Done
- [x] unrelated-z9 - done (reported 2026-07-07)
EOF
  cat > "$dir/state/active-e5.meta" <<'EOF'
window=fm-active-e5
kind=ship
EOF
  printf '%s\n' 'working: still busy' > "$dir/state/active-e5.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/active-e5.status" 2>/dev/null || touch -t 200001010000 "$dir/state/active-e5.status"
  cat > "$dir/state/secondmate-s1.meta" <<'EOF'
window=fm-secondmate-s1
kind=secondmate
EOF
  printf '%s\n' 'working: watching' > "$dir/state/secondmate-s1.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/secondmate-s1.status" 2>/dev/null || touch -t 200001010000 "$dir/state/secondmate-s1.status"
  printf '%s\n' '• Working (10s • esc to interrupt)' > "$capture"

  FM_FAKE_TMUX_CAPTURE="$capture" out=$(run_check "$dir") || fail "clear check exited non-zero"
  [ -z "$out" ] || fail "expected silence when clear, got: $out"
  pass "stays silent when only busy, future, blocked, or secondmate work exists"
}

test_pr_ready_task_not_flagged() {
  local dir out capture
  dir=$(make_case prready)
  capture="$dir/capture.txt"
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight
- [ ] pr-ready-p1 - awaiting captain merge (repo: firstmate)

## Queued

## Done
EOF
  cat > "$dir/state/pr-ready-p1.meta" <<'EOF'
window=fm-pr-ready-p1
kind=ship
pr=https://github.com/lndshk/firstmate/pull/9
EOF
  printf '%s\n' 'done: PR https://github.com/lndshk/firstmate/pull/9 checks green' > "$dir/state/pr-ready-p1.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/pr-ready-p1.status" 2>/dev/null || touch -t 200001010000 "$dir/state/pr-ready-p1.status"
  printf '%s\n' 'all quiet' '> ' > "$capture"

  FM_FAKE_TMUX_CAPTURE="$capture" out=$(run_check "$dir") || fail "pr-ready check exited non-zero"
  [ -z "$out" ] || fail "expected silence for PR-ready parked task, got: $out"
  pass "does not flag a task parked awaiting captain merge (pr= in meta)"
}

test_advisor_idle_terminal_no_children_flagged() {
  local dir out capture home
  dir=$(make_case advisor_idle)
  capture="$dir/capture.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  cat > "$dir/state/learn-advisor.meta" <<EOF
window=fm-learn-advisor
kind=secondmate
EOF
  cat > "$dir/data/secondmates.md" <<EOF
- learn-advisor - learning domain advisor (home: $home; scope: learning program; projects: firstmate; added 2026-07-07)
EOF
  printf '%s\n' 'working: routed task' 'done: route next program step' > "$dir/state/learn-advisor.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/learn-advisor.status" 2>/dev/null || touch -t 200001010000 "$dir/state/learn-advisor.status"
  printf '%s\n' 'all quiet' '> ' > "$capture"

  FM_FAKE_TMUX_CAPTURE="$capture" out=$(run_check "$dir") || fail "advisor idle check exited non-zero"
  printf '%s\n' "$out" | grep -E 'advisor-idle\?: learn-advisor - idle [0-9]+s, no active child work, route its next program step or confirm intentionally parked' >/dev/null \
    || fail "advisor idle finding missing: $out"
  pass "detects idle terminal advisor with no child work"
}

test_advisor_needs_decision_not_flagged() {
  local dir out capture home
  dir=$(make_case advisor_needs_decision)
  capture="$dir/capture.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  cat > "$dir/state/rt-advisor.meta" <<EOF
window=fm-rt-advisor
kind=secondmate
home=$home
EOF
  printf '%s\n' 'needs-decision: pick a routing option' > "$dir/state/rt-advisor.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/rt-advisor.status" 2>/dev/null || touch -t 200001010000 "$dir/state/rt-advisor.status"
  printf '%s\n' 'all quiet' '> ' > "$capture"

  FM_FAKE_TMUX_CAPTURE="$capture" out=$(run_check "$dir") || fail "advisor needs-decision check exited non-zero"
  [ -z "$out" ] || fail "expected silence for captain-gated advisor, got: $out"
  pass "does not flag advisor parked on needs-decision"
}

test_advisor_with_child_work_not_flagged() {
  local dir out capture capture_dir home
  dir=$(make_case advisor_child_work)
  capture="$dir/capture.txt"
  capture_dir="$dir/captures"
  home="$dir/advisor-home"
  mkdir -p "$home/state" "$capture_dir"
  cat > "$dir/state/strat-advisor.meta" <<EOF
window=fm-strat-advisor
kind=secondmate
home=$home
EOF
  printf '%s\n' 'done: routed work complete' > "$dir/state/strat-advisor.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/strat-advisor.status" 2>/dev/null || touch -t 200001010000 "$dir/state/strat-advisor.status"
  cat > "$home/state/child-a1.meta" <<'EOF'
window=fm-child-a1
kind=ship
EOF
  printf '%s\n' 'working: actively running child task' > "$home/state/child-a1.status"
  touch -d '2000-01-01 00:00:00' "$home/state/child-a1.status" 2>/dev/null || touch -t 200001010000 "$home/state/child-a1.status"
  printf '%s\n' 'all quiet' '> ' > "$capture"
  printf '%s\n' 'all quiet' '> ' > "$capture_dir/fm-strat-advisor"
  printf '%s\n' '• Working (10s • esc to interrupt)' > "$capture_dir/fm-child-a1"

  FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CAPTURE_DIR="$capture_dir" out=$(run_check "$dir") || fail "advisor child-work check exited non-zero"
  [ -z "$out" ] || fail "expected silence for advisor with child work, got: $out"
  pass "does not flag advisor with a busy child pane in its home"
}

test_advisor_with_terminal_idle_child_flagged() {
  local dir out capture home
  dir=$(make_case advisor_idle_terminal_child)
  capture="$dir/capture.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  cat > "$dir/state/learn-advisor.meta" <<EOF
window=fm-learn-advisor
kind=secondmate
home=$home
EOF
  printf '%s\n' 'done: routed work complete' > "$dir/state/learn-advisor.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/learn-advisor.status" 2>/dev/null || touch -t 200001010000 "$dir/state/learn-advisor.status"
  cat > "$home/state/learn-first-pass-r7.meta" <<'EOF'
window=fm-learn-first-pass-r7
kind=ship
EOF
  printf '%s\n' 'working: started' 'done: report written' > "$home/state/learn-first-pass-r7.status"
  touch -d '2000-01-01 00:00:00' "$home/state/learn-first-pass-r7.status" 2>/dev/null || touch -t 200001010000 "$home/state/learn-first-pass-r7.status"
  printf '%s\n' 'all quiet' '> ' > "$capture"

  FM_FAKE_TMUX_CAPTURE="$capture" out=$(run_check "$dir") || fail "advisor idle-terminal-child check exited non-zero"
  printf '%s\n' "$out" | grep -E 'advisor-idle\?: learn-advisor - idle [0-9]+s, no active child work, route its next program step or confirm intentionally parked' >/dev/null \
    || fail "advisor idle finding missing with terminal idle child: $out"
  pass "detects idle terminal advisor whose only child is terminal and idle"
}

test_advisor_busy_not_flagged() {
  local dir out capture home
  dir=$(make_case advisor_busy)
  capture="$dir/capture.txt"
  home="$dir/advisor-home"
  mkdir -p "$home/state"
  cat > "$dir/state/busy-advisor.meta" <<EOF
window=fm-busy-advisor
kind=secondmate
home=$home
EOF
  printf '%s\n' 'result: routed work complete' > "$dir/state/busy-advisor.status"
  touch -d '2000-01-01 00:00:00' "$dir/state/busy-advisor.status" 2>/dev/null || touch -t 200001010000 "$dir/state/busy-advisor.status"
  printf '%s\n' 'thinking' '• Working (10s • esc to interrupt)' > "$capture"

  FM_FAKE_TMUX_CAPTURE="$capture" out=$(run_check "$dir") || fail "advisor busy check exited non-zero"
  [ -z "$out" ] || fail "expected silence for busy advisor, got: $out"
  pass "does not flag advisor with a busy pane"
}

test_guard_surfaces_stall_pointer() {
  local dir err
  dir=$(make_case guard)
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight
- [ ] guard-i9 - done but parked (repo: firstmate)

## Queued

## Done
EOF
  cat > "$dir/state/guard-i9.meta" <<'EOF'
window=fm-guard-i9
kind=ship
EOF
  printf '%s\n' 'done: ready' > "$dir/state/guard-i9.status"

  err=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$GUARD" 2>&1 >/dev/null) || fail "guard exited non-zero"
  printf '%s\n' "$err" | grep -F 'WARNING: stall detector has findings - run bin/fm-stall-check.sh and act on each line.' >/dev/null \
    || fail "guard stall pointer missing: $err"
  pass "fm-guard surfaces a stall-check pointer"
}

test_finished_but_not_advanced
test_unblocked_parked_item
test_unblocked_item_blocker_in_archive
test_date_gate_ready
test_idle_stall_candidate
test_silent_when_clear_and_secondmate_skip
test_pr_ready_task_not_flagged
test_advisor_idle_terminal_no_children_flagged
test_advisor_needs_decision_not_flagged
test_advisor_with_child_work_not_flagged
test_advisor_with_terminal_idle_child_flagged
test_advisor_busy_not_flagged
test_guard_surfaces_stall_pointer
