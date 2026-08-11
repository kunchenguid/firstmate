#!/usr/bin/env bash
# Behavior tests for the data-only contender lifecycle command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTENDER="$ROOT/bin/fm-contender.sh"
TMP_ROOT=$(fm_test_tmproot fm-contender)

make_home() {  # <case> <id> [kind]
  local case_name=$1 id=$2 kind=${3:-scout} home
  home="$TMP_ROOT/$case_name"
  mkdir -p "$home/state" "$home/data/$id"
  printf 'kind=%s\n' "$kind" > "$home/state/$id.meta"
  printf 'report for %s\n' "$id" > "$home/data/$id/report.md"
  printf '%s\n' "$home"
}

make_teardown_stub() {  # <home>
  local home=$1 stub
  stub="$home/teardown-stub.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEARDOWN_LOG"
rm -f "$FM_STATE_OVERRIDE/$1.meta" "$FM_STATE_OVERRIDE/$1.status"
EOF
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

run_contender() {  # <home> <stub> <args...>
  local home=$1 stub=$2
  shift 2
  FM_HOME="$home" FM_TEARDOWN_BIN="$stub" TEARDOWN_LOG="$home/teardown.log" "$CONTENDER" "$@"
}

test_await_pick_is_durable_and_releases_endpoint() {
  local home stub out
  home=$(make_home await contender-a1)
  stub=$(make_teardown_stub "$home")
  out=$(run_contender "$home" "$stub" await-pick contender-a1) || fail "await-pick failed"
  [ "$out" = 'awaiting-pick contender-a1 data/contender-a1/report.md' ] \
    || fail "await-pick did not report its durable data artifact: $out"
  [ ! -e "$home/state/contender-a1.meta" ] || fail "await-pick retained the finished contender endpoint"
  [ -f "$home/data/contender-a1/report.md" ] || fail "await-pick removed the contender report"
  [ "$(cat "$home/teardown.log")" = contender-a1 ] || fail "await-pick did not use ordinary teardown"
  out=$(run_contender "$home" "$stub" list) || fail "list failed after await-pick"
  [ "$out" = 'awaiting-pick contender-a1 data/contender-a1/report.md' ] \
    || fail "awaiting-pick was not a durable first-class state: $out"
  pass "fm-contender: awaiting-pick is durable while the completed endpoint is cleaned"
}

test_rejection_converges_cleanup_and_removes_leftover_record() {
  local home stub out
  home=$(make_home rejection contender-b2)
  stub=$(make_teardown_stub "$home")
  out=$(run_contender "$home" "$stub" settle rejected contender-b2) || fail "rejection settlement failed"
  [ "$out" = rejected\ contender-b2 ] || fail "rejection did not report settlement: $out"
  [ ! -e "$home/state/contender-b2.meta" ] || fail "rejection retained the finished contender endpoint"
  [ ! -e "$home/state/contenders/contender-b2" ] || fail "rejection retained a settled contender record"
  [ -f "$home/data/contender-b2/report.md" ] || fail "rejection removed the retained report"
  [ "$(cat "$home/teardown.log")" = contender-b2 ] || fail "rejection did not clean through teardown"
  pass "fm-contender: rejected data-only contender cleanup converges automatically"
}

test_interrupted_settlement_converges_without_reopening_an_endpoint() {
  local home stub out
  home=$(make_home interrupted contender-c3)
  stub=$(make_teardown_stub "$home")
  mkdir -p "$home/state/contenders"
  printf 'phase=rejected\nreport=data/contender-c3/report.md\n' > "$home/state/contenders/contender-c3"
  out=$(run_contender "$home" "$stub" settle rejected contender-c3) || fail "interrupted settlement did not converge"
  [ "$out" = rejected\ contender-c3 ] || fail "interrupted settlement did not report recovery: $out"
  [ ! -e "$home/state/contenders/contender-c3" ] || fail "interrupted settlement retained its record"
  [ -e "$home/state/contender-c3.meta" ] || fail "recovered settlement touched a new live endpoint"
  [ ! -e "$home/teardown.log" ] || fail "recovered settlement repeated teardown"
  pass "fm-contender: interrupted settlement converges without reviving work"
}

test_only_data_only_scouts_can_enter_lifecycle() {
  local home stub out status
  home=$(make_home non-scout contender-d4 ship)
  stub=$(make_teardown_stub "$home")
  out=$(run_contender "$home" "$stub" await-pick contender-d4 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship entered the data-only contender lifecycle"
  printf '%s\n' "$out" | grep -F 'only data-only scout options may use this lifecycle' >/dev/null \
    || fail "non-scout refusal did not identify the safety boundary: $out"
  [ -e "$home/state/contender-d4.meta" ] || fail "non-scout refusal removed live work"
  [ ! -e "$home/teardown.log" ] || fail "non-scout refusal called teardown"
  pass "fm-contender: non-scout work stays on its ordinary delivery lifecycle"
}

test_malformed_record_fails_closed() {
  local home stub out status
  home=$(make_home malformed contender-e5)
  stub=$(make_teardown_stub "$home")
  mkdir -p "$home/state/contenders"
  printf 'phase=awaiting-pick\nreport=data/other/report.md\n' > "$home/state/contenders/contender-e5"
  out=$(run_contender "$home" "$stub" list 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed contender record was accepted"
  printf '%s\n' "$out" | grep -F 'malformed contender record' >/dev/null \
    || fail "malformed record refusal was not explicit: $out"
  [ -e "$home/state/contender-e5.meta" ] || fail "malformed record check removed live work"
  pass "fm-contender: malformed durable lifecycle evidence fails closed"
}

test_spawnable_task_ids_enter_the_lifecycle() {
  local home stub out id
  id='Design_v2.Final'
  home=$(make_home spawnable-id "$id")
  stub=$(make_teardown_stub "$home")
  out=$(run_contender "$home" "$stub" await-pick "$id") || fail "spawnable mixed-character task id was rejected"
  [ "$out" = "awaiting-pick $id data/$id/report.md" ] \
    || fail "spawnable mixed-character task id produced the wrong lifecycle result: $out"
  pass "fm-contender: lifecycle accepts every shared spawnable task id"
}

test_concurrent_settlement_cannot_resurrect_a_contender() {
  local home stub await_pid settle_pid i second_entered=0
  home=$(make_home concurrent contender-f6)
  stub="$home/racing-teardown.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
home=${FM_STATE_OVERRIDE%/state}
while ! mkdir "$home/teardown-counter.lock" 2>/dev/null; do sleep 0.01; done
count=$(cat "$home/teardown-count" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$home/teardown-count"
rmdir "$home/teardown-counter.lock"
if [ "$count" -eq 1 ]; then
  : > "$home/first-entered"
  while [ ! -e "$home/release-first" ]; do sleep 0.01; done
else
  : > "$home/second-entered"
fi
rm -f "$FM_STATE_OVERRIDE/$1.meta" "$FM_STATE_OVERRIDE/$1.status"
EOF
  chmod +x "$stub"

  run_contender "$home" "$stub" await-pick contender-f6 > "$home/await.out" 2> "$home/await.err" &
  await_pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -e "$home/first-entered" ] && break
    sleep 0.01
    i=$((i + 1))
  done
  [ -e "$home/first-entered" ] || fail "first contender transition did not reach teardown"

  run_contender "$home" "$stub" settle rejected contender-f6 > "$home/settle.out" 2> "$home/settle.err" &
  settle_pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    if [ -e "$home/second-entered" ]; then
      second_entered=1
      break
    fi
    sleep 0.01
    i=$((i + 1))
  done
  if [ "$second_entered" -eq 1 ]; then
    wait "$settle_pid" || fail "concurrent settlement failed before the first transition resumed"
  fi
  : > "$home/release-first"
  wait "$await_pid" || fail "await-pick failed after concurrent settlement"
  if [ "$second_entered" -eq 0 ]; then
    wait "$settle_pid" || fail "serialized concurrent settlement failed"
  fi

  [ ! -e "$home/state/contenders/contender-f6" ] || fail "concurrent settlement resurrected an awaiting-pick record"
  [ "$(cat "$home/settle.out")" = 'rejected contender-f6' ] || fail "concurrent settlement did not complete"
  pass "fm-contender: concurrent transitions serialize through terminal settlement"
}

test_await_pick_is_durable_and_releases_endpoint
test_rejection_converges_cleanup_and_removes_leftover_record
test_interrupted_settlement_converges_without_reopening_an_endpoint
test_only_data_only_scouts_can_enter_lifecycle
test_malformed_record_fails_closed
test_spawnable_task_ids_enter_the_lifecycle
test_concurrent_settlement_cannot_resurrect_a_contender

echo "# all fm-contender tests passed"
