#!/usr/bin/env bash
# Behavior tests for non-destructive fleet-record reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-record-reconcile)
DRAIN="$ROOT/bin/fm-wake-drain.sh"

append_status_wake() {  # <state-dir> <task-id>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_append signal "$2.status" "signal: $3/$2.status"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$2" "$1"
}

test_terminal_row_reconciles_while_unlanded_work_remains() {
  local home wt dirty_wt receipt head guard_root drain_out
  home="$TMP_ROOT/home"
  wt="$home/projects/sample-terminal"
  mkdir -p "$home/data" "$home/state" "$home/projects" "$wt"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] sample-terminal - Completed producer awaiting an independent gate (repo: sample) (kind: ship) (since 2026-07-31)
- [ ] captain-wait - Completed producer awaiting the captain (repo: sample) (kind: ship) (since 2026-07-31)
- [ ] dirty-terminal - Terminal event with uncommitted work (repo: sample) (kind: ship) (since 2026-07-31)
- [ ] missing-meta - Preserve a row whose endpoint metadata is missing (repo: sample) (kind: ship) (since 2026-07-31)

## Queued

## Done
EOF
  git -C "$wt" init -q
  git -C "$wt" config user.email test@example.com
  git -C "$wt" config user.name Test
  git -C "$wt" commit -q --allow-empty -m base
  git -C "$wt" checkout -q -b fm/sample-terminal
  git -C "$wt" commit -q --allow-empty -m 'unlanded completed work'
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$home/state/sample-terminal.meta" \
    'window=test:fm-sample-terminal' "worktree=$wt" 'project=sample' 'kind=ship' 'endpoint_task_id=sample-terminal'
  printf 'done: ready in branch fm/sample-terminal at %s\n' "$head" > "$home/state/sample-terminal.status"
  fm_write_meta "$home/state/captain-wait.meta" \
    'window=test:fm-captain-wait' "worktree=$wt" 'project=sample' 'kind=ship' 'endpoint_task_id=captain-wait'
  printf 'awaiting-captain [key=gate]: approve the independent gate result\n' > "$home/state/captain-wait.status"
  dirty_wt="$home/projects/dirty-terminal"
  mkdir -p "$dirty_wt"
  git -C "$dirty_wt" init -q
  git -C "$dirty_wt" config user.email test@example.com
  git -C "$dirty_wt" config user.name Test
  git -C "$dirty_wt" commit -q --allow-empty -m base
  printf 'uncommitted evidence\n' > "$dirty_wt/uncommitted.txt"
  fm_write_meta "$home/state/dirty-terminal.meta" \
    'window=test:fm-dirty-terminal' "worktree=$dirty_wt" 'project=sample' 'kind=ship' 'endpoint_task_id=dirty-terminal'
  printf 'done: reported too early\n' > "$home/state/dirty-terminal.status"
  fm_write_meta "$home/state/orphan-meta.meta" \
    'window=test:fm-orphan-meta' "worktree=$home/projects/orphan" 'project=sample' 'kind=ship'
  printf 'done: historical status with no metadata row\n' > "$home/state/orphan-status.status"

  guard_root="$home/guard-root"
  drain_out="$home/drain.out"
  mkdir -p "$guard_root"
  touch "$home/state/.last-watcher-beat"
  append_status_wake "$home/state" sample-terminal || fail "could not queue terminal status wake"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$guard_root" "$DRAIN" > "$drain_out" \
    || fail "terminal wake drain and record reconciliation failed"
  grep "$(printf '\tsignal\tsample-terminal.status\t')" "$drain_out" >/dev/null \
    || fail "terminal wake did not traverse the ordinary drain path"
  ! sed -n '/^## In flight/,/^## /p' "$home/data/backlog.md" | grep -F -- '- [ ] sample-terminal -' >/dev/null \
    || fail "terminal report still reads in flight"
  sed -n '/^## Done/,$p' "$home/data/backlog.md" | grep -F -- '- [x] sample-terminal -' >/dev/null \
    || fail "terminal report was not reconciled into Done"
  sed -n '/^## Done/,$p' "$home/data/backlog.md" | grep -F -- '- [x] captain-wait -' >/dev/null \
    || fail "complete awaiting-captain report was not reconciled into Done"
  grep -F -- '- [ ] dirty-terminal -' "$home/data/backlog.md" >/dev/null \
    || fail "dirty terminal row was retired despite uncommitted evidence"
  assert_present "$dirty_wt/uncommitted.txt" "reconciliation erased uncommitted evidence"
  assert_present "$home/state/sample-terminal.meta" "reconciliation erased retained task metadata"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || fail "reconciliation changed unlanded work"
  assert_absent "$wt/.git/refs/remotes/origin" "fixture unexpectedly gained a landing remote"
  grep -F -- '- [ ] missing-meta -' "$home/data/backlog.md" >/dev/null \
    || fail "reconciliation erased a row that proves missing metadata"
  assert_present "$home/state/orphan-meta.meta" "reconciliation erased orphan metadata evidence"
  receipt=$(find "$home/data/record-reconciliation" -type f -name '*.receipt' | head -1)
  assert_present "$receipt" "reconciliation wrote no durable inventory receipt"
  assert_grep $'terminal-retained\tsample-terminal' "$receipt" "receipt omitted the reconciled terminal row"
  assert_grep $'terminal-retained\tcaptain-wait' "$receipt" "receipt omitted the reconciled captain-wait row"
  assert_grep $'terminal-unreconciled\tdirty-terminal' "$receipt" "receipt omitted the dirty terminal refusal"
  assert_grep $'missing-meta\tmissing-meta' "$receipt" "receipt omitted metadata-count drift"
  assert_grep $'orphan-meta\torphan-meta' "$receipt" "receipt omitted the orphan metadata"
  assert_grep $'orphan-status\torphan-status' "$receipt" "receipt omitted the orphan status record"
  assert_grep 'in_flight_count=2' "$receipt" "receipt omitted the reconciled in-flight count"
  assert_grep 'metadata_count=4' "$receipt" "receipt omitted the retained metadata count"
  assert_grep 'metadata_minus_in_flight=2' "$receipt" "receipt omitted explicit metadata-count drift"
  pass "terminal row reconciles without cleaning unlanded work or erasing drift evidence"
}

test_terminal_row_reconciles_while_unlanded_work_remains
