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
SLOT_DIR="$HOME_DIR/data/graphify/scheduler"
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

# Moves the fixture's HEAD the way a guarded merge or fast-forward would.
commit_project() {
  printf '%s\n' "$1" >> "$PROJECT/app.py"
  git -C "$PROJECT" add app.py
  git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "fixture revision"
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
  assert_absent "$LOCK_DIR.recovery" "abandoned-lock recovery left its exclusion region behind"
  assert_contains "$(run_graph status demo)" '"state": "fresh"' "rebuild after a broken lock did not publish"
  pass "fm-graphify: live locks serialize while abandoned locks are recovered"
}

test_lifecycle_refresh_owner() {
  local before after
  commit_project 'def committed(): pass' >/dev/null
  run_graph rebuild demo >/dev/null
  before=$(graph_sha)
  # No revision or configuration change: a fresh project stays a cheap no-op.
  run_graph refresh demo 'project already current at aaa' >/dev/null \
    || fail "refresh must never fail its lifecycle caller"
  [ "$before" = "$(graph_sha)" ] || fail "refresh rebuilt an unchanged project"
  assert_contains "$(run_graph status demo)" '"state": "fresh"' "refresh invalidated an unchanged fresh graph"
  # The explicit invalidate token is what a remote merge needs: the local clone
  # still lags, so the published generation is kept but no longer offered.
  run_graph refresh demo 'project PR merged: fixture' invalidate >/dev/null \
    || fail "refresh must never fail its lifecycle caller"
  [ "$before" = "$(graph_sha)" ] || fail "invalidating refresh rebuilt an unchanged project"
  assert_contains "$(run_graph status demo)" '"state": "stale"' "refresh did not record the lifecycle event"
  # A real project revision is the only trigger for an eager rebuild.
  commit_project 'def refreshed(): pass' >/dev/null
  run_graph refresh demo 'project refreshed aaa..bbb' >/dev/null \
    || fail "refresh must never fail its lifecycle caller"
  after=$(graph_sha)
  [ "$before" != "$after" ] || fail "refresh did not rebuild after the revision moved"
  assert_contains "$(run_graph status demo)" '"state": "fresh"' "eager refresh did not publish a fresh graph"
  assert_contains "$(run_graph intake demo 'where is refreshed?')" 'Provenance:' \
    "refreshed graph was not available to bounded intake"
  pass "fm-graphify: one lifecycle owner rebuilds only on real change and never fails its caller"
}

# The lifecycle owner runs for every project on every guarded sync, so settling
# an unchanged project must not re-read the source. What status and intake report
# must be unaffected by that shortcut.
test_unchanged_refresh_does_not_reread_source() {
  local before
  commit_project 'def settled(): pass' >/dev/null
  run_graph rebuild demo >/dev/null
  before=$(graph_sha)
  printf '%s\n' 'def uncommitted(): pass' >> "$PROJECT/app.py"
  run_graph refresh demo 'project already current at aaa' >/dev/null \
    || fail "refresh must never fail its lifecycle caller"
  [ "$before" = "$(graph_sha)" ] || fail "refresh re-read source for an unchanged revision"
  assert_contains "$(run_graph status demo)" '"state": "stale"' \
    "the revision shortcut weakened what status reports"
  [ -z "$(run_graph intake demo 'where is settled?')" ] \
    || fail "the revision shortcut let intake offer a graph status calls stale"
  commit_project 'def settled_again(): pass' >/dev/null
  run_graph rebuild demo >/dev/null
  pass "fm-graphify: settling an unchanged revision skips the content hash without weakening status"
}

