#!/usr/bin/env bash
# Behavior tests for the startup pool-slot leak check (bin/fm-pool-leak-lib.sh),
# exercised through the bootstrap detect path that prints its lines.
#
# The check answers one question per Treehouse pool slot: does the task whose
# claim holds this slot still have a worker? A slot held by a finished task is
# the leak that emptied a 16-slot pool on 2026-09-15, so every such slot must be
# named with what was observed about it - and nothing may be returned, reset, or
# re-claimed by the check itself, nor any command printed that would, because a
# held slot can still carry work no branch holds.
#
# Every fixture here carries the full shape Treehouse actually writes, including
# owner_pid and owner_started_at on a slot in use. A fixture that omits a field
# the real producer always writes is not a simplification, it is a hole shaped
# exactly like the bug.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-pool-leak)

unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# One pool with one slot, a project it is a worktree of, and a home that can
# hold task records. FM_FAKE_LIVE_TARGETS names the endpoints the fake tmux
# reports as present, so a case chooses liveness without racing real processes.
make_pool_case() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin jq_bin
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/pool/1"
  git init -q "$dir/project"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  pool_state "$dir" "$dir/pool/1/project"
  fakebin=$(fm_fakebin "$dir")
  jq_bin=$(command -v jq) \
    || fail "these cases read the pool's treehouse-state.json and need jq"
  ln -sf "$jq_bin" "$fakebin/jq"
  fm_fake_exit0 "$fakebin" gh gh-axi treehouse node tasks-axi quota-axi \
    lavish-axi no-mistakes chrome-devtools-axi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  for live in ${FM_FAKE_LIVE_TARGETS:-}; do
    [ "$live" != "${4:-}" ] || exit 0
  done
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# The pool's own state file, in the shape Treehouse writes it: per worktree
# name, path, created_at, and - only while a process holds the slot - owner_pid
# and owner_started_at (epoch milliseconds). No field names a task.
pool_state() {  # <case> <slot-checkout> [pid] [started-at-ms]
  local dir=$1 path=$2 pid=${3:-} started=${4:-}
  if [ -n "$pid" ]; then
    printf '{"worktrees":[{"name":"1","path":"%s","created_at":"2026-09-15T10:00:00+09:00","owner_pid":%s,"owner_started_at":%s}]}\n' \
      "$path" "$pid" "$started" > "$dir/pool/treehouse-state.json"
  else
    printf '{"worktrees":[{"name":"1","path":"%s","created_at":"2026-09-15T10:00:00+09:00"}]}\n' \
      "$path" > "$dir/pool/treehouse-state.json"
  fi
}

