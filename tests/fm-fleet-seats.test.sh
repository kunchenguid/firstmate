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

reserve() {  # <home> <id> <model> [harness]: reserve generation g-<id> for the most recent holder
  seats "$1" reserve "$2" --generation "g-$2" --harness "${4:-pi}" --model "$3" --holder-pid "$LAST_HOLDER"
}

reserve_gen() {  # <home> <id> <generation> <previous|-> <model> [kind]
  seats "$1" reserve "$2" --generation "$3" --previous-generation "$4" --harness pi \
    --model "$5" --kind "${6:-ship}" --holder-pid "$LAST_HOLDER"
}

lifecycle_of() {  # <home> <id> <generation>
  seats "$1" show "$2" | jq -r --arg g "$3" '.incarnations[] | select(.generation == $g) | .lifecycle'
}

# A fake tmux whose one server holds the windows listed in <dir>/windows, each
# running the foreground command in <dir>/command (a shell reads dead, an
# agent name reads alive); <dir>/inventory-broken makes every read unreadable.
endpoint_fakebin() {  # <dir>: prints the fakebin
  local fakebin
  fakebin=$(fm_fakebin "$1")
  mkdir -p "$1/endpoint"
  : > "$1/endpoint/windows"
  printf 'bash\n' > "$1/endpoint/command"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
D="$1/endpoint"
case "\$1" in
  list-windows)
    [ ! -e "\$D/inventory-broken" ] || { echo 'lost server' >&2; exit 1; }
    cat "\$D/windows" ;;
  display-message)
    case "\$*" in *pane_current_command*) cat "\$D/command" ;; *) printf 'fakepane\\n' ;; esac ;;
  kill-window) : > "\$D/windows" ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# owner_launch <home> <id> <generation> <previous|-> <kind> <target> <ready-file>
# A background launch owner: reserves, dispatches a local tmux route, touches
# <ready-file>, then waits to be killed or released through <ready-file>.stop,
# where it runs the commands in <ready-file>.then (as the owner) and exits.
owner_launch() {
  local home=$1 id=$2 gen=$3 prev=$4 kind=$5 target=$6 ready=$7
  # shellcheck disable=SC2016 # the child shell or fixture expands these.
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" SEATS="$SEATS" bash -c '
      id=$1 gen=$2 prev=$3 kind=$4 target=$5 ready=$6
      "$SEATS" reserve "$id" --generation "$gen" --previous-generation "$prev" --kind "$kind" \
        --harness pi --model pool-model-a --holder-pid "$$" > "$ready.out" 2>&1 || { echo "reserve=$?" > "$ready"; exit 1; }
      route="$ready.route"
      (umask 077 && printf "{\"placement\":\"local\",\"backend\":\"tmux\",\"target\":\"%s\",\"home\":null,\"host\":null,\"remote_root\":null,\"spawn_gen\":\"%s\",\"operation\":null}\n" "$target" "$gen" > "$route")
      "$SEATS" dispatch "$id" --generation "$gen" --route-file "$route" >> "$ready.out" 2>&1 || { echo "dispatch=$?" > "$ready"; exit 1; }
      echo ok > "$ready"
      while [ ! -e "$ready.stop" ]; do sleep 0.1; done
      [ ! -f "$ready.then" ] || . "$ready.then" >> "$ready.out" 2>&1
      echo done > "$ready.done"
    ' _ "$id" "$gen" "$prev" "$kind" "$target" "$ready" &
  OWNER_PID=$!
  HOLDER_PIDS="$HOLDER_PIDS $OWNER_PID"
  for _ in $(seq 1 100); do
    [ -s "$ready" ] && break
    sleep 0.1
  done
  [ "$(cat "$ready" 2>/dev/null)" = ok ] || fail "launch owner for $id did not dispatch: $(cat "$ready" "$ready.out" 2>/dev/null)"
}

reserve_without_jq() {
  local home=$1
  shift
  # shellcheck disable=SC2016 # the child shell or fixture expands these.
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" SEATS="$SEATS" bash -c '
    command() {
      if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then return 1; fi
      builtin command "$@"
    }
    export -f command
    exec "$SEATS" "$@"
  ' _ "$@"
}

# used_seats <home>: the pool's current holder count, measured by a probe
# reservation that is then released before it could ever have launched.
used_seats() {
  local out rc gen
  new_holder
  gen="probe$(date +%s)$RANDOM$RANDOM"
  out=$(reserve_gen "$1" zz-probe "$gen" - pool-model-a 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || seats "$1" release zz-probe --generation "$gen" --reason prelaunch >/dev/null 2>&1
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
  out=$(seats "$home" reserve raw-off --generation g-raw-off --harness claude --model default --holder-pid "$LAST_HOLDER" --raw-launch 2>&1)
  expect_code 0 "$?" "a raw launch without a declaration"
  assert_equals "" "$out" "an undeclared raw launch printed a seat refusal"
  out=$(reserve_without_jq "$home" reserve t3 --generation g-t3 --harness pi --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1)
  expect_code 0 "$?" "an undeclared primary without jq"
  assert_equals "" "$out" "an undeclared primary without jq printed a reservation"
  task_record "$home" legacy-default default
  out=$(reserve "$home" no-declaration pool-model-a 2>&1)
  expect_code 0 "$?" "a legacy default record without a declaration"
  assert_equals "" "$out" "an undeclared home counted a legacy default record"
  pools "$home" 1
  out=$(reserve_without_jq "$home" reserve t4 --generation g-t4 --harness pi --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1)
  expect_code 5 "$?" "a declared pool without jq"
  assert_contains "$out" "jq is not installed" "the missing-jq fixture did not disable jq"
  pass "without config/fleet-seats a reservation is a silent no-op"
}

test_pool_names_do_not_escape_the_seat_directory() {
  local home="$TMP_ROOT/pool-names/primary" out name
  make_home "$home"
  new_holder
  for name in . ..; do
    printf '{"pools":[{"name":"%s","capacity":1,"models":["pool-model-a"]}]}\n' "$name" \
      > "$home/config/fleet-seats"
    out=$(reserve "$home" named pool-model-a 2>&1)
    expect_code 5 "$?" "pool name $name"
    assert_contains "$out" "malformed" "pool name $name was accepted"
  done
  printf '{"pools":[{"name":"team.a","capacity":1,"models":["pool-model-a"]}]}\n' \
    > "$home/config/fleet-seats"
  out=$(reserve "$home" named pool-model-a 2>&1) || fail "an ordinary dotted pool name was refused: $out"
  assert_contains "$out" "pool=team.a" "the dotted pool did not reserve its own directory"
  pass "path-like pool names refuse while ordinary dotted names reserve"
}

test_legacy_unresolved_models_count_in_every_pool() {
  local root="$TMP_ROOT/legacy-default/primary" out shape model
  make_home "$root"
  printf '{"pools":[{"name":"first","capacity":1,"models":["pool-model-a"]},{"name":"second","capacity":1,"models":["pool-model-b"]}]}\n' \
    > "$root/config/fleet-seats"
  new_holder
  for shape in default empty missing; do
    case "$shape" in
      default) task_record "$root" legacy default ship ;;
      empty) task_record "$root" legacy '' scout ;;
      missing) printf 'kind=secondmate\nremote_host=remote-mac\nharness=pi\n' > "$root/state/legacy.meta" ;;
    esac
    for model in pool-model-a pool-model-b; do
      out=$(reserve "$root" next "$model" 2>&1)
      expect_code 4 "$?" "a $shape legacy record before a $model launch"
      assert_contains "$out" "legacy" "the unresolved $shape record was absent from the holders"
    done
    rm -f "$root/state/legacy.meta"
  done
  task_record "$root" legacy unrelated-model
  out=$(reserve "$root" first pool-model-a 2>&1) || fail "a resolved unpooled record blocked the first pool: $out"
  out=$(reserve "$root" second pool-model-b 2>&1) || fail "a resolved unpooled record blocked the second pool: $out"
  pass "legacy default, empty, and missing models occupy every declared pool"
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
  out=$(reserve "$mate" a1 pool-model-a 2>&1) || fail "a holder's own retry was refused: $out"
  assert_contains "$out" "already reserved" "a same-generation retry did not keep its seat"
  new_holder
  out=$(reserve_gen "$mate" a1 g-a1-next g-a1 pool-model-b 2>&1) || fail "a same-pool replacement was refused at full capacity: $out"
  assert_contains "$out" "already held" "a same-pool replacement took a second seat"
  out=$(reserve "$mate" a3 some-other-model 2>&1) || fail "an unpooled model was refused: $out"
  assert_contains "$out" "is in no pool" "an unpooled model should hold no pool seat"
  pass "the primary and a local secondmate share one capacity and pre-existing agents count"
}

