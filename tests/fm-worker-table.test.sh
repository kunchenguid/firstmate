#!/usr/bin/env bash
# Behavioral coverage for bin/fm-worker-table.sh: the machine-readable summary
# line, per-home blocks in plain text, live main-home rows through the real
# bin/fm-crew-state.sh under faked backends, secondmate homes served from the
# cached fm-live-board-input.v1 summary (with ages recomputed, cache age
# disclosed, secondmate-kind rows excluded), busy counting that counts only
# working rows, remote and unreadable and invalid home disclosure, the
# fm-worker-table.v1 document, and the usage exits.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKER_TABLE="$ROOT/bin/fm-worker-table.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-table)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# The pinned clock: every fixture epoch and every assertion is written against
# it, so ages are deterministic and never depend on the test machine's clock.
NOW=1794296000

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
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta 2>/dev/null
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *fm-ship-working) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

write_main_fixture() {  # <home>
  local home=$1 gen
  mkdir -p "$home/state"
  # A live busy worker: its own semantic busy-state record (bin/fm-busy-lib.sh)
  # is what the current-state read consults; pane text is no state source.
  fm_write_meta "$home/state/ship-working.meta" \
    "kind=ship" "harness=claude" "model=opus" \
    "window=firstmate:fm-ship-working" "worktree=$home/projects/ship-working"
  mkdir -p "$home/projects/ship-working"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-working)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-working busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'working [at=%s]: mid-turn on the table\n' "$((NOW - 300))" \
    > "$home/state/ship-working.status"
  # A parked listener: idle record, status log ends in needs-decision, and the
  # PR comes from the meta.
  fm_write_meta "$home/state/scout-parked.meta" \
    "kind=scout" "harness=claude" "model=sonnet" \
    "window=firstmate:fm-scout-parked" "worktree=$home/projects/scout-parked" \
    "pr=https://github.com/doitdigital0495/firstmate/pull/200"
  mkdir -p "$home/projects/scout-parked"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" scout-parked)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" scout-parked idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'needs-decision [at=%s]: board open, waiting for the captain\n' "$((NOW - 7200))" \
    > "$home/state/scout-parked.status"
  # A done worker whose PR is only in the status log.
  fm_write_meta "$home/state/ship-done.meta" \
    "kind=ship" "harness=claude" "model=opus" \
    "window=firstmate:fm-ship-done" "worktree=$home/projects/ship-done"
  mkdir -p "$home/projects/ship-done"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-done)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-done idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'done [at=%s]: landed https://github.com/doitdigital0495/firstmate/pull/201\n' "$((NOW - 172800))" \
    > "$home/state/ship-done.status"
  # A registered secondmate meta: homes hold no lane, so no worker row.
  fm_write_secondmate_meta "$home/state/terp.meta" "$home"
}

# seed_secondmate_home <dir> <id>: the smallest home validate_secondmate_home
# accepts (marker, AGENTS.md, bin/, operational dirs).
seed_secondmate_home() {
  local dir=$1 id=$2
  mkdir -p "$dir/state" "$dir/data" "$dir/bin"
  printf '%s\n' "$id" > "$dir/.fm-secondmate-home"
  printf '# home\n' > "$dir/AGENTS.md"
  printf '#!/usr/bin/env bash\n' > "$dir/bin/true"
}

# cache_path <cache-dir> <id> <home>: the exact route the collector writes.
cache_path() {
  printf '%s\n%s\n%s\n' "$2" "" "$3" \
    | shasum -a 256 | awk -v dir="$1" '{print dir "/" $1 ".board-input.json"}'
}

