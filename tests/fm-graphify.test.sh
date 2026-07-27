#!/usr/bin/env bash
# Regression and real-package E2E coverage for managed Graphify project context.
#
# The registered-identity and no-Graphify contract cases need nothing but bash,
# so they always run. The E2E cases need the pinned local `graphifyy` venv, which
# means python3 with venv/pip support and network reach to the index; those are
# gated with the repo's standard `skip:` guards so an offline or python-less
# runner reports a clean gate skip instead of failing the whole shard.
set -euo pipefail

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-graphify)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$HOME_DIR/projects/demo"
GRAPH="$ROOT/bin/fm-graphify.sh"
GRAPH_DIR="$HOME_DIR/data/graphify/projects/demo"
GRAPH_JSON="$GRAPH_DIR/graph.json"
STATE_JSON="$GRAPH_DIR/state.json"
LOCK_DIR="$GRAPH_DIR/.build.lock"
VENV_PYTHON="$HOME_DIR/data/graphify/venv/bin/python"
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

graph_sha() {
  sha256sum "$GRAPH_JSON" | awk '{print $1}'
}

# One dead pid: the child has already been reaped, so kill -0 provably fails.
dead_pid() {
  local p
  sleep 0 &
  p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

test_unprovisioned_contract() {
  local status intake
  status=$(run_graph status demo)
  assert_contains "$status" '"state":"missing"' "Graphify absence must be explicit before provisioning"
  intake=$(run_graph intake demo 'where is hello?') || fail "intake must succeed as a no-op without Graphify"
  [ -z "$intake" ] || fail "intake produced context without a provisioned Graphify"
  pass "fm-graphify: unprovisioned home reports missing and injects nothing"
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

test_real_e2e_and_scope() {
  local before after status graph query intake
  run_graph rebuild demo >/dev/null
  status=$(run_graph status demo)
  assert_contains "$status" '"state": "fresh"' "actual pinned Graphify rebuild must become fresh"
  assert_present "$GRAPH_JSON" "actual Graphify E2E did not publish a graph"
  graph=$(<"$GRAPH_JSON")
  assert_not_contains "$graph" 'leaked_secret' "symlink escape entered the managed graph"
  assert_not_contains "$graph" 'must-not-enter-the-graph' ".env material entered the managed graph"
  assert_absent "$LOCK_DIR" "a completed rebuild left its generation lock behind"
  before=$(graph_sha)
  if FM_HOME="$HOME_DIR" FM_GRAPHIFY_MAX_GRAPH_BYTES=1 "$GRAPH" rebuild demo >/dev/null 2>&1; then
    fail "oversized generation unexpectedly published"
  fi
  after=$(graph_sha)
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
  pass "fm-graphify: real pinned Graphify E2E, containment, freshness, and bounded intake"
}

# The publish step is the last thing that can fail. An interrupted generation
# leaves state=building carrying the NEW fingerprint while graph.json is still
# the OLD published generation, so the fingerprint comparison alone would call it
# fresh and inject a pre-build graph under a post-build revision.
test_interrupted_generation_is_never_fresh() {
  local before status intake
  run_graph rebuild demo >/dev/null
  before=$(graph_sha)
  "$VENV_PYTHON" - "$STATE_JSON" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p,encoding='utf-8')); d['state']='building'
json.dump(d,open(p,'w',encoding='utf-8'))
PY
  status=$(run_graph status demo)
  assert_contains "$status" '"state": "stale"' "an unpublished generation was reported fresh"
  [ "$before" = "$(graph_sha)" ] || fail "interrupted generation changed the last valid graph"
  intake=$(run_graph intake demo 'where is hello?')
  [ -z "$intake" ] || fail "an unpublished generation was injected into intake"
  run_graph rebuild demo >/dev/null
  assert_contains "$(run_graph status demo)" '"state": "fresh"' "recovery rebuild did not republish"
  pass "fm-graphify: an interrupted generation reports stale, never fresh"
}

test_build_lock_liveness() {
  local holder second status
  # A lock held by a live process serializes both status and rebuild.
  sleep 30 &
  holder=$!
  mkdir -p "$LOCK_DIR"
  printf '%s\n' "$holder" > "$LOCK_DIR/pid"
  status=$(run_graph status demo)
  assert_contains "$status" '"state":"building"' "a live generation lock was not reported as building"
  second=$(run_graph rebuild demo)
  assert_contains "$second" '"state":"building"' "concurrent rebuild did not serialize on the generation lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  # The same lock with a provably dead holder is abandoned, not permanent.
  printf '%s\n' "$(dead_pid)" > "$LOCK_DIR/pid"
  status=$(run_graph status demo)
  assert_not_contains "$status" '"state":"building"' "an abandoned lock kept reporting building"
  run_graph rebuild demo >/dev/null
  assert_absent "$LOCK_DIR" "rebuild did not release the lock it broke and retook"
  assert_contains "$(run_graph status demo)" '"state": "fresh"' "rebuild after a broken lock did not publish"
  pass "fm-graphify: live locks serialize while abandoned locks are recovered"
}

test_lifecycle_refresh_owner() {
  local before after
  run_graph rebuild demo >/dev/null
  before=$(graph_sha)
  # No revision or configuration change: record the lifecycle event, rebuild
  # nothing, and keep the published generation byte-for-byte.
  run_graph refresh demo 'project PR merged: fixture' >/dev/null \
    || fail "refresh must never fail its lifecycle caller"
  [ "$before" = "$(graph_sha)" ] || fail "refresh rebuilt an unchanged project"
  assert_contains "$(run_graph status demo)" '"state": "stale"' "refresh did not record the lifecycle event"
  # A real source change is the only trigger for an eager rebuild.
  printf '%s\n' 'def refreshed(): pass' >> "$PROJECT/app.py"
  run_graph refresh demo 'project refreshed aaa..bbb' >/dev/null \
    || fail "refresh must never fail its lifecycle caller"
  after=$(graph_sha)
  [ "$before" != "$after" ] || fail "refresh did not rebuild after the source changed"
  assert_contains "$(run_graph status demo)" '"state": "fresh"' "eager refresh did not publish a fresh graph"
  assert_contains "$(run_graph intake demo 'where is refreshed?')" 'Provenance:' \
    "refreshed graph was not available to bounded intake"
  pass "fm-graphify: one lifecycle owner rebuilds only on real change and never fails its caller"
}

test_cleanup() {
  run_graph cleanup demo >/dev/null
  assert_absent "$GRAPH_DIR" "cleanup did not remove only derived project state"
  [ -f "$PROJECT/app.py" ] || fail "cleanup touched project clone"
  pass "fm-graphify: cleanup removes only derived project state"
}

test_unprovisioned_contract
test_registered_path_refusal

command -v python3 >/dev/null 2>&1 \
  || { echo "skip: python3 not found (required by the managed Graphify environment)"; exit 0; }
python3 -c 'import ensurepip' >/dev/null 2>&1 \
  || { echo "skip: python3 venv/pip support not available (required to provision the pinned Graphify)"; exit 0; }
if ! run_graph install >"$TMP_ROOT/install.log" 2>&1; then
  echo "skip: pinned Graphify could not be provisioned locally: $(tail -n 1 "$TMP_ROOT/install.log")"
  exit 0
fi

test_real_e2e_and_scope
test_interrupted_generation_is_never_fresh
test_build_lock_liveness
test_lifecycle_refresh_owner
test_cleanup
