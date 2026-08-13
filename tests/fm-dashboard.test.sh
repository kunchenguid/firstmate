#!/usr/bin/env bash
# Behavior tests for the read-only local fleet dashboard (bin/fm-dashboard.sh).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# make_fakebin builds a fakebin whose tmux answers the probes the fleet
# snapshot and crew-state readers make, and whose no-mistakes is a no-op.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    printf 'compiling module alpha\n'
    printf 'tests: 12 passed\n'
    printf '> \n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

# make_run_fakebin adds a no-mistakes that attributes an active run to the
# current worktree branch+head, so a ship task reads as a run-step source.
make_run_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    printf 'validating review step\n'
    ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    case "${2:-}" in
      status)
        branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        head=$(git rev-parse HEAD 2>/dev/null || true)
        printf 'status: running\n'
        printf 'outcome:\n'
        printf 'branch: %s\n' "$branch"
        printf 'head: %s\n' "$head"
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# fake_gh writes a fake gh into <fakebin> that echoes <json> for any call and,
# when GH_COUNT_FILE is set, appends one line per invocation so a test can count
# how many times the server actually called gh.
fake_gh() {  # <fakebin> <json>
  local fb=$1 json=$2
  cat > "$fb/gh" <<SH
#!/usr/bin/env bash
[ -n "\${GH_COUNT_FILE:-}" ] && printf 'x\n' >> "\$GH_COUNT_FILE"
cat <<'JSON'
$json
JSON
SH
  chmod +x "$fb/gh"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

test_empty_fleet_snapshot() {
  local home out
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$DASH" --snapshot)
  printf '%s' "$out" | jq -e '
    .schema == "fm-dashboard.v1"
      and .error == null
      and (.tasks | length == 0)
  ' >/dev/null || fail "empty snapshot must have no tasks and no error: $out"
  pass "empty fleet snapshot reports an explicit empty task list"
}

test_pane_source_task_enrichment() {
  local home fakebin out
  home=$(make_home pane)
  mkdir -p "$home/projects/wt"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/wt" \
    "project=alpha" \
    "harness=claude" \
    "model=opus-4" \
    "kind=ship" \
    "mode=ship" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'working: implementing the fix\n' > "$home/state/ship-task.status"
  record_busy "$home/state" ship-task
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$DASH" --snapshot)
  printf '%s' "$out" | jq -e '
    (.tasks | length) == 1
      and .tasks[0].id == "ship-task"
      and .tasks[0].kind == "ship"
      and .tasks[0].harness == "claude"
      and .tasks[0].model == "opus-4"
      and .tasks[0].project == "alpha"
      and .tasks[0].state == "working"
      and .tasks[0].state_source == "pane"
      and .tasks[0].pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .tasks[0].validation.active == false
      and ((.tasks[0].pane_tail.lines | length) > 0)
      and .tasks[0].pane_tail.error == null
  ' >/dev/null || fail "pane task enrichment wrong: $out"
  pass "dashboard enriches a live pane worker with state, model, tail, and PR"
}

test_pane_capture_error_is_loud() {
  local home fakebin out
  home=$(make_home paneerr)
  mkdir -p "$home/projects/wt"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  printf 'working: x\n' > "$home/state/ship-task.status"
  record_busy "$home/state" ship-task
  fakebin=$(make_fakebin "$home")
  # Break the fake tmux's capture-pane so the pane tail must surface an error.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) exit 1 ;;
esac
exit 0
SH
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$DASH" --snapshot)
  printf '%s' "$out" | jq -e '
    .tasks[0].pane_tail.error != null and (.tasks[0].pane_tail.lines | length == 0)
  ' >/dev/null || fail "a pane capture failure must surface an error, not an empty tail: $out"
  pass "dashboard surfaces a pane capture failure loudly"
}

test_run_step_validation_active() {
  local home fakebin out repo wt
  home=$(make_home runstep)
  repo=$home/repo
  wt=$home/projects/wt
  mkdir -p "$home/projects"
  fm_git_worktree "$repo" "$wt" dashboard-branch
  fm_write_meta "$home/state/run-task.meta" \
    "window=firstmate:fm-run-task" \
    "worktree=$wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  printf 'working: validating\n' > "$home/state/run-task.status"
  fakebin=$(make_run_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$DASH" --snapshot)
  printf '%s' "$out" | jq -e '
    (.tasks | length) == 1
      and .tasks[0].id == "run-task"
      and .tasks[0].state_source == "run-step"
      and .tasks[0].validation.active == true
      and (.tasks[0].validation.detail | test("validating"))
  ' >/dev/null || fail "a ship task with an active run must read validation.active: $out"
  pass "dashboard surfaces the no-mistakes validation step for an active run"
}

test_pr_check_verdicts() {
  local fb success failure pending empty nongithub
  fb=$(fm_fakebin "$TMP_ROOT/prchecks")
  fake_gh "$fb" '{"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  success=$(PATH="$fb:$PATH" "$DASH" --pr-check "https://github.com/o/r/pull/1")
  printf '%s' "$success" | jq -e '.verdict == "success" and .pr_state == "OPEN" and .error == null' >/dev/null \
    || fail "success verdict wrong: $success"

  fake_gh "$fb" '{"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}'
  failure=$(PATH="$fb:$PATH" "$DASH" --pr-check "https://github.com/o/r/pull/1")
  printf '%s' "$failure" | jq -e '.verdict == "failure"' >/dev/null \
    || fail "failure verdict wrong: $failure"

  fake_gh "$fb" '{"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
  pending=$(PATH="$fb:$PATH" "$DASH" --pr-check "https://github.com/o/r/pull/1")
  printf '%s' "$pending" | jq -e '.verdict == "pending"' >/dev/null \
    || fail "pending verdict wrong: $pending"

  fake_gh "$fb" '{"state":"OPEN","statusCheckRollup":[]}'
  empty=$(PATH="$fb:$PATH" "$DASH" --pr-check "https://github.com/o/r/pull/1")
  printf '%s' "$empty" | jq -e '.verdict == "no_checks"' >/dev/null \
    || fail "no_checks verdict wrong: $empty"

  nongithub=$("$DASH" --pr-check "https://gitlab.com/o/r/-/merge_requests/1")
  printf '%s' "$nongithub" | jq -e '.error == "PR checks support github.com only"' >/dev/null \
    || fail "non-github PR must fail loud: $nongithub"
  pass "pr-check maps gh rollups to success/failure/pending/no_checks and refuses non-github"
}

test_html_page() {
  local html
  html=$("$DASH" --html --refresh 7)
  assert_contains "$html" "var REFRESH = 7;" "html must bake in the refresh interval"
  assert_contains "$html" "firstmate fleet" "html must carry the title"
  assert_contains "$html" "No live workers. The fleet is empty." "html must carry the explicit empty state"
  assert_contains "$html" "Harness / Model" "html must carry the harness/model column"
  assert_contains "$html" "Validation / Activity" "html must carry the validation column"
  assert_contains "$html" "--bg:#0d1117" "html must use a dark terminal theme"
  pass "html page carries refresh, empty state, columns, and dark theme"
}

# The serve-mode tests need a real HTTP server and client; skip them cleanly on
# a host without either, matching the snapshot-bearings optional-binary gate.
serve_tools_available() {
  command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1
}

# Serve mode: start the server against a fixture fleet, verify it binds
# loopback, serves the HTML and snapshot, and caches PR checks for the TTL.
test_serve_and_cache() {
  serve_tools_available || { pass "serve test skipped (python3 or curl absent)"; return 0; }
  local home fakebin port pid out1 out2 count_html gh_count
  home=$(make_home serve)
  mkdir -p "$home/projects/wt"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "pr=https://github.com/o/r/pull/7"
  printf 'working: building\n' > "$home/state/ship-task.status"
  record_busy "$home/state" ship-task
  fakebin=$(make_fakebin "$home")
  fake_gh "$fakebin" '{"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  GH_COUNT_FILE=$TMP_ROOT/gh-count
  : > "$GH_COUNT_FILE"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

  GH_COUNT_FILE="$GH_COUNT_FILE" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$DASH" --port "$port" --gh-cache 60 >"$TMP_ROOT/serve.log" 2>&1 &
  pid=$!

  local i=0 ready=0
  while [ "$i" -lt 50 ]; do
    if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$ready" -ne 1 ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "dashboard server did not come up: $(cat "$TMP_ROOT/serve.log")"
  fi

  out1=$(curl -fsS "http://127.0.0.1:$port/snapshot")
  out2=$(curl -fsS "http://127.0.0.1:$port/snapshot")
  count_html=$(curl -fsS "http://127.0.0.1:$port/")

  printf '%s' "$out1" | jq -e '
    (.tasks | length) == 1
      and .tasks[0].id == "ship-task"
      and .tasks[0].pr.url == "https://github.com/o/r/pull/7"
      and .tasks[0].pr.checks.verdict == "success"
      and .tasks[0].pr.checks.pr_state == "OPEN"
  ' >/dev/null || fail "served snapshot must include cached PR checks: $out1"
  printf '%s' "$out2" | jq -e '.tasks[0].pr.checks.verdict == "success"' >/dev/null \
    || fail "second snapshot must serve the same cached checks: $out2"
  gh_count=$(wc -l < "$GH_COUNT_FILE" | tr -d ' ')
  [ "$gh_count" = "1" ] || fail "gh must be called once across two refreshes (cache), got $gh_count"
  case "$count_html" in
    *"firstmate fleet"*) : ;;
    *) fail "root path must serve the dashboard HTML, got: $count_html" ;;
  esac

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "dashboard serves localhost snapshot and HTML, caching PR checks across refreshes"
}