test_nested_secondmate_records_share_capacity() {
  local root="$TMP_ROOT/nested/primary" child="$TMP_ROOT/nested/child" grandchild="$TMP_ROOT/nested/grandchild" out status row
  make_home "$root"
  pools "$root" 1
  make_local_secondmate "$child" "$root" child
  make_local_secondmate "$grandchild" "$child" grandchild
  task_record "$grandchild" existing pool-model-a
  new_holder
  out=$(reserve "$root" next pool-model-a 2>&1)
  status=$?
  expect_code 4 "$status" "a primary launch while a nested secondmate holds the only seat"
  assert_contains "$out" "existing" "the nested pre-existing agent was absent from the holders"

  printf -- '- broken - Mate with a damaged record. (home: %s; added 2026-09-28)\n' "$grandchild" \
    >> "$child/data/secondmates.md"
  out=$(reserve "$root" malformed pool-model-a 2>&1)
  expect_code 5 "$?" "an unparseable nested registry record"
  assert_contains "$out" "unparseable secondmate registry line" "nested registry corruption was skipped"
  row=$(sed -n '1p' "$child/data/secondmates.md")
  printf '%s\n' "$row" > "$child/data/secondmates.md"

  mv "$grandchild/state" "$grandchild/state-away"
  out=$(reserve "$root" missing pool-model-a 2>&1)
  expect_code 5 "$?" "a registered nested state directory that is missing"
  mv "$grandchild/state-away" "$grandchild/state"
  chmod 000 "$grandchild/state"
  out=$(reserve "$root" unreadable pool-model-a 2>&1)
  status=$?
  chmod 755 "$grandchild/state"
  if [ "$(id -u)" -ne 0 ]; then
    expect_code 5 "$status" "a registered nested state directory that cannot be listed"
  fi

  pools "$root" 2
  row=$(cat "$child/data/secondmates.md")
  printf '%s\n' "$row" >> "$child/data/secondmates.md"
  printf -- '- revisit - Root cycle. (home: %s; scope: tests; projects: ; added 2026-09-28)\n' "$root" \
    >> "$grandchild/data/secondmates.md"
  out=$(reserve "$root" next pool-model-a 2>&1) || fail "repeated or cyclic homes prevented a valid reservation: $out"
  assert_contains "$out" "used=2 capacity=2" "a repeated nested home was counted more than once"
  pass "nested local homes count existing agents once and refuse ambiguous occupancy"
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
  printf 'window=firstmate:fm-mate-idle\nworktree=%s\nproject=%s\n' "$mate" "$mate" >> "$root/state/mate-idle.meta"
  kill "$mateholder"
  wait "$mateholder" 2>/dev/null
  # An unmanaged record frees only on a backend-proven dead or missing endpoint.
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/supervisors/dead-backend")
  # shellcheck disable=SC2016 # the child shell or fixture expands these.
  printf '#!/usr/bin/env bash\n[ "$1" != list-windows ] || printf "main\\n"\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  assert_equals 3 "$(PATH="$fakebin:$PATH" used_seats "$root")" "a dead secondmate supervisor retained a seat"
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
  out=$(reserve "$root" d3 default claude 2>&1)
  expect_code 5 "$?" "a Claude default while pooled"
  out=$(reserve "$root" d4 default codex 2>&1)
  expect_code 5 "$?" "a Codex default while pooled"
  out=$(seats "$root" reserve raw --generation g-raw --harness claude --model pool-model-a --holder-pid "$LAST_HOLDER" --raw-launch 2>&1)
  expect_code 5 "$?" "a raw launch with an explicit claimed model"
  assert_contains "$out" "raw launch command cannot verify" "raw-command refusal reason"
  pass "declared pools reject harness defaults and raw launch commands"
}

