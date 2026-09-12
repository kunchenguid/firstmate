#!/usr/bin/env bash
# Composition tests for treehouse lease refusals and their spawn-failure ledger rows.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TELEMETRY="$ROOT/bin/fm-model-telemetry.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-lease-refusal)

make_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  mkdir -p "$case_dir"
  fm_test_spawn_home "$home" pi
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" pi)
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'Pi 0.84.0' ;;
  --help) printf '%s\n' 'Options: --tui-mode <mode>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/pi"
  printf '%s|%s|%s|%s|%s|%s\n' \
    "$case_dir" "$home" "$project" "$worktree" "$fakebin" "$case_dir/treehouse-calls"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR TREEHOUSE_CALLS <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 worktree=$2 fakebin=$3 id=$4 project=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX='fake,1,0' \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --harness pi --mode direct-PR --yolo off "$@" 2>&1
}

write_treehouse_refusal_fake() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'get --help') printf '%s\n' 'Usage: treehouse get [--lease] [--json] [--lease-holder <id>]'; exit 0 ;;
  'return --help') printf '%s\n' 'Usage: treehouse return [--if-lease-id <id>] [--if-lease-holder <id>] <path>'; exit 0 ;;
esac
if [ "${1:-}" = get ]; then
  case " $* " in
    *' --lease '*)
      printf '%s\n' "${FM_FAKE_TREEHOUSE_STDERR:-no free slot for holder}" >&2
      printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_CALLS:?}"
      if [ "${FM_FAKE_TREEHOUSE_MODE:-refuse}" = empty-path ]; then
        printf '{}\n'
        exit 0
      fi
      exit "${FM_FAKE_TREEHOUSE_STATUS:-3}"
      ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

write_capture_mode_mktemp_fake() {
  local fakebin=$1
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -u
path=$(/usr/bin/mktemp "$@") || exit $?
case "$*" in
  *'.treehouse-lease-stderr.'*)
    chmod "${FM_FAKE_CAPTURE_MODE:?}" "$path"
    [ -z "${FM_FAKE_CAPTURE_MKTEMP_LOG:-}" ] || printf '%s\n' "$path" >> "$FM_FAKE_CAPTURE_MKTEMP_LOG"
    [ -z "${FM_FAKE_CAPTURE_PATH_FILE:-}" ] || printf '%s\n' "$path" > "$FM_FAKE_CAPTURE_PATH_FILE"
    ;;
esac
printf '%s\n' "$path"
SH
  chmod +x "$fakebin/mktemp"
}

wrap_treehouse_get_counter() {
  local fakebin=$1
  mv "$fakebin/treehouse" "$fakebin/treehouse-real"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *' --lease '*)
    printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_CALLS:?}"
    if [ -n "${FM_FAKE_CAPTURE_CALL_MODE_LOG:-}" ] && [ -e "$(cat "$FM_FAKE_CAPTURE_PATH_FILE" 2>/dev/null || true)" ]; then
      stat -f '%Sp' "$(cat "$FM_FAKE_CAPTURE_PATH_FILE")" >> "$FM_FAKE_CAPTURE_CALL_MODE_LOG"
    fi
    ;;
esac
FM_FAKE_CAPTURE_FLIP=0 exec "${0%/*}/treehouse-real" "$@"
SH
  chmod +x "$fakebin/treehouse"
}

