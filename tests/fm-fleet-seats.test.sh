#!/usr/bin/env bash
# tests/fm-fleet-seats.test.sh - opt-in fleet-wide seat pools across a primary
# home, its registered local secondmate homes, and a remote secondmate, driven
# through bin/fm-fleet-seats.sh, the real fm-on -> remote entrypoint -> remote
# job worker transport (fake ssh on this machine), the real primary watcher
# poll, and the real bin/fm-spawn.sh and bin/fm-teardown.sh (fake tmux, real
# git worktree). Holders and supervisors are real processes.
# docs/configuration.md "Fleet seat pools" owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-seats)
SEATS="$ROOT/bin/fm-fleet-seats.sh"
HOLDER_PIDS=
REMOTE_JOBS="$TMP_ROOT/remote-jobs"

stop_remote_worker() {
  if [ -f "$REMOTE_JOBS/worker.pid" ]; then
    # shellcheck source=bin/fm-remote-job-lib.sh
    ( . "$ROOT/bin/fm-remote-job-lib.sh" && fm_remote_job_stop_worker_tree "$(cat "$REMOTE_JOBS/worker.pid")" ) || true
  fi
}

cleanup_holders() {
  local pid
  for pid in $HOLDER_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  stop_remote_worker
  fm_test_cleanup
}
trap cleanup_holders EXIT

new_holder() {  # start a fresh live holder process; sets LAST_HOLDER
  sleep 600 >/dev/null 2>&1 &
  HOLDER_PIDS="$HOLDER_PIDS $!"
  LAST_HOLDER=$!
}

make_home() {  # <dir>
  mkdir -p "$1/state" "$1/config" "$1/data"
}

pools() {  # <home> <capacity> [extra-json-fields]
  printf '{"pools":[{"name":"shared","capacity":%s,"models":["pool-model-a","pool-model-b"]}]%s}\n' \
    "$2" "${3:-}" > "$1/config/fleet-seats"
}

make_local_secondmate() {  # <dir> <root> <id>
  make_home "$1"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$1/.fm-secondmate-parent"
  printf '%s\n' "$3" > "$1/.fm-secondmate-home"
  printf -- '- %s - Test mate. (home: %s; scope: tests; projects: ; added 2026-09-28)\n' "$3" "$1" \
    >> "$2/data/secondmates.md"
}

make_remote_secondmate() {  # <dir> <id>
  make_home "$1"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$1/.fm-secondmate-parent"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
}

task_record() {  # <home> <id> <model> [kind] [extra-line]
  printf 'kind=%s\nmodel=%s\nharness=pi\n%s' "${4:-ship}" "$3" "${5:+$5
}" > "$1/state/$2.meta"
}

busy_record() {  # <home> <id> <busy|idle|unknown> [source]
  printf 'g1\n' > "$1/state/$2.busy-gen"
  printf 'v1 gen=g1 seq=1 state=%s source=%s event=test ts=1790000000\n' "$3" "${4:-pi-ext}" > "$1/state/$2.busy-state"
}

seats() {  # <home> <args...>: run the script as that home
  local home=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" "$SEATS" "$@"
}

reserve() {  # <home> <id> <model> [harness]: reserve for the most recent holder
  seats "$1" reserve "$2" --harness "${4:-pi}" --model "$3" --holder-pid "$LAST_HOLDER"
}

# used_seats <home>: the pool's current holder count, measured by a probe
# reservation whose holder is then stopped so its seat reclaims itself.
used_seats() {
  local out rc
  new_holder
  out=$(reserve "$1" zz-probe pool-model-a 2>&1)
  rc=$?
  kill "$LAST_HOLDER" 2>/dev/null
  wait "$LAST_HOLDER" 2>/dev/null
  case "$rc" in
    0) out=${out##*used=}; echo $(( ${out%% *} - 1 )) ;;
    4) out=${out#*is full (}; echo "${out%% of*}" ;;
    *) echo "probe-error:$rc:$out" ;;
  esac
}

test_no_pool_configured_is_off() {
  local home="$TMP_ROOT/off/primary" out status
  make_home "$home"
  new_holder
  out=$(reserve "$home" t1 pool-model-a 2>&1)
  status=$?
  expect_code 0 "$status" "reserve with no pool"
  assert_equals "" "$out" "reserve with no pool should print nothing"
  out=$(reserve "$home" t2 default 2>&1) || fail "a harness default was refused with no pool: $out"
  pass "without config/fleet-seats a reservation is a silent no-op"
}