test_stale_reservations_recover_without_preempting_live_work() {
  local root="$TMP_ROOT/stale/primary" out crashed live
  make_home "$root"
  pools "$root" 2
  new_holder
  out=$(reserve "$root" crashed pool-model-a 2>&1) || fail "reserve crashed: $out"
  crashed=$LAST_HOLDER
  new_holder
  out=$(reserve "$root" running pool-model-a 2>&1) || fail "reserve running: $out"
  live=$LAST_HOLDER
  # The running task published its record; its spawner then exited.
  task_record "$root" running pool-model-a ship "spawn_gen=g-running"
  kill "$live" "$crashed"
  wait "$live" "$crashed" 2>/dev/null

  # A dead owner alone frees nothing: counting never reclaims.
  new_holder
  out=$(reserve "$root" next pool-model-a 2>&1)
  expect_code 4 "$?" "a reservation before maintenance proved anything"
  # Maintenance proves the crashed spawn never dispatched and reclaims it; the
  # running task's seat stays with its record until cleanup.
  out=$(seats "$root" reconcile --limit 8 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "reclaimed id=crashed" "the undispatched crashed reservation was not reclaimed"
  assert_equals reserved "$(lifecycle_of "$root" running g-running)" "maintenance preempted the running task's seat"
  new_holder
  out=$(reserve "$root" next pool-model-a 2>&1) || fail "a crashed spawn's seat was not recovered: $out"
  assert_contains "$out" "used=2 capacity=2" "recovery count"
  new_holder
  out=$(reserve "$root" extra pool-model-a 2>&1)
  expect_code 4 "$?" "the running worker's seat was preempted"
  pass "maintenance reclaims a proven-undispatched reservation while a live task record keeps its seat"
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

  out=$(seats "$root" reserve l2 --generation g-l2 --harness pi --model pool-model-a --holder-pid 999999 2>&1)
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
if [ -n "${FM_TEST_SERVE_PROBE_HOME:-}" ]; then
  . "$FM_TEST_CODE_ROOT/bin/fm-timeout-lib.sh"
  probe_rc=0
  fm_run_timed 2 env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$FM_TEST_SERVE_PROBE_HOME" "$FM_TEST_CODE_ROOT/bin/fm-fleet-seats.sh" release lockprobe --generation g-lockprobe --reason prelaunch >/dev/null 2>&1 || probe_rc=$?
  printf '%s\n' "$probe_rc" > "$FM_TEST_SERVE_PROBE_RESULT"
fi
if [ -e "${FM_TEST_SSH_LOSE_REPLY:-/nonexistent}" ]; then
  "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" > "$FM_TEST_SSH_LOSE_REPLY.reply"
  exit 255
fi
if [ -e "${FM_TEST_SSH_TRUNCATE:-/nonexistent}" ]; then
  "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" | head -c 40
  exit 0
fi
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
  R_SSH_LOSE_REPLY="$base/ssh-lose-reply"
  R_SSH_TRUNCATE="$base/ssh-truncate"
}

serve_remotes() {  # run the root's serve pass with the fake transport
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$R_ROOT" FM_SSH_BIN="$R_SSH" FM_TEST_SSH_DOWN="$R_SSH_DOWN" \
    FM_TEST_SSH_LOSE_REPLY="$R_SSH_LOSE_REPLY" FM_TEST_SSH_TRUNCATE="$R_SSH_TRUNCATE" \
    FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" FM_TEST_CODE_ROOT="$ROOT" \
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
  rm -f "$R_ROOT/state/fleet-seats/remote-theshop.cert"
  new_holder
  out=$(reserve "$R_ROOT" absent-snapshot pool-model-a 2>&1)
  expect_code 5 "$?" "a remote with no certificate"
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

  # A retry of a seated remote generation keeps its seat with no round trip.
  new_holder
  out=$(reserve "$R_REMOTE" shop-1 pool-model-a 2>&1) || fail "a seated remote retry was refused: $out"
  assert_contains "$out" "already granted" "a seated remote retry needed another grant"

  # The remote spawner dies: its seat stays counted, because the launch it
  # reserved may still run.
  kill "$r1_holder"
  wait "$r1_holder" 2>/dev/null
  serve_remotes >/dev/null 2>&1 || fail "recovery serve failed"
  new_holder
  out=$(reserve "$R_LOCAL" a2 pool-model-a 2>&1)
  expect_code 4 "$?" "a local launch after the remote spawner died"
  # Its own rollback proves the launch never dispatched: the next serve frees it.
  seats "$R_REMOTE" release shop-1 --generation g-shop-1 --reason prelaunch >/dev/null \
    || fail "the remote candidate that never dispatched could not be released"
  serve_remotes >/dev/null 2>&1 || fail "release serve failed"
  new_holder
  out=$(reserve "$R_LOCAL" a2 pool-model-a 2>&1) || fail "the released remote seat was not reusable locally: $out"
  pass "primary, local, and remote homes share one capacity; remote grants, denials, retries, and proven release hold"
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

  # The link drops: admission stays refused rather than trusting old counts.
  : > "$R_SSH_DOWN"
  out=$(serve_remotes 2>&1)
  assert_contains "$out" "unreachable theshop" "a dropped link was not reported"
  new_holder
  out=$(reserve "$R_ROOT" next pool-model-a 2>&1)
  expect_code 5 "$?" "a reservation after an incomplete serve"
  assert_contains "$out" "have not confirmed" "a failed serve kept its confirmation"

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
  local out
  make_remote_fleet remote-deliver 2
  new_holder
  out=$(reserve "$R_REMOTE" before pool-model-a 2>&1)
  expect_code 0 "$?" "an undeclared remote before first delivery"
  assert_equals "" "$out" "an undeclared remote printed a reservation"
  cp "$R_ROOT/config/fleet-seats" "$R_REMOTE/config/fleet-seats"
  out=$(reserve "$R_REMOTE" declared-before pool-model-a 2>&1)
  expect_code 5 "$?" "a declared remote pooled launch before delivery"
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
  new_holder
  out=$(reserve "$R_REMOTE" cleared pool-model-a 2>&1)
  expect_code 0 "$?" "a cleared remote model"
  assert_equals "" "$out" "a cleared remote should reserve nothing"
  pass "declared remote launches require current confirmation and clearing restores opt-out"
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
  [ -z "$(seats "$R_REMOTE" show waiting)" ] || fail "a wrong-pool request left a granted seat"

  remote_reserve_bg moved pool-model-a "$dir/moved"
  serve_remotes >/dev/null 2>&1 || fail "current pool grant failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/moved.rc")" "a new request using the current pool"
  assert_contains "$(cat "$dir/moved.out")" "pool=moved" "current pool grant"
  pass "newly pooled and moved models refuse stale remote requests before a current grant"
}

test_inflight_remote_seat_follows_model_between_pools() {
  local dir="$TMP_ROOT/remote-move-out" out inflight
  make_remote_fleet remote-move 1
  mkdir -p "$dir"
  printf '{"pools":[{"name":"former","capacity":1,"models":["pool-model-a"]},{"name":"other","capacity":1,"models":["pool-model-b"]}]}\n' \
    > "$R_ROOT/config/fleet-seats"
  serve_remotes >/dev/null 2>&1 || fail "initial policy delivery failed"
  remote_reserve_bg inflight pool-model-a "$dir/inflight"
  inflight=$LAST_HOLDER
  serve_remotes >/dev/null 2>&1 || fail "in-flight remote grant failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/inflight.rc")" "the remote in-flight grant"

  printf '{"pools":[{"name":"current","capacity":1,"models":["pool-model-a"]},{"name":"other","capacity":1,"models":["pool-model-b"]}]}\n' \
    > "$R_ROOT/config/fleet-seats"
  out=$(serve_remotes 2>&1) || fail "policy move delivery failed: $out"
  assert_contains "$out" "holders=1" "the in-flight seat vanished during the move"
  new_holder
  out=$(reserve "$R_ROOT" local pool-model-a 2>&1)
  expect_code 4 "$?" "a local launch into the moved pool while its remote seat is live"
  assert_contains "$out" "remote:theshop" "the moved seat is absent from the root's holders"

  kill "$inflight"
  wait "$inflight" 2>/dev/null
  serve_remotes >/dev/null 2>&1 || fail "serve after the spawner died failed"
  new_holder
  out=$(reserve "$R_ROOT" local pool-model-a 2>&1)
  expect_code 4 "$?" "a local launch while the dead spawner's reservation is unresolved"
  seats "$R_REMOTE" release inflight --generation g-inflight --reason prelaunch >/dev/null \
    || fail "the undispatched in-flight seat could not be released"
  serve_remotes >/dev/null 2>&1 || fail "serve after release failed"
  new_holder
  out=$(reserve "$R_ROOT" local pool-model-a 2>&1) || fail "the released in-flight seat stayed held: $out"
  pass "an in-flight remote seat follows its model across pools and frees only on proven release"
}

