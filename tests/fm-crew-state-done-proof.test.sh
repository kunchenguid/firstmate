#!/usr/bin/env bash
# Behavior tests for the delivery-proof wiring in bin/fm-crew-state.sh - a done
# claim read from the status log is a self-report, so the status-log fallback
# must prove it against the recorded delivery contract before reporting it as
# terminal current state. Refuted claims read blocked with the concrete absence;
# unverified probes keep today's behavior; delivered and modeless tasks are
# unchanged. Portable regression over real throwaway git repos, a bare origin,
# and a recording fake `gh`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state-done-proof)
fm_git_identity fmtest fmtest@example.invalid

make_fakebin() {  # <dir>
  local dir=$1
  local fb="$dir/fakebin"
  mkdir -p "$fb"
  # An empty axi answer means "no run for this branch" without ever reaching a
  # real no-mistakes install that might happen to sit on the host.
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    # An UNREADABLE inventory (not "missing") keeps the process-evidence read
    # ambiguous so the case falls through to the semantic busy verdict, the
    # same convention tests/fm-crew-state.test.sh uses for legacy paths.
    printf 'fake inventory unavailable\n'; exit 1 ;;
  display-message)
    case "$*" in *pane_tty*) exit 1 ;; esac
    printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?GH_STUB_LOG unset}"
if [ -n "${GH_STUB_FAIL:-}" ]; then exit 1; fi
printf '%s\n' "${GH_STUB_OUT:-[]}"
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh"
  printf '%s\n' "$fb"
}

run_crew_state() {  # <case-dir>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" t1
}

# Real repo + published default + worktree on fm/t1 at the base commit, meta
# with kind=ship and the requested mode, an idle-pane busy record, and a done
# status log - the exact shape of a worker that stopped after claiming done.
make_done_case() {  # <name> <mode>
  local name=$1 mode=$2 dir base gen
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_fakebin "$dir" >/dev/null
  fm_git_worktree "$dir/project" "$dir/wt" "fm/t1"
  base=$(git -C "$dir/project" symbolic-ref --quiet --short HEAD)
  git -C "$dir/project" push -q origin "$base"
  git -C "$dir/project" fetch -q origin
  fm_write_meta "$dir/state/t1.meta" \
    "window=fake:fm-t1" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=$mode" \
    "yolo=off"
  printf 'working: started\n' >> "$dir/state/t1.status"
  printf 'done: angeblich fertig\n' >> "$dir/state/t1.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" t1)
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" t1 idle --gen "$gen" \
    --source claude-hook --event stop >/dev/null
  printf '%s\n' "$dir"
}

# Exports live in the test bodies, not in make_done_case: a function run
# through a command substitution is a subshell, and its exports would die
# there instead of reaching the crew-state child.
stub_env() {  # <case-dir>
  export GH_STUB_LOG="$1/gh.log" GH_STUB_OUT='[]'
}

test_refuted_done_reads_blocked_not_terminal() {
  local d out
  d=$(make_done_case refuted no-mistakes)
  stub_env "$d"
  out=$(run_crew_state "$d")
  assert_contains "$out" "state: blocked" "a refuted claim is not terminal"
  assert_contains "$out" "source: status-log" "the verdict still names its source"
  assert_contains "$out" "done widerlegt - keine Lieferung am Ziel (ls-remote leer, kein PR)" \
    "the blocked detail carries the concrete absence"
  pass "status-log done without delivery reads blocked with the evidence"
}

test_delivered_done_still_reads_done() {
  local d out
  d=$(make_done_case delivered direct-PR)
  stub_env "$d"
  git -C "$d/wt" commit -q --allow-empty -m "the fix"
  git -C "$d/wt" push -q origin fm/t1
  out=$(run_crew_state "$d")
  assert_contains "$out" "state: done" "delivered work stays terminal done"
  assert_contains "$out" "source: status-log" "delivered path keeps the status-log source"
  pass "status-log done backed by an origin branch still reads done"
}

test_unverified_probe_keeps_done() {
  local d out
  d=$(make_done_case offline no-mistakes)
  stub_env "$d"
  git -C "$d/wt" remote set-url origin /nonexistent/broken-origin.git
  out=$(run_crew_state "$d")
  assert_contains "$out" "state: done" "an unanswered probe is never evidence of absence"
  pass "a failed ls-remote keeps today's done behavior"
}

test_local_only_empty_branch_reads_blocked_committed_reads_done() {
  local d out
  d=$(make_done_case local-empty local-only)
  stub_env "$d"
  out=$(run_crew_state "$d")
  assert_contains "$out" "state: blocked" "empty local-only branch is not terminal"
  assert_contains "$out" "leerer Zweig fm/t1 im Worktree" "the empty branch is named"

  git -C "$d/wt" commit -q --allow-empty -m "the fix"
  out=$(run_crew_state "$d")
  assert_contains "$out" "state: done" "committed local-only branch delivers again"
  pass "local-only current state follows the committed-work rule both ways"
}

test_modeless_task_is_unchanged() {
  local d out
  d=$(make_done_case legacy "")
  stub_env "$d"
  sed -i '/^mode=/d' "$d/state/t1.meta"
  out=$(run_crew_state "$d")
  assert_contains "$out" "state: done" "a task without a recorded mode keeps today's behavior"
  pass "metas predating recorded modes skip the probe entirely"
}

test_main() {
  test_refuted_done_reads_blocked_not_terminal
  test_delivered_done_still_reads_done
  test_unverified_probe_keeps_done
  test_local_only_empty_branch_reads_blocked_committed_reads_done
  test_modeless_task_is_unchanged
}

test_main
echo "all fm-crew-state-done-proof tests passed"