run_capture_block() {
  local case_dir=$1 project=$2 id=$3 fakebin=$4 block
  block="$case_dir/capture-block.sh"
  {
    cat <<'SH'
spawn_lease_cause() { printf '%s' 'treehouse could not acquire a durable task lease'; }
spawn_lease_refusal() { printf 'error: %s\n' "$1" >&2; exit 1; }
SH
    awk '
      /^[[:space:]]+lease_attempt_marker=spawn-lease-attempted$/ { in_block=1 }
      in_block && /^[[:space:]]+WT=\$\(printf/ { exit }
      in_block { print }
    ' "$SPAWN"
    cat <<'SH'
printf 'allocation=%s\n' "${TREEHOUSE_ALLOCATION:-}"
SH
  } > "$block"
  mkdir -p "$case_dir/tasktmp" "$case_dir/tmp"
  TASK_TMP="$case_dir/tasktmp" TMPDIR="$case_dir/tmp" PROJ_ABS="$project" ID="$id" \
    FM_FAKE_PANE_PATH="$WORKTREE_DIR" PATH="$fakebin:$PATH" bash "$block" 2>&1
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

failure_payload() {
  jq -cn --arg attemptedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{attemptedAt:$attemptedAt,tuple:{harness:"pi",provider:null,model:null,effort:"default",modelVersion:null,cliVersion:null},taskClass:"unresolved",failureKind:"other",cause:"lease refusal",routingSource:null,dispatchAttestation:null,dispatchModelFamily:null,capability:"unknown",quotaReader:"not-applicable"}'
}

failure_count() {
  local ledger=$1
  [ -f "$ledger" ] || { printf '0\n'; return 0; }
  jq -s '[.[] | select(.eventType=="spawn-failure")] | length' "$ledger"
}

failure_row() {
  local ledger=$1
  jq -c 'select(.eventType=="spawn-failure")' "$ledger" | head -n 1
}

assert_one_failure() {
  local ledger=$1 expected_cause=$2 row
  [ "$(failure_count "$ledger")" = 1 ] || fail "expected exactly one spawn-failure row in $ledger"
  row=$(failure_row "$ledger")
  printf '%s' "$row" | jq -e --arg cause "$expected_cause" \
    '.failure.failureKind=="other" and .failure.capability=="unknown" and .failure.quotaReader=="not-applicable" and .failure.cause==$cause' \
    >/dev/null || fail "spawn-failure row had the wrong shape: $row"
}

source_lease_cause() {
  local home=$1 stderr_line=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_SOURCE_ONLY=1 \
    bash -c '. "$1"; spawn_lease_cause "$2"' _ "$SPAWN" "$stderr_line"
}

test_lease_cause_builder() {
  local case_data actual expected long_input long_output
  case_data=$(make_case cause-builder cause-builder-z1)
  read_case "$case_data"
  actual=$(source_lease_cause "$HOME_DIR" '')
  expected='treehouse could not acquire a durable task lease'
  [ "$actual" = "$expected" ] || fail "empty treehouse stderr invented a reason: $actual"
  actual=$(source_lease_cause "$HOME_DIR" $'  no free slot\r')
  expected='treehouse could not acquire a durable task lease: no free slot'
  [ "$actual" = "$expected" ] || fail "treehouse stderr was not trimmed: $actual"
  long_input=$(printf 'x%.0s' $(seq 1 400))
  long_output=$(source_lease_cause "$HOME_DIR" "$long_input")
  [ "$(printf '%s' "$long_output" | LC_ALL=C wc -c | tr -d ' ')" = 350 ] \
    || fail "treehouse stderr detail was not clipped to 300 bytes"
  pass "the lease cause builder trims, clips, and preserves the empty-stderr branch"
}

test_lease_refusal_records_reason() {
  local case_data id out status ledger lifecycle
  id=lease-refusal-reason-z2
  case_data=$(make_case refusal-reason "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR="no free slot for holder $id" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a treehouse lease refusal should keep exit 1"
  assert_contains "$out" "treehouse could not acquire a durable task lease: no free slot for holder $id" \
    "the treehouse stderr reason was not surfaced"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  assert_one_failure "$ledger" "treehouse lease: treehouse could not acquire a durable task lease: no free slot for holder $id"
  lifecycle="$HOME_DIR/data/telemetry/lifecycle.jsonl"
  jq -e --arg task "$id" '
    select(.op=="wait" and .taskId==$task and .waitOwner=="lock"
      and .waitKey=="treehouse-slot" and (.operationId|type)=="string"
      and .homeId=="home" and (.openedAt|type)=="number" and .resumedAt==null)' \
    "$lifecycle" >/dev/null || fail "a refused treehouse slot wrote no lock wait event"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused lease must not publish task metadata"
  assert_absent "$CASE_DIR/allocated-worktree" "a refused lease must not create an allocated worktree"
  pass "a refused treehouse lease records its bounded stderr reason"
}

test_lease_refusal_surfaces_actionable_treehouse_error() {
  local case_data id out status
  id=lease-refusal-actionable-z22
  case_data=$(make_case actionable "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR=$'🌳 Setting up worktree...\nall 24 worktrees are in use or dirty (max_trees = 24); increase max_trees in treehouse.toml' \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an exhausted treehouse pool should keep exit 1"
  assert_contains "$out" "all 24 worktrees are in use or dirty (max_trees = 24); increase max_trees in treehouse.toml" \
    "the actionable treehouse pool diagnostic was hidden"
  pass "a treehouse progress line does not hide its actionable lease refusal"
}

test_lease_refusal_without_path_records_reason() {
  local case_data id out status ledger
  id=lease-refusal-path-z3
  case_data=$(make_case refusal-path "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_MODE=empty-path FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an allocation without a path should keep exit 1"
  assert_contains "$out" "treehouse acquisition omitted its worktree path" \
    "the missing-path refusal changed its message"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  assert_one_failure "$ledger" "treehouse lease: treehouse acquisition omitted its worktree path"
  assert_absent "$HOME_DIR/state/$id.meta" "a missing-path refusal must not publish task metadata"
  pass "an allocation without a path records the existing refusal"
}

test_recorded_writer_refusal_records_reason() {
  local case_data id out status ledger
  id=lease-refusal-reuse-z4
  case_data=$(make_case refusal-reuse "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "worktree=$WORKTREE_DIR" "access=writer" "project=$PROJECT_DIR" \
    'kind=ship' 'harness=pi' 'window=fake:1' 'endpoint_task_id='
  out=$(FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "recorded-writer reuse without a lease should keep exit 1"
  assert_contains "$out" "recorded writer recovery is missing treehouse lease identity" \
    "the recorded-writer refusal changed its message"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  assert_one_failure "$ledger" "treehouse lease: recorded writer recovery is missing treehouse lease identity; refusing a generic allocation that would split the task"
  [ ! -e "$TREEHOUSE_CALLS" ] || assert_no_grep --lease "$TREEHOUSE_CALLS" \
    "recorded-writer recovery attempted a new treehouse lease"
  pass "recorded-writer reuse refusal records its existing reason"
}

test_ledger_write_failure_does_not_retry() {
  local case_data id out status ledger
  id=lease-refusal-write-z5
  case_data=$(make_case refusal-write "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  mkdir -p "$ledger"
  out=$(FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR="no free slot for holder $id" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a ledger write failure must preserve the lease refusal exit"
  assert_contains "$out" "treehouse could not acquire a durable task lease: no free slot for holder $id" \
    "a ledger write failure lost the lease refusal"
  assert_contains "$out" "warn: spawn-failure telemetry could not be recorded (kind=other)" \
    "a ledger write failure did not warn"
  [ "$(wc -l < "$TREEHOUSE_CALLS" | tr -d ' ')" = 1 ] \
    || fail "a refused spawn retried treehouse after telemetry failed"
  assert_absent "$HOME_DIR/state/$id.meta" "a ledger write failure must not publish task metadata"
  pass "a failed ledger write preserves the refusal without retrying treehouse"
}

test_capture_failure_falls_back_without_retrying() {
  local case_data id out status ledger
  id=lease-refusal-capture-z55
  case_data=$(make_case capture-failure "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  mkdir "$CASE_DIR/unwritable"
  chmod 500 "$CASE_DIR/unwritable"
  cat > "$FAKEBIN_DIR/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'.treehouse-lease-stderr.'*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$FAKEBIN_DIR/mktemp"
  out=$(TMPDIR="$CASE_DIR/unwritable" FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR="no free slot for holder $id" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "capture setup failure should keep the lease refusal exit"
  assert_contains "$out" "treehouse could not acquire a durable task lease" \
    "capture setup failure lost the fixed lease refusal"
  assert_not_contains "$out" "no free slot for holder $id" \
    "capture setup failure unexpectedly surfaced uncaptured stderr"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  assert_one_failure "$ledger" "treehouse lease: treehouse could not acquire a durable task lease"
  [ "$(wc -l < "$TREEHOUSE_CALLS" | tr -d ' ')" = 1 ] \
    || fail "capture setup failure retried treehouse"
  pass "an unwritable lease-stderr temp path falls back without retrying"
}

test_redirection_failure_allows_success() {
  local case_data id out status ledger
  id=lease-success-capture-z56
  case_data=$(make_case success-capture "$id")
  read_case "$case_data"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR"
  wrap_treehouse_get_counter "$FAKEBIN_DIR"
  write_capture_mode_mktemp_fake "$FAKEBIN_DIR"
  out=$(FM_FAKE_CAPTURE_MODE=0400 FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a capture redirection failure must not refuse a healthy lease: $out"
  [ "$(wc -l < "$TREEHOUSE_CALLS" | tr -d ' ')" = 1 ] \
    || fail "a capture redirection failure did not attempt treehouse exactly once"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  [ "$(failure_count "$ledger")" = 0 ] || fail "a successful lease wrote a spawn-failure row"
  jq -se 'any(.[]; .eventType=="attempt-intake")' "$ledger" >/dev/null \
    || fail "a capture redirection failure lost the ordinary intake row"
  pass "a redirection failure stays advisory and admits a healthy lease"
}

test_capture_reopen_failure_allows_success() {
  local case_data id out status
  id=lease-success-reopen-z58
  case_data=$(make_case reopen-capture "$id")
  read_case "$case_data"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR"
  wrap_treehouse_get_counter "$FAKEBIN_DIR"
  write_capture_mode_mktemp_fake "$FAKEBIN_DIR"
  cat > "$CASE_DIR/cd-hook" <<'SH'
cd() {
  local target=${1:-}
  builtin cd "$@"
  [ "$target" = -- ] && target=${2:-}
  if [ "${FM_FAKE_CAPTURE_FLIP:-0}" = 1 ] \
    && [ "${FM_FAKE_CAPTURE_FLIPPED:-0}" != 1 ] \
    && [ "$target" = "${FM_FAKE_CAPTURE_PROJECT:-}" ] \
    && [ -f "${FM_FAKE_CAPTURE_PATH_FILE:-}" ]; then
    capture_path=$(cat "$FM_FAKE_CAPTURE_PATH_FILE")
    chmod 0400 "$capture_path"
    [ -z "${FM_FAKE_CAPTURE_MODE_LOG:-}" ] || stat -f '%Sp' "$capture_path" >> "$FM_FAKE_CAPTURE_MODE_LOG"
    rm -f "$capture_path"
    mkdir "$capture_path"
    [ -z "${FM_FAKE_CAPTURE_FLIPPED_FILE:-}" ] || printf '%s\n' flipped > "$FM_FAKE_CAPTURE_FLIPPED_FILE"
    export FM_FAKE_CAPTURE_FLIPPED=1
  fi
}
SH
  out=$(BASH_ENV="$CASE_DIR/cd-hook" FM_FAKE_CAPTURE_MODE=0600 \
    FM_FAKE_CAPTURE_FLIP=1 FM_FAKE_CAPTURE_PROJECT="$PROJECT_DIR" \
    FM_FAKE_CAPTURE_PATH_FILE="$CASE_DIR/capture-path" \
    FM_FAKE_CAPTURE_MKTEMP_LOG="$CASE_DIR/mktemp.log" \
    FM_FAKE_CAPTURE_MODE_LOG="$CASE_DIR/mode.log" \
    FM_FAKE_CAPTURE_CALL_MODE_LOG="$CASE_DIR/call-mode.log" \
    FM_FAKE_CAPTURE_FLIPPED_FILE="$CASE_DIR/flipped" \
    FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    run_capture_block "$CASE_DIR" "$PROJECT_DIR" "$id" "$FAKEBIN_DIR")
  status=$?
  expect_code 0 "$status" "a capture reopen failure must not refuse a healthy lease: $out"
  assert_contains "$out" "allocation=" "the capture reopen control did not return a lease allocation"
  [ "$(wc -l < "$CASE_DIR/mktemp.log" | tr -d ' ')" = 1 ] \
    || fail "the capture reopen control used more than one stderr temp"
  [ "$(wc -l < "$TREEHOUSE_CALLS" | tr -d ' ')" = 1 ] \
    || fail "a capture reopen failure did not attempt treehouse exactly once"
  pass "an actual capture reopen failure stays advisory and admits a healthy lease"
}

test_unreadable_capture_after_attempt_refuses_once() {
  local case_data id out status ledger
  id=lease-refusal-unreadable-z57
  case_data=$(make_case unreadable-capture "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  write_capture_mode_mktemp_fake "$FAKEBIN_DIR"
  out=$(FM_FAKE_CAPTURE_MODE=0200 FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR="no free slot for holder $id" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an unreadable post-attempt capture must preserve refusal"
  assert_contains "$out" "treehouse could not acquire a durable task lease" \
    "an unreadable post-attempt capture lost the fixed refusal"
  assert_not_contains "$out" "no free slot for holder $id" \
    "an unreadable post-attempt capture exposed unavailable stderr"
  [ "$(wc -l < "$TREEHOUSE_CALLS" | tr -d ' ')" = 1 ] \
    || fail "an unreadable post-attempt capture retried treehouse"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  assert_one_failure "$ledger" "treehouse lease: treehouse could not acquire a durable task lease"
  pass "an unreadable post-attempt capture refuses after one lease attempt"
}

test_successful_real_lease_is_not_failure() {
  local case_data id out status ledger
  id=lease-success-z6
  case_data=$(make_case success "$id")
  read_case "$case_data"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR"
  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a real lease fixture should spawn successfully: $out"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  [ "$(failure_count "$ledger")" = 0 ] || fail "a successful lease wrote a spawn-failure row"
  jq -se 'any(.[]; .eventType=="attempt-intake")' "$ledger" >/dev/null \
    || fail "a successful lease did not preserve the ordinary intake row"
  pass "a successful real lease preserves ordinary intake telemetry"
}

test_busy_ledger_lock_skips_evidence() {
  local case_data id out status ledger before after holder start_ms elapsed direct_out direct_status payload
  id=lease-refusal-lock-z7
  case_data=$(make_case busy-lock "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  printf '%s\n' '{"existing":"ledger"}' > "$ledger"
  before=$(hash_file "$ledger")
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash -c '. "$1"; fm_lock_try_acquire "$2"; sleep 60' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR/state/.model-telemetry.lock" &
  holder=$!
  for _ in $(seq 1 40); do
    [ -e "$HOME_DIR/state/.model-telemetry.lock" ] && break
    sleep 0.05
  done
  [ -e "$HOME_DIR/state/.model-telemetry.lock" ] || fail "could not establish the ledger lock holder"
  start_ms=$(now_ms)
  out=$(FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR="no free slot for holder $id" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  elapsed=$(( $(now_ms) - start_ms ))
  payload=$(failure_payload)
  direct_out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$TELEMETRY" spawn-failure --state "$HOME_DIR/state" --task "$id" --payload "$payload" 2>&1)
  direct_status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$status" "a busy ledger lock must preserve the lease refusal exit"
  expect_code 1 "$direct_status" "direct spawn-failure telemetry should refuse a live ledger holder"
  assert_contains "$direct_out" "spawn-failure evidence skipped: ledger lock held (pid $holder)" \
    "direct spawn-failure telemetry did not name its live holder"
  [ "$elapsed" -lt 5000 ] || fail "a busy ledger lock stalled spawn refusal for ${elapsed}ms"
  assert_contains "$out" "warn: spawn-failure telemetry could not be recorded (kind=other)" \
    "a busy ledger lock did not preserve the best-effort warning"
  after=$(hash_file "$ledger")
  [ "$before" = "$after" ] || fail "a busy ledger lock changed the telemetry ledger"
  assert_absent "$HOME_DIR/state/.treehouse-acquisition.lock" \
    "treehouse acquisition lock remained held after a refused spawn"
  [ "$(wc -l < "$TREEHOUSE_CALLS" | tr -d ' ')" = 1 ] \
    || fail "a busy ledger lock caused a treehouse retry"
  pass "a busy ledger lock skips evidence without holding the treehouse lock"
}

test_unknown_ledger_lock_failure_is_not_a_live_holder() {
  local case_data id out status ledger direct_out direct_status payload
  id=lease-refusal-lock-create-z8
  case_data=$(make_case lock-create-failure "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  printf '%s\n' '{"existing":"ledger"}' > "$ledger"
  cat > "$FAKEBIN_DIR/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'.model-telemetry.lock.owner.'*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$FAKEBIN_DIR/mktemp"
  out=$(FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR="no free slot for holder $id" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a ledger lock allocation failure must preserve the lease refusal exit"
  assert_contains "$out" "warn: spawn-failure telemetry could not be recorded (kind=other)" \
    "a ledger lock allocation failure did not preserve the best-effort warning"
  assert_not_contains "$out" "ledger lock held (pid" \
    "a lock allocation failure was misreported as a live holder"
  payload=$(failure_payload)
  direct_out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    PATH="$FAKEBIN_DIR:$PATH" "$TELEMETRY" spawn-failure --state "$HOME_DIR/state" --task "$id" --payload "$payload" 2>&1)
  direct_status=$?
  expect_code 1 "$direct_status" "direct spawn-failure telemetry should refuse an unknown ledger holder"
  assert_contains "$direct_out" "spawn-failure evidence skipped: ledger lock unavailable (holder unknown)" \
    "direct spawn-failure telemetry invented a live holder after allocation failure"
  pass "a ledger lock allocation failure stays an unknown holder"
}

test_telemetry_consumer_reads_refusal() {
  local case_data id out status ledger
  id=lease-refusal-consumer-z9
  case_data=$(make_case consumer "$id")
  read_case "$case_data"
  write_treehouse_refusal_fake "$FAKEBIN_DIR"
  out=$(FM_FAKE_TREEHOUSE_CALLS="$TREEHOUSE_CALLS" \
    FM_FAKE_TREEHOUSE_STDERR="no free slot for holder $id" \
    run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "consumer fixture refusal should keep exit 1"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$TELEMETRY" spawn-failures --format json)
  printf '%s' "$out" | jq -e 'length==1 and .[0].failures==1 and .[0].failureKinds.other==1 and .[0].capability==["unknown"] and .[0].quotaReader==["not-applicable"]' \
    >/dev/null || fail "spawn-failures consumer did not list the refusal: $out"
  pass "the spawn-failures consumer lists a recorded lease refusal"
}

test_absent_task_class_warns_unresolved() {
  local case_data id out status ledger warning
  warning='warning: --task-class absent; model telemetry records taskClass=unresolved'
  id=task-class-absent-z9
  case_data=$(make_case task-class-absent "$id")
  read_case "$case_data"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR"
  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a ship launch without --task-class should still spawn: $out"
  assert_contains "$out" "$warning" \
    "a ship launch without --task-class did not warn that telemetry records unresolved"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  jq -e 'select(.eventType=="attempt-intake") | .intake.taskClass=="unresolved"' "$ledger" >/dev/null \
    || fail "absent --task-class changed the recorded intake class"

  id=task-class-set-z10
  case_data=$(make_case task-class-set "$id")
  read_case "$case_data"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR"
  out=$(run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" \
    --task-class rote-reversible-edit)
  status=$?
  expect_code 0 "$status" "a ship launch with --task-class should still spawn: $out"
  assert_not_contains "$out" "$warning" \
    "an explicit --task-class still printed the absent-flag warning"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  jq -e 'select(.eventType=="attempt-intake") | .intake.taskClass=="rote-reversible-edit"' "$ledger" >/dev/null \
    || fail "explicit --task-class was not recorded on intake"
  pass "absent --task-class warns once; an explicit class keeps the warning off"
}

test_lease_cause_builder
test_lease_refusal_records_reason
test_lease_refusal_surfaces_actionable_treehouse_error
test_absent_task_class_warns_unresolved
test_lease_refusal_without_path_records_reason
test_recorded_writer_refusal_records_reason
test_ledger_write_failure_does_not_retry
test_capture_failure_falls_back_without_retrying
test_redirection_failure_allows_success
test_capture_reopen_failure_allows_success
test_unreadable_capture_after_attempt_refuses_once
test_successful_real_lease_is_not_failure
test_busy_ledger_lock_skips_evidence
test_unknown_ledger_lock_failure_is_not_a_live_holder
test_telemetry_consumer_reads_refusal

echo "# all fm-spawn-lease-refusal tests passed"