test_one_capacity_across_homes() {
  local root="$TMP_ROOT/shared/primary" mate="$TMP_ROOT/shared/android" out status
  make_home "$root"
  pools "$root" 3
  make_local_secondmate "$mate" "$root" android
  # An agent launched before the pool existed holds a seat with no reservation.
  task_record "$root" legacy-r1 pool-model-a

  new_holder
  out=$(reserve "$mate" a1 pool-model-a 2>&1) || fail "secondmate reserve a1 failed: $out"
  assert_contains "$out" "used=2 capacity=3" "the legacy worker was not counted"
  new_holder
  out=$(reserve "$root" r2 pool-model-b 2>&1) || fail "primary reserve r2 failed: $out"
  assert_contains "$out" "used=3 capacity=3" "the secondmate's seat was not counted by the primary"

  new_holder
  out=$(reserve "$mate" a2 pool-model-a 2>&1)
  status=$?
  expect_code 4 "$status" "a fourth seat across the two homes"
  assert_contains "$out" "pool shared is full (3 of 3 seats held)" "full-pool refusal"
  assert_contains "$out" "legacy-r1" "the refusal did not name the holders"

  new_holder
  out=$(reserve "$mate" a1 pool-model-a 2>&1) || fail "a holder's own relaunch was refused: $out"
  assert_contains "$out" "already held" "a relaunch did not keep its seat"
  out=$(reserve "$mate" a3 some-other-model 2>&1) || fail "an unpooled model was refused: $out"
  assert_equals "" "$out" "an unpooled model should reserve nothing"
  pass "the primary and a local secondmate share one capacity and pre-existing agents count"
}

test_live_supervisors_hold_seats_even_while_idle() {
  local root="$TMP_ROOT/supervisors/primary" mate="$TMP_ROOT/supervisors/mate" out status lockholder mateholder
  make_home "$root"
  make_home "$mate"
  pools "$root" 5 ',"primary_model":"pool-model-a"'
  # A live primary session on the declared pooled model counts: no primary
  # busy record exists, so a live session is indeterminate.
  new_holder
  lockholder=$LAST_HOLDER
  printf '%s\n' "$lockholder" > "$root/state/.lock"
  task_record "$root" mate-busy pool-model-a secondmate
  busy_record "$root" mate-busy busy
  task_record "$root" mate-idle pool-model-a secondmate "home=$mate"
  new_holder
  mateholder=$LAST_HOLDER
  printf '%s\n' "$mateholder" > "$mate/state/.lock"
  busy_record "$root" mate-idle idle
  task_record "$root" mate-untrusted pool-model-a secondmate
  busy_record "$root" mate-untrusted idle claude-hook
  task_record "$root" mate-remote pool-model-b secondmate 'remote_host=shop-host'
  busy_record "$root" mate-remote idle
  task_record "$root" mate-other some-other-model secondmate

  out=$(used_seats "$root")
  assert_equals 5 "$out" "all four supervisors plus the live primary"
  new_holder
  out=$(reserve "$root" w1 pool-model-a 2>&1)
  status=$?
  expect_code 4 "$status" "a worker while supervisors fill the pool"
  assert_contains "$out" ".primary" "the primary supervisor was not named as a holder"
  assert_contains "$out" "mate-idle" "an idle supervisor did not hold its seat"

  busy_record "$root" mate-busy idle
  assert_equals 5 "$(used_seats "$root")" "an idle transition released a reserved supervisor seat"
  kill "$lockholder"
  wait "$lockholder" 2>/dev/null
  assert_equals 4 "$(used_seats "$root")" "the primary's death did not release its seat"
  task_record "$root" mate-idle some-other-model secondmate
  assert_equals 3 "$(used_seats "$root")" "a supervisor's model exit did not release its seat"
  task_record "$root" mate-idle pool-model-a secondmate "home=$mate"
  kill "$mateholder"
  wait "$mateholder" 2>/dev/null
  assert_equals 3 "$(used_seats "$root")" "a dead secondmate supervisor retained a seat"
  pass "live pooled supervisors keep seats while idle and release them on death or model exit"
}