# Empty fleet served over HTTP must render the explicit empty state.
test_serve_empty_fleet() {
  serve_tools_available || { pass "empty serve test skipped (python3 or curl absent)"; return 0; }
  local home fakebin port pid out
  home=$(make_home serveempty)
  fakebin=$(make_fakebin "$home")
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  PATH="$fakebin:$PATH" FM_HOME="$home" "$DASH" --port "$port" >"$TMP_ROOT/serve-empty.log" 2>&1 &
  pid=$!
  local i=0 ready=0
  while [ "$i" -lt 50 ]; do
    if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$ready" -ne 1 ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "empty-fleet dashboard server did not come up: $(cat "$TMP_ROOT/serve-empty.log")"
  fi
  out=$(curl -fsS "http://127.0.0.1:$port/snapshot")
  printf '%s' "$out" | jq -e '(.tasks | length) == 0 and .error == null' >/dev/null \
    || fail "empty fleet snapshot must be empty with no error: $out"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "dashboard serves an explicit empty state for an empty fleet"
}

test_usage_and_validation() {
  local out rc
  out=$("$DASH" --help)
  assert_contains "$out" "--port" "usage must document --port"
  assert_contains "$out" "--refresh" "usage must document --refresh"
  "$DASH" --port 0 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "port 0 must be refused"
  "$DASH" --host 0.0.0.0 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "non-loopback host must be refused"
  "$DASH" --refresh 0 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "refresh 0 must be refused"
  pass "usage documents flags and argument validation refuses bad values"
}

test_empty_fleet_snapshot
test_pane_source_task_enrichment
test_pane_capture_error_is_loud
test_run_step_validation_active
test_pr_check_verdicts
test_html_page
test_serve_and_cache
test_serve_empty_fleet
test_usage_and_validation