# owner_started_at as Treehouse records it for a running process.
pid_started_at_ms() {  # <pid>
  local lstart epoch
  lstart=$(LC_ALL=C ps -p "$1" -o lstart=) || return 1
  lstart=${lstart#"${lstart%%[![:space:]]*}"}
  epoch=$(date -j -f '%a %b %e %T %Y' "$lstart" +%s 2>/dev/null) \
    || epoch=$(date -d "$lstart" +%s 2>/dev/null) \
    || return 1
  printf '%s\n' "$(( epoch * 1000 ))"
}

claim_slot() {  # <case> <task-id> <home>
  printf 'task=%s\nhome=%s\n' "$2" "$3" > "$1/pool/1/.fm-slot-owner"
}

run_detect() {  # <case> [live-target...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_FAKE_LIVE_TARGETS="$*" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_finished_task_still_holding_its_slot_is_named_without_a_teardown_command() {
  local dir out id=finished-task
  dir=$(make_pool_case held-by-finished-task)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"

  out=$(run_detect "$dir")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 is still held by task $id" \
    "a slot held by a task with no worker should be reported"
  assert_not_contains "$out" "fm-teardown.sh" \
    "an endpoint that did not answer must not be spent on a teardown command"
  assert_contains "$out" "FM_HOME=$dir/home $ROOT/bin/fm-crew-state.sh $id" \
    "the report should name the read-only check that confirms the task is finished"
  # Detection only: the slot, its claim, and its copy are untouched.
  assert_present "$dir/pool/1/.fm-slot-owner" "the check removed a slot claim"
  assert_present "$dir/pool/1/project/.git" "the check removed a held slot's checkout"
  assert_present "$dir/home/state/$id.meta" "the check removed a task record"
  pass "pool leak: a slot whose claimant's endpoint did not answer is named without a teardown command"
}

# A live claimant only justifies silence while its own record still names THIS
# slot. Once that record was republished onto another slot - which is how a
# claim is orphaned - the slot it left behind is reachable by no task's cleanup.
test_a_live_claimant_whose_record_names_another_slot_is_reported() {
  local dir out live started id=moved-task
  dir=$(make_pool_case live-claimant-moved-on)
  git -C "$dir/project" worktree add -q --detach "$dir/pool/2/project"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/2/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"
  ( cd "$dir/pool/2/project" && exec sleep 30 ) &
  live=$!
  started=$(pid_started_at_ms "$live") \
    || fail "this host cannot read a process start time, so the in-use fixture cannot be built"
  pool_state "$dir" "$dir/pool/2/project" "$live" "$started"

  out=$(run_detect "$dir" "firstmate:fm-$id")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 is claimed by task $id" \
    "a claim its own claimant's record no longer names should be reported"
  assert_contains "$out" "$dir/pool/2/project" \
    "the report should name the slot the claimant's record does point at"
  assert_not_contains "$out" "fm-teardown.sh" \
    "an orphaned claim must carry no destructive command"
  assert_present "$dir/pool/1/.fm-slot-owner" "the check removed an orphaned slot claim"
  pass "pool leak: a live claimant whose record names another slot leaves a reported orphan claim"
}

test_slot_held_by_a_live_worker_is_silent() {
  local dir out live started id=live-task
  dir=$(make_pool_case held-by-live-worker)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"
  # The shape a slot in use is really in: the pool records the live process its
  # `treehouse get` left holding the slot.
  ( cd "$dir/pool/1/project" && exec sleep 30 ) &
  live=$!
  started=$(pid_started_at_ms "$live") \
    || fail "this host cannot read a process start time, so the in-use fixture cannot be built"
  pool_state "$dir" "$dir/pool/1/project" "$live" "$started"

  out=$(run_detect "$dir" "firstmate:fm-$id")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  assert_not_contains "$out" "POOL_LEAK:" \
    "a slot whose worker is still running is not a leak"
  pass "pool leak: a slot whose worker is still running reports nothing"
}

test_claim_with_no_record_and_an_unreadable_claim_are_reported_differently() {
  local dir out id=vanished-task
  dir=$(make_pool_case claim-without-record)
  claim_slot "$dir" "$id" "$dir/home"
  # Discovery runs over this home's records, so the neighbour record is what
  # keeps the pool discoverable once the claimant's own record is gone, and is
  # what makes this case reachable at all.
  git -C "$dir/project" worktree add -q --detach "$dir/pool/2/project" 2>/dev/null \
    || mkdir -p "$dir/pool/2"
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/pool/2/project" "project=$dir/project" "kind=ship"

  out=$(run_detect "$dir" "firstmate:fm-neighbour")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 claims task $id" \
    "a claim whose home holds no record should be reported"
  assert_contains "$out" "no cleanup command can return that slot" \
    "the report should say why no cleanup command is offered"

  dir=$(make_pool_case unreadable-claim)
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  printf 'not-a-claim\n' > "$dir/pool/1/.fm-slot-owner"

  out=$(run_detect "$dir" "firstmate:fm-neighbour")
  assert_contains "$out" "$dir/pool/1/.fm-slot-owner" \
    "an unreadable claim should name the file to inspect"
  pass "pool leak: a claim with no record, and a claim that cannot be read, each report their own remediation"
}

test_unresolvable_backend_reports_unknown_liveness_without_a_command() {
  local dir out id=herdr-task
  dir=$(make_pool_case backend-unresolvable)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "backend=herdr" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"

  out=$(run_detect "$dir")
  assert_contains "$out" "whether its worker is still running is unknown" \
    "a backend whose CLI cannot be resolved must not be reported as a gone worker"
  assert_not_contains "$out" "fm-teardown.sh $id" \
    "no cleanup command may be offered for a liveness state that could not be read"
  pass "pool leak: a record whose backend CLI is unresolvable reports unknown liveness, not a dead worker"
}

test_a_missing_adapter_dependency_is_unknown_liveness_not_a_dead_worker() {
  local dir rc probe tool
  dir=$(make_pool_case backend-missing-jq)
  fm_write_meta "$dir/home/state/herdr-task.meta" \
    "window=firstmate:fm-herdr-task" "endpoint_task_id=herdr-task" "backend=herdr" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  fm_fake_exit0 "$dir/fakebin" herdr
  ln -sf /usr/bin/true "$dir/fakebin/treehouse"
  rm -f "$dir/fakebin/jq"
  for tool in dirname basename; do
    ln -sf "$(command -v "$tool")" "$dir/fakebin/$tool"
  done
  # $1 and $2 are positional parameters of the bash -c calls below, not of this shell.
  # shellcheck disable=SC2016
  probe='. "$1/bin/fm-backend.sh"; . "$1/bin/fm-treehouse-slot-lib.sh"; . "$1/bin/fm-pool-leak-lib.sh"; fm_pool_leak_task_state "$2" herdr-task'

  # herdr resolves, jq does not: the adapter parses its session list with jq, so
  # the liveness read cannot be trusted and must not read as a gone worker.
  rc=0
  PATH="$dir/fakebin" "$BASH" -c "$probe" _ "$ROOT" "$dir/home" || rc=$?
  [ "$rc" -eq 3 ] \
    || fail "a backend missing its jq dependency reported liveness state $rc instead of unknown"

  # The same record with every tool the adapter needs resolvable is a real
  # liveness read again, not the unknown state.
  ln -sf "$(command -v jq)" "$dir/fakebin/jq"
  rc=0
  PATH="$dir/fakebin" "$BASH" -c "$probe" _ "$ROOT" "$dir/home" || rc=$?
  [ "$rc" -ne 3 ] \
    || fail "a backend with every required tool present still reported unknown liveness"
  pass "pool leak: a missing adapter dependency reads as unknown liveness, not a dead worker"
}

test_unclaimed_slot_reports_nothing() {
  local dir out id=preclaim-task
  dir=$(make_pool_case unclaimed-slot)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"

  out=$(run_detect "$dir")
  assert_not_contains "$out" "POOL_LEAK:" \
    "an unclaimed slot has no claim to attribute and must not be reported"
  pass "pool leak: a slot carrying no claim reports nothing"
}


test_claim_with_no_home_is_reported_and_a_foreign_home_stays_silent() {
  local dir out id=homeless-task
  dir=$(make_pool_case claim-without-home)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  printf 'task=%s\nhome=\n' "$id" > "$dir/pool/1/.fm-slot-owner"

  out=$(run_detect "$dir")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 claims task $id" \
    "a claim naming a task but no home must still name the held slot"
  assert_contains "$out" "records no home" \
    "the report should say the claim carries no home"

  dir=$(make_pool_case claim-from-another-machine)
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "foreign-task" "$dir/absent-home"

  out=$(run_detect "$dir")
  assert_not_contains "$out" "POOL_LEAK:" \
    "a claim whose home does not exist here belongs to another machine and must stay silent"
  pass "pool leak: a claim with no home is reported, a claim from a home absent here is not"
}

# The pool's own state file, not the claim alone, decides whether a slot is
# still the claimant's to return. A stale claim on a slot the pool has taken
# back must never come with a command that reaps processes and resets a copy.
test_pool_state_disagreeing_with_a_claim_never_prints_a_teardown_command() {
  local dir out live started id=stale-claim-task

  dir=$(make_pool_case pool-state-dropped-slot)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"
  printf '{"worktrees":[]}\n' > "$dir/pool/treehouse-state.json"

  out=$(run_detect "$dir")
  assert_contains "$out" "lists no worktree under that slot directory" \
    "a slot the pool has taken back is a stale claim, not a held slot"
  assert_not_contains "$out" "fm-teardown.sh $id" \
    "a slot the pool has taken back must carry no teardown command"
  assert_present "$dir/pool/1/.fm-slot-owner" "the check cleared a slot claim"

  # A process is running under the slot right now. The pool records the pid, not
  # a task, so this may be a successor and nothing destructive may be offered.
  dir=$(make_pool_case pool-state-slot-in-use)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"
  ( cd "$dir/pool/1/project" && exec sleep 30 ) &
  live=$!
  started=$(pid_started_at_ms "$live") \
    || fail "this host cannot read a process start time, so the in-use fixture cannot be built"
  pool_state "$dir" "$dir/pool/1/project" "$live" "$started"

  out=$(run_detect "$dir")
  assert_contains "$out" "the pool records process $live running under that slot" \
    "a slot with a live process must be reported as in use"
  assert_not_contains "$out" "fm-teardown.sh $id" \
    "a slot with a live process must carry no teardown command"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  # The same slot once that process is gone: the pool holds a dead pid, the
  # claimant's worker is gone too, and that - only that - is the leak.
  dir=$(make_pool_case pool-state-slot-pid-dead)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"
  ( exec sleep 30 ) &
  live=$!
  started=$(pid_started_at_ms "$live") \
    || fail "this host cannot read a process start time, so the dead-pid fixture cannot be built"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  kill -0 "$live" 2>/dev/null && fail "the dead-pid fixture's process is still alive"
  pool_state "$dir" "$dir/pool/1/project" "$live" "$started"

  out=$(run_detect "$dir")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 is still held by task $id" \
    "a slot whose pool process is dead and whose endpoint did not answer is the leak"
  assert_not_contains "$out" "fm-teardown.sh" \
    "no leak shape may be handed a command that reaps processes and resets a copy"

  dir=$(make_pool_case pool-state-unreadable)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"
  printf 'not json at all\n' > "$dir/pool/treehouse-state.json"

  out=$(run_detect "$dir")
  assert_contains "$out" "could not be read" \
    "a pool state that cannot be read must be reported as unconfirmed"
  assert_not_contains "$out" "fm-teardown.sh $id" \
    "an unconfirmed slot must not be handed a destructive command"
  pass "pool leak: a dropped slot, a slot in use, and an unreadable pool state never print a teardown command"
}

# Discovery checks one record per pool to keep the git cost bounded. The record
# it happens to check first must not decide the pool for the others: an
# abandoned slot directory is the very state this detector exists for.
test_an_unusable_slot_record_does_not_hide_its_pools_other_slots() {
  local dir out id=z-stale-task
  dir=$(make_pool_case pool-with-a-broken-slot)
  # Sorts before the claimant's record, so discovery meets it first.
  mkdir -p "$dir/pool/2/project"
  fm_write_meta "$dir/home/state/a-broken.meta" \
    "window=firstmate:fm-a-broken" "endpoint_task_id=a-broken" \
    "worktree=$dir/pool/2/project" "project=$dir/project" "kind=ship"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"

  out=$(run_detect "$dir")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 is still held by task $id" \
    "a slot directory that is not a Treehouse slot hid the leak in its pool's other slot"
  pass "pool leak: a record naming an unusable slot does not hide the rest of its pool"
}

test_finished_task_still_holding_its_slot_is_named_without_a_teardown_command
test_slot_held_by_a_live_worker_is_silent
test_a_live_claimant_whose_record_names_another_slot_is_reported
test_claim_with_no_record_and_an_unreadable_claim_are_reported_differently
test_unresolvable_backend_reports_unknown_liveness_without_a_command
test_a_missing_adapter_dependency_is_unknown_liveness_not_a_dead_worker
test_unclaimed_slot_reports_nothing
test_claim_with_no_home_is_reported_and_a_foreign_home_stays_silent
test_pool_state_disagreeing_with_a_claim_never_prints_a_teardown_command
test_an_unusable_slot_record_does_not_hide_its_pools_other_slots