# A repeat that is coalesced into a running worker leaves its intent in the
# project's pending request, so the worker must honour an invalidation it was not
# itself started for.
test_coalesced_invalidate_survives() {
  local before
  commit_project 'def coalesced(): pass' >/dev/null
  run_graph rebuild demo >/dev/null
  before=$(graph_sha)
  printf '%s\n' 'project PR merged: coalesced fixture' > "$GRAPH_DIR/.refresh.invalidate"
  : > "$GRAPH_DIR/.refresh.request"
  run_graph refresh-worker demo 'project refreshed aaa..bbb' \
    || fail "the worker must not fail its caller"
  [ "$before" = "$(graph_sha)" ] || fail "a coalesced invalidate rebuilt an unchanged project"
  assert_contains "$(run_graph status demo)" '"state": "stale"' \
    "a coalesced invalidate was downgraded to the running worker's own request"
  assert_absent "$GRAPH_DIR/.refresh.invalidate" "the worker did not consume the pending invalidation"
  run_graph rebuild demo >/dev/null
  pass "fm-graphify: coalescing keeps the strongest pending request"
}

# The worker body is driven directly so coalescing and the home-wide rebuild cap
# are asserted on their own terms, with no dependence on scheduling timing.
test_scheduling_owner_coalesces_and_bounds() {
  local holder request worker
  request="$GRAPH_DIR/.refresh.request"
  worker="$GRAPH_DIR/.refresh.worker"
  run_graph cleanup demo >/dev/null
  mkdir -p "$GRAPH_DIR"
  sleep 30 &
  holder=$!
  # A live worker for this project absorbs the repeat: the request survives so
  # the running worker re-reads it instead of a second worker duplicating it.
  mkdir -p "$worker"
  printf '%s\n' "$holder" > "$worker/pid"
  : > "$request"
  run_graph refresh-worker demo 'coalesced event' || fail "a coalesced event must not fail"
  assert_present "$request" "a coalesced event discarded its outstanding request"
  assert_absent "$GRAPH_JSON" "a coalesced event rebuilt behind the live worker"
  rm -rf "$worker"
  # Every rebuild slot is taken, so the worker gives up without losing the work.
  mkdir -p "$SLOT_DIR/slot.1"
  printf '%s\n' "$holder" > "$SLOT_DIR/slot.1/pid"
  FM_HOME="$HOME_DIR" FM_GRAPHIFY_MAX_CONCURRENT_REBUILDS=1 FM_GRAPHIFY_SCHEDULE_WAIT=0 \
    "$GRAPH" refresh-worker demo 'capped event' || fail "a capped event must not fail"
  assert_present "$request" "the rebuild cap discarded outstanding work instead of deferring it"
  assert_absent "$GRAPH_JSON" "the rebuild cap was exceeded"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -rf "$SLOT_DIR/slot.1"
  # With a free worker and a free slot the same request builds the first graph.
  run_graph refresh-worker demo 'first graph' || fail "the worker must not fail its caller"
  assert_absent "$request" "the worker did not consume the request it served"
  assert_absent "$worker" "the worker did not release its project marker"
  assert_contains "$(run_graph status demo)" '"state": "fresh"' \
    "the scheduling owner did not build a first graph for a project with none"
  pass "fm-graphify: scheduling coalesces per project, bounds concurrent rebuilds, and defers rather than drops"
}

# schedule is the front door every lifecycle caller uses: it must return without
# waiting for the generation and must leave no temporary state behind.
test_schedule_returns_without_waiting() {
  local waited=0
  run_graph cleanup demo >/dev/null
  run_graph schedule demo 'detached first graph' || fail "schedule must never fail its lifecycle caller"
  while [ -d "$GRAPH_DIR/.refresh.worker" ] || [ -f "$GRAPH_DIR/.refresh.request" ]; do
    [ "$waited" -lt 300 ] || fail "the detached scheduling worker never settled"
    sleep 1
    waited=$((waited + 1))
  done
  assert_contains "$(run_graph status demo)" '"state": "fresh"' "the detached worker did not publish a graph"
  [ -z "$(find "$HOME_DIR/data/graphify" -maxdepth 1 -name 'tmp.*' -print -quit)" ] \
    || fail "a Graphify run leaked its temporary fingerprint directory"
  pass "fm-graphify: schedule returns immediately and leaves no temporary state behind"
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
test_unchanged_refresh_does_not_reread_source
test_coalesced_invalidate_survives
test_scheduling_owner_coalesces_and_bounds
test_schedule_returns_without_waiting
test_cleanup