test_explicit_model_required_while_pooled() {
  local root="$TMP_ROOT/explicit/primary" out status
  make_home "$root"
  pools "$root" 6
  new_holder
  out=$(reserve "$root" d1 default pi 2>&1)
  status=$?
  expect_code 5 "$status" "a multi-provider harness default while pooled"
  assert_contains "$out" "pass an explicit --model" "explicit-model refusal reason"
  out=$(reserve "$root" d2 default omp 2>&1)
  expect_code 5 "$?" "an omp default while pooled"
  out=$(reserve "$root" d3 default claude 2>&1) || fail "a single-provider default was refused: $out"
  pass "a harness default that could be pooled is refused while pools exist"
}

test_stale_reservations_recover_without_preempting_live_work() {
  local root="$TMP_ROOT/stale/primary" out status crashed live
  make_home "$root"
  pools "$root" 2
  new_holder
  out=$(reserve "$root" crashed pool-model-a 2>&1) || fail "reserve crashed: $out"
  crashed=$LAST_HOLDER
  new_holder
  out=$(reserve "$root" running pool-model-a 2>&1) || fail "reserve running: $out"
  live=$LAST_HOLDER
  # The running task published its record; its spawner then exited.
  task_record "$root" running pool-model-a
  kill "$live" "$crashed"
  wait "$live" "$crashed" 2>/dev/null

  new_holder
  out=$(reserve "$root" next pool-model-a 2>&1) || fail "a crashed spawn's seat was not recovered: $out"
  assert_contains "$out" "used=2 capacity=2" "recovery count"
  new_holder
  out=$(reserve "$root" extra pool-model-a 2>&1)
  expect_code 4 "$?" "the running worker's seat was preempted"

  # A relaunch onto another route releases the seat through its record.
  task_record "$root" running gpt-other
  new_holder
  out=$(reserve "$root" extra pool-model-a 2>&1) || fail "a relaunch onto another route kept its seat: $out"
  pass "dead reservations are reclaimed while a live task record keeps its seat"
}

