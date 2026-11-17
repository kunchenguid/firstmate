#!/usr/bin/env bash
# Behavior tests for spawn admission: the inputs bin/fm-capacity.sh --admit adds
# for a fresh start (the fleet-wide working count against the cap, the project's
# GitHub CI queue with zombie runs ignored, open PR and merge-queue depth, and
# memory that is not a limit while plenty is available), the durable deferred-
# start queue (bin/fm-admission-queue.sh), the real bin/fm-spawn.sh recording a
# held start and the retry admitting it once the hold clears, the drain's
# ADMISSION section, and the worker-table cache refresh.
#
# Capacity cases run the real script against faked host probes and a fake
# gh-axi that answers from fixture JSON through the real jq expression the
# script passes, so the 24 hour zombie filter is proved on data, not on text.
# Spawn cases drive the real fm-spawn.sh with fake tmux and treehouse binaries.
# A reserve flag is the deterministic hold, so nothing depends on how busy the
# machine running the tests is.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-admission)
CAPACITY="$ROOT/bin/fm-capacity.sh"
QUEUE="$ROOT/bin/fm-admission-queue.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TABLE="$ROOT/bin/fm-worker-table.sh"
DEFER_EXIT=75

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- capacity fixtures --------------------------------------------------------

# Fake Darwin probes: <load1> <mem-free-pct> <cores> <disk-avail-kb> <memsize-bytes>.
make_probes() {  # <dir> ...
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin/uname"
  printf '%s\n' "$6" > "$fakebin/memsize"
  cat > "$fakebin/sysctl" <<SH
#!/usr/bin/env bash
case "\$2" in
  vm.loadavg) echo "{ $2 1.00 1.00 }" ;;
  kern.memorystatus_level) echo "$3" ;;
  hw.logicalcpu) echo "$4" ;;
  hw.memsize) cat "$fakebin/memsize" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/getconf"
  cat > "$fakebin/df" <<SH
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 999999999 1 $5 1% /"
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