write_cache() {  # <cache-file> <home> <generated-epoch>
  local file=$1 home=$2 gen=$3
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<EOF
{
  "schema": "fm-live-board-input.v1",
  "generated": "fixture",
  "generated_epoch": $gen,
  "fm_home": "$home",
  "tasks": [
    {
      "id": "sm-ship-pr",
      "kind": "ship",
      "harness": "pi",
      "model": "zai/glm-5.3",
      "current_state": {"state": "working", "source": "pane", "detail": "harness busy (pi-ext)"},
      "pr": {"url": "https://github.com/miko-systems/miko/pull/426", "source": "meta", "head": "fm/x"},
      "last_meaningful_event": {"type": "status", "verb": "working", "name": "sm-ship-pr",
        "note": "mid build", "emitted_at_epoch": $((NOW - 600)), "observed_at_epoch": $gen,
        "age_seconds": 0}
    },
    {
      "id": "sm-scout-held",
      "kind": "scout",
      "harness": "claude",
      "current_state": {"state": "parked", "source": "status-log", "detail": "board open"},
      "pr": {"url": null, "source": "absent", "head": null},
      "last_meaningful_event": {"type": "status", "verb": "needs-decision", "name": "sm-scout-held",
        "note": "waiting", "emitted_at_epoch": $((NOW - 259200)), "observed_at_epoch": $gen,
        "age_seconds": 0}
    },
    {
      "id": "terp",
      "kind": "secondmate",
      "harness": "echo",
      "current_state": {"state": "parked", "source": "none", "detail": "listener"},
      "pr": {"url": null, "source": "absent", "head": null},
      "last_meaningful_event": null
    }
  ]
}
EOF
}

write_registry() {  # <home> <lines...>
  local home=$1
  shift
  : > "$home/data/secondmates.md"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$home/data/secondmates.md"; done
}

local_line() {  # <id> <home>: the registered local line for a local mate
  printf '%s' "- $1 - Fixture mate (home: $2; scope: fixture; projects: ; added 2026-10-28)"
}

sm_line() {  # <home>: the registered local line for terp
  local_line terp "$1"
}

rm_line() {  # the registered remote line for far
  printf '%s' '- far - Remote mate (host: far.example; root: /srv/fm; home: /srv/fm/.firstmate; scope: fixture; projects: ; added 2026-10-28)'
}

