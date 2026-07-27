#!/usr/bin/env bash
# Regression and real-package E2E coverage for managed Graphify project context.
set -euo pipefail

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-graphify)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$HOME_DIR/projects/demo"
GRAPH="$ROOT/bin/fm-graphify.sh"
mkdir -p "$PROJECT" "$HOME_DIR/data"
printf '%s\n' '- demo - Graphify fixture (added 2026-07-28)' > "$HOME_DIR/data/projects.md"
printf '%s\n' 'def hello(name):' '    return "hello " + name' > "$PROJECT/app.py"
printf '%s\n' 'TOKEN=must-not-enter-the-graph' > "$PROJECT/.env"
mkdir -p "$TMP_ROOT/outside"
printf '%s\n' 'def leaked_secret(): pass' > "$TMP_ROOT/outside/outside.py"
ln -s "$TMP_ROOT/outside/outside.py" "$PROJECT/escape.py"
fm_git_init_commit "$PROJECT"

run_graph() {
  FM_HOME="$HOME_DIR" "$GRAPH" "$@"
}

test_real_e2e_and_scope() {
  local before after status graph query intake
  status=$(run_graph status demo)
  assert_contains "$status" '"state":"missing"' "Graphify absence must be explicit before provisioning"
  run_graph install >/dev/null
  run_graph rebuild demo >/dev/null
  status=$(run_graph status demo)
  assert_contains "$status" '"state": "fresh"' "actual pinned Graphify rebuild must become fresh"
  graph="$HOME_DIR/data/graphify/projects/demo/graph.json"
  assert_present "$graph" "actual Graphify E2E did not publish a graph"
  assert_not_contains "$(<"$graph")" 'leaked_secret' "symlink escape entered the managed graph"
  assert_not_contains "$(<"$graph")" 'must-not-enter-the-graph' ".env material entered the managed graph"
  before=$(sha256sum "$graph" | awk '{print $1}')
  if FM_HOME="$HOME_DIR" FM_GRAPHIFY_MAX_GRAPH_BYTES=1 "$GRAPH" rebuild demo >/dev/null 2>&1; then
    fail "oversized generation unexpectedly published"
  fi
  after=$(sha256sum "$graph" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "failed generation changed the last valid graph"
  status=$(run_graph status demo)
  assert_contains "$status" '"state": "failed"' "failed rebuild did not retain a failed outcome"
  [ -z "$(run_graph intake demo 'where is hello?')" ] || fail "failed graph was injected into intake"
  run_graph rebuild demo >/dev/null
  query=$(FM_HOME="$HOME_DIR" FM_GRAPHIFY_QUERY_BYTES=180 "$GRAPH" query demo hello)
  [ ${#query} -le 181 ] || fail "query exceeded its byte cap"
  assert_contains "$query" 'app.py' "bounded query omitted file provenance"
  intake=$(FM_HOME="$HOME_DIR" FM_GRAPHIFY_QUERY_BYTES=180 "$GRAPH" intake demo 'where is hello?')
  assert_contains "$intake" 'Provenance:' "intake omitted graph provenance"
  printf '%s\n' 'def changed(): pass' >> "$PROJECT/app.py"
  status=$(run_graph status demo)
  assert_contains "$status" '"state": "stale"' "source revision change did not make graph stale"
  run_graph mark-stale demo 'guarded refresh fixture' >/dev/null
  status=$(run_graph status demo)
  assert_contains "$status" '"state": "stale"' "lifecycle invalidation did not persist stale state"
  run_graph cleanup demo >/dev/null
  assert_absent "$HOME_DIR/data/graphify/projects/demo" "cleanup did not remove only derived project state"
  [ -f "$PROJECT/app.py" ] || fail "cleanup touched project clone"
  pass "fm-graphify: real pinned Graphify E2E, containment, freshness, bounded intake, and cleanup"
}

test_concurrent_rebuild() {
  local first second
  run_graph rebuild demo >/dev/null
  printf '%s\n' 'def concurrent_change(): pass' >> "$PROJECT/app.py"
  FM_HOME="$HOME_DIR" FM_GRAPHIFY_BUILD_TIMEOUT=30 "$GRAPH" rebuild demo >"$TMP_ROOT/first.out" 2>&1 &
  first=$!
  tries=0
  while [ ! -d "$HOME_DIR/data/graphify/projects/demo/.build.lock" ] && [ "$tries" -lt 100 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  second=$(run_graph rebuild demo)
  wait "$first"
  assert_contains "$second" '"state":"building"' "concurrent rebuild did not serialize on the generation lock"
  pass "fm-graphify: concurrent rebuild serialization"
}

test_registered_path_refusal() {
  if FM_HOME="$HOME_DIR" "$GRAPH" status "$TMP_ROOT/outside" >/dev/null 2>&1; then
    fail "arbitrary caller path was accepted as a project"
  fi
  ln -s "$PROJECT" "$HOME_DIR/projects/alias"
  printf '%s\n' '- alias - unsafe alias (added 2026-07-28)' >> "$HOME_DIR/data/projects.md"
  if run_graph status alias >/dev/null 2>&1; then
    fail "symlinked registered project was accepted"
  fi
  pass "fm-graphify: registered identity and symlink containment refuse unsafe paths"
}

test_real_e2e_and_scope
test_concurrent_rebuild
test_registered_path_refusal
