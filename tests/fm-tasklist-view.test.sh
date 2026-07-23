#!/usr/bin/env bash
# Behavior tests for the live task-list board renderer over fm-fleet-snapshot.sh.
# Covers band composition (in-flight/queued/upcoming/done), priority ordering,
# the parallel-in-flight marker, secondmate exclusion, graceful empty rendering,
# the fail-closed FM_HOME contract, the --done/--width knobs, and a proof that a
# render mutates no state/ or data/ file (it only reads through the snapshot).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/fm-tasklist-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasklist)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A tmux stub so the snapshot can read live-pane current state for the fixture.
# ship-api and ship-ui read as actively working; everything else is quiet.
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
target=""; prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$*" in *pane_current_command*) printf 'codex\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane)
    case "$target" in
      *ship-api*|*ship-search*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# A fixture with all four bands, a priority order, two parallel workers, a
# blocked queued item, a captain hold, a done PR and a done scout report, plus a
# persistent secondmate that must NOT appear on the task board.
write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/a" "$home/projects/b" "$home/secondmate-home" "$home/data/scout-task"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] scout-task - Investigate flaky login redirect data/scout-task/report.md (repo: webapp) (kind: scout) (priority: 1) (since 2026-07-20)
- [ ] ship-api - Add pagination to the events API https://github.com/acme/repo/pull/9 (repo: api) (kind: ship) (priority: 2) (since 2026-07-21)
- [ ] ship-search - Speed up the search index (repo: api) (kind: ship) (priority: 3) (since 2026-07-22)
- [ ] ship-ui - Rework the settings sidebar (repo: webapp) (kind: ship) (since 2026-07-22)

## Queued
- [ ] queued-cache - Add a caching layer to the search endpoint (repo: api) (kind: ship)
- [ ] queued-report - Weekly usage report generator (repo: analytics) (kind: ship)
- [ ] blocked-migrate - Migrate to the new pagination shape blocked-by: ship-api - waits on the API change (repo: api) (kind: ship)
- [ ] held-canary - Run the production canary (repo: api) (kind: captain) (hold: captain runs the canary) (hold-kind: captain)

## Done
- [x] done-auth - Fix OAuth token refresh https://github.com/acme/repo/pull/7 (repo: api) (kind: ship) (merged 2026-07-19)
- [x] done-scout - Audit bundle size data/done-scout/report.md (repo: webapp) (kind: scout) (reported 2026-07-18)
EOF
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" "worktree=$home/projects/a" "project=webapp" \
    "harness=codex" "kind=scout" "mode=scout"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/ship-api.meta" \
    "window=firstmate:fm-ship-api" "worktree=$home/projects/b" "project=$home/projects/b" \
    "harness=codex" "kind=ship" "mode=ship" \
    "pr=https://github.com/acme/repo/pull/9"
  printf 'working: building endpoint\n' > "$home/state/ship-api.status"
  fm_write_meta "$home/state/ship-search.meta" \
    "window=firstmate:fm-ship-search" "worktree=$home/projects/b" "project=api" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: reindexing\n' > "$home/state/ship-search.status"
  fm_write_meta "$home/state/ship-ui.meta" \
    "window=firstmate:fm-ship-ui" "worktree=$home/projects/a" "project=webapp" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'needs-decision: pick sidebar layout A or B\n' > "$home/state/ship-ui.status"
  fm_write_meta "$home/state/domain-second.meta" \
    "window=firstmate:fm-domain-second" "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" "harness=codex" "kind=secondmate" "mode=secondmate" \
    "home=$home/secondmate-home" "projects=api, webapp"
  printf 'working: watching delegated scope\n' > "$home/state/domain-second.status"
}

test_empty_fleet_renders_gracefully() {
  local home out
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$VIEW" --once --no-color --width 72)
  assert_contains "$out" "IN FLIGHT" "empty board still shows the IN FLIGHT band"
  assert_contains "$out" "nothing under way" "empty board marks in-flight as empty"
  assert_contains "$out" "none ready" "empty board marks queued as empty"
  pass "empty fleet renders every band without crashing"
}

test_board_bands_and_parallel() {
  local home fakebin out ship_line
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --once --no-color --width 96)
  assert_contains "$out" "2 in parallel" "two actively-working workers are marked parallel"
  assert_contains "$out" "ship-api" "in-flight shows the working ship task"
  ship_line=$(printf '%s\n' "$out" | grep 'ship-api' | head -1)
  assert_contains "$ship_line" "ship-api         api" "in-flight repo prefers backlog repo over meta project"
  assert_contains "$out" "Add pagination to the events API" "in-flight shows the backlog title"
  assert_contains "$out" "needs decision" "a parked worker with an open decision is flagged"
  assert_contains "$out" "queued-cache" "queued-ready shows a ready item"
  assert_contains "$out" "blocked-by: ship-api" "upcoming shows the unresolved blocker"
  assert_contains "$out" "hold: captain runs" "upcoming shows a captain hold"
  assert_contains "$out" "https://github.com/acme/repo/pull/7" "done shows the merged PR artifact"
  assert_not_contains "$out" "domain-second" "a persistent secondmate must not appear on the task board"
  pass "board composes all four bands with parallel, blocker, hold, and PR detail"
}