test_remote_without_pools_confirms_unpooled_models() {
  local out
  make_remote_fleet remote-off 3
  rm -f "$R_ROOT/config/fleet-seats"
  new_holder
  out=$(reserve_without_jq "$R_REMOTE" reserve unpooled --generation g-unpooled --harness pi --model unrelated-model --holder-pid "$LAST_HOLDER" 2>&1)
  expect_code 0 "$?" "an undeclared remote without jq or delivery"
  assert_equals "" "$out" "an undeclared remote printed a seat grant"
  pools "$R_ROOT" 3
  serve_remotes >/dev/null 2>&1 || fail "active policy delivery failed"
  rm -f "$R_ROOT/config/fleet-seats"
  serve_remotes >/dev/null 2>&1 || fail "empty policy delivery failed"
  out=$(reserve_without_jq "$R_REMOTE" reserve cleared --generation g-cleared --harness pi --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1)
  expect_code 0 "$?" "a cleared remote without jq"
  assert_equals "" "$out" "a cleared remote printed a seat grant"
  pass "undeclared and cleared remote policies leave launches unchanged"
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
  assert_equals 3 "$(grep -lxE '4|5' "$dir"/*.rc | wc -l | tr -d ' ')" "refusals across remote and local contention"
  for result in "$dir"/*.rc; do
    [ "$(cat "$result")" != 5 ] || assert_contains "$(cat "${result%.rc}.out")" "have not confirmed the current seat policy" "contention refused for an unrelated authority error"
  done
  assert_equals 3 "$(used_seats "$R_ROOT")" "contention granted more than the fleet capacity"
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
      FM_HOME="$R_ROOT" FM_SSH_BIN="$R_SSH" FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" FM_TEST_CODE_ROOT="$ROOT" \
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

test_spawn_rejects_unverified_models() {
  local out
  spawn_case spawn-model-proof
  pools "$HOME_DIR" 1
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude 2>&1)
  expect_code 1 "$?" "a default-model spawn with a declared pool"
  assert_contains "$out" "unverified default model" "the default-model spawn did not reach the seat refusal"
  assert_absent "$HOME_DIR/state/$TASK.meta" "a refused default-model spawn published a task record"

  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" 'claude --model pool-model-a' \
    --mode local-only --yolo off --model pool-model-a 2>&1)
  expect_code 1 "$?" "a raw launch with a declared pool"
  assert_contains "$out" "raw launch command cannot verify" "the raw launch did not reach the seat refusal"
  assert_absent "$HOME_DIR/state/$TASK.meta" "a refused raw launch published a task record"
  pass "spawn rejects unverified default and raw-command models before publication"
}

test_spawn_holds_a_seat_until_cleanup() {
  local out
  spawn_case spawn-seat
  pools "$HOME_DIR" 1
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude --model pool-model-a 2>&1) || fail "pooled spawn failed: $out"
  new_holder
  out=$(in_home "$SEATS" reserve other --generation g-other --harness claude --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1)
  expect_code 4 "$?" "a second seat while the spawned worker holds the only one"
  assert_contains "$out" "$TASK" "the seat does not name the spawned task"
  out=$(in_home "$ROOT/bin/fm-teardown.sh" "$TASK" 2>&1) || fail "cleanup failed: $out"
  new_holder
  out=$(in_home "$SEATS" reserve other --generation g-other --harness claude --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1) \
    || fail "cleanup did not release the seat: $out"
  pass "a spawned pooled worker holds its seat until cleanup releases its generation"
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

# --- generation-fenced lifecycle ---------------------------------------------

# Both startup findings: a submitted launch whose spawner died and whose
# endpoint still shows only a shell may yet run its buffered source line, so its
# seat stays counted whatever the session lock or task record says.
test_buffered_supervisor_launch_keeps_its_seat() {
  local base="$TMP_ROOT/buffered" root mate fakebin ep out rc
  root="$base/primary"
  mate="$base/mate"
  make_home "$root"
  pools "$root" 1
  make_local_secondmate "$mate" "$root" sm
  fakebin=$(endpoint_fakebin "$base/tmux")
  ep="$base/tmux/endpoint"
  printf 'fm-sm\n' > "$ep/windows"
  PATH="$fakebin:$PATH" owner_launch "$root" sm g1 - secondmate firstmate:fm-sm "$base/ready"
  task_record "$root" sm pool-model-a secondmate "home=$mate
spawn_gen=g1
window=firstmate:fm-sm
worktree=$mate
project=$mate"
  kill "$OWNER_PID"
  wait "$OWNER_PID" 2>/dev/null
  new_holder
  for lock in free stale; do
    [ "$lock" != stale ] || printf '99999999\n' > "$mate/state/.lock"
    out=$(PATH="$fakebin:$PATH" reserve "$root" other pool-model-a 2>&1)
    expect_code 4 "$?" "a second holder beside a shell-only buffered launch with a $lock session lock: $out"
    out=$(PATH="$fakebin:$PATH" seats "$root" reclaim sm --generation g1 2>&1); rc=$?
    expect_code 3 "$rc" "reclaiming a shell-only submitted launch: $out"
    out=$(PATH="$fakebin:$PATH" seats "$root" reconcile --limit 8 2>&1) || fail "reconcile failed: $out"
    assert_equals reserved "$(lifecycle_of "$root" sm g1)" "maintenance freed a shell-only submitted launch"
  done
  rm -f "$root/state/sm.meta"
  out=$(PATH="$fakebin:$PATH" reserve "$root" other pool-model-a 2>&1)
  expect_code 4 "$?" "a second holder after the task record was rolled back: $out"
  # The buffered line runs: the same generation is confirmed, still one holder.
  printf 'claude\n' > "$ep/command"
  out=$(PATH="$fakebin:$PATH" seats "$root" reclaim sm --generation g1 2>&1) || fail "confirming the started launch failed: $out"
  assert_contains "$out" "confirmed id=sm generation=g1" "the started launch was not confirmed"
  out=$(PATH="$fakebin:$PATH" reserve "$root" other pool-model-a 2>&1)
  expect_code 4 "$?" "a second holder beside the confirmed supervisor"
  assert_contains "$out" "(1 of 1" "the confirmed supervisor counted more than once"
  # Only a started generation's later death frees it.
  printf 'bash\n' > "$ep/command"
  out=$(PATH="$fakebin:$PATH" seats "$root" reclaim sm --generation g1 2>&1) || fail "reclaiming the dead started generation failed: $out"
  assert_equals reclaimed "$(lifecycle_of "$root" sm g1)" "the dead started generation kept its seat"
  out=$(PATH="$fakebin:$PATH" reserve "$root" other pool-model-a 2>&1) || fail "the reclaimed seat was not reusable: $out"
  pass "a buffered supervisor launch keeps its seat until it starts and later dies"
}

test_proven_cancellation_frees_a_buffered_launch() {
  local base="$TMP_ROOT/cancel" root fakebin ep out rc
  root="$base/primary"
  make_home "$root"
  pools "$root" 1
  fakebin=$(endpoint_fakebin "$base/tmux")
  ep="$base/tmux/endpoint"
  printf 'fm-c1\nfm-c2\n' > "$ep/windows"
  # The launch owner's authorized rollback closes its own endpoint, sees it
  # gone from the server it created it on, and releases exactly its candidate.
  # shellcheck disable=SC2016 # the child shell or fixture expands these.
  printf 'tmux kill-window -t firstmate:fm-c1\n"$SEATS" release c1 --generation g1 --reason cancelled\n' > "$base/ready1.then"
  PATH="$fakebin:$PATH" owner_launch "$root" c1 g1 - ship firstmate:fm-c1 "$base/ready1"
  : > "$base/ready1.stop"
  for _ in $(seq 1 100); do [ -e "$base/ready1.done" ] && break; sleep 0.1; done
  assert_equals released "$(lifecycle_of "$root" c1 g1)" "the owner's proven cancellation did not release its candidate: $(cat "$base/ready1.out")"
  printf 'fm-c2\n' > "$ep/windows"
  PATH="$fakebin:$PATH" owner_launch "$root" c2 g2 - ship firstmate:fm-c2 "$base/ready2"
  kill "$OWNER_PID"
  wait "$OWNER_PID" 2>/dev/null
  # Anyone else needs the backend's absence proof: a shell-only endpoint, an
  # absence tmux cannot prove, or an unreadable inventory all keep the seat.
  out=$(PATH="$fakebin:$PATH" seats "$root" release c2 --generation g2 --reason cancelled 2>&1); rc=$?
  expect_code 3 "$rc" "a shell-only verdict as cancellation proof: $out"
  : > "$ep/windows"
  out=$(PATH="$fakebin:$PATH" seats "$root" release c2 --generation g2 --reason cancelled 2>&1); rc=$?
  expect_code 3 "$rc" "an unprovable absence as cancellation proof: $out"
  : > "$ep/inventory-broken"
  out=$(PATH="$fakebin:$PATH" seats "$root" release c2 --generation g2 --reason cancelled 2>&1); rc=$?
  expect_code 3 "$rc" "an unreadable inventory as cancellation proof: $out"
  out=$(PATH="$fakebin:$PATH" seats "$root" release c2 --generation g2 --reason prelaunch 2>&1); rc=$?
  expect_code 5 "$rc" "a prelaunch release after dispatch: $out"
  new_holder
  out=$(PATH="$fakebin:$PATH" reserve "$root" other pool-model-a 2>&1)
  expect_code 4 "$?" "a second holder beside an unproven cancellation"
  pass "only a proven endpoint cancellation frees a submitted launch"
}

# The stale-death schedule: an episode holds the mutex, so no other supervisor
# mutation for that task can run, and an old generation's evidence can never
# free a newer generation afterward.
test_lifecycle_episode_excludes_stale_mutations() {
  local base="$TMP_ROOT/episode" root lock carrier out rc blocker
  root="$base/primary"
  make_home "$root"
  pools "$root" 1
  new_holder
  out=$(reserve_gen "$root" sm g1 - pool-model-a secondmate 2>&1) || fail "initial supervisor reservation: $out"
  bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh" && fm_supervisor_lifecycle_acquire "$2" sm 0 \
      && printf "%s\n" "$FM_SUPERVISOR_LIFECYCLE_CARRIER" > "$3" && exec sleep 600' \
    _ "$ROOT" "$root/state" "$base/carrier" &
  blocker=$!
  HOLDER_PIDS="$HOLDER_PIDS $blocker"
  for _ in $(seq 1 50); do [ -s "$base/carrier" ] && break; sleep 0.1; done
  [ -s "$base/carrier" ] || fail "the episode holder never started"
  out=$(reserve_gen "$root" sm g2 g1 pool-model-a secondmate 2>&1); rc=$?
  expect_code 5 "$rc" "a relaunch reservation during another episode"
  assert_contains "$out" "another lifecycle episode" "the episode refusal was not named"
  out=$(seats "$root" release sm --generation g1 --reason prelaunch 2>&1); rc=$?
  expect_code 5 "$rc" "a release during another episode"
  carrier=$(cat "$base/carrier")
  lock=${carrier%%|*}
  out=$(FM_SUPERVISOR_LIFECYCLE_CARRIER="$carrier" reserve_gen "$root" sm g2 g1 pool-model-a secondmate 2>&1); rc=$?
  expect_code 5 "$rc" "a valid carrier from a process that is not an ancestor"
  out=$(FM_SUPERVISOR_LIFECYCLE_CARRIER="$lock|$blocker|forged|forged" reserve_gen "$root" sm g2 g1 pool-model-a secondmate 2>&1); rc=$?
  expect_code 5 "$rc" "a forged carrier"
  assert_contains "$out" "does not verify" "the forged carrier was not rejected"
  kill "$blocker"
  wait "$blocker" 2>/dev/null
  # The episode ends; a new generation replaces g1, which ends through its own
  # proven release. Replaying the old evidence changes nothing.
  out=$(seats "$root" release sm --generation g1 --reason prelaunch 2>&1) || fail "releasing g1: $out"
  out=$(reserve_gen "$root" sm g2 g1 pool-model-a secondmate 2>&1) || fail "the new generation was refused: $out"
  out=$(seats "$root" reclaim sm --generation g1 2>&1) || fail "replaying old evidence failed loudly: $out"
  assert_contains "$out" "already terminal" "the stale reclaim did not report a no-op"
  out=$(seats "$root" release sm --generation g1 --reason teardown 2>&1) || fail "a stale teardown failed loudly: $out"
  assert_equals reserved "$(lifecycle_of "$root" sm g2)" "stale evidence changed the newer generation"
  new_holder
  out=$(reserve "$root" other pool-model-a 2>&1)
  expect_code 4 "$?" "another holder beside the newer generation"
  pass "one lifecycle episode excludes other supervisor mutations and stale evidence never frees a newer generation"
}

test_collection_never_waits_on_task_locks() {
  local base="$TMP_ROOT/lock-order" root out rc blocker
  root="$base/primary"
  make_home "$root"
  pools "$root" 2
  task_record "$root" busy pool-model-a
  bash -c '. "$1/bin/fm-wake-lib.sh" && fm_lock_try_acquire "$2" && : > "$3" && exec sleep 600' \
    _ "$ROOT" "$root/state/.meta-busy.lock" "$base/locked" &
  blocker=$!
  HOLDER_PIDS="$HOLDER_PIDS $blocker"
  for _ in $(seq 1 50); do [ -e "$base/locked" ] && break; sleep 0.1; done
  new_holder
  out=$(. "$ROOT/bin/fm-timeout-lib.sh" && fm_run_timed 20 env -u FM_STATE_OVERRIDE FM_HOME="$root" "$SEATS" \
    reserve next --generation g-next --harness pi --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1); rc=$?
  kill "$blocker"
  wait "$blocker" 2>/dev/null
  expect_code 0 "$rc" "a reservation while another process holds a task metadata lock: $out"
  assert_contains "$out" "used=2" "the locked task record was not counted"
  pass "seat collection completes without waiting on task metadata locks"
}

test_serve_epochs_fence_lost_and_late_responses() {
  local dir="$TMP_ROOT/epochs-out" out rc served seq issuer digest
  make_remote_fleet epochs 1
  mkdir -p "$dir"
  out=$(serve_remotes 2>&1) || fail "initial empty serve failed: $out"
  assert_contains "$out" "served theshop" "initial empty serve was not confirmed"
  remote_reserve_bg granted pool-model-a "$dir/granted"
  : > "$R_SSH_LOSE_REPLY"
  out=$(serve_remotes 2>&1)
  assert_contains "$out" "unreachable theshop" "the lost serve response was not reported"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/granted.rc")" "the remote grant before losing the serve response"
  assert_present "$R_ROOT/state/fleet-seats/remote-theshop.pending" "the lost serve left no pending marker"
  new_holder
  out=$(reserve "$R_ROOT" next pool-model-a 2>&1)
  expect_code 5 "$?" "a primary launch after the serve granted remotely but lost its reply"
  rm -f "$R_SSH_LOSE_REPLY"
  serve_remotes >/dev/null 2>&1 || fail "serve reconciliation failed"
  assert_absent "$R_ROOT/state/fleet-seats/remote-theshop.pending" "a complete serve left the pending marker"
  out=$(reserve "$R_ROOT" next pool-model-a 2>&1)
  expect_code 4 "$?" "the confirmed remote grant occupies the sole seat"

  # A delayed older epoch reaching the remote grants nothing and is refused.
  served="$R_REMOTE/state/fleet-seats/served.json"
  issuer=$(jq -r .issuer "$served")
  seq=$(jq -r .seq "$served")
  digest=$(jq -r .digest "$served")
  remote_reserve_bg late pool-model-a "$dir/late"
  out=$(seats "$R_REMOTE" serve --digest "$digest" --epoch "$issuer.$((seq - 1))" --allowance shared=1 \
    < "$R_ROOT/config/fleet-seats" 2>&1); rc=$?
  expect_code 5 "$rc" "an older serve epoch: $out"
  out=$(seats "$R_REMOTE" serve --digest "$digest" --epoch "$issuer.$seq" --allowance shared=1 \
    < "$R_ROOT/config/fleet-seats" 2>&1) || fail "an exact same-epoch replay failed: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | jq '.holders | length')" "the same-epoch replay changed the certificate"
  [ -z "$(seats "$R_REMOTE" show late)" ] || fail "a replayed or older epoch granted a waiting request"
  out=$(seats "$R_REMOTE" serve --digest "0-0" --epoch "$issuer.$seq" < "$R_ROOT/config/fleet-seats" 2>&1); rc=$?
  expect_code 5 "$rc" "a conflicting same-epoch serve: $out"

  # A truncated answer never certifies.
  : > "$R_SSH_TRUNCATE"
  out=$(serve_remotes 2>&1)
  assert_contains "$out" "unreachable theshop" "a truncated serve answer was accepted"
  rm -f "$R_SSH_TRUNCATE"
  new_holder
  out=$(reserve "$R_ROOT" next pool-model-a 2>&1)
  expect_code 5 "$?" "a primary launch after a truncated serve"
  serve_remotes >/dev/null 2>&1 || fail "serve after truncation failed"
  wait "$BG_PID"
  expect_code 4 "$(cat "$dir/late.rc")" "the late request was granted beyond capacity: $(cat "$dir/late.out")"
  pass "serve epochs fence lost, late, replayed, and truncated responses"
}

test_pool_grammar_is_uniform() {
  local home="$TMP_ROOT/grammar/primary" out name dir="$TMP_ROOT/grammar-out"
  make_home "$home"
  for name in '' 'a/b' 'a b' "$(printf 'a\tb')"; do
    jq -n --arg n "$name" '{pools: [{name: $n, capacity: 1, models: ["pool-model-a"]}]}' > "$home/config/fleet-seats"
    new_holder
    out=$(reserve "$home" named pool-model-a 2>&1)
    expect_code 5 "$?" "pool name '$name'"
  done
  printf '{"pools":[{"name":".shared","capacity":1,"models":["pool-model-a"]},{"name":"..other","capacity":1,"models":["pool-model-b"]}]}\n' \
    > "$home/config/fleet-seats"
  new_holder
  out=$(reserve "$home" x pool-model-a 2>&1) || fail "a .shared reservation: $out"
  assert_contains "$out" "pool=.shared" "the .shared pool did not reserve"
  out=$(reserve "$home" y pool-model-b 2>&1) || fail "a ..other reservation: $out"
  assert_contains "$out" "pool=..other" "the ..other pool did not reserve"
  out=$(reserve "$home" z pool-model-b 2>&1)
  expect_code 4 "$?" "a second ..other holder"
  seats "$home" release y --generation g-y --reason prelaunch >/dev/null || fail "releasing a ..other seat"
  out=$(reserve "$home" z pool-model-b 2>&1) || fail "a released ..other seat was not reusable: $out"
  out=$(seats "$home" reconcile --limit 4 2>&1) || fail "reconcile over hidden pools: $out"
  out=$(seats "$home" serve --digest 1-1 --epoch r1.1 --allowance ./bad=1 < /dev/null 2>&1)
  expect_code 2 "$?" "a path-like allowance pool name on the wire"

  make_remote_fleet grammar-remote 1
  jq '.pools[0].name = ".shared"' "$R_ROOT/config/fleet-seats" > "$TMP_ROOT/dot-policy"
  mv "$TMP_ROOT/dot-policy" "$R_ROOT/config/fleet-seats"
  mkdir -p "$dir"
  serve_remotes >/dev/null 2>&1 || fail "dot-prefixed allowance delivery failed"
  remote_reserve_bg dot-agent pool-model-a "$dir/agent"
  serve_remotes >/dev/null 2>&1 || fail "dot-prefixed remote grant failed"
  wait "$BG_PID"
  expect_code 0 "$(cat "$dir/agent.rc")" "dot-prefixed remote admission: $(cat "$dir/agent.out")"
  new_holder
  out=$(reserve "$R_ROOT" next pool-model-a 2>&1)
  expect_code 4 "$?" "dot-prefixed remote occupancy: $out"
  pass "hidden pool names reach every path and invalid names refuse before any write"
}

test_exact_counting_across_route_changes() {
  local home="$TMP_ROOT/routes/primary" out
  make_home "$home"
  printf '{"pools":[{"name":"one","capacity":1,"models":["pool-model-a"]},{"name":"two","capacity":1,"models":["pool-model-b"]}]}\n' \
    > "$home/config/fleet-seats"
  new_holder
  out=$(reserve_gen "$home" h g1 - pool-model-a) || fail "initial holder: $out"
  out=$(reserve_gen "$home" h g2 g1 pool-model-a) || fail "a same-pool replacement at full capacity: $out"
  assert_contains "$out" "already held" "the same-pool replacement took a second seat"
  out=$(reserve "$home" o1 pool-model-a 2>&1)
  expect_code 4 "$?" "another holder during a same-pool handoff"
  seats "$home" release h --generation g1 --reason prelaunch >/dev/null || fail "releasing the replaced generation"
  out=$(reserve "$home" o1 pool-model-a 2>&1)
  expect_code 4 "$?" "the count dropped to zero during the handoff"
  out=$(reserve "$home" o2 pool-model-b 2>&1) || fail "filling the second pool: $out"
  out=$(reserve_gen "$home" h g3 g2 pool-model-b 2>&1)
  expect_code 4 "$?" "a cross-pool replacement into a full pool"
  assert_equals reserved "$(lifecycle_of "$home" h g2)" "a refused cross-pool replacement touched the old generation"
  seats "$home" release o2 --generation g-o2 --reason prelaunch >/dev/null || fail "freeing the second pool"
  out=$(reserve_gen "$home" h g3 g2 pool-model-b 2>&1) || fail "a cross-pool replacement with room: $out"
  out=$(reserve "$home" o1 pool-model-a 2>&1)
  expect_code 4 "$?" "the old pool freed before its generation ended"
  out=$(reserve "$home" o5 pool-model-b 2>&1)
  expect_code 4 "$?" "the destination seat was not counted"
  # Counting follows the CURRENT policy: moving model a into pool two makes
  # both of h's generations one holder there and frees pool one.
  printf '{"pools":[{"name":"one","capacity":1,"models":["pool-model-c"]},{"name":"two","capacity":1,"models":["pool-model-a","pool-model-b"]}]}\n' \
    > "$home/config/fleet-seats"
  out=$(reserve "$home" o3 pool-model-c 2>&1) || fail "a remapped policy kept counting the moved model in its old pool: $out"
  out=$(reserve "$home" o4 pool-model-a 2>&1)
  expect_code 4 "$?" "a remapped pool ignored the moved generations"
  assert_contains "$out" "(1 of 1" "one holder's two generations counted twice in one pool"
  pass "same-pool handoffs keep one seat, cross-pool candidates need destination capacity, and counting follows the current policy"
}

test_managed_records_and_legacy_import() {
  local home="$TMP_ROOT/managed/primary" out st name
  make_home "$home"
  pools "$home" 1
  st=$(cd "$home/state" && pwd -P)
  new_holder
  out=$(reserve "$home" t pool-model-a 2>&1) || fail "initial reservation: $out"
  seats "$home" release t --generation g-t --reason prelaunch >/dev/null || fail "release"
  task_record "$home" t pool-model-a ship "spawn_gen=g-t"
  out=$(reserve "$home" other pool-model-a 2>&1) || fail "a terminal generation's stale record re-counted it: $out"
  seats "$home" release other --generation g-other --reason prelaunch >/dev/null
  task_record "$home" t pool-model-a ship "spawn_gen=g-unknown"
  out=$(reserve "$home" other2 pool-model-a 2>&1)
  expect_code 5 "$?" "a task record whose generation its holder never issued"
  assert_contains "$out" "never issued" "the conflicting generation was not named"
  rm -f "$home/state/t.meta"
  printf 'not json\n' > "$home/state/fleet-seats/holders/broken.json"
  out=$(reserve "$home" other2 pool-model-a 2>&1)
  expect_code 5 "$?" "a malformed holder record"
  rm -f "$home/state/fleet-seats/holders/broken.json"

  # A v1 reservation imports once, conservatively, and counts exactly once
  # beside its own task record.
  name=$(printf '%s\t%s' "$st" legacy | cksum | tr -s ' ' '-' | cut -d- -f1-2)
  mkdir -p "$home/state/fleet-seats/.shared"
  printf 'state=%s\ntask=legacy\nmodel=pool-model-a\npid=999999\npid_identity=\nnonce=\npolicy=\nhold=\nat=1\n' "$st" \
    > "$home/state/fleet-seats/.shared/$name.seat"
  task_record "$home" legacy pool-model-a ship "spawn_gen=g-legacy"
  out=$(reserve "$home" other3 pool-model-a 2>&1)
  expect_code 4 "$?" "a new holder beside an imported legacy reservation"
  assert_contains "$out" "(1 of 1" "the legacy reservation and its record counted twice"
  assert_absent "$home/state/fleet-seats/.shared/$name.seat" "the imported v1 record was not retired"
  assert_equals v1 "$(seats "$home" show legacy | jq -r '.incarnations[0].legacy.source')" "the import lost its provenance"
  pass "managed records follow the ledger, conflicts and malformed ledgers refuse, and v1 reservations import once"
}

test_cleanup_releases_only_its_generation() {
  local home="$TMP_ROOT/cleanup/primary" out rc
  make_home "$home"
  pools "$home" 1
  new_holder
  out=$(reserve "$home" s pool-model-a 2>&1) || fail "initial reservation: $out"
  task_record "$home" s pool-model-a ship "spawn_gen=g-s"
  out=$(seats "$home" release s --generation g-s --reason teardown 2>&1); rc=$?
  expect_code 5 "$rc" "a cleanup release while the record still names the generation: $out"
  rm -f "$home/state/s.meta"
  out=$(seats "$home" release s --generation g-s --reason teardown 2>&1) || fail "a finished cleanup release: $out"
  out=$(reserve_gen "$home" s g-s2 - pool-model-a 2>&1) || fail "a new episode after cleanup: $out"
  out=$(seats "$home" release s --generation g-s --reason teardown 2>&1) || fail "a late stale cleanup failed loudly: $out"
  assert_contains "$out" "already terminal" "a late stale cleanup was not a no-op"
  assert_equals reserved "$(lifecycle_of "$home" s g-s2)" "a late stale cleanup released the successor"
  new_holder
  out=$(reserve "$home" other pool-model-a 2>&1)
  expect_code 4 "$?" "another holder beside the successor"
  pass "cleanup releases exactly its own generation and stale cleanup never frees a successor"
}

test_confirmed_missing_and_policy_removal() {
  local base="$TMP_ROOT/confirmed-missing" home fakebin ep out
  home="$base/home"
  make_home "$home"
  pools "$home" 1
  fakebin=$(endpoint_fakebin "$base/tmux")
  ep="$base/tmux/endpoint"
  printf 'fm-sm\n' > "$ep/windows"
  PATH="$fakebin:$PATH" owner_launch "$home" sm g1 - secondmate firstmate:fm-sm "$base/ready"
  printf 'claude\n' > "$ep/command"
  PATH="$fakebin:$PATH" seats "$home" confirm sm --generation g1 >/dev/null || fail "confirming g1"
  kill "$OWNER_PID"
  wait "$OWNER_PID" 2>/dev/null
  : > "$ep/windows"
  out=$(PATH="$fakebin:$PATH" seats "$home" reclaim sm --generation g1 2>&1)
  expect_code 3 "$?" "a confirmed endpoint missing from another tmux server: $out"
  assert_equals confirmed "$(lifecycle_of "$home" sm g1)" "unproven absence reclaimed a confirmed launch"
  new_holder
  out=$(reserve "$home" other pool-model-a 2>&1)
  expect_code 4 "$?" "unproven confirmed absence must keep capacity: $out"
  rm "$home/config/fleet-seats"
  assert_equals confirmed "$(lifecycle_of "$home" sm g1)" "policy removal hid the surviving ledger"
  seats "$home" release sm --generation g1 --reason teardown >/dev/null || fail "teardown after policy removal"
  pools "$home" 1
  assert_equals released "$(lifecycle_of "$home" sm g1)" "policy removal skipped teardown"
  reserve "$home" other pool-model-a >/dev/null || fail "a released seat remained occupied after policy restoration"
  pass "confirmed absence needs destruction proof and policy removal preserves cleanup"
}

test_unconfirmed_replacement_retains_predecessor() {
  local base="$TMP_ROOT/unconfirmed-replaced" home fakebin out
  home="$base/home"
  make_home "$home"
  pools "$home" 1
  fakebin=$(endpoint_fakebin "$base/tmux")
  printf 'fm-sm\n' > "$base/tmux/endpoint/windows"
  PATH="$fakebin:$PATH" owner_launch "$home" sm g1 - secondmate firstmate:fm-sm "$base/ready"
  kill "$OWNER_PID"
  wait "$OWNER_PID" 2>/dev/null
  new_holder
  reserve_gen "$home" sm g2 g1 pool-model-a secondmate >/dev/null || fail "reserving replacement"
  out=$(PATH="$fakebin:$PATH" seats "$home" release sm --generation g1 --reason replaced 2>&1)
  expect_code 3 "$?" "shell-only unconfirmed predecessor: $out"
  assert_equals reserved "$(lifecycle_of "$home" sm g1)" "replacement released a buffered launch"
  printf 'claude\n' > "$base/tmux/endpoint/command"
  PATH="$fakebin:$PATH" seats "$home" confirm sm --generation g1 >/dev/null || fail "confirming predecessor"
  printf 'bash\n' > "$base/tmux/endpoint/command"
  PATH="$fakebin:$PATH" seats "$home" release sm --generation g1 --reason replaced >/dev/null || fail "releasing a confirmed dead predecessor"
  assert_equals released "$(lifecycle_of "$home" sm g1)" "confirmed predecessor's later death did not release it"
  pass "replacement retains buffered predecessors until confirmed startup and subsequent death"
}

test_terminal_generations_and_removed_aliases() {
  local base="$TMP_ROOT/terminal-history" home fakebin out n
  home="$base/home"
  make_home "$home"
  pools "$home" 1
  fakebin=$(endpoint_fakebin "$base/tmux")
  printf 'fm-sm\n' > "$base/tmux/endpoint/windows"
  for n in 1 2 3 4 5; do
    PATH="$fakebin:$PATH" owner_launch "$home" sm "g$n" - secondmate firstmate:fm-sm "$base/ready$n"
    printf 'claude\n' > "$base/tmux/endpoint/command"
    PATH="$fakebin:$PATH" seats "$home" confirm sm --generation "g$n" >/dev/null || fail "confirming generation $n"
    kill "$OWNER_PID"
    wait "$OWNER_PID" 2>/dev/null
    printf 'bash\n' > "$base/tmux/endpoint/command"
    PATH="$fakebin:$PATH" seats "$home" reclaim sm --generation "g$n" >/dev/null || fail "reclaiming generation $n"
  done
  new_holder
  out=$(reserve_gen "$home" sm g1 - pool-model-a secondmate 2>&1)
  expect_code 5 "$?" "replaying the oldest terminal generation: $out"
  assert_equals reclaimed "$(lifecycle_of "$home" sm g1)" "terminal history forgot g1"
  out=$(seats "$home" cancel-relaunch sm --token g1 2>&1)
  expect_code 2 "$?" "removed cancellation command"
  out=$(seats "$home" release sm --token g1 --reason prelaunch 2>&1)
  expect_code 2 "$?" "removed token alias"
  pass "terminal generations never revive and removed aliases refuse"
}

test_serve_delivery_releases_fleet_lock() {
  local base="$TMP_ROOT/serve-lock" out
  make_remote_fleet serve-lock 2
  serve_remotes >/dev/null || fail "initial serve"
  new_holder
  reserve "$R_ROOT" lockprobe pool-model-a >/dev/null || fail "probe reservation"
  out=$(FM_TEST_SERVE_PROBE_HOME="$R_ROOT" FM_TEST_SERVE_PROBE_RESULT="$base/probe-result" serve_remotes 2>&1)
  assert_equals 0 "$(cat "$base/probe-result")" "the serve RPC prevented a concurrent fleet transition: $out"
  assert_equals released "$(lifecycle_of "$R_ROOT" lockprobe g-lockprobe)" "concurrent release did not take effect"
  assert_contains "$out" "served theshop" "serve failed after concurrent transition"
  pass "serve delivery permits concurrent fleet transitions and publishes its fenced certificate"
}

test_no_pool_configured_is_off
test_pool_names_do_not_escape_the_seat_directory
test_legacy_unresolved_models_count_in_every_pool
test_one_capacity_across_homes
test_nested_secondmate_records_share_capacity
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
test_inflight_remote_seat_follows_model_between_pools
test_remote_without_pools_confirms_unpooled_models
test_remote_and_local_contention_never_overbooks
test_primary_watcher_serves_remote_requests
test_spawn_refuses_a_full_pool_before_any_record
test_spawn_rejects_unverified_models
test_spawn_holds_a_seat_until_cleanup
test_secondmate_spawn_takes_a_seat
test_buffered_supervisor_launch_keeps_its_seat
test_proven_cancellation_frees_a_buffered_launch
test_lifecycle_episode_excludes_stale_mutations
test_collection_never_waits_on_task_locks
test_serve_epochs_fence_lost_and_late_responses
test_pool_grammar_is_uniform
test_exact_counting_across_route_changes
test_managed_records_and_legacy_import
test_cleanup_releases_only_its_generation

test_confirmed_missing_and_policy_removal
test_unconfirmed_replacement_retains_predecessor
test_terminal_generations_and_removed_aliases
test_serve_delivery_releases_fleet_lock