run_table() {  # <home> [args...] -> text on stdout
  local home=$1
  shift
  local fakebin
  fakebin=$(make_fakebin "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_WORKER_TABLE_NOW_EPOCH=$NOW "$WORKER_TABLE" "$@"
}

test_usage_exits() {
  local home out rc
  home=$(make_home usage)
  out=$(run_table "$home" --bogus 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "--bogus must exit 2, got $rc"
  assert_contains "$out" "usage:" "usage error must print the usage line"
  run_table "$home" --help >/dev/null || fail "--help must exit 0"
  out=$(FM_WORKER_TABLE_CREW_STATE_TIMEOUT=0 run_table "$home" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an unbounded timeout must exit 2, got $rc"
  pass "usage errors exit 2 and --help exits 0"
}

test_empty_home() {
  local home out
  home=$(make_home empty)
  out=$(run_table "$home")
  assert_contains "$out" "workers: total=0 working=0 parked=0 idle=0 homes=1" \
    "empty home must report one home and zero workers"
  assert_contains "$out" "  (no workers)" "empty home must print its no-workers row"
  run_table "$home" --json | jq -e '
    .schema == "fm-worker-table.v1"
      and .home_id == "main"
      and (.homes | length) == 1
      and .homes[0].status == "local"
      and .homes[0].counts.total == 0
      and .totals.homes == 1 and .totals.workers == 0
  ' >/dev/null || fail "empty home document wrong"
  pass "an empty home reports zero workers without inventing any"
}

test_main_rows_live() {
  local home out
  home=$(make_home main)
  write_main_fixture "$home"
  out=$(run_table "$home")
  # 3 workers: 1 working, 1 parked, 1 done(idle); the secondmate meta is no lane.
  assert_contains "$out" "workers: total=3 working=1 parked=1 idle=1 homes=1" \
    "summary line must count only the working row as busy"
  assert_contains "$out" "ship-working  claude/opus  working  5m (working)  -" \
    "busy worker row must show harness/model, state, and record-era age"
  assert_contains "$out" "scout-parked  claude/sonnet  parked  2h (needs-decision)  https://github.com/doitdigital0495/firstmate/pull/200" \
    "parked row must show the meta PR"
  assert_contains "$out" "ship-done  claude/opus  done  2d (done)  https://github.com/doitdigital0495/firstmate/pull/201" \
    "done row must surface the status-log PR"
  case "$out" in
    *'terp  '*|*'  terp '*)
      fail "a kind=secondmate meta must not become a main-home worker row"$'\n'"--- output ---"$'\n'"$out" ;;
  esac
  pass "live main rows carry harness/model, state, progress age, and PR"
}

test_main_rows_json() {
  local home
  home=$(make_home main-json)
  write_main_fixture "$home"
  run_table "$home" --json | jq -e --argjson now "$NOW" '
    .schema == "fm-worker-table.v1" and .generated_epoch == $now
      and .home_id == "main"
      and .totals == {homes:1, working:1, parked:1, idle:1, workers:3}
      and ([.homes[0].workers[].id] == ["scout-parked","ship-done","ship-working"])
      and ([.homes[0].workers[] | select(.id == "ship-working")
            | .state, .state_class, .source, .harness, .model,
              .pr_source, .last_progress.verb,
              .last_progress.emitted_at_epoch, .last_progress.age_seconds]
           == ["working","working","pane","claude","opus",null,"working",
               $now - 300, 300])
      and ([.homes[0].workers[] | select(.id == "scout-parked")
            | .state, .state_class, .harness, .model, .pr, .pr_source]
           == ["parked","parked","claude","sonnet",
               "https://github.com/doitdigital0495/firstmate/pull/200","meta"])
      and ([.homes[0].workers[] | select(.id == "ship-done")
            | .state_class, .pr, .pr_source] == ["idle",
              "https://github.com/doitdigital0495/firstmate/pull/201","status_event"])
  ' >/dev/null || fail "main-home document rows or totals wrong"
  pass "the main-home document carries exact states, classes, and PR provenance"
}

test_cached_secondmate() {
  local home sm_home cache out gen
  home=$(make_home cached)
  sm_home=$TMP_ROOT/terp-home
  seed_secondmate_home "$sm_home" terp
  write_registry "$home" "$(sm_line "$sm_home")"
  gen=$((NOW - 7200))
  cache=$(cache_path "$home/state/secondmate-summary-cache" terp "$sm_home")
  write_cache "$cache" "$sm_home" "$gen"

  out=$(run_table "$home")
  assert_contains "$out" "workers: total=2 working=1 parked=1 idle=0 homes=2" \
    "cached home workers count toward the fleet totals, parked not busy"
  assert_contains "$out" "terp ($sm_home - cached 2h ago)" \
    "cached home must disclose its cache age"
  assert_contains "$out" "sm-ship-pr  pi/zai/glm-5.3  working  10m (working)  https://github.com/miko-systems/miko/pull/426" \
    "cached row must recompute the age against this run's clock"
  assert_contains "$out" "sm-scout-held  claude  parked  3d (needs-decision)  -" \
    "cached parked row keeps its unknown model off the line"
  case "$out" in
    *'  terp '*)
      fail "a cached kind=secondmate task row must not be a worker row"$'\n'"--- output ---"$'\n'"$out" ;;
  esac

  run_table "$home" --json | jq -e --argjson now "$NOW" --arg home "$sm_home" '
    ([.homes[] | select(.id == "terp")][0]) as $terp
    | .totals == {homes:2, working:1, parked:1, idle:0, workers:2}
      and ([.homes[].id] == ["main","terp"])
      and $terp.status == "cached"
      and $terp.home == $home
      and $terp.cache_age_s == 7200
      and $terp.observed_at_epoch == $now - 7200
      and ([$terp.workers[].id] == ["sm-ship-pr","sm-scout-held"])
      and ([$terp.workers[] | select(.id == "sm-ship-pr")
            | .state_class, .harness, .model, .source, .pr,
              .pr_source, .last_progress.age_seconds]
           == ["working","pi","zai/glm-5.3","pane",
               "https://github.com/miko-systems/miko/pull/426","meta",600])
      and ([$terp.workers[] | select(.id == "sm-scout-held") | .model, .pr] == [null, null])
  ' >/dev/null || fail "cached secondmate document wrong"
  pass "a cached secondmate serves rows, ages, and provenance from the cache"
}

test_remote_and_unreadable() {
  local home sm_home out
  home=$(make_home remote)
  sm_home=$TMP_ROOT/uncached-home
  seed_secondmate_home "$sm_home" uncached
  write_registry "$home" "$(rm_line)" "$(local_line uncached "$sm_home")"

  out=$(run_table "$home")
  assert_contains "$out" "workers: total=0 working=0 parked=0 idle=0 homes=3" \
    "remote and unreadable homes contribute no workers but stay counted as homes"
  assert_contains "$out" "far (/srv/fm/.firstmate - remote: the home is on another machine)" \
    "a remote home must say it is on another machine"
  assert_contains "$out" "uncached ($sm_home - unreadable: no valid cached worker rows for this home)" \
    "a home without a cache must be disclosed as unreadable"
  run_table "$home" --json | jq -e '
    ([.homes[] | select(.id == "far")]
     | .[0].status == "remote"
       and .[0].reason == "the home is on another machine"
       and (.[0].workers | length) == 0
       and .[0].counts.total == 0)
      and ([.homes[] | select(.id == "uncached")]
           | .[0].status == "unreadable"
             and .[0].cache_age_s == null
             and .[0].observed_at_epoch == null)
  ' >/dev/null || fail "remote/unreadable document wrong"
  pass "remote and uncached homes are disclosed, never guessed"
}

test_invalid_cache_inputs() {
  local home sm_home cache bad
  home=$(make_home invalid)
  sm_home=$TMP_ROOT/terp-invalid
  seed_secondmate_home "$sm_home" terp
  write_registry "$home" "$(sm_line "$sm_home")"
  cache=$(cache_path "$home/state/secondmate-summary-cache" terp "$sm_home")

  # A cache for a different home must be rejected.
  write_cache "$cache" "$TMP_ROOT/somewhere-else" "$((NOW - 60))"
  assert_contains "$(run_table "$home")" \
    "unreadable: no valid cached worker rows for this home" \
    "a cache naming another home must not serve rows"

  # A future generation must be rejected.
  write_cache "$cache" "$sm_home" "$((NOW + 600))"
  assert_contains "$(run_table "$home")" \
    "unreadable: no valid cached worker rows for this home" \
    "a future-dated cache must not serve rows"

  # A foreign schema must be rejected.
  bad=${cache%.board-input.json}.board-input.json
  printf '{"schema":"fm-fleet-snapshot.v1","fm_home":"%s","generated_epoch":%s}\n' \
    "$sm_home" "$((NOW - 60))" > "$bad"
  assert_contains "$(run_table "$home")" \
    "unreadable: no valid cached worker rows for this home" \
    "a foreign schema must not serve rows"
  # A superficially valid header without worker rows must not look empty.
  printf '{"schema":"fm-live-board-input.v1","fm_home":"%s","generated_epoch":%s}\n' \
    "$sm_home" "$((NOW - 60))" > "$bad"
  assert_contains "$(run_table "$home")" \
    "unreadable: no valid cached worker rows for this home" \
    "a malformed cache must not become a cached home with zero workers"
  pass "cache validation rejects wrong home, future clocks, foreign schemas, and missing tasks"
}

test_invalid_registry_home() {
  local home out
  home=$(make_home badhome)
  # A registered path that exists but is not a seeded secondmate home.
  mkdir -p "$TMP_ROOT/plain-dir"
  write_registry "$home" \
    '- plain - Not seeded (home: '"$TMP_ROOT"'/plain-dir; scope: fixture; projects: ; added 2026-10-28)'
  out=$(run_table "$home")
  assert_contains "$out" "plain ($TMP_ROOT/plain-dir - invalid: not a seeded secondmate home)" \
    "an unseeded registered home must be reported invalid"
  assert_contains "$out" "workers: total=0 working=0 parked=0 idle=0 homes=2" \
    "an invalid home adds no workers"
  pass "an unseeded registered home is disclosed as invalid"
}

test_parked_never_busy() {
  local home sm_home cache
  home=$(make_home never-busy)
  sm_home=$TMP_ROOT/terp-parked
  seed_secondmate_home "$sm_home" terp-parked
  write_registry "$home" "$(local_line terp-parked "$sm_home")"
  cache=$(cache_path "$home/state/secondmate-summary-cache" terp-parked "$sm_home")
  mkdir -p "$home/state/secondmate-summary-cache"
  # Every cached row is a parked listener; none may count as working.
  jq -n --argjson now "$NOW" '{
    schema:"fm-live-board-input.v1", generated:"p", generated_epoch:($now - 100),
    fm_home: $home, tasks: [
      {id:"listener-a", kind:"ship", harness:"pi", current_state:{state:"parked",source:"status-log"}, pr:{url:null}},
      {id:"listener-b", kind:"ship", harness:"pi", current_state:{state:"paused",source:"status-log"}, pr:{url:null}},
      {id:"listener-c", kind:"ship", harness:"pi", current_state:{state:"blocked",source:"status-log"}, pr:{url:null}}
    ]}' --arg home "$sm_home" > "$cache"
  run_table "$home" --json | jq -e '
    .totals == {homes:2, working:0, parked:3, idle:0, workers:3}
      and ([.homes[] | select(.id == "terp-parked") | .counts.total] == [3])
  ' >/dev/null || fail "parked listeners must never count as working"
  pass "parked, paused, and blocked listeners stay out of the working count"
}

