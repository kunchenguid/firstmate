#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree with new content, landed   -> REFUSE (unique dirt wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#
# Stale-index shape (bin/fm-worktree-unique-content.sh consult): a branch ref
# rewritten beneath a live worktree leaves index and working tree at the
# pre-rewrite state, so plain dirtiness inverts - the "uncommitted changes" are
# deletions of landed content plus pre-merge line versions. The consult narrows
# the dirty refusal to worktrees actually holding unique content and can never
# widen what tears down.
#   (z1) stale index, all content reachable, commits pushed     -> ALLOW  (proxy fixed)
#   (z2) stale index + one genuinely new file                   -> REFUSE (safety intact)
#   (z3) stale index reachable but commits unlanded             -> REFUSE (landed check still runs)
#   (z4) local-only stale index, work merged into local main    -> ALLOW
#   (z5) classifier deleted from bin                            -> REFUSE (fail-closed fallback)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TELEMETRY="$ROOT/bin/fm-model-telemetry.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
mkdir -p "$TMP_ROOT/firstmate-home"
export FM_HOME="$TMP_ROOT/firstmate-home"
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# The post-check teardown steps are mocked; refuse logic exits before they run,
# while the allow cases need them so the script can complete cleanly.
write_default_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ] && [ "${2:-}" = --force ] && [ -n "${3:-}" ]; then
  rm -rf -- "$3"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# `treehouse return` fails for a reason that is not a git lock, so teardown
# aborts after it has already sealed the terminal - the state an operator is
# told to re-run from.
add_failing_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  echo "fatal: pool lease is held elsewhere" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin occupancy_bin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  occupancy_bin="$case_dir/occupancy-bin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin" "$occupancy_bin"

  cat > "$occupancy_bin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  jq -n --arg path "${FM_FAKE_TREEHOUSE_WORKTREE:?}" '[{
    name: "slot-task-x1",
    path: $path,
    status: "leased",
    lease_id: "lease-task-x1",
    lease_holder: "task-x1",
    leased_at: null,
    processes: []
  }]'
  exit 0
fi
if [ "${1:-}" = return ]; then
  shift
  args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --if-lease-id|--if-lease-holder) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  exec "${FM_FAKE_TREEHOUSE_DELEGATE:?}" return "${args[@]}"
fi
exec "${FM_FAKE_TREEHOUSE_DELEGATE:?}" "$@"
SH
  chmod +x "$occupancy_bin/treehouse"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  write_default_treehouse "$case_dir"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then
  printf '%s\n' "${FM_FAKE_TMUX_CAPTURE:-}"