test_priority_ordering() {
  local home fakebin out cache_line report_line
  home=$(make_home priority)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --once --no-color --width 96)
  cache_line=$(printf '%s\n' "$out" | grep -n 'queued-cache' | head -1 | cut -d: -f1)
  report_line=$(printf '%s\n' "$out" | grep -n 'queued-report' | head -1 | cut -d: -f1)
  [ -n "$cache_line" ] && [ -n "$report_line" ] && [ "$cache_line" -lt "$report_line" ] \
    || fail "queued items must render in backlog priority order (cache before report)"
  pass "queued band preserves backlog priority order"
}

test_done_limit_and_width() {
  local home fakebin out rule_len
  home=$(make_home limits)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --once --no-color --width 96 --done 1)
  assert_contains "$out" "done-auth" "the most recent done row is shown under --done 1"
  assert_not_contains "$out" "done-scout" "--done 1 caps the done band to a single row"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --once --no-color --width 56)
  # The tabular band rows must fit the pane. Three kinds of line are intentional
  # full-length annotations exempt from the column bound: the home-path header,
  # full-URL sub-lines (indented "└ "), and the short "⚠" decision/blocked flag.
  # Measure display width in CHARACTERS (box-drawing and glyphs are multibyte),
  # counting with wc -m under a UTF-8 locale, not byte-counting awk.
  local longest line n
  longest=0
  while IFS= read -r line; do
    case "$line" in ''|FLEET*|"as of "*|*└*|*⚠*) continue ;; esac
    n=$(printf '%s' "$line" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
    [ "$n" -gt "$longest" ] && longest=$n
  done <<EOF
$out
EOF
  [ "$longest" -le 56 ] || fail "no tabular column line may exceed the requested --width (got $longest > 56)"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --once --no-color --width 48)
  rule_len=$(printf '%s\n' "$out" | grep '^─' | head -1 | tr -d '\n' | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  [ "$rule_len" -eq 56 ] || fail "--width below 56 must clamp to a 56-column rule"
  pass "--done caps the done band and --width bounds line length for narrow panes"
}

test_fail_closed_without_home() {
  local rc out
  out=$(env -u FM_HOME "$VIEW" --once 2>&1)
  rc=$?
  expect_code 1 "$rc" "unset FM_HOME must fail closed"
  assert_contains "$out" "FM_HOME is not set" "the refusal names the missing home"
  pass "the board refuses to guess a home when FM_HOME is unset"
}

test_interval_validation() {
  local home bad rc out
  home=$(make_home interval)
  for bad in 0 1..2 1.2.3; do
    out=$(FM_HOME="$home" "$VIEW" --interval "$bad" 2>&1)
    rc=$?
    expect_code 2 "$rc" "invalid --interval $bad must fail"
    assert_contains "$out" "--interval must be a positive number" "invalid --interval $bad explains the refusal"
  done
  out=$(FM_TASKLIST_INTERVAL='' FM_HOME="$home" "$VIEW" --once 2>&1)
  rc=$?
  expect_code 2 "$rc" "empty FM_TASKLIST_INTERVAL must fail"
  assert_contains "$out" "--interval must be a positive number" "empty FM_TASKLIST_INTERVAL explains the refusal"
  pass "interval validation rejects nonpositive and malformed values"
}

# Provably read-only: a full render must not create, delete, or modify any file
# under state/ or data/. The only child process is fm-fleet-snapshot.sh, itself
# read-only, so a byte-level snapshot of both trees is identical afterward.
test_render_mutates_nothing() {
  local home fakebin before after
  home=$(make_home readonly)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  before=$(cd "$home" && find state data -type f -exec cksum {} \; | sort)
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --once --no-color --width 80 >/dev/null
  after=$(cd "$home" && find state data -type f -exec cksum {} \; | sort)
  [ "$before" = "$after" ] || fail "a render changed state/ or data/ files"
  pass "rendering the board mutates no state or data file"
}

test_empty_fleet_renders_gracefully
test_board_bands_and_parallel
test_priority_ordering
test_done_limit_and_width
test_fail_closed_without_home
test_interval_validation
test_render_mutates_nothing