test_fleet_snapshot_task_model() {
  # The cache is written by fm-fleet-snapshot.sh --live-board-input, so its
  # task rows must now carry the model field this table reads.
  local home out fakebin gen
  home=$(make_home snapshot-model)
  mkdir -p "$home/projects/w"
  fm_write_meta "$home/state/w.meta" \
    "kind=ship" "harness=claude" "model=opus" \
    "window=firstmate:fm-w" "worktree=$home/projects/w"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" w)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" w busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'working [at=%s]: building\n' "$((NOW - 30))" > "$home/state/w.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SNAPSHOT_NOW_EPOCH=$NOW "$ROOT/bin/fm-fleet-snapshot.sh" --live-board-input)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "w")
    | .model == "opus" and .harness == "claude"
  ' >/dev/null || fail "fleet snapshot task rows must carry the meta model: $out"
  pass "fleet snapshot task rows carry the model for future caches"
}

test_refresh_sweep_cadence() {
  local home sm_home cache snapshot
  home=$(make_home refresh-cadence)
  sm_home="$TMP_ROOT/refresh-second"
  seed_secondmate_home "$sm_home" terp
  write_registry "$home" "$(sm_line "$sm_home")"
  cache=$(cache_path "$home/state/secondmate-summary-cache" terp "$sm_home")
  write_cache "$cache" "$sm_home" "$NOW"
  snapshot="$home/snapshot"
  # shellcheck disable=SC2016 # Variables belong to the generated fixture.
  printf '#!/usr/bin/env bash\nprintf "sweep\\n" >> "$FM_HOME/sweeps"\nexit "${FM_TEST_SNAPSHOT_RC:-0}"\n' > "$snapshot"
  chmod +x "$snapshot"
  # Even a just-written sibling cache is not proof of a complete fleet sweep.
  FM_WORKER_TABLE_SNAPSHOT=$snapshot run_table "$home" --refresh || fail 'initial refresh failed'
  FM_WORKER_TABLE_SNAPSHOT=$snapshot run_table "$home" --refresh || fail 'cadenced refresh failed'
  [ "$(wc -l < "$home/sweeps" | tr -d ' ')" = 1 ] || fail 'successful sweep was repeated inside cadence'
  rm -f "$home/state/.worker-table-refresh-complete"
  if FM_TEST_SNAPSHOT_RC=1 FM_WORKER_TABLE_SNAPSHOT=$snapshot run_table "$home" --refresh >/dev/null 2>&1; then
    fail 'failed refresh claimed success'
  fi
  [ ! -e "$home/state/.worker-table-refresh-complete" ] || fail 'failure suppressed later refreshes'
  FM_WORKER_TABLE_SNAPSHOT=$snapshot run_table "$home" --refresh || fail 'failed sweep did not retry'
  [ "$(wc -l < "$home/sweeps" | tr -d ' ')" = 3 ] || fail 'fresh sibling cache hid a missing/failed sweep'
  pass 'fleet refresh: complete-sweep cadence, fresh sibling cannot hide missing homes, failures retry'
}

fm_test_run \
  test_refresh_sweep_cadence \
  test_usage_exits \
  test_empty_home \
  test_main_rows_live \
  test_main_rows_json \
  test_cached_secondmate \
  test_remote_and_unreadable \
  test_invalid_cache_inputs \
  test_invalid_registry_home \
  test_parked_never_busy \
  test_fleet_snapshot_task_model