fi
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), and `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set. This keeps every case hermetic - without it,
  # `command -v no-mistakes` would fall through to whatever real binary
  # happens to be on the test runner's own PATH. Tests exercising the run-abort
  # path override FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG before run_teardown.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# Optional per-invocation NM_HOME recording so a teardown safety test can prove
# which no-mistakes root the observer queried (finding 2). Additive: only writes
# when FM_FAKE_NM_HOME_LOG is set.
if [ -n "${FM_FAKE_NM_HOME_LOG:-}" ]; then
  printf '%s\t%s\n' "${NM_HOME:-}" "${1:-}" >> "$FM_FAKE_NM_HOME_LOG"
fi
case "${1:-}" in
  stats)
    printf '%s\n' "${FM_FAKE_NM_STATS:-}"
    ;;
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.2.4'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi hold <id> --reason <reason> [--kind captain]'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

setup_allow_local_teardown() {
  local name=$1 case_dir wt_head
  case_dir=$(make_case "$name")
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "completion reminder work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf '%s\n' "$case_dir"
}

write_backlog_repo_line() {
  local case_dir=$1 id=$2 repo=$3
  mkdir -p "$case_dir/data"
  printf '%s\n' "- [ ] $id - Completion reminder fixture (repo: $repo) (kind: ship)" \
    > "$case_dir/data/backlog.md"
}

add_unsealed_linked_kit_run_fixture() {
  local case_dir=$1
  local wt_path
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  mkdir -p "$case_dir/scratch/demo-run"
  printf '%s\n' "{\"schemaVersion\":\"1\",\"phase\":\"done\",\"worktree\":{\"path\":\"$wt_path\"}}" \
    > "$case_dir/scratch/demo-run/run.json"
}

add_sealed_linked_kit_run_fixture() {
  local case_dir=$1
  local wt_path
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  mkdir -p "$case_dir/scratch/demo-run"
  printf '%s\n' "{\"schemaVersion\":\"1\",\"phase\":\"done\",\"worktree\":{\"path\":\"$wt_path\"}}" \
    > "$case_dir/scratch/demo-run/run.json"
  printf '%s\n' '{"schemaVersion":"1","event":"shipped","timestamp":"2026-08-15T00:00:00Z"}' \
    > "$case_dir/scratch/demo-run/outcomes.jsonl"
}

spec_kit_scripts_dir() {
  printf '%s\n' "${FM_SPEC_KIT_SCRIPTS_DIR:-$ROOT/tests/fixtures/spec-kit-kit-seal}"
}

with_kit_teardown_env() {
  local case_dir=$1; shift
  FM_HOME="${FM_HOME:-$case_dir}" \
  FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-$case_dir/data}" \
  FM_KIT_SCRATCH_ROOT="$case_dir/scratch" \
  FM_SPEC_KIT_SCRIPTS_DIR="$(spec_kit_scripts_dir)" \
    run_teardown "$case_dir" "$@"
}

test_teardown_allows_when_no_linked_kit_run() {
  local case_dir out rc
  case_dir=$(setup_allow_local_teardown no-kit-run)
  add_compatible_tasks_axi "$case_dir"
  set +e
  out=$(with_kit_teardown_env "$case_dir" 2> "$case_dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "no-kit-run: teardown should succeed without a linked kit run"
  [ ! -d "$case_dir/wt" ] || fail "no-kit-run: realistic treehouse return left the worktree behind"
  pass "teardown allows cleanup when no linked kit run exists"
}

test_teardown_refuses_unsealed_linked_kit_run_before_return() {
  local case_dir rc stderr
  case_dir=$(setup_allow_local_teardown unsealed-kit-run)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  set +e
  with_kit_teardown_env "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")
  expect_code 1 "$rc" "unsealed-kit-run: teardown should refuse before return"
  grep -F 'unsealed-outcome' "$case_dir/stderr" >/dev/null \
    || fail "unsealed-kit-run: refusal did not name unsealed-outcome: $stderr"
  grep -F 'reconcile_run_outcome.py' "$case_dir/stderr" >/dev/null \
    || fail "unsealed-kit-run: refusal did not name reconcile_run_outcome.py: $stderr"
  [ -d "$case_dir/wt" ] || fail "unsealed-kit-run: refusal removed the worktree"
  pass "teardown refuses an unsealed linked kit run before destructive return"
}

test_teardown_kit_seal_refusal_precedes_telemetry_seal() {
  local case_dir rc stderr ledger terminal_count
  case_dir=$(setup_allow_local_teardown kit-before-telemetry)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  seed_teardown_telemetry "$case_dir" || fail "could not seed telemetry for kit-ordering test"
  set +e
  with_kit_teardown_env "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")
  expect_code 1 "$rc" "kit-before-telemetry: teardown should refuse on unsealed kit run"
  grep -F 'unsealed-outcome' "$case_dir/stderr" >/dev/null \
    || fail "kit-before-telemetry: refusal did not name unsealed-outcome: $stderr"
  grep -F 'model telemetry terminal seal refused' "$case_dir/stderr" >/dev/null \
    && fail "kit-before-telemetry: telemetry seal ran before kit refusal: $stderr"
  ledger="$case_dir/data/routing-outcomes.jsonl"
  if [ -f "$ledger" ]; then
    terminal_count=$(jq -s '[.[] | select(.eventType=="attempt-terminal")] | length' "$ledger")
    [ "$terminal_count" -eq 0 ] || fail "kit-before-telemetry: telemetry terminal seal wrote before kit refusal (count=$terminal_count)"
  fi
  [ -d "$case_dir/wt" ] || fail "kit-before-telemetry: refusal removed the worktree"
  pass "teardown kit-seal refusal runs before telemetry sealing"
}

test_teardown_force_bypasses_unsealed_kit_run_with_durable_record() {
  local case_dir rc force_log
  case_dir=$(setup_allow_local_teardown kit-force-bypass)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  mkdir -p "$case_dir/data"
  set +e
  with_kit_teardown_env "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "kit-force-bypass: --force should complete teardown"
  force_log="$case_dir/data/teardown-kit-seal-forces.jsonl"
  [ -f "$force_log" ] || fail "kit-force-bypass: durable bypass record missing"
  jq -e 'select(.task=="task-x1" and (.error|test("unsealed-outcome")))' "$force_log" >/dev/null \
    || fail "kit-force-bypass: bypass record did not capture task-x1 and unsealed-outcome"
  grep -F 'recorded in data/teardown-kit-seal-forces.jsonl' "$case_dir/stderr" >/dev/null \
    || fail "kit-force-bypass: stderr did not name the durable bypass record"
  [ ! -d "$case_dir/wt" ] || fail "kit-force-bypass: teardown did not return the worktree"
  pass "teardown --force bypasses unsealed kit seal with a durable record"
}

test_teardown_force_bypass_record_appends_to_existing_ledger() {
  local case_dir rc force_log rows
  case_dir=$(setup_allow_local_teardown kit-force-bypass-append)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  mkdir -p "$case_dir/data"
  force_log="$case_dir/data/teardown-kit-seal-forces.jsonl"
  printf '%s\n' '{"task":"task-prior","runDir":"prior-run","error":"prior bypass","forcedAt":"2026-08-01T00:00:00Z"}' \
    > "$force_log"
  set +e
  with_kit_teardown_env "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "kit-force-bypass-append: --force should complete teardown"
  rows=$(wc -l < "$force_log" | tr -d ' ')
  [ "$rows" = 2 ] || fail "kit-force-bypass-append: expected 2 ledger rows after the append, got $rows"
  jq -se 'any(.[]; .task=="task-prior")' "$force_log" >/dev/null \
    || fail "kit-force-bypass-append: the pre-existing bypass record was destroyed"
  jq -se 'any(.[]; .task=="task-x1")' "$force_log" >/dev/null \
    || fail "kit-force-bypass-append: the new bypass record was not appended"
  pass "teardown --force appends the bypass record without destroying prior rows"
}

test_teardown_force_refuses_when_bypass_record_unwritable() {
  local case_dir rc
  case_dir=$(setup_allow_local_teardown kit-force-bypass-log-blocked)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  mkdir -p "$case_dir/data"
  mkdir "$case_dir/data/teardown-kit-seal-forces.jsonl"
  set +e
  with_kit_teardown_env "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "kit-force-bypass-log-blocked: teardown should refuse when bypass record cannot be written"
  [ -d "$case_dir/wt" ] || fail "kit-force-bypass-log-blocked: worktree was removed despite failed bypass record"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "kit-force-bypass-log-blocked: task metadata was removed despite failed bypass record"
  grep -F 'teardown-kit-seal-forces.jsonl' "$case_dir/stderr" >/dev/null \
    || fail "kit-force-bypass-log-blocked: refusal did not name the bypass log path"
  grep -F 'recorded in data/teardown-kit-seal-forces.jsonl' "$case_dir/stderr" >/dev/null \
    && fail "kit-force-bypass-log-blocked: stderr falsely claimed the bypass was recorded"
  pass "teardown --force refuses when kit-seal bypass record cannot be written"
}

test_teardown_force_refuses_when_bypass_record_is_symlink() {
  local case_dir rc
  case_dir=$(setup_allow_local_teardown kit-force-bypass-log-symlink)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  mkdir -p "$case_dir/data"
  ln -s /dev/null "$case_dir/data/teardown-kit-seal-forces.jsonl"
  set +e
  with_kit_teardown_env "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "kit-force-bypass-log-symlink: teardown should refuse when the bypass record is a symlink"
  [ -d "$case_dir/wt" ] || fail "kit-force-bypass-log-symlink: worktree was removed though the bypass went unrecorded"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "kit-force-bypass-log-symlink: task metadata was removed though the bypass went unrecorded"
  grep -F 'teardown-kit-seal-forces.jsonl' "$case_dir/stderr" >/dev/null \
    || fail "kit-force-bypass-log-symlink: refusal did not name the bypass log path"
  grep -F 'recorded in data/teardown-kit-seal-forces.jsonl' "$case_dir/stderr" >/dev/null \
    && fail "kit-force-bypass-log-symlink: stderr falsely claimed the bypass was recorded"
  pass "teardown --force refuses when the kit-seal bypass record is a symlink"
}

test_teardown_reports_unrunnable_kit_seal_predicate() {
  local case_dir rc stderr scripts_dir
  case_dir=$(setup_allow_local_teardown kit-seal-predicate-unrunnable)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  add_compatible_tasks_axi "$case_dir"
  scripts_dir="$case_dir/kitscripts"
  mkdir -p "$scripts_dir"
  printf '%s\n' 'ENTRY_POINT_REMOVED = True' > "$scripts_dir/list_worktrees.py"
  set +e
  FM_SPEC_KIT_SCRIPTS_DIR="$scripts_dir" \
    with_kit_teardown_env "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")
  expect_code 0 "$rc" "kit-seal-predicate-unrunnable: teardown should continue when the predicate cannot run"
  grep -F 'linked-run outcome check could not run' "$case_dir/stderr" >/dev/null \
    || fail "kit-seal-predicate-unrunnable: teardown skipped the seal gate without warning: $stderr"
  grep -F 'has no _unsealed_linked_run entry point' "$case_dir/stderr" >/dev/null \
    || fail "kit-seal-predicate-unrunnable: predicate stderr was discarded: $stderr"
  pass "teardown reports when the kit-seal predicate cannot run"
}

test_teardown_kit_gate_ignores_host_scratch_root() {
  local case_dir rc wt_path stderr
  case_dir=$(setup_allow_local_teardown kit-host-scratch-isolation)
  add_compatible_tasks_axi "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  mkdir -p "$case_dir/home/.claude/scratch/poison-run"
  printf '%s\n' "{\"schemaVersion\":\"1\",\"phase\":\"done\",\"worktree\":{\"path\":\"$wt_path\"}}" \
    > "$case_dir/home/.claude/scratch/poison-run/run.json"
  set +e
  HOME="$case_dir/home" FM_SPEC_KIT_SCRIPTS_DIR="$(spec_kit_scripts_dir)" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")
  expect_code 0 "$rc" "kit-host-scratch-isolation: a teardown case that never opts into the kit gate must not read \$HOME/.claude/scratch"
  grep -F 'poison-run' "$case_dir/stderr" >/dev/null \
    && fail "kit-host-scratch-isolation: the gate scanned the host scratch root: $stderr"
  [ ! -d "$case_dir/wt" ] || fail "kit-host-scratch-isolation: teardown left the worktree behind"
  pass "teardown kit gate ignores the host scratch root for cases that do not opt in"
}

test_teardown_configured_kit_scripts_missing_refuses() {
  local case_dir rc stderr
  case_dir=$(setup_allow_local_teardown kit-scripts-missing)
  add_unsealed_linked_kit_run_fixture "$case_dir"
  set +e
  FM_SPEC_KIT_SCRIPTS_DIR=/nonexistent/spec-kit/scripts \
    FM_KIT_SCRATCH_ROOT="$case_dir/scratch" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")
  expect_code 1 "$rc" "kit-scripts-missing: configured missing scripts should refuse"
  grep -F 'configured kit seal scripts missing' "$case_dir/stderr" >/dev/null \
    || fail "kit-scripts-missing: refusal did not name missing configured scripts: $stderr"
  pass "teardown refuses when FM_SPEC_KIT_SCRIPTS_DIR points at missing scripts"
}

test_teardown_allows_sealed_linked_kit_run() {
  local case_dir out rc
  case_dir=$(setup_allow_local_teardown sealed-kit-run)
  add_sealed_linked_kit_run_fixture "$case_dir"
  add_compatible_tasks_axi "$case_dir"
  set +e
  out=$(with_kit_teardown_env "$case_dir" 2> "$case_dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "sealed-kit-run: teardown should succeed once the linked run is sealed"
  [ ! -d "$case_dir/wt" ] || fail "sealed-kit-run: realistic treehouse return left the worktree behind"
  pass "teardown allows cleanup when the linked kit run is sealed"
}

test_teardown_prints_retro_acceleration_before_return() {
  local case_dir out accel_line complete_line
  case_dir=$(setup_allow_local_teardown retro-acceleration)
  add_compatible_tasks_axi "$case_dir"
  out=$(with_kit_teardown_env "$case_dir") \
    || fail "teardown failed before retro acceleration prompt"
  printf '%s\n' "$out" | grep -F 'Retro acceleration:' >/dev/null \
    || fail "teardown did not print retro acceleration header: $out"
  printf '%s\n' "$out" | grep -F 'something we already own would have done' >/dev/null \
    || fail "teardown did not print the highest-yield retro question: $out"
  accel_line=$(printf '%s\n' "$out" | grep -n 'Retro acceleration:' | sed -n '1p' | cut -d: -f1)
  complete_line=$(printf '%s\n' "$out" | grep -n 'teardown task-x1 complete' | sed -n '1p' | cut -d: -f1)
  [ -n "$accel_line" ] && [ -n "$complete_line" ] && [ "$accel_line" -lt "$complete_line" ] \
    || fail "retro acceleration printed after teardown completion: $out"
  [ ! -d "$case_dir/wt" ] || fail "retro-acceleration ordering test left the worktree behind"
  pass "teardown prints retro acceleration before destructive return"
}

add_compatible_tasks_axi_with_ready() {
  local case_dir=$1 ready_row=$2
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '0.2.4'
  exit 0
fi
if [ "\${1:-}" = ready ]; then
  cat <<'OUT'
count: 1
ready: 1 unblocked queued tasks
ready[1]{id,state,kind,repo,title}:
  $ready_row
OUT
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

test_teardown_secondmate_seam_prompt_on_subject_change() {
  local case_dir out home
  case_dir=$(setup_allow_local_teardown secondmate-seam-change)
  home="$case_dir"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  write_backlog_repo_line "$case_dir" task-x1 alpha
  add_compatible_tasks_axi_with_ready "$case_dir" 'next-task,queued,ship,beta,Next subject'
  out=$(FM_HOME="$home" with_kit_teardown_env "$case_dir") \
    || fail "teardown failed for secondmate seam prompt"
  printf '%s\n' "$out" | grep -F 'Secondmate memory hygiene:' >/dev/null \
    || fail "teardown did not print secondmate seam prompt on subject change: $out"
  printf '%s\n' "$out" | grep -F 'Run /stow in this home' >/dev/null \
    || fail "teardown secondmate seam did not prompt /stow: $out"
  printf '%s\n' "$out" | grep -F 'next-task (beta)' >/dev/null \
    || fail "teardown secondmate seam did not name the next ready item: $out"
  pass "teardown prompts secondmate /stow when the next ready item changes subject"
}

test_teardown_secondmate_seam_silent_when_same_subject() {
  local case_dir out home
  case_dir=$(setup_allow_local_teardown secondmate-seam-same)
  home="$case_dir"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  write_backlog_repo_line "$case_dir" task-x1 alpha
  add_compatible_tasks_axi_with_ready "$case_dir" 'next-task,queued,ship,alpha,Same subject'
  out=$(FM_HOME="$home" with_kit_teardown_env "$case_dir") \
    || fail "teardown failed for same-subject secondmate seam"
  printf '%s\n' "$out" | grep -F 'Secondmate memory hygiene:' >/dev/null \
    && fail "teardown nagged secondmate seam when the next ready item matches repo: $out"
  pass "teardown stays silent on secondmate seam when the next ready item matches subject"
}

test_teardown_secondmate_kind_skips_completion_reminders() {
  local case_dir out rc sub_home
  case_dir=$(make_case secondmate-no-completion-reminders)
  write_meta "$case_dir" local-only secondmate
  sub_home="$case_dir/secondmate-home"
  mkdir -p "$sub_home/state" "$sub_home/data" "$sub_home/config"
  printf '%s\n' task-x1 > "$sub_home/.fm-secondmate-home"
  printf '%s\n' "home=$sub_home" >> "$case_dir/state/task-x1.meta"
  set +e
  out=$(run_teardown "$case_dir" --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "secondmate teardown failed: $out"
  printf '%s\n' "$out" | grep -E 'Backlog:|Retro acceleration:|Secondmate memory hygiene:' >/dev/null \
    && fail "secondmate teardown emitted ship/scout completion reminders: $out"
  pass "secondmate teardown prints no ship/scout completion reminders"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "treehouse_slot=slot-task-x1" \
    "treehouse_lease=lease-task-x1" \
    "kind=$kind" \
    "mode=$mode"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *" --json state "*) printf '%s\n' 'MERGED' ; exit 0 ;;
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override the direct GitHub lookup for a recorded PR URL with one exact state.
add_gh_pr_state_for_url() {
  local case_dir=$1 state=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *" --json state "*) printf '%s\n' '$state'; exit 0 ;;
    esac
    ;;
esac
echo "error: unsupported gh fixture call" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_TREEHOUSE_WORKTREE="$case_dir/wt" \
  FM_FAKE_TREEHOUSE_DELEGATE="$case_dir/fakebin/treehouse" \
  PATH="$case_dir/occupancy-bin:$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

run_local_merge() {
  local case_dir=$1
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_ROOT_OVERRIDE="$ROOT" \
    "$MERGE_LOCAL" task-x1
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id jq ln \
    mkdir mktemp mv perl ps python3 readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"
  add_gh_pr_state_for_url "$case_dir" MERGED

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"
  add_gh_pr_state_for_url "$case_dir" MERGED

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

# Build the measured stale-index incident shape inside make_case: branch
# commits B1 then B2 on the worktree, optionally pushed, then index and working
# tree rewound to B1's state while HEAD stays at B2 - the state a bare ref
# rewrite beneath a live worktree leaves behind. Args: case_dir push-all|push-b1|none
make_stale_index_fixture() {
  local case_dir=$1 push=${2:-push-all} b1
  wt_commit_file "$case_dir" feature.txt "hello v1" "B1"
  b1=$(git -C "$case_dir/wt" rev-parse HEAD)
  if [ "$push" = push-b1 ]; then
    git -C "$case_dir/wt" push -q origin fm/task-x1
    git -C "$case_dir/project" fetch -q origin
  fi
  wt_commit_file "$case_dir" feature.txt "hello v2" "B2"
  if [ "$push" = push-all ]; then
    git -C "$case_dir/wt" push -q origin fm/task-x1
    git -C "$case_dir/project" fetch -q origin
  fi
  git -C "$case_dir/wt" read-tree -u --reset "$b1"
  git -C "$case_dir/wt" status --porcelain | grep -q '^M  feature.txt' \
    || fail "stale-index fixture: expected a staged-only modification; got: $(git -C "$case_dir/wt" status --porcelain)"
}

test_stale_index_reachable_content_allows() {
  local case_dir rc
  case_dir=$(make_case stale-index-allow)
  write_meta "$case_dir" no-mistakes ship
  make_stale_index_fixture "$case_dir" push-all

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-allow: a dirty worktree whose every differing path is reachable from surviving refs should tear down ($(cat "$case_dir/stderr"))"
  ! grep -q REFUSED "$case_dir/stderr" || fail "stale-index-allow: teardown printed a REFUSED line"
  grep -qi reachable "$case_dir/stderr" \
    || fail "stale-index-allow: teardown did not report why the dirty state was not treated as work"
  pass "stale-index dirt with only reachable content no longer blocks teardown"
}

test_stale_index_with_new_content_still_refuses() {
  local case_dir rc
  case_dir=$(make_case stale-index-new-content)
  write_meta "$case_dir" no-mistakes ship
  make_stale_index_fixture "$case_dir" push-all
  printf 'genuinely new line\n' > "$case_dir/wt/newfile.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-index-new-content: one genuinely new file among reachable staleness must still refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-index-new-content: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" \
    || fail "stale-index-new-content: refusal did not cite uncommitted changes"
  grep -q "newfile.txt" "$case_dir/stderr" \
    || fail "stale-index-new-content: refusal did not name the path holding unique content"
  pass "one genuinely new file keeps the dirty refusal exactly as before"
}

test_stale_index_pass_does_not_bypass_landed_check() {
  local case_dir rc
  case_dir=$(make_case stale-index-unlanded)
  write_meta "$case_dir" no-mistakes ship
  # B1 is pushed (so the rewound index holds only reachable content) but B2 is
  # not on any remote and its content is not in origin/main: the dirty check
  # must step aside and the landed-work check must still refuse.
  make_stale_index_fixture "$case_dir" push-b1
  "$ROOT/bin/fm-worktree-unique-content.sh" "$case_dir/wt" > /dev/null 2>&1 \
    || fail "stale-index-unlanded: precondition failed - the classifier itself should pass this worktree"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-index-unlanded: unlanded commits must refuse even when the dirty state is provably reachable"
  grep -q "not on any remote and not landed" "$case_dir/stderr" \
    || fail "stale-index-unlanded: refusal did not come from the landed-work check: $(cat "$case_dir/stderr")"
  pass "a reachable-content pass cannot bypass the landed-work check"
}

test_stale_index_local_only_merged_allows() {
  local case_dir rc tip
  case_dir=$(make_case stale-index-local-only)
  write_meta "$case_dir" local-only ship
  make_stale_index_fixture "$case_dir" none
  tip=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$tip"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-local-only: locally merged work with only reachable dirt should tear down ($(cat "$case_dir/stderr"))"
  ! grep -q REFUSED "$case_dir/stderr" || fail "stale-index-local-only: teardown printed a REFUSED line"
  pass "local-only stale-index dirt with merged work no longer blocks teardown"
}

test_missing_classifier_keeps_dirty_refusal() {
  local case_dir rc binmut
  case_dir=$(make_case stale-index-no-classifier)
  write_meta "$case_dir" no-mistakes ship
  make_stale_index_fixture "$case_dir" push-all

  # Integration halves of the mutation classes "delete it" and "make it
  # unreachable": with the classifier gone, the exact same fixture that
  # test_stale_index_reachable_content_allows tears down must refuse again -
  # the consult can only ever narrow the refusal, never widen what tears down.
  binmut="$case_dir/binmut"
  cp -R "$ROOT/bin" "$binmut"
  rm -f "$binmut/fm-worktree-unique-content.sh"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_TREEHOUSE_WORKTREE="$case_dir/wt" \
  FM_FAKE_TREEHOUSE_DELEGATE="$case_dir/fakebin/treehouse" \
  PATH="$case_dir/occupancy-bin:$case_dir/fakebin:$PATH" \
    "$binmut/fm-teardown.sh" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-index-no-classifier: with the classifier missing the dirty refusal must stand"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-index-no-classifier: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" \
    || fail "stale-index-no-classifier: refusal did not cite uncommitted changes"
  pass "a missing classifier falls back to the plain dirty refusal"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_teardown_reaps_escalation_log_and_abandoned_lock_owner() {
  local case_dir lock owner
  case_dir=$(make_case escalation-cleanup)
  write_meta "$case_dir" local-only ship
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 1700000000 mechanical relaunch none \
    codex,default,low codex,default,low > "$case_dir/state/task-x1.escalation"
  lock="$case_dir/state/.task-x1.escalation.lock"
  # Exactly the lock an `escalate` process killed between acquire and release
  # leaves behind: the real helper's symlink plus its sibling owner directory.
  FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_create "$2"
  ' _ "$ROOT" "$lock" || fail "escalation-cleanup: could not create the escalation lock"
  owner=$(readlink "$lock") || fail "escalation-cleanup: the escalation lock is not the helper's symlink"
  [ -d "$owner" ] || fail "escalation-cleanup: the escalation lock has no owner directory"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "escalation-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.escalation" "escalation-cleanup: teardown left the attempt-budget log"
  assert_absent "$lock" "escalation-cleanup: teardown left the escalation lock"
  assert_absent "$owner" "escalation-cleanup: teardown left the escalation lock's owner directory in state/"
  pass "teardown removes the ladder's budget log and reaps an abandoned escalation lock with its owner dir"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# A pre-endpoint_task_id Herdr record: window and every herdr_* field are
# present, but the exact task binding firstmate later started stamping never
# got written. The recorded pane itself is authoritatively confirmed gone
# (every `pane get` reports pane_not_found), so there is nothing left to
# close - the task and its worktree must not stay stranded on that account.
configure_legacy_herdr_meta_confirmed_gone() {  # <case-dir>
  local case_dir=$1
  grep -v '^endpoint_task_id=' "$case_dir/state/task-x1.meta" > "$case_dir/state/task-x1.meta.tmp"
  mv "$case_dir/state/task-x1.meta.tmp" "$case_dir/state/task-x1.meta"
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_teardown_legacy_missing_binding_proceeds_when_target_confirmed_gone() {
  local case_dir rc
  case_dir=$(make_case herdr-legacy-absent-binding)
  write_meta "$case_dir" local-only ship
  configure_legacy_herdr_meta_confirmed_gone "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "herdr-legacy-absent-binding: teardown refused a legacy Herdr record whose recorded pane is confirmed gone: $(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-legacy-absent-binding: teardown left the durable endpoint metadata behind"
  [ ! -d "$case_dir/wt" ] \
    || fail "herdr-legacy-absent-binding: teardown never returned the isolated worktree copy"
  pass "herdr teardown proceeds past a legacy no-binding record once the recorded pane is confirmed gone"
}

test_herdr_teardown_legacy_missing_binding_refuses_when_target_present() {
  local case_dir rc
  case_dir=$(make_case herdr-legacy-present-binding)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  grep -v '^endpoint_task_id=' "$case_dir/state/task-x1.meta" > "$case_dir/state/task-x1.meta.tmp"
  mv "$case_dir/state/task-x1.meta.tmp" "$case_dir/state/task-x1.meta"

  rc=0
  FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-legacy-present-binding: teardown accepted a legacy no-binding record whose recorded pane is still present"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-legacy-present-binding: the refusal erased the durable endpoint metadata"
  [ -d "$case_dir/wt" ] \
    || fail "herdr-legacy-present-binding: the refusal returned the isolated worktree copy"
  assert_grep "lacks an exact task binding" "$case_dir/stderr" \
    "herdr-legacy-present-binding: the refusal was not explained visibly"
  pass "herdr teardown still refuses a legacy no-binding record whose recorded pane is present, even with --force"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Occupancy may query `treehouse status --json` before the Herdr lock; that is
  # a read, not a return. The contended-lock refusal must still fire before
  # `treehouse return`.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if grep -E '(^|[[:space:]])return($|[[:space:]])' "$thlog" >/dev/null 2>&1; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  jq -n --arg path '$case_dir/wt' '[{name:"slot-task-x1",path:\$path,status:"leased",lease_id:"lease-task-x1",lease_holder:"task-x1",leased_at:null,processes:[]}]'
  exit 0
fi
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      ;;
  esac
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  if grep -E '(^|[[:space:]])return($|[[:space:]])' "$thlog" >/dev/null 2>&1; then
    fail "herdr-preflight-$mode: refusal returned the isolated copy: $(cat "$thlog")"
  fi
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

configure_secondmate_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

# --- Fix 1: conclude/abort the task's own parked no-mistakes run before the
# worker is removed, and Fix 2: reap leaked descendant processes rooted under
# the task's own worktree/tasktmp - both exercised through the real teardown
# path (bin/fm-teardown.sh), never by matching its source text. ------------

# A parked-at-a-gate `axi status` TOON payload for <branch>/<head>, matching
# the shape no-mistakes actually emits (see tests/fm-crew-state.test.sh's
# run_parked fixture, the same shape bin/fm-crew-state.sh's own tests pin).
parked_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$2"
  pr: ""
  findings: none
gate: review
EOF
}

running_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: running
  head: "$2"
  pr: ""
steps[1]{step,status,findings,summary}:
  test,running,0,"agent under way"
EOF
}

terminal_axi_status_toon() {  # <branch> <head> <outcome> [run-id]
  cat <<EOF
run:
  id: "${4:-01RUN}"
  branch: $1
  status: completed
  head: "$2"
  pr: ""
  findings: none
outcome: $3
EOF
}

# One review fix cycle whose follow-up also re-ran document: review and document
# each ran a second round, so this is two step reruns, not two correction cycles.
step_rerun_stats_table() {
  cat <<'EOF'
run 01RUN (completed)
STEP      ROUND  PURPOSE     AGENT
review    1      review      claude
review    2      review-fix  claude
review    2      review      claude
document  1      document    claude
document  2      document    claude

EOF
}

# A stats build whose per-step table this teardown cannot read: the header is
# there but no step row follows it, so the step-rerun count stays unknown.
unreadable_stats_table() {
  cat <<'EOF'
run 01RUN (completed)
STEP      ROUND  PURPOSE     AGENT

EOF
}

# Land a shippable commit on the task branch and push it to origin, the same
# "definitely landed, teardown must ALLOW" shape test_no_mistakes_origin_remote_allows
# uses, so these new cases exercise the abort/reap steps on a real successful
# teardown rather than a refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

# Finding 2: teardown must observe the no-mistakes root bound per task in metadata
# so a pre-rollout parked run never disappears and a post-rollout run is queried at
# its own private root. The no-mistakes stub records NM_HOME on every invocation
# (FM_FAKE_NM_HOME_LOG) so the test proves which root the observer queried.
test_teardown_observes_legacy_root_for_pre_rollout_task() {
  local case_dir rc head legacy_home legacy_root
  case_dir=$(make_case nm-home-legacy-binding)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  # A pre-rollout task has no nm_home binding in metadata; its run lives at the
  # legacy shared root, so teardown must observe it there (not the new private
  # root) or the parked run would be orphaned by a false-negative lookup.
  legacy_home="$case_dir/legacy-home"
  mkdir -p "$legacy_home"
  legacy_root="$legacy_home/.no-mistakes"

  rc=0
  HOME="$legacy_home" \
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_HOME_LOG="$case_dir/nm-home.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "legacy-binding: teardown should succeed after aborting the parked run"
  assert_grep "$legacy_root" "$case_dir/nm-home.log" \
    "legacy-binding: teardown did not query the legacy shared root for a pre-rollout task"
  assert_present "$case_dir/nm-abort.log" \
    "legacy-binding: the pre-rollout parked run was never aborted (false-negative lookup orphaned it)"
  pass "teardown observes the legacy shared root for a pre-rollout task and aborts its parked run"
}

test_teardown_observes_bound_private_root_for_post_rollout_task() {
  local case_dir rc head private_root
  case_dir=$(make_case nm-home-private-binding)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  # A post-rollout task records nm_home=<private> at spawn; teardown must query
  # that exact private root, not the legacy shared root.
  private_root="$case_dir/private-nm"
  mkdir -p "$private_root"
  printf 'nm_home=%s\n' "$private_root" >> "$case_dir/state/task-x1.meta"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_HOME_LOG="$case_dir/nm-home.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "private-binding: teardown should succeed after aborting the parked run"
  assert_grep "$private_root" "$case_dir/nm-home.log" \
    "private-binding: teardown did not query the bound private root for a post-rollout task"
  case "$(cat "$case_dir/nm-home.log")" in
    *"$HOME/.no-mistakes"*) fail "private-binding: teardown fell back to the legacy shared root instead of the bound private root" ;;
  esac
  assert_present "$case_dir/nm-abort.log" \
    "private-binding: the post-rollout parked run at the private root was never aborted"
  pass "teardown observes the bound private root for a post-rollout task and aborts its parked run"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  printf 'return\n' >> "$case_dir/treehouse.log"
fi
if [ "\${1:-}" = status ]; then
  printf '%s\n' '[]'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  pass "teardown refuses before reap or removal when a task-owned run remains parked"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/tasktmp" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_reaps_tmux_process_group() {
  local case_dir rc pid path_without_lsof
  case_dir=$(make_case lsof-absent-process-group-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-process-group-reap: fixture path unexpectedly exposes lsof"

  perl -e 'setpgrp(0, 0); chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "lsof-absent-process-group-reap: teardown should succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "lsof-absent-process-group-reap: tmux process group survived teardown"
  fi
  assert_grep "reaping leaked worktree process group" "$case_dir/stderr" \
    "lsof-absent-process-group-reap: teardown did not use the process-group fallback"
  pass "missing lsof falls back to reaping the tmux pane process group"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  printf 'return\n' >> "$case_dir/treehouse.log"
fi
if [ "\${1:-}" = status ]; then
  printf '%s\n' '[]'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  perl -e '$SIG{TERM} = "IGNORE"; sleep 300' &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 2 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  kill -KILL "$pid" 2>/dev/null || true
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  ( cd "$case_dir/wt" && exec perl -e '
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '\''$SIG{TERM} = "IGNORE"; sleep 300'\'';
    ' "$marker" "$done_flag" ) &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  ( cd "$case_dir/wt" && exec perl -e '
      my $file = shift;
      $SIG{TERM} = sub {
        my $child = fork();
        die "fork" unless defined $child;
        if (!$child) { exec "sleep", "300"; }
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh;
        exit 0;
      };
      sleep 300;
    ' "$child_file" ) &
  pid=$!
  disown
  sleep 0.2

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc wt_path fake_pid=99999999
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_PERSISTENT_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  printf 'Tue Aug  4 10:00:00 2026\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_PERSISTENT_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  printf 'returned\n' > "$case_dir/treehouse.log"
fi
if [ "\${1:-}" = status ]; then
  printf '%s\n' '[]'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
  if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
fi
if [ "\${1:-}" = status ]; then
  printf '%s\n' '[]'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

seed_teardown_telemetry() {
  local case_dir=$1 result
  mkdir -p "$case_dir/data"
  result=$(FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    "$TELEMETRY" intake --state "$case_dir/state" --task task-x1 --payload \
    '{"attemptClass":"real","source":"firstmate","taskRootId":null,"parentAttemptId":null,"projectRef":"project_0123456789abcdef","taskClass":"unresolved","tuple":{"harness":"codex","provider":null,"model":"default","effort":"default","modelVersion":"default","cliVersion":"codex-cli fixture"},"selection":{"matchedRule":null,"configSha256":null,"fitReasons":[],"candidateAssessments":[],"quota":{"decision":"not-applicable","headroom":"unknown","runway":"unknown","observedAt":null}},"neutralExecution":{"correlation":null,"capabilityProfile":"not-applicable","owner":"not-applicable","phase":null,"behavioralResult":"not-applicable"},"evaluation":{"kind":"none","fixtureId":null,"fixtureManifestSha256":null,"oracleId":null,"oracleSha256":null,"sourceCommit":null},"startedAt":"2026-08-02T00:00:00Z","privacy":{"classification":"operational-minimized","contentPolicy":"ids-codes-hashes-bounded-evidence-only"}}') || return 1
  printf 'telemetry_attempt=%s\n' "$(printf '%s' "$result" | jq -r .attemptId)" >> "$case_dir/state/task-x1.meta"
  printf 'telemetry_task_root=%s\n' "$(printf '%s' "$result" | jq -r .taskRootId)" >> "$case_dir/state/task-x1.meta"
}

record_task_base() {
  local case_dir=$1 base
  base=$(git -C "$case_dir/wt" rev-parse HEAD) || return 1
  printf 'base_commit=%s\n' "$base" >> "$case_dir/state/task-x1.meta"
}

reuse_lane_after_landed_prior_task() {
  local case_dir=$1 prior_head
  git -C "$case_dir/wt" branch -m fm/prior-task
  wt_commit_file "$case_dir" prior.txt prior-task "prior lane task"
  prior_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" merge -q --ff-only "$prior_head"
  git -C "$case_dir/wt" checkout -q -B fm/task-x1 main
}

test_teardown_derives_quality_and_cost_from_observable_facts() {
  local case_dir terminal ledger head sheet stderr
  case_dir=$(make_case telemetry-mechanical-scoreboard)
  write_meta "$case_dir" no-mistakes ship
  printf 'harness=pi\n' >> "$case_dir/state/task-x1.meta"
  land_shippable_commit "$case_dir"
  seed_teardown_telemetry "$case_dir" || fail "could not seed mechanical teardown telemetry"
  printf 'failed: prose must not classify the routing outcome\n' > "$case_dir/state/task-x1.status"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  terminal='{"classification":"failed","refusalQuality":"not-applicable","endedAt":"2026-08-02T00:01:00Z","wallSeconds":60,"firstPassAccepted":false,"correctionCount":99,"interventionCount":0,"evidence":{"tests":"fail","reviewer":"not-run","oracle":"not-run","refs":[]},"outcomeLink":{"kind":"commit","id":"caller-prose"},"usage":{"inputTokens":null,"outputTokens":null,"cost":999,"currency":"USD"},"primaryFailureClass":"capability","flags":{"tool":false,"transport":false,"environment":false,"externalWait":false,"scopeChange":false,"quota":false},"reclassification":{"fromTaskClass":null,"toTaskClass":null,"reasonCodes":["none"],"escalated":false}}'
  stderr="$case_dir/seal.err"
  # shellcheck disable=SC2016 # Literal dollar spend is a captured harness fixture.
  FM_FAKE_AXI_STATUS="$(terminal_axi_status_toon fm/task-x1 "$head" passed)" \
  FM_FAKE_NM_STATS="$(step_rerun_stats_table)" \
  FM_FAKE_TMUX_CAPTURE='↑109k ↓2.9k R383k CH87.9% $0.728 (sub) 38.5%/272k (auto) (openai-codex) gpt-5.6-sol • low' \
    FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" run_teardown "$case_dir" --terminal-payload "$terminal" >/dev/null 2>"$stderr" || fail "mechanical telemetry teardown failed"
  ledger="$case_dir/data/routing-outcomes.jsonl"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="accepted" and .terminal.firstPassAccepted==false and .terminal.correctionCount==2 and .terminal.gateFacts=={source:"no-mistakes",result:"green",stepReruns:2} and .terminal.evidence.tests=="pass" and .terminal.usage.cost==null and .terminal.usage.currency==null and .terminal.outcomeLink.id!="caller-prose")' "$ledger" >/dev/null || fail "prose overrode gate quality or the step-rerun count, or a token-derived pane figure was recorded as spend"
  assert_grep "terminal payload's quality fields were not used" "$stderr" \
    "teardown did not describe payload-quality supersession truthfully"
  sheet=$(FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" "$TELEMETRY" sheet --format json) || fail "mechanical telemetry sheet failed"
  printf '%s' "$sheet" | jq -e '.[0].quality=="accepted-after-step-reruns" and .[0].stepReruns==2 and .[0].costReported==false and .[0].cost==null and .[0].costPerAcceptedDelivery==null and .[0].wallSeconds==null' >/dev/null || fail "sheet omitted mechanical quality, invented duration without session facts, or reported an unbacked cost"
  pass "teardown seals quality from gate facts, leaves cost absent, and says when a payload was superseded"
}

test_local_only_delivery_seals_true_outcome_and_usage() {
  local case_dir ledger task_base advanced_main wt_head session_dir sheet terminal
  case_dir=$(make_case telemetry-local-only-delivery)
  reuse_lane_after_landed_prior_task "$case_dir"
  write_meta "$case_dir" local-only ship
  printf 'harness=codex\n' >> "$case_dir/state/task-x1.meta"
  record_task_base "$case_dir" || fail "could not record the local delivery task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed local-only delivery telemetry"
  task_base=$(git -C "$case_dir/wt" rev-parse HEAD)

  printf 'another task\n' > "$case_dir/project/other.txt"
  git -C "$case_dir/project" add other.txt
  git -C "$case_dir/project" commit -q -m "advance main before task delivery"
  advanced_main=$(git -C "$case_dir/project" rev-parse HEAD)
  git -C "$case_dir/wt" merge -q --ff-only main
  wt_commit_file "$case_dir" delivered.txt real-delivery "accepted local delivery"
  git -C "$case_dir/wt" diff --quiet "$task_base" HEAD -- &&
    fail "local delivery fixture produced no content"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  run_local_merge "$case_dir" > "$case_dir/local-merge.stdout" 2> "$case_dir/local-merge.stderr" ||
    fail "could not land the local delivery through its production merge gate: $(cat "$case_dir/local-merge.stderr")"
  assert_grep "local_delivery_base=$advanced_main" "$case_dir/state/task-x1.meta" \
    "local merge attributed another task's synced commit to this task"
  assert_grep "local_delivery_head=$wt_head" "$case_dir/state/task-x1.meta" \
    "local merge did not bind the exact task-authored delivery head"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "idempotent local merge retry failed"
  assert_grep "local_delivery_base=$advanced_main" "$case_dir/state/task-x1.meta" \
    "idempotent local merge retry discarded task authorship"

  session_dir="$case_dir/codex-sessions/2026/08/02"
  mkdir -p "$session_dir"
  cat > "$session_dir/rollout-before-attempt.jsonl" <<EOF
{"timestamp":"2026-08-01T23:59:59Z","type":"session_meta","payload":{"id":"before-attempt","timestamp":"2026-08-01T23:59:59Z","cwd":"$case_dir/wt"}}
{"timestamp":"2026-08-02T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900000,"output_tokens":900000}}}}
EOF
  cat > "$session_dir/rollout-wrong-worktree.jsonl" <<EOF
{"timestamp":"2026-08-02T00:00:01Z","type":"session_meta","payload":{"id":"wrong-worktree","timestamp":"2026-08-02T00:00:01Z","cwd":"$case_dir/project"}}
{"timestamp":"2026-08-02T09:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":800000,"output_tokens":800000}}}}
EOF
  cat > "$session_dir/rollout-task.jsonl" <<EOF
{"timestamp":"2026-08-02T00:00:05Z","type":"session_meta","payload":{"id":"task-session","timestamp":"2026-08-02T00:00:05Z","cwd":"$case_dir/wt"}}
{"timestamp":"2026-08-02T00:00:25Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"output_tokens":40}}}}
{"timestamp":"2026-08-02T00:02:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3210,"output_tokens":98}}}}
EOF

  terminal='{"classification":"failed","refusalQuality":"not-applicable","endedAt":"2026-08-02T00:01:00Z","wallSeconds":60,"firstPassAccepted":false,"correctionCount":1,"interventionCount":0,"evidence":{"tests":"fail","reviewer":"not-run","oracle":"fail","refs":[{"kind":"test","id":"contradictory-caller-payload"}]},"outcomeLink":{"kind":"none","id":null},"usage":{"inputTokens":null,"outputTokens":null,"cost":null,"currency":null},"primaryFailureClass":"capability","flags":{"tool":false,"transport":false,"environment":false,"externalWait":false,"scopeChange":false,"quota":false},"reclassification":{"fromTaskClass":null,"toTaskClass":null,"reasonCodes":["none"],"escalated":false}}'
  FM_CODEX_SESSIONS_OVERRIDE="$case_dir/codex-sessions" \
    FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --force --terminal-payload "$terminal" >/dev/null || fail "forced local-only delivery teardown failed"

  ledger="$case_dir/data/routing-outcomes.jsonl"
  jq -e --arg head "$wt_head" '
    select(.eventType=="attempt-terminal") and
    .terminal.classification=="accepted" and
    .terminal.evidence.oracle=="pass" and
    .terminal.gateFacts=={source:"delivery",result:"green",stepReruns:null} and
    .terminal.wallSeconds==120 and
    .terminal.usage=={inputTokens:3210,outputTokens:98,cost:null,currency:null} and
    .terminal.outcomeLink=={kind:"commit",id:$head}
  ' "$ledger" >/dev/null || fail "a completed local-only task did not record its true accepted outcome, active duration, and exact-session token usage"
  sheet=$(FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" "$TELEMETRY" sheet --format json) ||
    fail "local-only delivery telemetry sheet failed"
  printf '%s' "$sheet" | jq -e '.[0].classification=="accepted" and .[0].wallSeconds==120 and .[0].inputTokens==3210 and .[0].outputTokens==98' >/dev/null ||
    fail "the read-only sheet hid the accepted outcome, active duration, or exact-session token totals"
  pass "a completed local-only task stays accepted under force and contradictory caller payload, with usage from its exact session"
}

test_local_only_zero_work_does_not_seal_accepted() {
  local case_dir task_base lane_base stale_count
  case_dir=$(make_case telemetry-local-only-zero-work)
  reuse_lane_after_landed_prior_task "$case_dir"

  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the reused-lane task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed zero-work telemetry"
  task_base=$(git -C "$case_dir/wt" rev-parse HEAD)
  lane_base=$(git -C "$case_dir/wt" reflog show --format=%H HEAD | tail -1)
  stale_count=$(git -C "$case_dir/wt" rev-list --count "$lane_base..HEAD")
  [ "$stale_count" -gt 0 ] || fail "zero-work fixture did not retain prior lane reflog history"
  [ "$(git -C "$case_dir/wt" rev-list --count "$task_base..HEAD")" -eq 0 ] ||
    fail "zero-work fixture accidentally created a current-task commit"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "zero-work production merge gate failed"
  assert_no_grep '^local_delivery_' "$case_dir/state/task-x1.meta" \
    "zero-work merge recorded a task-authored delivery interval"

  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" >/dev/null || fail "zero-work local-only teardown failed"

  jq -e '
    select(.eventType=="attempt-terminal") and
    .terminal.classification=="incomplete" and
    .terminal.evidence.oracle=="not-run" and
    .terminal.primaryFailureClass=="outcome-observed-cause-unobserved" and
    .terminal.gateFacts=={source:"delivery",result:"incomplete",stepReruns:null}
  ' "$case_dir/data/routing-outcomes.jsonl" >/dev/null ||
    fail "a zero-work local-only task did not preserve the observed outcome without inventing a cause"
  pass "a reused-lane zero-work task preserves the observed outcome without inventing a cause"
}

# A sealed terminal takes the agent-authored payload, but the usage source is an
# observation teardown made, not something the agent can know. The observed
# source is authoritative on that path too, so a sealed row never records usage
# as silently absent and never keeps a stale self-reported source.
test_sealed_terminal_records_the_observed_usage_source() {
  local case_dir terminal declared sessions row sheet before after contradicting declared_usage digest_tool
  terminal='{"classification":"failed","refusalQuality":"not-applicable","endedAt":"2026-08-02T00:01:00Z","wallSeconds":60,"firstPassAccepted":false,"correctionCount":1,"interventionCount":0,"evidence":{"tests":"fail","reviewer":"not-run","oracle":"fail","refs":[{"kind":"test","id":"sealed-usage-source"}]},"outcomeLink":{"kind":"none","id":null},"usage":{"inputTokens":null,"outputTokens":null,"cost":null,"currency":null},"primaryFailureClass":"capability","flags":{"tool":false,"transport":false,"environment":false,"externalWait":false,"scopeChange":false,"quota":false},"reclassification":{"fromTaskClass":null,"toTaskClass":null,"reasonCodes":["none"],"escalated":false}}'
  declared=$(printf '%s' "$terminal" | jq -c '. + {usageSource:"recorded"}')

  # A payload that declares no usage source at all.
  case_dir=$(make_case telemetry-sealed-usage-source)
  reuse_lane_after_landed_prior_task "$case_dir"
  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the sealed-usage task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed sealed-usage telemetry"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "sealed-usage production merge gate failed"
  sessions="$case_dir/codex-sessions"
  mkdir -p "$sessions"
  FM_CODEX_SESSIONS_OVERRIDE="$sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$terminal" >/dev/null \
    || fail "sealed-usage teardown failed"
  row=$(jq -c 'select(.eventType=="attempt-terminal")' "$case_dir/data/routing-outcomes.jsonl" | head -n1)
  printf '%s' "$row" | jq -e '.terminal.evidence.refs[0].id=="sealed-usage-source"' >/dev/null \
    || fail "the sealed row did not carry the agent-authored payload: $row"
  printf '%s' "$row" | jq -e '.terminal.usageSource=="session-not-found"' >/dev/null \
    || fail "a sealed terminal recorded its usage as silently absent instead of naming the observed source: $row"

  # A payload that declares a usage source teardown did not observe.
  case_dir=$(make_case telemetry-sealed-usage-source-override)
  reuse_lane_after_landed_prior_task "$case_dir"
  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the override task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed override telemetry"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "override production merge gate failed"
  sessions="$case_dir/codex-sessions"
  mkdir -p "$sessions"
  FM_CODEX_SESSIONS_OVERRIDE="$sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$declared" >/dev/null \
    || fail "override teardown failed"
  row=$(jq -c 'select(.eventType=="attempt-terminal")' "$case_dir/data/routing-outcomes.jsonl" | head -n1)
  printf '%s' "$row" | jq -e '.terminal.usageSource=="session-not-found"' >/dev/null \
    || fail "a self-reported usage source outranked the source teardown observed: $row"

  # usageSource="recorded" is a positive claim that tokens were read, so the
  # tokens the observation read must travel with it - a row claiming recorded
  # usage while carrying none is counted as recorded and contributes nothing.
  case_dir=$(make_case telemetry-sealed-usage-source-recorded)
  reuse_lane_after_landed_prior_task "$case_dir"
  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the recorded-usage task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed recorded-usage telemetry"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "recorded-usage production merge gate failed"
  sessions="$case_dir/codex-sessions/2026/08/02"
  mkdir -p "$sessions"
  cat > "$sessions/rollout-task.jsonl" <<EOF
{"timestamp":"2026-08-02T00:00:05Z","type":"session_meta","payload":{"id":"task-session","timestamp":"2026-08-02T00:00:05Z","cwd":"$case_dir/wt"}}
{"timestamp":"2026-08-02T00:00:25Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"output_tokens":40}}}}
{"timestamp":"2026-08-02T00:02:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3210,"output_tokens":98}}}}
EOF
  # Abort teardown after the seal, which is the state the operator re-runs from.
  add_failing_treehouse "$case_dir"
  if FM_CODEX_SESSIONS_OVERRIDE="$case_dir/codex-sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$terminal" >/dev/null 2>"$case_dir/seal.stderr"; then
    fail "the recorded-usage fixture did not abort after its seal"
  fi
  assert_grep "treehouse return failed" "$case_dir/seal.stderr" \
    "the recorded-usage fixture aborted for the wrong reason: $(cat "$case_dir/seal.stderr")"
  row=$(jq -c 'select(.eventType=="attempt-terminal")' "$case_dir/data/routing-outcomes.jsonl" | head -n1)
  printf '%s' "$row" | jq -e '.terminal.usageSource=="recorded"' >/dev/null \
    || fail "a readable session did not seal as recorded usage: $row"
  printf '%s' "$row" | jq -e '.terminal.usage.inputTokens==3210 and .terminal.usage.outputTokens==98' >/dev/null \
    || fail "a sealed terminal claimed recorded usage while discarding the tokens that were read: $row"
  printf '%s' "$row" | jq -e '.terminal.wallSeconds==120' >/dev/null \
    || fail "a sealed terminal discarded the active duration the observation measured: $row"
  # The renewal join must be able to add the tokens it counts as recorded.
  sheet=$(FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" "$TELEMETRY" subscription-sheet --format json) \
    || fail "recorded-usage subscription sheet failed"
  printf '%s' "$sheet" | jq -e '.[0].usageRecorded==1 and .[0].inputTokens==3210 and .[0].outputTokens==98' >/dev/null \
    || fail "the subscription sheet counted a recorded usage row that contributed no tokens: $sheet"

  before=$(jq -c 'select(.eventType=="attempt-terminal") | .terminal' "$case_dir/data/routing-outcomes.jsonl")

  # A rerun carrying a DIFFERENT payload is a contradiction against an immutable
  # terminal, and the ledger must still refuse it rather than discard it.
  contradicting=$(printf '%s' "$terminal" | jq -c '.classification="accepted" | .evidence.oracle="pass"')
  if FM_CODEX_SESSIONS_OVERRIDE="$case_dir/codex-sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$contradicting" >/dev/null 2>"$case_dir/contradict.stderr"; then
    fail "a rerun carrying a contradicting terminal payload was accepted"
  fi
  assert_grep "terminal-conflict" "$case_dir/contradict.stderr" \
    "the contradicting rerun did not surface the ledger's refusal"
  after=$(jq -c 'select(.eventType=="attempt-terminal") | .terminal' "$case_dir/data/routing-outcomes.jsonl")
  [ "$before" = "$after" ] || fail "a refused contradiction still altered the recorded terminal: $after"

  # A terminal is immutable and compared byte-for-byte, so re-running the same
  # teardown after a later step failed must still seal as a duplicate - the
  # observation differs on the rerun (the worktree is gone by then) and must not
  # be restamped onto an already recorded terminal.
  write_default_treehouse "$case_dir"
  [ ! -d "$case_dir/wt" ] || rm -rf "$case_dir/wt"
  FM_CODEX_SESSIONS_OVERRIDE="$case_dir/codex-sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$terminal" >/dev/null 2>"$case_dir/rerun.stderr" \
    || fail "re-running the identical teardown was refused: $(cat "$case_dir/rerun.stderr")"
  assert_grep "already carries the terminal this teardown sealed" "$case_dir/rerun.stderr" \
    "the rerun did not say the recorded terminal stayed authoritative"
  [ "$(jq -c 'select(.eventType=="attempt-terminal")' "$case_dir/data/routing-outcomes.jsonl" | wc -l | tr -d ' ')" = 1 ] \
    || fail "a teardown rerun appended a second terminal row"
  after=$(jq -c 'select(.eventType=="attempt-terminal") | .terminal' "$case_dir/data/routing-outcomes.jsonl")
  [ "$before" = "$after" ] || fail "a teardown rerun rewrote the recorded terminal: $after"

  # An observation with no token counts must not erase usage the caller declared:
  # usageSource names why the observation is absent, it does not overwrite numbers.
  case_dir=$(make_case telemetry-sealed-usage-declared)
  reuse_lane_after_landed_prior_task "$case_dir"
  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the declared-usage task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed declared-usage telemetry"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "declared-usage production merge gate failed"
  mkdir -p "$case_dir/codex-sessions"
  declared_usage=$(printf '%s' "$terminal" | jq -c '.usage={inputTokens:4242,outputTokens:77,cost:null,currency:null}')
  FM_CODEX_SESSIONS_OVERRIDE="$case_dir/codex-sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$declared_usage" >/dev/null \
    || fail "declared-usage teardown failed"
  row=$(jq -c 'select(.eventType=="attempt-terminal")' "$case_dir/data/routing-outcomes.jsonl" | head -n1)
  printf '%s' "$row" | jq -e '.terminal.usage.inputTokens==4242 and .terminal.usage.outputTokens==77' >/dev/null \
    || fail "an observation with no token counts erased the usage the caller declared: $row"
  printf '%s' "$row" | jq -e '.terminal.usageSource=="session-not-found"' >/dev/null \
    || fail "the absent observation was not named on a row that kept its declared usage: $row"

  # The merge is only safe because the payload can be fingerprinted for the
  # retry; with no digest available the payload is recorded as authored, so an
  # identical rerun stays a no-op instead of a contradiction teardown authored.
  case_dir=$(make_case telemetry-sealed-usage-no-digest)
  reuse_lane_after_landed_prior_task "$case_dir"
  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the no-digest task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed no-digest telemetry"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "no-digest production merge gate failed"
  mkdir -p "$case_dir/codex-sessions"
  for digest_tool in shasum sha256sum; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$case_dir/fakebin/$digest_tool"
    chmod +x "$case_dir/fakebin/$digest_tool"
  done
  add_failing_treehouse "$case_dir"
  if FM_CODEX_SESSIONS_OVERRIDE="$case_dir/codex-sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$terminal" >/dev/null 2>"$case_dir/nodigest.stderr"; then
    fail "the no-digest fixture did not abort after its seal"
  fi
  assert_grep "could not be fingerprinted" "$case_dir/nodigest.stderr" \
    "teardown did not say the payload was recorded as authored: $(cat "$case_dir/nodigest.stderr")"
  row=$(jq -c 'select(.eventType=="attempt-terminal")' "$case_dir/data/routing-outcomes.jsonl" | head -n1)
  printf '%s' "$row" | jq -e '(.terminal|has("usageSource")|not) or .terminal.usageSource==null' >/dev/null \
    || fail "an unrecordable digest still merged the observation into the sealed payload: $row"
  before=$(jq -c 'select(.eventType=="attempt-terminal") | .terminal' "$case_dir/data/routing-outcomes.jsonl")
  write_default_treehouse "$case_dir"
  [ ! -d "$case_dir/wt" ] || rm -rf "$case_dir/wt"
  FM_CODEX_SESSIONS_OVERRIDE="$case_dir/codex-sessions" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --terminal-payload "$terminal" >/dev/null 2>"$case_dir/nodigest-rerun.stderr" \
    || fail "an unrecordable digest wedged the identical teardown rerun: $(cat "$case_dir/nodigest-rerun.stderr")"
  [ "$(jq -c 'select(.eventType=="attempt-terminal")' "$case_dir/data/routing-outcomes.jsonl" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the no-digest rerun appended a second terminal row"
  after=$(jq -c 'select(.eventType=="attempt-terminal") | .terminal' "$case_dir/data/routing-outcomes.jsonl")
  [ "$before" = "$after" ] || fail "the no-digest rerun rewrote the recorded terminal: $after"
  pass "a sealed terminal records the usage source teardown observed, not the agent's"
}

test_local_only_sync_to_advanced_main_does_not_seal_accepted() {
  local case_dir task_base advanced_main
  case_dir=$(make_case telemetry-local-only-sync-only)
  reuse_lane_after_landed_prior_task "$case_dir"
  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the sync-only task base"
  task_base=$(git -C "$case_dir/wt" rev-parse HEAD)
  seed_teardown_telemetry "$case_dir" || fail "could not seed sync-only telemetry"

  printf 'another task\n' > "$case_dir/project/other.txt"
  git -C "$case_dir/project" add other.txt
  git -C "$case_dir/project" commit -q -m "advance main from another task"
  advanced_main=$(git -C "$case_dir/project" rev-parse HEAD)
  git -C "$case_dir/wt" merge -q --ff-only main
  [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$advanced_main" ] ||
    fail "sync-only fixture did not advance the task branch to current main"
  [ "$(git -C "$case_dir/wt" rev-list --count "$task_base..HEAD")" -gt 0 ] ||
    fail "sync-only fixture did not carry another task's commit into the lane"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "sync-only production merge gate failed"
  assert_no_grep '^local_delivery_' "$case_dir/state/task-x1.meta" \
    "sync-only merge recorded another task's commits as this task's delivery"

  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" >/dev/null || fail "sync-only local teardown failed"

  jq -e '
    select(.eventType=="attempt-terminal") and
    .terminal.classification=="incomplete" and
    .terminal.evidence.oracle=="not-run" and
    .terminal.primaryFailureClass=="outcome-observed-cause-unobserved" and
    .terminal.gateFacts=={source:"delivery",result:"incomplete",stepReruns:null}
  ' "$case_dir/data/routing-outcomes.jsonl" >/dev/null ||
    fail "a task that authored nothing did not preserve the observed outcome without inventing a cause"
  pass "a reused-lane task that only syncs advanced main preserves the observed outcome without inventing a cause"
}

test_local_only_missing_task_base_is_diagnosed() {
  local case_dir rc
  case_dir=$(make_case telemetry-local-only-legacy-meta)
  write_meta "$case_dir" local-only ship
  seed_teardown_telemetry "$case_dir" || fail "could not seed legacy-meta telemetry"

  rc=0
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "legacy local-only metadata should fail closed without blocking teardown"
  assert_grep 'teardown: local-only gate facts unavailable for task-x1: missing or invalid task base commit' \
    "$case_dir/stderr" "legacy local-only metadata became incomplete without a diagnostic"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="incomplete")' \
    "$case_dir/data/routing-outcomes.jsonl" >/dev/null ||
    fail "legacy local-only metadata did not fail closed to incomplete"
  pass "legacy local-only metadata seals incomplete with a missing-base diagnostic"
}

test_local_only_empty_commit_does_not_seal_accepted() {
  local case_dir
  case_dir=$(make_case telemetry-local-only-empty-commit)
  write_meta "$case_dir" local-only ship
  record_task_base "$case_dir" || fail "could not record the empty-commit task base"
  seed_teardown_telemetry "$case_dir" || fail "could not seed empty-commit telemetry"
  wt_commit "$case_dir" "empty task checkpoint"
  run_local_merge "$case_dir" >/dev/null 2>&1 || fail "empty-commit production merge gate failed"
  assert_no_grep '^local_delivery_' "$case_dir/state/task-x1.meta" \
    "content-less commit recorded a task-authored delivery interval"

  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" >/dev/null || fail "empty-commit local-only teardown failed"

  jq -e '
    select(.eventType=="attempt-terminal") and
    .terminal.classification=="incomplete" and
    .terminal.evidence.oracle=="not-run" and
    .terminal.gateFacts=={source:"delivery",result:"incomplete",stepReruns:null} and
    .terminal.primaryFailureClass=="outcome-observed-cause-unobserved"
  ' "$case_dir/data/routing-outcomes.jsonl" >/dev/null ||
    fail "a content-less local-only commit falsely sealed accepted"
  pass "a content-less local-only commit seals incomplete instead of false acceptance"
}

test_teardown_notes_gate_observation_branch_mismatch() {
  local case_dir head rc
  case_dir=$(make_case telemetry-branch-mismatch-note)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  seed_teardown_telemetry "$case_dir" || fail "could not seed branch-mismatch teardown telemetry"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(terminal_axi_status_toon fm/another-task "$head" passed)" \
    FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "telemetry-branch-mismatch-note: teardown must remain non-blocking"
  assert_grep 'teardown: no-mistakes gate facts unavailable for task-x1: branch mismatch' \
    "$case_dir/stderr" "telemetry-branch-mismatch-note: missing refused-precondition note"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.gateFacts=={source:"delivery",result:"incomplete",stepReruns:null})' \
    "$case_dir/data/routing-outcomes.jsonl" >/dev/null \
    || fail "telemetry-branch-mismatch-note: existing incomplete fallback changed"
  pass "teardown names a branch mismatch without blocking its incomplete telemetry seal"
}

test_teardown_finishes_returned_ship_with_recorded_merged_pr() {
  local case_dir gen ledger rc
  case_dir=$(make_case telemetry-returned-slot-recorded-pr)
  write_meta "$case_dir" no-mistakes ship
  append_pr_meta_url "$case_dir"
  seed_teardown_telemetry "$case_dir" || fail "could not seed returned-slot teardown telemetry"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  printf 'working: stranded after worktree return\n' > "$case_dir/state/task-x1.status"

  # The task branch is gone and the path now exposes the pool's detached base,
  # while the stale task metadata and telemetry attempt still need retirement.
  git -C "$case_dir/wt" checkout -q --detach origin/main
  git -C "$case_dir/project" branch -D fm/task-x1 >/dev/null
  add_gh_pr_state_for_url "$case_dir" MERGED

  rc=0
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" \
    "returned-slot-recorded-pr: teardown should finish from recorded PR evidence: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" \
    "returned-slot-recorded-pr: teardown left task metadata behind"
  assert_absent "$case_dir/state/task-x1.status" \
    "returned-slot-recorded-pr: teardown left status behind"
  assert_absent "$case_dir/state/task-x1.busy-gen" \
    "returned-slot-recorded-pr: teardown left the busy generation behind"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "returned-slot-recorded-pr: teardown left the busy state behind"
  ledger="$case_dir/data/routing-outcomes.jsonl"
  jq -e '
    select(.eventType=="attempt-terminal") and
    .terminal.classification=="accepted" and
    .terminal.gateFacts=={source:"delivery",result:"green",stepReruns:null} and
    .terminal.outcomeLink=={kind:"pull-request",id:"https://github.com/example/repo/pull/7"}
  ' "$ledger" >/dev/null || fail "returned-slot-recorded-pr: telemetry was not sealed from the merged recorded PR"
  pass "a returned ship slot with a recorded merged PR seals telemetry and removes stranded task state"
}

test_returned_ship_with_recorded_unmerged_pr_stays_incomplete() {
  local case_dir ledger rc
  case_dir=$(make_case telemetry-returned-slot-unmerged-pr)
  write_meta "$case_dir" no-mistakes ship
  append_pr_meta_url "$case_dir"
  seed_teardown_telemetry "$case_dir" || fail "could not seed unmerged-PR teardown telemetry"
  git -C "$case_dir/wt" checkout -q --detach origin/main
  git -C "$case_dir/project" branch -D fm/task-x1 >/dev/null
  add_gh_pr_state_for_url "$case_dir" OPEN

  rc=0
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" \
    --acknowledge-open-pr-without-watch "test: unmerged recorded PR seals incomplete" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" \
    "returned-slot-unmerged-pr: teardown should clean up without claiming acceptance: $(cat "$case_dir/stderr")"
  ledger="$case_dir/data/routing-outcomes.jsonl"
  jq -e '
    select(.eventType=="attempt-terminal") and
    .terminal.classification=="incomplete" and
    .terminal.gateFacts=={source:"delivery",result:"incomplete",stepReruns:null}
  ' "$ledger" >/dev/null || fail "returned-slot-unmerged-pr: an unmerged PR was accepted as merged"
  pass "a returned ship slot with a recorded unmerged PR seals incomplete"
}

make_recorded_pr_teardown_variant() {  # <variant>
  local variant=$1 variant_root script
  variant_root="$TMP_ROOT/recorded-pr-variants/$variant"
  mkdir -p "$variant_root"
  cp -R "$ROOT/bin" "$variant_root/"
  script="$variant_root/bin/fm-teardown.sh"
  python3 - "$script" "$variant" <<'PY' || return 1
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
variant = sys.argv[2]
mutations = {
    "control": None,
    "delete": (
        "recorded_pr_is_merged() {  # <pr-url>",
        "recorded_pr_is_merged_deleted() {  # <pr-url>",
    ),
    "unreachable": (
        '  elif [ "$KIND" = ship ] && [ -n "$PR_URL" ] && recorded_pr_is_merged "$PR_URL"; then',
        '  elif [ "$KIND" = ship ] && [ -n "$PR_URL" ] && false && recorded_pr_is_merged "$PR_URL"; then',
    ),
    "weakened-unmerged": (
        "    MERGED|merged) return 0 ;;",
        "    MERGED|merged|OPEN|open) return 0 ;;",
    ),
    "constant-true": (
        "recorded_pr_is_merged() {  # <pr-url>\n  local target=$1 state",
        "recorded_pr_is_merged() {  # <pr-url>\n  local target=$1 state\n  return 0",
    ),
}

if variant not in mutations:
    raise SystemExit(f"unknown recorded-PR predicate variant: {variant}")
text = path.read_text()
mutation = mutations[variant]
if mutation is not None:
    old, new = mutation
    if text.count(old) != 1:
        raise SystemExit(f"recorded-PR predicate mutation {variant} matched {text.count(old)} times")
    path.write_text(text.replace(old, new))
PY
  printf '%s\n' "$script"
}

probe_returned_ship_recorded_pr_result() {  # <teardown> <case> <forge-state> <accepted|incomplete>
  local teardown=$1 name=$2 forge_state=$3 expected=$4 case_dir gen ledger rc
  case_dir=$(make_case "telemetry-recorded-pr-$name") || return 1
  write_meta "$case_dir" no-mistakes ship
  append_pr_meta_url "$case_dir"
  seed_teardown_telemetry "$case_dir" || return 1
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1) || return 1
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  printf 'working: stranded after worktree return\n' > "$case_dir/state/task-x1.status"
  git -C "$case_dir/wt" checkout -q --detach origin/main || return 1
  git -C "$case_dir/project" branch -D fm/task-x1 >/dev/null || return 1
  add_gh_pr_state_for_url "$case_dir" "$forge_state"

  rc=0
  TEARDOWN="$teardown" FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" \
    --acknowledge-open-pr-without-watch "test: recorded-PR telemetry classification" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ ! -e "$case_dir/state/task-x1.meta" ] || return 1
  [ ! -e "$case_dir/state/task-x1.status" ] || return 1
  [ ! -e "$case_dir/state/task-x1.busy-gen" ] || return 1
  [ ! -e "$case_dir/state/task-x1.busy-state" ] || return 1
  ledger="$case_dir/data/routing-outcomes.jsonl"
  case "$expected" in
    accepted)
      jq -e '
        select(.eventType=="attempt-terminal") and
        .terminal.classification=="accepted" and
        .terminal.gateFacts=={source:"delivery",result:"green",stepReruns:null}
      ' "$ledger" >/dev/null
      ;;
    incomplete)
      jq -e '
        select(.eventType=="attempt-terminal") and
        .terminal.classification=="incomplete" and
        .terminal.gateFacts=={source:"delivery",result:"incomplete",stepReruns:null}
      ' "$ledger" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

test_recorded_pr_merge_predicate_kills_required_mutations() {
  local control delete unreachable weakened constant_true
  local control_rc delete_rc unreachable_rc weakened_rc constant_true_rc
  control=$(make_recorded_pr_teardown_variant control) || fail "could not build recorded-PR control"
  delete=$(make_recorded_pr_teardown_variant delete) || fail "could not build recorded-PR delete mutant"
  unreachable=$(make_recorded_pr_teardown_variant unreachable) || fail "could not build recorded-PR unreachable mutant"
  weakened=$(make_recorded_pr_teardown_variant weakened-unmerged) || fail "could not build recorded-PR weakened-unmerged mutant"
  constant_true=$(make_recorded_pr_teardown_variant constant-true) || fail "could not build recorded-PR constant-true mutant"

  control_rc=0
  probe_returned_ship_recorded_pr_result "$control" control MERGED accepted || control_rc=$?
  delete_rc=0
  probe_returned_ship_recorded_pr_result "$delete" delete MERGED accepted || delete_rc=$?
  unreachable_rc=0
  probe_returned_ship_recorded_pr_result "$unreachable" unreachable MERGED accepted || unreachable_rc=$?
  weakened_rc=0
  probe_returned_ship_recorded_pr_result "$weakened" weakened-unmerged OPEN incomplete || weakened_rc=$?
  constant_true_rc=0
  probe_returned_ship_recorded_pr_result "$constant_true" constant-true OPEN incomplete || constant_true_rc=$?

  printf 'recorded_pr_is_merged mutation exit codes: control=%s delete=%s unreachable=%s weakened-unmerged=%s constant-true=%s\n' \
    "$control_rc" "$delete_rc" "$unreachable_rc" "$weakened_rc" "$constant_true_rc"
  expect_code 0 "$control_rc" "recorded-PR predicate control should pass"
  expect_code 1 "$delete_rc" "recorded-PR predicate delete mutant should be killed"
  expect_code 1 "$unreachable_rc" "recorded-PR predicate unreachable mutant should be killed"
  expect_code 1 "$weakened_rc" "recorded-PR predicate weakened-unmerged mutant should be killed"
  expect_code 1 "$constant_true_rc" "recorded-PR predicate constant-true mutant should be killed"
  pass "recorded-PR telemetry predicate kills delete, unreachable, weakened-unmerged, and constant-true mutations"
}

test_teardown_keeps_a_green_gate_accepted_and_seals_a_cancelled_gate_without_an_observed_cause() {
  local case_dir ledger head sheet
  case_dir=$(make_case telemetry-green-without-step-rerun-counts)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  seed_teardown_telemetry "$case_dir" || fail "could not seed green-gate teardown telemetry"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  FM_FAKE_AXI_STATUS="$(terminal_axi_status_toon fm/task-x1 "$head" passed)" \
  FM_FAKE_NM_STATS="$(unreadable_stats_table)" \
    FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" run_teardown "$case_dir" >/dev/null || fail "green-gate teardown failed"
  ledger="$case_dir/data/routing-outcomes.jsonl"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="accepted" and .terminal.correctionCount==null and .terminal.firstPassAccepted==null and .terminal.gateFacts=={source:"no-mistakes",result:"green",stepReruns:null})' "$ledger" >/dev/null || fail "an accepted delivery whose step-rerun count was unreadable was downgraded instead of recorded with an unknown count"
  sheet=$(FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" "$TELEMETRY" sheet --format json) || fail "green-gate sheet failed"
  printf '%s' "$sheet" | jq -e '.[0].quality=="accepted-step-reruns-unknown"' >/dev/null || fail "sheet did not report the accepted delivery with an unknown step-rerun count"

  case_dir=$(make_case telemetry-cancelled-gate)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  seed_teardown_telemetry "$case_dir" || fail "could not seed cancelled-gate teardown telemetry"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  FM_FAKE_AXI_STATUS="$(terminal_axi_status_toon fm/task-x1 "$head" cancelled)" \
    FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" run_teardown "$case_dir" >/dev/null || fail "cancelled-gate teardown failed"
  ledger="$case_dir/data/routing-outcomes.jsonl"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="cancelled" and .terminal.evidence.oracle=="not-run" and .terminal.gateFacts=={source:"no-mistakes",result:"cancelled",stepReruns:null} and .terminal.primaryFailureClass=="outcome-observed-cause-unobserved")' "$ledger" >/dev/null || fail "a cancelled gate without an observed cause did not preserve its observed facts"
  sheet=$(FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" "$TELEMETRY" sheet --format json) || fail "cancelled-gate sheet failed"
  printf '%s' "$sheet" | jq -e '.[0].quality=="cancelled" and .[0].primaryFailureClass=="outcome-observed-cause-unobserved"' >/dev/null || fail "sheet did not preserve the observed outcome"
  pass "an unreadable step-rerun count keeps a green gate accepted and a cancelled gate preserves its observed outcome without inventing a cause"
}

test_teardown_records_failed_terminal_status_and_forced_cancellation() {
  local case_dir ledger sheet
  case_dir=$(make_case telemetry-failed-status)
  write_meta "$case_dir" local-only ship
  seed_teardown_telemetry "$case_dir" || fail "could not seed failed-status telemetry"
  printf 'failed: implementation exhausted its retry budget\n' > "$case_dir/state/task-x1.status"
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --force >/dev/null || fail "failed-status teardown failed"
  ledger="$case_dir/data/routing-outcomes.jsonl"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="failed" and .terminal.evidence.oracle=="fail" and .terminal.gateFacts=={source:"delivery",result:"failed",stepReruns:null} and .terminal.primaryFailureClass=="outcome-observed-cause-unobserved")' \
    "$ledger" >/dev/null || fail "a failed status without an observed typed cause did not preserve its observed facts"
  sheet=$(FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" "$TELEMETRY" sheet --format json) || fail "failed-status sheet failed"
  printf '%s' "$sheet" | jq -e '.[0].quality=="failed" and .[0].primaryFailureClass=="outcome-observed-cause-unobserved"' >/dev/null ||
    fail "sheet did not preserve the observed outcome"

  case_dir=$(make_case telemetry-forced-cancellation)
  write_meta "$case_dir" local-only ship
  seed_teardown_telemetry "$case_dir" || fail "could not seed forced-cancellation telemetry"
  printf 'working: attempt stopped by explicit discard decision\n' > "$case_dir/state/task-x1.status"
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --force >/dev/null || fail "forced cancellation teardown failed"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="cancelled" and .terminal.evidence.oracle=="not-run" and .terminal.gateFacts=={source:"delivery",result:"cancelled",stepReruns:null} and .terminal.primaryFailureClass=="outcome-observed-cause-unobserved")' \
    "$case_dir/data/routing-outcomes.jsonl" >/dev/null || fail "a forced teardown without an observed typed cause did not preserve its observed facts"

  case_dir=$(make_case telemetry-forced-scout-without-report)
  write_meta "$case_dir" local-only scout
  seed_teardown_telemetry "$case_dir" || fail "could not seed forced-scout telemetry"
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    run_teardown "$case_dir" --force >/dev/null || fail "forced scout teardown failed"
  jq -e 'select(.eventType=="attempt-terminal" and .terminal.classification=="cancelled" and .terminal.evidence.oracle=="not-run" and .terminal.gateFacts=={source:"delivery",result:"cancelled",stepReruns:null} and .terminal.primaryFailureClass=="outcome-observed-cause-unobserved" and .terminal.outcomeLink=={kind:"none",id:null})' \
    "$case_dir/data/routing-outcomes.jsonl" >/dev/null || fail "a forced scout without an observed typed cause did not preserve the observed outcome"
  pass "status and forced teardown paths without observed typed causes preserve the observed outcome"
}

test_teardown_preserves_telemetry_across_safety_refusals() {
  local case_dir rc
  case_dir=$(make_case telemetry-safety-refusal)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unlanded telemetry boundary"
  seed_teardown_telemetry "$case_dir" || fail "could not seed refused teardown telemetry"
  rc=0
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" run_teardown "$case_dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "unlanded work unexpectedly passed teardown"
  [ "$(jq -s 'map(select(.eventType=="attempt-terminal"))|length' "$case_dir/data/routing-outcomes.jsonl")" -eq 0 ] || fail "teardown sealed telemetry before its safety gates passed"
  pass "teardown seals telemetry only after every safety refusal has passed"
}

test_forced_teardown_still_requires_ledger_repair() {
  local case_dir rc stderr
  case_dir=$(make_case telemetry-ledger-damage)
  write_meta "$case_dir" local-only ship
  seed_teardown_telemetry "$case_dir" || fail "could not seed damaged-ledger teardown telemetry"
  rm -f "$case_dir/data/routing-outcomes.jsonl"

  set +e
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" run_teardown "$case_dir" --force >/dev/null 2> "$case_dir/stderr"
  rc=$?
  set -e
  stderr=$(cat "$case_dir/stderr")
  [ "$rc" -ne 0 ] || fail "--force bypassed the telemetry seal on a damaged ledger"
  assert_contains "$stderr" "$case_dir/data/routing-outcomes.jsonl" "damaged-ledger refusal did not name the ledger to repair"
  assert_contains "$stderr" "no flag bypasses this seal, --force included" "damaged-ledger refusal did not state that --force is no bypass"
  assert_contains "$stderr" "re-run fm-teardown.sh task-x1" "damaged-ledger refusal did not name the retry after repair"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "damaged-ledger refusal discarded task state"
  [ -d "$case_dir/wt" ] || fail "damaged-ledger refusal removed the worktree"
  pass "a damaged ledger blocks even a forced teardown and prints its repair-then-re-run route"
}

# --- reader scouts (access=reader in meta): no pool worktree to return -------
#
# A reader scout was dispatched slot-free: its worktree= is a disposable scratch
# directory, never a treehouse pool worktree. Teardown must clean it WITHOUT
# calling treehouse return, must fail loudly when the scratch dir grew a git
# checkout (evidence the reader fell back to editing, so its content may be
# unlanded work), and must refuse a reader marker on any non-scout record as a
# contradiction rather than silently skipping that task's pool return.

# Reader records are only honored with the canonical home-scoped task temp root
# and worktree=<tasktmp>/scratch, exactly as fm-spawn writes them.
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$ROOT/bin/fm-backend-hometag-lib.sh"
READER_TMP=$(
  FM_HOME="$TMP_ROOT/reader-home" FM_ROOT="$ROOT"
  fm_reader_task_tmp task-x1 || exit 1
  printf '%s\n' "$FM_READER_TASK_TMP"
) || fail "the reader temp-root owner refused to derive a path for task-x1"

make_reader_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  add_compatible_tasks_axi "$case_dir"
  # Log every treehouse invocation so reader teardowns can prove none happened.
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
if [ "\${1:-}" = return ] && [ "\${2:-}" = --force ] && [ -n "\${3:-}" ]; then
  rm -rf -- "\$3"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rm -rf "$READER_TMP" "/tmp/fm-task-x1"
  mkdir -p "$READER_TMP/scratch" "$case_dir/data/task-x1"
  printf 'notes\n' > "$READER_TMP/scratch/notes.txt"
  printf 'findings\n' > "$case_dir/data/task-x1/report.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$READER_TMP/scratch" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=scout" \
    "access=reader" \
    "tasktmp=$READER_TMP" \
    "decisions_reviewed=1"
  git clone -q --bare --shared "$case_dir/project" "$READER_TMP/scratch/repo.git"
  printf '%s\n' "$case_dir"
}

run_reader_teardown() {  # <case-dir> [teardown args...]
  local case_dir=$1
  shift
  FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" run_teardown "$case_dir" "$@"
}

test_reader_teardown_skips_pool_return_and_removes_scratch() {
  local case_dir out rc
  case_dir=$(make_reader_case reader-clean)
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "reader teardown should complete"
  assert_contains "$out" "teardown task-x1 complete" "reader teardown did not report completion"
  assert_contains "$out" "Retro acceleration:" \
    "reader teardown skipped the pre-return reminders every other non-secondmate kind gets"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "reader teardown called treehouse, but a reader holds no pool worktree to return"
  [ ! -d "$READER_TMP/scratch" ] || fail "reader teardown left the scratch directory behind"
  [ ! -d "$READER_TMP" ] || fail "reader teardown left the task temp root behind"
  [ ! -f "$case_dir/state/task-x1.meta" ] || fail "reader teardown left the task record behind"
  pass "reader teardown cleans the scratch directory without any treehouse return"
}

test_reader_teardown_retains_evidence_archive() {
  local case_dir out rc archive
  case_dir=$(make_reader_case reader-retains-archive)
  archive="$case_dir/data/task-x1/sources"
  mkdir -p "$archive"
  printf 'source capture\n' > "$archive/capture.txt"
  printf '# Archive index\n' > "$archive/index.md"
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "reader teardown with an evidence archive should complete"
  assert_contains "$out" "teardown task-x1 complete" "reader teardown did not report archive retention completion"
  [ ! -d "$READER_TMP/scratch" ] || fail "reader teardown left the scratch directory behind"
  [ ! -f "$case_dir/state/task-x1.meta" ] || fail "reader teardown left the task record behind"
  assert_present "$archive/capture.txt" "reader teardown removed retained evidence capture"
  assert_present "$archive/index.md" "reader teardown removed retained evidence index"
  pass "reader teardown removes scratch and state while retaining the evidence archive"
}

test_reader_teardown_fails_loudly_on_grown_checkout() {
  local case_dir out rc
  case_dir=$(make_reader_case reader-violation)
  git init -q "$READER_TMP/scratch/hack"
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reader scratch that grew a git checkout must refuse teardown"
  assert_contains "$out" "grew a git checkout" "reader violation refusal did not name the checkout"
  [ -d "$READER_TMP/scratch/hack/.git" ] || fail "the refusal removed the checkout it should preserve for inspection"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "the refusal discarded the task record"

  set +e
  out=$(run_reader_teardown "$case_dir" --force 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--force after explicit discard approval should complete the reader teardown"
  [ ! -d "$READER_TMP" ] || fail "forced reader teardown left the task temp root behind"
  [ ! -s "$case_dir/treehouse.log" ] || fail "forced reader teardown still called treehouse"
  pass "a checkout grown inside a reader scratch refuses teardown loudly; --force is the approved discard path"
}

test_reader_marker_on_nonscout_meta_refuses() {
  local case_dir out rc
  case_dir=$(make_reader_case reader-contradiction)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "access=reader"
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reader marker on a ship record must refuse teardown"
  assert_contains "$out" "access=reader with kind=ship" "contradiction refusal did not name the disagreeing records"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "the contradiction refusal discarded the task record"
  [ -d "$case_dir/wt" ] || fail "the contradiction refusal removed the worktree"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=scout" \
    "access=partial"
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unknown access value must refuse teardown"
  assert_contains "$out" "unknown access" "unknown-access refusal did not name the bad record"
  pass "reader markers outside kind=scout and unknown access values refuse teardown as record damage"
}

test_reader_worktree_outside_tasktmp_refuses() {
  local case_dir out rc
  case_dir=$(make_reader_case reader-escape)
  mkdir -p "$case_dir/loot"
  printf 'precious\n' > "$case_dir/loot/keep.txt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/loot" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=scout" \
    "access=reader" \
    "tasktmp=$READER_TMP" \
    "decisions_reviewed=1"
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reader worktree outside its recorded tasktmp must refuse teardown"
  assert_contains "$out" "does not resolve inside its recorded tasktmp" \
    "escape refusal did not name the containment damage"
  [ -f "$case_dir/loot/keep.txt" ] || fail "the containment refusal deleted the out-of-tasktmp directory"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "the containment refusal discarded the task record"

  set +e
  out=$(run_reader_teardown "$case_dir" --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--force must not bypass the reader worktree containment refusal"
  [ -f "$case_dir/loot/keep.txt" ] || fail "a forced containment refusal deleted the out-of-tasktmp directory"
  rm -rf "$READER_TMP"
  pass "a reader worktree outside its recorded tasktmp refuses teardown as record damage, --force included"
}
test_reader_forged_tasktmp_refuses() {
  local case_dir out rc
  case_dir=$(make_reader_case reader-forged-tasktmp)
  mkdir -p "$case_dir/loot-root/scratch"
  printf 'precious\n' > "$case_dir/loot-root/keep.txt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/loot-root/scratch" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=scout" \
    "access=reader" \
    "tasktmp=$case_dir/loot-root" \
    "decisions_reviewed=1"
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reader tasktmp pointing outside the canonical per-task temp root must refuse teardown"
  assert_contains "$out" "not this task's canonical temp root" \
    "forged-tasktmp refusal did not name the record damage"
  [ -f "$case_dir/loot-root/keep.txt" ] || fail "the forged-tasktmp refusal deleted the recorded directory"
  [ -d "$case_dir/loot-root/scratch" ] || fail "the forged-tasktmp refusal deleted the recorded scratch"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "the forged-tasktmp refusal discarded the task record"

  set +e
  out=$(run_reader_teardown "$case_dir" --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--force must not bypass the forged-tasktmp refusal"
  [ -f "$case_dir/loot-root/keep.txt" ] || fail "a forced forged-tasktmp refusal deleted the recorded directory"
  rm -rf "$READER_TMP"
  pass "a reader record with a non-canonical tasktmp refuses teardown as record damage, --force included"
}

test_reader_symlinked_tasktmp_refuses_without_deleting_target() {
  local case_dir out rc target
  case_dir=$(make_reader_case reader-symlinked-tasktmp)
  target="$case_dir/loot-root"
  mkdir -p "$target/scratch"
  printf 'precious\n' > "$target/scratch/keep.txt"
  rm -rf "$READER_TMP"
  ln -s "$target" "$READER_TMP"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$target/scratch" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=scout" \
    "access=reader" \
    "tasktmp=$target" \
    "decisions_reviewed=1"

  set +e
  out=$(run_reader_teardown "$case_dir" --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--force must not accept a symlinked reader tasktmp destruction anchor"
  assert_contains "$out" "symlinked destruction anchor" \
    "symlinked-tasktmp refusal did not name the record damage"
  [ -f "$target/scratch/keep.txt" ] || fail "the symlinked-tasktmp refusal deleted the target scratch"
  [ -L "$READER_TMP" ] || fail "the symlinked-tasktmp refusal removed the recorded anchor"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "the symlinked-tasktmp refusal discarded the task record"
  rm -f "$READER_TMP"
  pass "a symlinked reader tasktmp refuses teardown without deleting its target"
}

test_reader_symlinked_worktree_refuses_without_deleting_target() {
  local case_dir out rc target
  case_dir=$(make_reader_case reader-symlinked-worktree)
  target="$case_dir/loot-scratch"
  mkdir -p "$target"
  printf 'precious\n' > "$target/keep.txt"
  rm -rf "$READER_TMP/scratch"
  ln -s "$target" "$READER_TMP/scratch"

  set +e
  out=$(run_reader_teardown "$case_dir" --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--force must not accept a symlinked reader worktree destruction anchor"
  assert_contains "$out" "symlinked destruction anchor" \
    "symlinked-worktree refusal did not name the record damage"
  [ -f "$target/keep.txt" ] || fail "the symlinked-worktree refusal deleted the target"
  [ -L "$READER_TMP/scratch" ] || fail "the symlinked-worktree refusal removed the recorded anchor"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "the symlinked-worktree refusal discarded the task record"
  rm -rf "$READER_TMP"
  pass "a symlinked reader worktree refuses teardown without deleting its target"
}

test_reader_checkout_created_while_reaping_refuses_before_cleanup() {
  local case_dir out rc pid survived=0
  case_dir=$(make_reader_case reader-reap-checkout-race)

  ( cd "$READER_TMP/scratch" && exec perl -e '
      my ($checkout) = @ARGV;
      $SIG{TERM} = sub {
        system "git", "init", "-q", $checkout;
        exit 0;
      };
      sleep 300;
    ' "$READER_TMP/scratch/hack" ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "reader-reap-checkout-race: setup process did not start"

  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  [ "$rc" -ne 0 ] || fail "a checkout created while reaping the reader must refuse teardown"
  [ "$survived" -eq 0 ] || fail "reader-reap-checkout-race: reaped process survived"
  assert_contains "$out" "grew a git checkout" \
    "reader-reap-checkout-race: final violation scan did not refuse the new checkout"
  [ -d "$READER_TMP/scratch/hack/.git" ] || fail "reader-reap-checkout-race: refusal erased the new checkout"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "reader-reap-checkout-race: refusal discarded task metadata"
  rm -rf "$READER_TMP"
  pass "a checkout created during process reaping is preserved and refuses teardown"
}

test_reader_sibling_checkout_in_tasktmp_refuses() {
  local case_dir out rc
  case_dir=$(make_reader_case reader-sibling-violation)
  git init -q "$READER_TMP/wt"
  set +e
  out=$(run_reader_teardown "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a checkout grown beside the scratch inside the task temp root must refuse teardown"
  assert_contains "$out" "grew a git checkout" "sibling-checkout refusal did not name the checkout"
  [ -d "$READER_TMP/wt/.git" ] || fail "the refusal removed the sibling checkout it should preserve for inspection"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "the sibling-checkout refusal discarded the task record"

  set +e
  out=$(run_reader_teardown "$case_dir" --force 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--force after explicit discard approval should complete the reader teardown"
  [ ! -d "$READER_TMP" ] || fail "forced reader teardown left the task temp root behind"
  [ ! -s "$case_dir/treehouse.log" ] || fail "forced reader teardown still called treehouse"
  pass "a checkout grown beside the scratch refuses teardown loudly; the violation scan covers the whole removed temp root"
}

test_teardown_records_failed_terminal_status_and_forced_cancellation
test_local_only_zero_work_does_not_seal_accepted
test_sealed_terminal_records_the_observed_usage_source
test_local_only_sync_to_advanced_main_does_not_seal_accepted
test_local_only_missing_task_base_is_diagnosed
test_local_only_empty_commit_does_not_seal_accepted
test_local_only_delivery_seals_true_outcome_and_usage
test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_allows_when_no_linked_kit_run
test_teardown_refuses_unsealed_linked_kit_run_before_return
test_teardown_kit_seal_refusal_precedes_telemetry_seal
test_teardown_force_bypasses_unsealed_kit_run_with_durable_record
test_teardown_force_bypass_record_appends_to_existing_ledger
test_teardown_force_refuses_when_bypass_record_unwritable
test_teardown_force_refuses_when_bypass_record_is_symlink
test_teardown_reports_unrunnable_kit_seal_predicate
test_teardown_kit_gate_ignores_host_scratch_root
test_teardown_configured_kit_scripts_missing_refuses
test_teardown_allows_sealed_linked_kit_run
test_teardown_prints_retro_acceleration_before_return
test_teardown_secondmate_seam_prompt_on_subject_change
test_teardown_secondmate_seam_silent_when_same_subject
test_teardown_secondmate_kind_skips_completion_reminders
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_teardown_missing_busy_sidecar_completes
test_teardown_reaps_escalation_log_and_abandoned_lock_owner
test_herdr_teardown_clears_escalation_marker
test_herdr_teardown_legacy_missing_binding_proceeds_when_target_confirmed_gone
test_herdr_teardown_legacy_missing_binding_refuses_when_target_present
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_teardown_derives_quality_and_cost_from_observable_facts
test_teardown_notes_gate_observation_branch_mismatch
test_teardown_finishes_returned_ship_with_recorded_merged_pr
test_returned_ship_with_recorded_unmerged_pr_stays_incomplete
test_recorded_pr_merge_predicate_kills_required_mutations
test_teardown_keeps_a_green_gate_accepted_and_seals_a_cancelled_gate_without_an_observed_cause
test_teardown_preserves_telemetry_across_safety_refusals
test_forced_teardown_still_requires_ledger_repair
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_stale_index_reachable_content_allows
test_stale_index_with_new_content_still_refuses
test_stale_index_pass_does_not_bypass_landed_check
test_stale_index_local_only_merged_allows
test_missing_classifier_keeps_dirty_refusal
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_parked_own_run_is_aborted_before_teardown
test_teardown_observes_legacy_root_for_pre_rollout_task
test_teardown_observes_bound_private_root_for_post_rollout_task
test_parked_own_run_refuses_when_abort_is_unconfirmed
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
test_leaked_tasktmp_process_is_reaped
test_lsof_absent_reaps_tmux_process_group
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
test_reader_teardown_skips_pool_return_and_removes_scratch
test_reader_teardown_retains_evidence_archive
test_reader_teardown_fails_loudly_on_grown_checkout
test_reader_marker_on_nonscout_meta_refuses
test_reader_worktree_outside_tasktmp_refuses
test_reader_forged_tasktmp_refuses
test_reader_symlinked_tasktmp_refuses_without_deleting_target
test_reader_symlinked_worktree_refuses_without_deleting_target
test_reader_checkout_created_while_reaping_refuses_before_cleanup
test_reader_sibling_checkout_in_tasktmp_refuses