test_simultaneous_reservations_never_overbook() {
  local root="$TMP_ROOT/race/primary" mate="$TMP_ROOT/race/mate" dir="$TMP_ROOT/race/out" i home granted refused racers=
  make_home "$root"
  pools "$root" 6
  make_local_secondmate "$mate" "$root" mate
  mkdir -p "$dir"
  new_holder
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    home=$root
    [ $((i % 2)) -eq 0 ] || home=$mate
    ( reserve "$home" "race-$i" pool-model-a >"$dir/$i.out" 2>&1; echo $? > "$dir/$i.rc" ) &
    racers="$racers $!"
  done
  # shellcheck disable=SC2086 # one pid per word
  wait $racers
  granted=$(grep -lx 0 "$dir"/*.rc | wc -l | tr -d ' ')
  refused=$(grep -lx 4 "$dir"/*.rc | wc -l | tr -d ' ')
  assert_equals 6 "$granted" "granted seats under contention: $(cat "$dir"/*.out)"
  assert_equals 6 "$refused" "refused seats under contention"
  pass "twelve simultaneous reservations from two homes grant exactly six seats"
}

test_unreachable_or_malformed_authority_refuses() {
  local base="$TMP_ROOT/unreachable" root mate out status
  root="$base/primary"
  make_home "$root"
  pools "$root" 6
  bash -c '. "$1/bin/fm-wake-lib.sh" && fm_lock_try_acquire "$2" && : > "$3" && exec sleep 600' \
    _ "$ROOT" "$root/state/.fleet-seats.lock" "$base/locked" &
  HOLDER_PIDS="$HOLDER_PIDS $!"
  blocker=$!
  for _ in $(seq 1 50); do
    [ -e "$base/locked" ] && break
    sleep 0.1
  done
  [ -e "$base/locked" ] || fail "the blocking lock holder never started"
  new_holder
  out=$(reserve "$root" l1 pool-model-a 2>&1)
  status=$?
  expect_code 5 "$status" "a lock held by another live process"
  assert_contains "$out" "stayed held" "lock refusal reason"
  kill "$blocker" 2>/dev/null
  wait "$blocker" 2>/dev/null

  out=$(seats "$root" reserve l2 --harness pi --model pool-model-a --holder-pid 999999 2>&1)
  expect_code 5 "$?" "a dead holder pid"

  mate="$base/mate"
  make_local_secondmate "$mate" "$root" mate
  printf 'invalid-parent-record\n' > "$mate/.fm-secondmate-parent"
  new_holder
  out=$(reserve "$mate" broken pool-model-a 2>&1)
  expect_code 5 "$?" "a secondmate whose root binding is broken"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
  mv "$mate/state" "$mate/state-away"
  new_holder
  out=$(reserve "$root" missing pool-model-a 2>&1)
  expect_code 5 "$?" "a registered local home whose state directory is missing"
  mv "$mate/state-away" "$mate/state"
  chmod 000 "$mate/state"
  new_holder
  out=$(reserve "$root" l3 pool-model-a 2>&1)
  status=$?
  chmod 755 "$mate/state"
  if [ "$(id -u)" -ne 0 ]; then
    expect_code 5 "$status" "a registered home whose tasks cannot be listed"
  fi

  # A registry record whose structured suffix is broken would hide that
  # home's agents, so the count refuses rather than skipping it.
  printf -- '- broken - Mate with a damaged record. (home: %s; added 2026-09-28)\n' "$mate" >> "$root/data/secondmates.md"
  out=$(reserve "$root" l4 pool-model-a 2>&1)
  status=$?
  expect_code 5 "$status" "a malformed secondmate registry record"
  assert_contains "$out" "unparseable secondmate registry line" "malformed registry refusal reason"

  printf '{"pools":[{"name":"shared","capacity":"six","models":["pool-model-a"]}]}\n' > "$root/config/fleet-seats"
  out=$(reserve "$root" l5 unrelated-model 2>&1)
  expect_code 5 "$?" "a malformed pool declaration"
  assert_contains "$out" "malformed" "malformed refusal reason"
  pass "a held lock, a dead holder, a missing or unreadable home, and malformed records refuse"
}

# --- remote secondmates -----------------------------------------------------

make_fake_ssh() {  # <fakebin>
  cat > "$1/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
[ ! -e "${FM_TEST_SSH_DOWN:-/nonexistent}" ] || exit 255
[ "$1" = shop-host ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
  chmod +x "$1/fake-ssh"
}

# Sets R_ROOT (primary), R_LOCAL (local secondmate), R_REMOTE (remote home).
# The remote home starts with no inherited declaration: the root's serve pass
# is what delivers the policy.
make_remote_fleet() {  # <name> <capacity>
  local base="$TMP_ROOT/$1" fakebin
  R_ROOT="$base/primary"
  R_LOCAL="$base/android"
  R_REMOTE="$base/theshop"
  make_home "$R_ROOT"
  pools "$R_ROOT" "$2"
  make_local_secondmate "$R_LOCAL" "$R_ROOT" android
  make_remote_secondmate "$R_REMOTE" theshop
  printf -- '- theshop - Test remote mate. (host: shop-host; root: %s; home: %s; scope: shop work; projects: ; added 2026-09-28)\n' \
    "$ROOT" "$R_REMOTE" >> "$R_ROOT/data/secondmates.md"
  fakebin=$(fm_fakebin "$base/fake")
  make_fake_ssh "$fakebin"
  R_SSH="$fakebin/fake-ssh"
  R_SSH_DOWN="$base/ssh-down"
}

serve_remotes() {  # run the root's serve pass with the fake transport
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$R_ROOT" FM_SSH_BIN="$R_SSH" FM_TEST_SSH_DOWN="$R_SSH_DOWN" \
    FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$REMOTE_JOBS" \
    FM_FLEET_SEATS_TEST_BACKOFF=0 "$SEATS" serve-remotes
}

# remote_reserve_bg <id> <model> <out-prefix>: start a waiting remote reservation.
remote_reserve_bg() {
  new_holder
  ( FM_FLEET_SEATS_TEST_REMOTE_WAIT="${FM_TEST_REMOTE_WAIT:-60}" reserve "$R_REMOTE" "$1" "$2" \
      > "$3.out" 2>&1; echo $? > "$3.rc" ) &
  BG_PID=$!
  for _ in $(seq 1 100); do
    [ -n "$(find "$R_REMOTE/state/fleet-seats" -name '*.req' 2>/dev/null)" ] && return 0
    sleep 0.1
  done
  fail "remote reservation $1 never filed its request: $(cat "$3.out" 2>/dev/null)"
}

test_remote_policy_must_be_confirmed_before_any_grant() {
  local out status
  make_remote_fleet remote-policy 3
  # An agent already running on the remote before the pool was enabled.
  task_record "$R_REMOTE" shop-legacy pool-model-a
  new_holder
  out=$(reserve "$R_ROOT" p1 pool-model-a 2>&1)
  status=$?
  expect_code 5 "$status" "a local grant before the remote confirmed the policy"
  assert_contains "$out" "have not confirmed the current seat policy" "unconfirmed-remote refusal"

  out=$(serve_remotes 2>&1) || fail "first serve failed: $out"
  assert_contains "$out" "served theshop" "the remote was not served"
  assert_contains "$out" "holders=1" "the already-running remote agent was not reported"
  out=$(used_seats "$R_ROOT")
  assert_equals 1 "$out" "the already-running remote agent is counted at the primary"
  rm -f "$R_ROOT/state/fleet-seats/remote-theshop.holders"
  new_holder
  out=$(reserve "$R_ROOT" absent-snapshot pool-model-a 2>&1)
  expect_code 5 "$?" "a confirmed remote with no holder snapshot"
  serve_remotes >/dev/null 2>&1 || fail "snapshot recovery serve failed"

  # A changed policy is unconfirmed again until the next serve.
  pools "$R_ROOT" 4
  new_holder
  out=$(reserve "$R_ROOT" p2 pool-model-a 2>&1)
  expect_code 5 "$?" "a grant under a policy the remote has not confirmed"
  serve_remotes >/dev/null 2>&1 || fail "second serve failed"
  new_holder
  out=$(reserve "$R_ROOT" p2 pool-model-a 2>&1) || fail "a grant after confirmation was refused: $out"
  assert_contains "$out" "used=2 capacity=4" "count after confirmation"
  pass "the primary requires a current policy and readable snapshot for every remote"
}

test_remote_home_shares_the_fleet_capacity() {
  local out dir="$TMP_ROOT/remote-share-out" r1_holder
  make_remote_fleet remote-share 3
  mkdir -p "$dir"
  task_record "$R_ROOT" legacy-r pool-model-a
  serve_remotes >/dev/null 2>&1 || fail "initial serve failed"

  remote_reserve_bg shop-1 pool-model-a "$dir/shop-1"
  r1_holder=$LAST_HOLDER
  out=$(serve_remotes 2>&1) || fail "serve pass failed: $out"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/shop-1.rc")" "remote reservation shop-1: $(cat "$dir/shop-1.out")"
  assert_contains "$(cat "$dir/shop-1.out")" "granted by the fleet root" "remote grant"

  new_holder
  out=$(reserve "$R_LOCAL" a1 pool-model-a 2>&1) || fail "local reserve a1 failed: $out"
  new_holder
  out=$(reserve "$R_LOCAL" a2 pool-model-a 2>&1)
  expect_code 4 "$?" "a local reservation while the remote holds a seat"
  assert_contains "$out" "remote:theshop" "the remote seat is not counted at the primary"

  remote_reserve_bg shop-2 pool-model-a "$dir/shop-2"
  serve_remotes >/dev/null 2>&1 || fail "second serve pass failed"
  wait "$BG_PID"
  expect_code 4 "$(cat "$dir/shop-2.rc")" "a remote reservation into a full fleet: $(cat "$dir/shop-2.out")"
  assert_contains "$(cat "$dir/shop-2.out")" "pool shared is full (3 of 3" "remote denial reason"

  # A relaunch of a seated remote id keeps its seat with no round trip.
  remote_reserve_bg shop-1 pool-model-a "$dir/shop-1-relaunch"
  r1_holder=$LAST_HOLDER
  serve_remotes >/dev/null 2>&1 || fail "remote relaunch serve failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/shop-1-relaunch.rc")" "a seated remote relaunch"

  # The remote spawn dies before publishing its record: the next serve frees
  # its seat, which becomes usable locally.
  kill "$r1_holder"
  wait "$r1_holder" 2>/dev/null
  serve_remotes >/dev/null 2>&1 || fail "recovery serve failed"
  new_holder
  out=$(reserve "$R_LOCAL" a2 pool-model-a 2>&1) || fail "the freed remote seat was not reusable locally: $out"
  pass "primary, local, and remote homes share one capacity; remote grants, denials, relaunches, and recovery hold"
}

test_unreachable_remote_is_never_free() {
  local out status dir="$TMP_ROOT/remote-down-out"
  make_remote_fleet remote-down 2
  mkdir -p "$dir"
  serve_remotes >/dev/null 2>&1 || fail "initial serve failed"
  remote_reserve_bg shop-1 pool-model-a "$dir/shop-1"
  serve_remotes >/dev/null 2>&1 || fail "grant serve failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/shop-1.rc")" "first remote grant: $(cat "$dir/shop-1.out")"

  # The link drops: the primary keeps counting the remote's last snapshot.
  : > "$R_SSH_DOWN"
  out=$(serve_remotes 2>&1)
  assert_contains "$out" "unreachable theshop" "a dropped link was not reported"
  assert_equals 1 "$(used_seats "$R_ROOT")" "an unreachable remote's seat became free"

  # A remote request the primary never answers is withdrawn and refused.
  new_holder
  out=$(FM_FLEET_SEATS_TEST_REMOTE_WAIT=2 reserve "$R_REMOTE" shop-2 pool-model-a 2>&1)
  status=$?
  expect_code 5 "$status" "an unanswered remote request"
  assert_contains "$out" "did not answer" "unanswered refusal reason"
  [ -z "$(find "$R_REMOTE/state/fleet-seats" -name '*.req')" ] || fail "the unanswered request was left behind"
  rm -f "$R_SSH_DOWN"
  pass "an unreachable remote keeps its counted seats and an unanswered remote request refuses"
}

test_delivered_policy_governs_the_remote_home() {
  local out dir="$TMP_ROOT/remote-deliver-out"
  make_remote_fleet remote-deliver 2
  mkdir -p "$dir"
  new_holder
  out=$(reserve "$R_REMOTE" before pool-model-a 2>&1)
  expect_code 5 "$?" "an unserved remote pooled launch"
  # Once served, the delivered policy applies even though no inherited copy
  # ever arrived: a pooled request waits for a grant, and a default model on
  # a multi-provider harness refuses.
  serve_remotes >/dev/null 2>&1 || fail "policy serve failed"
  new_holder
  out=$(FM_FLEET_SEATS_TEST_REMOTE_WAIT=2 reserve "$R_REMOTE" after pool-model-a 2>&1)
  expect_code 5 "$?" "a pooled remote request with no serve to answer it"
  out=$(reserve "$R_REMOTE" dflt default pi 2>&1)
  expect_code 5 "$?" "a remote harness default under a delivered policy"
  printf '{"pools":[]}\n' > "$R_REMOTE/config/fleet-seats"
  new_holder
  out=$(FM_FLEET_SEATS_TEST_REMOTE_WAIT=2 reserve "$R_REMOTE" stale pool-model-a 2>&1)
  expect_code 5 "$?" "a stale inherited copy let a pooled model through"
  rm -f "$R_ROOT/config/fleet-seats"
  serve_remotes >/dev/null 2>&1 || fail "clearing serve failed"
  remote_reserve_bg cleared pool-model-a "$dir/cleared"
  serve_remotes >/dev/null 2>&1 || fail "unpooled confirmation serve failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/cleared.rc")" "a cleared remote model after root confirmation"
  assert_equals "" "$(cat "$dir/cleared.out")" "a cleared remote should reserve nothing"
  pass "remote launches require a delivered policy and current root confirmation"
}

test_stale_remote_requests_refuse_before_launch() {
  local dir="$TMP_ROOT/remote-stale-out" out
  make_remote_fleet remote-stale 3
  mkdir -p "$dir"
  serve_remotes >/dev/null 2>&1 || fail "initial policy delivery failed"

  printf '{"pools":[{"name":"shared","capacity":3,"models":["pool-model-a","pool-model-b","new-model"]}]}\n' \
    > "$R_ROOT/config/fleet-seats"
  remote_reserve_bg new-agent new-model "$dir/new"
  out=$(serve_remotes 2>&1) || fail "changed policy delivery failed: $out"
  wait "$BG_PID"
  expect_code 5 "$(cat "$dir/new.rc")" "a new pooled model absent from the remote's old policy"
  assert_contains "$(cat "$dir/new.out")" "policy changed" "stale unpooled request refusal"

  remote_reserve_bg waiting pool-model-a "$dir/waiting"
  printf '{"pools":[{"name":"shared","capacity":3,"models":["pool-model-b","new-model"]},{"name":"moved","capacity":3,"models":["pool-model-a"]}]}\n' \
    > "$R_ROOT/config/fleet-seats"
  out=$(serve_remotes 2>&1) || fail "moved policy delivery failed: $out"
  wait "$BG_PID"
  expect_code 5 "$(cat "$dir/waiting.rc")" "a request waiting in its former pool"
  assert_contains "$(cat "$dir/waiting.out")" "policy changed" "wrong-pool request refusal"
  [ -z "$(find "$R_REMOTE/state/fleet-seats/shared" -name '*.seat' 2>/dev/null)" ] \
    || fail "a wrong-pool request left a granted seat"

  remote_reserve_bg moved pool-model-a "$dir/moved"
  serve_remotes >/dev/null 2>&1 || fail "current pool grant failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/moved.rc")" "a new request using the current pool"
  assert_contains "$(cat "$dir/moved.out")" "pool=moved" "current pool grant"
  pass "newly pooled and moved models refuse stale remote requests before a current grant"
}

test_remote_without_pools_confirms_unpooled_models() {
  local dir="$TMP_ROOT/remote-off-out"
  make_remote_fleet remote-off 3
  mkdir -p "$dir"
  rm -f "$R_ROOT/config/fleet-seats"
  serve_remotes >/dev/null 2>&1 || fail "empty policy delivery failed"
  remote_reserve_bg unpooled unrelated-model "$dir/unpooled"
  serve_remotes >/dev/null 2>&1 || fail "empty policy confirmation failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/unpooled.rc")" "an unpooled model with no pool configured"
  assert_equals "" "$(cat "$dir/unpooled.out")" "unpooled confirmation printed a seat grant"
  pass "a remote without configured pools confirms unpooled models through the root"
}

test_remote_and_local_contention_never_overbooks() {
  local dir="$TMP_ROOT/remote-race-out" i racers='' granted pid home
  make_remote_fleet remote-race 3
  mkdir -p "$dir"
  serve_remotes >/dev/null 2>&1 || fail "initial serve failed"
  for i in 1 2 3; do
    new_holder
    ( FM_FLEET_SEATS_TEST_REMOTE_WAIT=60 reserve "$R_REMOTE" "shop-$i" pool-model-a \
        > "$dir/shop-$i.out" 2>&1; echo $? > "$dir/shop-$i.rc" ) &
    racers="$racers $!"
  done
  for _ in $(seq 1 100); do
    [ "$(find "$R_REMOTE/state/fleet-seats" -name '*.req' 2>/dev/null | wc -l | tr -d ' ')" -eq 3 ] && break
    sleep 0.1
  done
  new_holder
  ( serve_remotes > "$dir/serve.out" 2>&1 ) &
  pid=$!
  for i in 1 2 3; do
    home=$R_ROOT
    [ "$i" -ne 2 ] || home=$R_LOCAL
    ( reserve "$home" "local-$i" pool-model-a > "$dir/local-$i.out" 2>&1; echo $? > "$dir/local-$i.rc" ) &
    racers="$racers $!"
  done
  wait "$pid"
  # shellcheck disable=SC2086 # one pid per word
  wait $racers
  granted=$(grep -lx 0 "$dir"/*.rc | wc -l | tr -d ' ')
  assert_equals 3 "$granted" "seats granted across remote and local contention"
  assert_equals 3 "$(grep -lx 4 "$dir"/*.rc | wc -l | tr -d ' ')" "refusals across remote and local contention"
  pass "simultaneous remote and local reservations grant exactly the fleet capacity"
}

test_primary_watcher_serves_remote_requests() {
  local dir="$TMP_ROOT/remote-watch-out" out fakebin
  make_remote_fleet remote-watch 2
  mkdir -p "$dir"
  printf '%s\n' "$$" > "$R_ROOT/state/.lock"
  touch "$R_ROOT/state/.last-watcher-beat"
  fakebin=$(fm_fakebin "$TMP_ROOT/remote-watch/tmux-fake")
  fm_fake_exit0 "$fakebin" tmux
  watch_once() {
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_TRACE_CONTEXT \
      FM_BACKEND=tmux TMUX="fake,1,0" PATH="$fakebin:$PATH" \
      FM_HOME="$R_ROOT" FM_SSH_BIN="$R_SSH" FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$REMOTE_JOBS" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 2>&1
  }
  serve_remotes >/dev/null 2>&1 || fail "policy delivery serve failed"
  FM_TEST_REMOTE_WAIT=60 remote_reserve_bg shop-1 pool-model-a "$dir/shop-1"
  out=$(watch_once)
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/shop-1.rc")" "the watcher did not serve the remote request: $(cat "$dir/shop-1.out")"$'\n'"$out"
  pass "the primary watcher's poll grants a waiting remote request"
}

# --- spawn and cleanup ------------------------------------------------------

make_spawn_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  printf '%s\n' "$fakebin"
}

spawn_case() {  # <name>: sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN TASK
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  PROJ_DIR="$dir/sample"
  TASK="$1-t1"
  WT_DIR="$dir/wt"
  mkdir -p "$HOME_DIR/data/$TASK" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/user-home"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$TASK"
  cat > "$HOME_DIR/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Exercise fleet seats for $TASK.

## Firstmate spec
Nothing to build.
EOF
  FAKEBIN=$(make_spawn_fakebin "$dir")
}

in_home() {  # the fake tmux backend is pinned so no real terminal is ever created
  env -u FM_TRACE_CONTEXT FM_BACKEND=tmux FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" "$@"
}

test_spawn_refuses_a_full_pool_before_any_record() {
  local out status
  spawn_case spawn-full
  pools "$HOME_DIR" 1
  task_record "$HOME_DIR" busy pool-model-a
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude --model pool-model-a 2>&1)
  status=$?
  expect_code 1 "$status" "spawn into a full pool"
  assert_contains "$out" "pool shared is full" "spawn refusal reason"
  assert_absent "$HOME_DIR/state/$TASK.meta" "a refused spawn published a task record"

  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude --model gpt-other 2>&1) || fail "an unpooled spawn was refused: $out"
  pass "a pooled spawn into a full pool refuses before any record, and another route still launches"
}

test_spawn_holds_a_seat_until_cleanup() {
  local out
  spawn_case spawn-seat
  pools "$HOME_DIR" 1
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude --model pool-model-a 2>&1) || fail "pooled spawn failed: $out"
  new_holder
  out=$(in_home "$SEATS" reserve other --harness claude --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1)
  expect_code 4 "$?" "a second seat while the spawned worker holds the only one"
  assert_contains "$out" "$TASK" "the seat does not name the spawned task"
  out=$(in_home "$ROOT/bin/fm-teardown.sh" "$TASK" 2>&1) || fail "cleanup failed: $out"
  new_holder
  out=$(in_home "$SEATS" reserve other --harness claude --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1) \
    || fail "cleanup did not release the seat: $out"
  pass "a spawned pooled worker holds its seat until cleanup removes its record"
}

test_secondmate_spawn_takes_a_seat() {
  local out status sm
  spawn_case spawn-mate
  pools "$HOME_DIR" 1
  task_record "$HOME_DIR" busy pool-model-a
  sm="$TMP_ROOT/spawn-mate/mate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/state" "$sm/config"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' mate1 > "$sm/.fm-secondmate-home"
  printf 'charter for mate1\n' > "$sm/data/charter.md"
  git -C "$sm" init -q -b main
  out=$(in_home "$ROOT/bin/fm-spawn.sh" mate1 "$sm" --secondmate --harness claude --model pool-model-a 2>&1)
  status=$?
  expect_code 1 "$status" "a secondmate supervisor spawn into a full pool"
  assert_contains "$out" "pool shared is full" "secondmate spawn refusal reason"
  assert_absent "$HOME_DIR/state/mate1.meta" "a refused secondmate spawn published a record"
  pass "a secondmate supervisor on a pooled model needs a seat to launch"
}

test_no_pool_configured_is_off
test_one_capacity_across_homes
test_live_supervisors_hold_seats_even_while_idle
test_explicit_model_required_while_pooled
test_stale_reservations_recover_without_preempting_live_work
test_simultaneous_reservations_never_overbook
test_unreachable_or_malformed_authority_refuses
test_remote_policy_must_be_confirmed_before_any_grant
test_remote_home_shares_the_fleet_capacity
test_unreachable_remote_is_never_free
test_delivered_policy_governs_the_remote_home
test_stale_remote_requests_refuse_before_launch
test_remote_without_pools_confirms_unpooled_models
test_remote_and_local_contention_never_overbooks
test_primary_watcher_serves_remote_requests
test_spawn_refuses_a_full_pool_before_any_record
test_spawn_holds_a_seat_until_cleanup
test_secondmate_spawn_takes_a_seat