# A fake gh-axi: answers the two reads fm-admission-lib.sh makes from fixture
# files, applying the real --jq expression it was given with jq, and logs every
# call so a case can prove nothing was asked.
make_gh() {  # <dir> <fakebin>
  local dir=$1 fakebin=$2
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
[ -z "${FM_FAKE_GH_FAIL:-}" ] || exit 1
path=$2 expr=
[ "$1" = api ] || exit 1
[ "$2" != POST ] || path=graphql
while [ "$#" -gt 0 ]; do
  [ "$1" != --jq ] || expr=$2
  shift
done
case "$path" in
  /repos/*/actions/runs*) jq -r "$expr" "$FM_FAKE_GH_RUNS" ;;
  graphql) jq -r "$expr" "$FM_FAKE_GH_GRAPH" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
  : > "$dir/gh.log"
}

write_runs() {  # <file> <fresh-queued> <zombie-queued>
  local file=$1 fresh=$2 zombies=$3 i fresh_at old_at
  fresh_at=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
  old_at=$(date -u -d '-5 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5d +%Y-%m-%dT%H:%M:%SZ)
  {
    printf '{"workflow_runs":['
    i=0
    while [ "$i" -lt "$fresh" ]; do
      [ "$i" -eq 0 ] || printf ','
      printf '{"created_at":"%s"}' "$fresh_at"
      i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$zombies" ]; do
      { [ "$i" -gt 0 ] || [ "$fresh" -gt 0 ]; } && printf ','
      printf '{"created_at":"%s"}' "$old_at"
      i=$((i + 1))
    done
    printf ']}\n'
  } > "$file"
}

write_graph() {  # <file> <open-prs> <merge-queue-entries>
  printf '{"data":{"repository":{"pullRequests":{"totalCount":%s},"mergeQueue":{"entries":{"totalCount":%s}}}}}\n' \
    "$2" "$3" > "$1"
}

# A table command that reports a fixed working count.
make_table() {  # <file> <working>
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "'{\"totals\":{\"working\":$2,\"homes\":2}}'" > "$1"
  chmod +x "$1"
}

make_cap_case() {  # <name> -> prints the case dir; sets up home, probes, gh and a github project
  local dir=$TMP_ROOT/$1 fakebin
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data"
  fakebin=$(make_probes "$dir" 0.50 60 8 20971520 68719476736)
  make_gh "$dir" "$fakebin"
  fm_git_init_commit "$dir/project"
  git -C "$dir/project" remote add origin https://github.com/acme/widgets.git
  write_runs "$dir/runs.json" 0 0
  write_graph "$dir/graph.json" 0 0
  printf '%s\n' "$dir"
}

admit() {  # <case-dir> [extra env assignments...] -> sets ADMIT_OUT and ADMIT_RC
  local dir=$1
  shift
  ADMIT_RC=0
  ADMIT_OUT=$(env PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_FAKE_GH_LOG="$dir/gh.log" \
    FM_FAKE_GH_RUNS="$dir/runs.json" FM_FAKE_GH_GRAPH="$dir/graph.json" \
    FM_ADMISSION_WORKER_TABLE="${FM_TEST_TABLE:-$dir/table-none}" FM_ADMISSION_CACHE_TTL=0 "$@" \
    "$CAPACITY" --admit --project "$dir/project" 2>&1) || ADMIT_RC=$?
}

# --- capacity cases -------------------------------------------------------------

test_fleet_working_count_is_held_against_the_cap() {
  local dir out
  dir=$(make_cap_case fleet)
  printf '3\n' > "$dir/home/config/lane-capacity"
  make_table "$dir/table" 2
  admit "$dir" FM_ADMISSION_WORKER_TABLE="$dir/table"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "two workers working fleet-wide under a cap of 3 were not admitted: $out"
  make_table "$dir/table" 3
  admit "$dir" FM_ADMISSION_WORKER_TABLE="$dir/table"
  out=$ADMIT_OUT
  expect_code "$DEFER_EXIT" "$ADMIT_RC" "a fleet at the cap was admitted: $out"
  assert_contains "$out" "fleet: 3 workers working across homes, at the cap of 3" "the hold did not name the fleet count"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/table-broken"
  chmod +x "$dir/table-broken"
  admit "$dir" FM_ADMISSION_WORKER_TABLE="$dir/table-broken"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "an unreadable fleet count held the start: $out"
  assert_contains "$out" "fleet-wide worker count could not be read" "an unreadable fleet count was not disclosed"
  pass "the fleet-wide working count holds a start at the cap, and an unreadable count admits with a warning"
}

test_ci_queue_ignores_zombie_runs() {
  local dir out
  dir=$(make_cap_case ci)
  printf '50\nmax-ci-queued 4\n' > "$dir/home/config/lane-capacity"
  write_runs "$dir/runs.json" 3 39
  admit "$dir"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "39 zombie queued runs held a start whose real queue is 3: $out"
  write_runs "$dir/runs.json" 4 39
  admit "$dir"
  out=$ADMIT_OUT
  expect_code "$DEFER_EXIT" "$ADMIT_RC" "a real queue of 4 at max-ci-queued 4 was admitted: $out"
  assert_contains "$out" "ci: 4 queued Actions runs (zombies over 24h not counted), at the max-ci-queued 4" \
    "the hold did not name the live queue depth"
  printf '50\nmax-ci-queued 0\n' > "$dir/home/config/lane-capacity"
  admit "$dir"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "max-ci-queued 0 did not disable the check: $out"
  pass "CI queue depth holds a start, zombie queued runs over 24h are never counted, and 0 disables the limit"
}

test_pr_and_merge_queue_depth_hold_a_start() {
  local dir out
  dir=$(make_cap_case prs)
  printf '50\nmax-open-prs 5\nmax-merge-queue 2\n' > "$dir/home/config/lane-capacity"
  write_graph "$dir/graph.json" 4 1
  admit "$dir"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "depths under their limits held a start: $out"
  write_graph "$dir/graph.json" 5 1
  admit "$dir"
  out=$ADMIT_OUT
  expect_code "$DEFER_EXIT" "$ADMIT_RC" "open PRs at the limit were admitted: $out"
  assert_contains "$out" "prs: 5 open pull requests, at the max-open-prs 5" "the hold did not name the open PR depth"
  write_graph "$dir/graph.json" 1 2
  admit "$dir"
  out=$ADMIT_OUT
  expect_code "$DEFER_EXIT" "$ADMIT_RC" "a full merge queue was admitted: $out"
  assert_contains "$out" "merge-queue: 2 entries, at the max-merge-queue 2" "the hold did not name the merge-queue depth"
  pass "open PR depth and merge-queue depth each hold a start at their limit"
}

test_github_reads_are_opt_in_and_fail_open() {
  local dir out
  dir=$(make_cap_case github-optin)
  printf '50\n' > "$dir/home/config/lane-capacity"
  write_runs "$dir/runs.json" 90 0
  admit "$dir"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "a home with no GitHub limit was held: $out"
  assert_equals "" "$(cat "$dir/gh.log")" "a home with no GitHub limit asked GitHub anyway"
  printf '50\nmax-ci-queued 4\n' > "$dir/home/config/lane-capacity"
  admit "$dir" FM_FAKE_GH_FAIL=1
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "an unreadable GitHub queue held a start: $out"
  assert_contains "$out" "GitHub queue depth could not be read" "an unreadable queue was not disclosed"
  git -C "$dir/project" remote set-url origin https://example.org/acme/widgets.git
  : > "$dir/gh.log"
  admit "$dir"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "a project outside github.com was held: $out"
  assert_equals "" "$(cat "$dir/gh.log")" "a project outside github.com asked GitHub"
  pass "GitHub is read only when a limit names it, only for a github.com origin, and fails open"
}

test_github_reads_are_cached_for_a_batch() {
  local dir out
  dir=$(make_cap_case cache)
  printf '50\nmax-ci-queued 4\n' > "$dir/home/config/lane-capacity"
  write_runs "$dir/runs.json" 1 0
  admit "$dir" FM_ADMISSION_CACHE_TTL=300
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "the first read was held: $out"
  admit "$dir" FM_ADMISSION_CACHE_TTL=300
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "the cached read was held: $out"
  assert_equals "2" "$(grep -c . "$dir/gh.log")" "a second verdict inside the cache window asked GitHub again"
  pass "a second verdict inside the cache window reuses the GitHub read"
}

test_ram_is_not_a_limit_while_plenty_is_available() {
  local dir out fakebin
  dir=$(make_cap_case ram)
  printf '50\n' > "$dir/home/config/lane-capacity"
  # 5 percent of 256 GB is 12.8 GB available: under the 10 percent floor, over 8 GB.
  fakebin=$(make_probes "$dir" 0.50 5 8 20971520 274877906944)
  admit "$dir"
  out=$ADMIT_OUT
  expect_code 0 "$ADMIT_RC" "12.8 GB available was held for a low percentage: $out"
  # 5 percent of 64 GB is 3.2 GB available.
  fakebin=$(make_probes "$dir" 0.50 5 8 20971520 68719476736)
  admit "$dir"
  out=$ADMIT_OUT
  expect_code "$DEFER_EXIT" "$ADMIT_RC" "3.2 GB available was admitted: $out"
  assert_contains "$out" "memory: 5% free" "the hold did not name memory"
  [ -d "$fakebin" ] || fail "probe fixture missing"
  pass "memory holds a start only when little is available, never on a low percentage alone"
}

# --- queue cases ----------------------------------------------------------------

queue_env() {  # <home> <command...>
  local home=$1
  shift
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

test_queue_records_lists_and_drops_a_held_start() {
  local home out
  home=$TMP_ROOT/queue-basic
  mkdir -p "$home/state" "$home/lab dir"
  ( cd "$home/lab dir" && queue_env "$home" "$QUEUE" add job-a --reason 'deferred: load 40 on 20 cores' -- job-a "$home/project" --mode no-mistakes --yolo off ) \
    || fail "add failed"
  sleep 1
  ( cd "$home" && queue_env "$home" "$QUEUE" add job-b -- job-b "$home/project" ) || fail "add failed"
  out=$(queue_env "$home" "$QUEUE" list)
  assert_contains "$out" "job-a held queued" "the first held start is not listed"
  assert_contains "$out" "deferred: load 40 on 20 cores" "the hold reason is not listed"
  [ "$(printf '%s\n' "$out" | head -1 | cut -d' ' -f1)" = job-a ] || fail "the oldest held start is not first: $out"
  ( cd "$home/lab dir" && queue_env "$home" "$QUEUE" add job-a --reason 'deferred: again' -- job-a "$home/project" ) || fail "re-add failed"
  out=$(queue_env "$home" "$QUEUE" list)
  assert_contains "$out" "job-a held queued" "a re-added start lost its place"
  assert_contains "$out" "tries 2 deferred: again" "a re-added start did not count the try and take the new reason"
  [ "$(printf '%s\n' "$out" | head -1 | cut -d' ' -f1)" = job-a ] || fail "a re-add moved the start behind a newer one: $out"
  out=$(queue_env "$home" "$QUEUE" section)
  assert_contains "$out" "ADMISSION: 2 start(s) held" "the drain section did not count the held starts"
  queue_env "$home" "$QUEUE" drop job-a
  out=$(queue_env "$home" "$QUEUE" list)
  assert_not_contains "$out" job-a "a dropped start is still listed"
  queue_env "$home" "$QUEUE" drop job-b
  assert_equals "" "$(queue_env "$home" "$QUEUE" section)" "an empty queue printed a section"
  if queue_env "$home" "$QUEUE" add 'bad id' -- x 2>/dev/null; then fail "an invalid task id was queued"; fi
  pass "the queue records a held start with its directory, keeps its place and counts tries on a re-add, lists oldest first, and drops"
}

# A stand-in spawn that records how it was run and answers from a script file.
make_spawn_stub() {  # <file> <log>
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\$(pwd -P)" "\$*" >> "$2"
verdict=\$(cat "$2.verdict.\$1" 2>/dev/null || cat "$2.verdict" 2>/dev/null || echo 0)
case "\$verdict" in
  75) echo "deferred: stub hold for \$1" >&2; exit 75 ;;
  0) exit 0 ;;
  *) echo "stub failure for \$1" >&2; exit "\$verdict" ;;
esac
SH
  chmod +x "$1"
}

test_retry_offers_held_starts_and_survives_every_verdict() {
  local home out log stub
  home=$TMP_ROOT/queue-retry
  mkdir -p "$home/state" "$home/lab"
  log=$home/spawn.log
  stub=$home/spawn-stub
  make_spawn_stub "$stub" "$log"
  ( cd "$home/lab" && queue_env "$home" "$QUEUE" add job-a -- job-a "$home/project" --mode no-mistakes ) || fail "add failed"
  sleep 1
  ( cd "$home" && queue_env "$home" "$QUEUE" add job-b -- job-b "$home/project" ) || fail "add failed"

  printf '75\n' > "$log.verdict"
  out=$(queue_env "$home" FM_ADMISSION_SPAWN="$stub" "$QUEUE" retry)
  assert_contains "$out" "admission: job-a still held: deferred: stub hold for job-a" "a held retry was not reported"
  assert_equals "2" "$(queue_env "$home" "$QUEUE" list | grep -c .)" "a held retry dropped an entry"
  grep -qF "$home/lab|job-a $home/project --mode no-mistakes" "$log" || fail "retry did not run the saved arguments in the saved directory: $(cat "$log")"

  printf '0\n' > "$log.verdict"
  out=$(queue_env "$home" FM_ADMISSION_SPAWN="$stub" "$QUEUE" retry)
  assert_contains "$out" "admission: started job-a" "the oldest start was not offered first"
  assert_not_contains "$out" "job-b" "a recovered host took two starts in one tick"
  out=$(queue_env "$home" "$QUEUE" list)
  assert_not_contains "$out" job-a "a started task stayed in the queue"
  assert_contains "$out" job-b "the second start was lost"
  grep -q "admission-started:job-a" "$home/state/.wake-queue" 2>/dev/null || fail "a started task was not announced to Firstmate"

  printf '3\n' > "$log.verdict"
  out=$(queue_env "$home" FM_ADMISSION_SPAWN="$stub" "$QUEUE" retry)
  assert_contains "$out" "admission: job-b failed: exit 3: stub failure for job-b" "a failed start was not reported"
  assert_contains "$(queue_env "$home" "$QUEUE" list)" "job-b failed" "a failed start was not kept visible"
  : > "$log"
  out=$(queue_env "$home" FM_ADMISSION_SPAWN="$stub" "$QUEUE" retry)
  assert_equals "" "$(cat "$log")" "a failed start was retried again"
  grep -q "admission-failed:job-b" "$home/state/.wake-queue" 2>/dev/null || fail "a failed start was not announced to Firstmate"

  queue_env "$home" "$QUEUE" drop job-b
  ( cd "$home" && queue_env "$home" "$QUEUE" add job-c -- job-c "$home/project" ) || fail "add failed"
  : > "$home/state/job-c.meta"
  : > "$log"
  out=$(queue_env "$home" FM_ADMISSION_SPAWN="$stub" "$QUEUE" retry)
  assert_contains "$out" "job-c already has a task record" "a start that is already running was not recognised"
  assert_equals "" "$(cat "$log")" "a start that already has a record was spawned again"
  pass "retry offers the oldest start first, one per tick, keeps held starts, and surfaces failed and finished ones"
}

test_retry_is_serialized_and_bounded() {
  local home out log stub i
  home=$TMP_ROOT/queue-bounded
  mkdir -p "$home/state"
  log=$home/spawn.log
  stub=$home/spawn-stub
  make_spawn_stub "$stub" "$log"
  printf '75\n' > "$log.verdict"
  for i in 1 2 3 4 5 6; do
    ( cd "$home" && queue_env "$home" "$QUEUE" add "job-$i" -- "job-$i" "$home/project" ) || fail "add failed"
  done
  out=$(queue_env "$home" FM_ADMISSION_SPAWN="$stub" FM_ADMISSION_RETRY_ATTEMPTS=2 "$QUEUE" retry)
  assert_equals "2" "$(grep -c . "$log")" "a tick tried more held starts than its bound: $out"
  assert_equals "6" "$(queue_env "$home" "$QUEUE" list | grep -c .)" "a bounded tick lost an entry"
  pass "a tick offers at most the bounded number of held starts and loses none"
}

# --- real spawn cases -----------------------------------------------------------

make_spawn_case() {  # <name> <task-id>...
  local name=$1 dir fakebin id
  shift
  dir=$TMP_ROOT/$name
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/home/projects"
  touch "$dir/home/state/.last-watcher-beat"
  printf '%s\n' codex > "$dir/home/config/crew-harness"
  fakebin=$(fm_fakebin "$dir")
  : > "$dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name= previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nprintf "treehouse %%s\\n" "$*" >> "$FM_FAKE_CALL_LOG"\nexit 0\n' > "$fakebin/treehouse"
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$dir/project"
  fm_git_add_origin "$dir/project" "$dir/project.origin.git"
  for id in "$@"; do
    mkdir -p "$dir/home/data/$id"
    cat > "$dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Prove admission for $id.

## Firstmate spec
Exercise spawn admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  done
  printf '%s\n' "$dir"
}

spawn_env() {  # <case-dir> <command...>
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_CALL_LOG="$dir/calls.log" FM_FAKE_PANE_PATH="$dir/wt" \
    FM_ADMISSION_WORKER_TABLE="$dir/table-none" FM_ADMISSION_CACHE_TTL=0 \
    PATH="$dir/fakebin:$PATH" "$@"
}

test_a_held_spawn_is_queued_then_admitted_by_retry() {
  local dir home out rc=0
  dir=$(make_spawn_case lab-spawn task-held)
  home=$dir/home
  printf '5\nreserve-flag %s captain reserved the host\n' "$dir/reserved.flag" > "$home/config/lane-capacity"
  : > "$dir/reserved.flag"
  git -C "$dir/project" worktree add --quiet -b wt-held "$dir/wt"

  out=$(cd "$dir" && spawn_env "$dir" "$SPAWN" task-held "$dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn on a reserved host was not deferred: $out"
  assert_contains "$out" "deferred: lane capacity of this home" "the deferral did not come from the admission verdict"
  assert_contains "$out" "captain reserved the host" "the deferral did not name the hold"
  assert_contains "$out" "held in the admission queue" "the deferral did not say the start is queued"
  assert_absent "$home/state/task-held.meta" "a deferred spawn published a task record"
  assert_equals "0" "$(grep -c . "$dir/calls.log")" "a deferred spawn touched the terminal or worktree pool"
  out=$(queue_env "$home" "$QUEUE" list)
  assert_contains "$out" "task-held held" "the held spawn was not recorded in the admission queue"

  assert_not_contains "$out" "fm-capacity:" "the queued reason carried a probe warning instead of the deferral line"
  assert_contains "$out" "deferred: lane capacity of this home" "the queued reason is not the deferral line"
  # The host is still reserved: the retry offers the start again and it stays held.
  out=$(cd "$dir" && spawn_env "$dir" "$QUEUE" retry 2>&1)
  assert_contains "$out" "admission: task-held still held" "a retry on a reserved host did not leave the start held"
  assert_absent "$home/state/task-held.meta" "a held retry launched the task"
  assert_contains "$(queue_env "$home" "$QUEUE" list)" "task-held held queued" "a held retry forgot the start"
  assert_contains "$(queue_env "$home" "$QUEUE" list)" "tries 2" "a held retry did not count its try"

  # The hold clears: the next retry admits and launches the same start.
  rm -f "$dir/reserved.flag"
  out=$(cd / && spawn_env "$dir" "$QUEUE" retry 2>&1)
  assert_contains "$out" "admission: started task-held" "the retry did not start the held task once the hold cleared: $out"
  assert_present "$home/state/task-held.meta" "an admitted retry published no task record"
  assert_equals "" "$(queue_env "$home" "$QUEUE" list)" "a started task stayed in the admission queue"
  pass "a spawn held by admission is queued with nothing created, stays held while the hold lasts, and starts once it clears"
}

test_load_guard_and_project_capacity_holds_are_queued_too() {
  local dir home out rc=0
  dir=$(make_spawn_case lab-other-holds task-load task-cap)
  home=$dir/home
  out=$(cd "$dir" && spawn_env "$dir" FM_LOAD1_OVERRIDE=500 "$SPAWN" task-load "$dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn above the load limit was not deferred: $out"
  assert_contains "$(queue_env "$home" "$QUEUE" list)" "task-load held" "a load-guard hold was not queued"
  printf 'project 1\n' > "$home/config/project-capacity"
  fm_write_meta "$home/state/live-a.meta" "window=firstmate:fm-live-a" "endpoint_task_id=live-a" \
    "worktree=$home/absent" "project=$dir/project" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=s-live-a"
  rc=0
  out=$(cd "$dir" && spawn_env "$dir" "$SPAWN" task-cap "$dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn beyond project capacity was not deferred: $out"
  assert_contains "$out" "task task-cap was not launched and its backlog item stays queued" "the capacity deferral lost its wording"
  assert_contains "$(queue_env "$home" "$QUEUE" list)" "task-cap held" "a project-capacity hold was not queued"
  pass "load-guard and project-capacity holds are recorded in the admission queue too"
}

test_home_without_lane_capacity_is_unchanged() {
  local dir home out rc=0
  dir=$(make_spawn_case lab-nocap task-free)
  home=$dir/home
  git -C "$dir/project" worktree add --quiet -b wt-free "$dir/wt"
  out=$(cd "$dir" && spawn_env "$dir" "$SPAWN" task-free "$dir/project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a home with no lane-capacity file refused a spawn: $out"
  assert_contains "$out" "spawned task-free" "the spawn did not launch"
  [ ! -d "$home/state/admission-queue" ] || fail "an admitted spawn created an admission queue"
  pass "a home with no config/lane-capacity spawns exactly as before and keeps no queue"
}

# --- drain and refresh ---------------------------------------------------------

test_drain_shows_held_starts() {
  local home out
  home=$(make_case drain-admission)
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$DRAIN" 2>&1)
  assert_not_contains "$out" "ADMISSION" "a home with no held start printed an ADMISSION section"
  ( cd "$home" && queue_env "$home" "$QUEUE" add job-a --reason 'deferred: stub' -- job-a "$home/project" ) || fail "add failed"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$DRAIN" 2>&1)
  assert_contains "$out" "ADMISSION: 1 start(s) held" "the drain did not show the held start"
  assert_contains "$out" "job-a held" "the drain did not list the held start"
  pass "the wake drain prints the held starts and nothing when none are held"
}

test_worker_table_refresh_runs_only_when_the_cache_is_stale() {
  local home cache stub log
  home=$TMP_ROOT/refresh
  mkdir -p "$home/state/secondmate-summary-cache" "$home/data"
  cache=$home/state/secondmate-summary-cache
  log=$home/snapshot.log
  stub=$home/snapshot-stub
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\ntouch "%s/fresh.board-input.json"\n' "$log" "$cache" > "$stub"
  chmod +x "$stub"
  : > "$log"
  refresh() { env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_WORKER_TABLE_SNAPSHOT="$stub" "$TABLE" --refresh "$@"; }

  refresh || fail "refresh with no registered secondmate failed"
  assert_equals "" "$(cat "$log")" "a home with no secondmate refreshed a cache"

  printf '%s\n' '- sm1 - a registered secondmate (home: /nowhere; scope: x; projects: ; added 2026-11-17)' > "$home/data/secondmates.md"
  touch -d '2 days ago' "$cache/old.board-input.json" 2>/dev/null || touch -t 202611010000 "$cache/old.board-input.json"
  refresh || fail "refresh of a stale cache failed"
  assert_equals "--live-board-input" "$(cat "$log")" "a stale cache was not refreshed through the snapshot"
  : > "$log"
  refresh || fail "refresh of a fresh cache failed"
  assert_equals "" "$(cat "$log")" "a fresh cache was refreshed again"
  refresh --max-age 0 || fail "refresh with --max-age 0 failed"
  assert_equals "--live-board-input" "$(cat "$log")" "--max-age 0 did not force a refresh"
  pass "the worker table refresh runs the snapshot only for a registered secondmate with a stale cache"
}

test_the_real_watcher_retries_a_held_start() {
  local home log stub i
  home=$TMP_ROOT/watcher-retry
  mkdir -p "$home/state" "$home/config" "$home/data"
  log=$home/spawn.log
  stub=$home/spawn-stub
  make_spawn_stub "$stub" "$log"
  printf '75\n' > "$log.verdict"
  ( cd "$home" && queue_env "$home" "$QUEUE" add job-w -- job-w "$home/project" ) || fail "add failed"
  fm_test_track_watcher_state "$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ADMISSION_RETRY_INTERVAL=1 FM_ADMISSION_SPAWN="$stub" \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
  i=0
  while [ "$i" -lt 100 ] && ! grep -q 'job-w' "$log" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -q 'job-w' "$log" 2>/dev/null || fail "the watcher never offered the held start again"
  assert_contains "$(queue_env "$home" "$QUEUE" list)" "job-w held" "a held retry from the watcher forgot the start"
  printf '0\n' > "$log.verdict"
  i=0
  while [ "$i" -lt 150 ] && [ -n "$(queue_env "$home" "$QUEUE" list)" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  assert_equals "" "$(queue_env "$home" "$QUEUE" list)" "the watcher did not start the held task once the hold cleared"
  pass "the real watcher offers a held start again on its poll and starts it once the hold clears"
}

test_fleet_working_count_is_held_against_the_cap
test_ci_queue_ignores_zombie_runs
test_pr_and_merge_queue_depth_hold_a_start
test_github_reads_are_opt_in_and_fail_open
test_github_reads_are_cached_for_a_batch
test_ram_is_not_a_limit_while_plenty_is_available
test_queue_records_lists_and_drops_a_held_start
test_retry_offers_held_starts_and_survives_every_verdict
test_retry_is_serialized_and_bounded
test_a_held_spawn_is_queued_then_admitted_by_retry
test_load_guard_and_project_capacity_holds_are_queued_too
test_home_without_lane_capacity_is_unchanged
test_drain_shows_held_starts
test_worker_table_refresh_runs_only_when_the_cache_is_stale
test_the_real_watcher_retries_a_held_start
echo "# all fm-admission tests passed"
