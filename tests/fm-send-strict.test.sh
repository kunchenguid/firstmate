#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
fm_test_tmproot_into TMP_ROOT fm-send-strict

# shellcheck source=bin/fm-account-routing-lib.sh
. "$ROOT/bin/fm-account-routing-lib.sh"

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
all=$*
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    case "$all" in
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#{session_name}'*) printf '%s\t%s\n' "${FM_FAKE_TMUX_SESSION:-sess}" "${FM_FAKE_TMUX_LABEL:-fm-lost}" ;;
      *) printf '%%1\n' ;;
    esac
    exit 0 ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_CAPTURE_FAIL:-0}" != 1 ] || exit 1
    printf '\xe2\x94\x82 \xe2\x94\x82\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

test_managed_tmux_send_rejects_reused_id_in_other_session() {
  local dir fb home err log rc
  dir="$TMP_ROOT/tmux-session-bound"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home tmux-session-bound); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/tmux-session-bound.meta" \
    "window=recorded:fm-tmux-session-bound" "tmux_window_id=@77" \
    "tmux_session_target=recorded:fm-tmux-session-bound" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_SESSION=other FM_FAKE_TMUX_LABEL=fm-tmux-session-bound FM_SEND_SETTLE=0 \
    "$SEND" tmux-session-bound "wrong-session steer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send accepted a stable id reused in another session"
  ! grep -q '^send-keys ' "$log" || fail "fm-send steered after stable tmux identity validation failed"
  pass "fm-send rejects managed stable ids reused in another tmux session"
}

test_managed_tmux_send_retains_verified_stable_id() {
  local dir fb home err log rc
  dir="$TMP_ROOT/tmux-stable-target"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home tmux-stable-target); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/tmux-stable-target.meta" \
    "window=recorded:fm-tmux-stable-target" "tmux_window_id=@78" \
    "tmux_session_target=recorded:fm-tmux-stable-target" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_SESSION=recorded FM_FAKE_TMUX_LABEL=fm-tmux-stable-target FM_SEND_SETTLE=0 \
    "$SEND" tmux-stable-target "stable steer" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -eq 0 ] || fail "fm-send rejected a verified stable tmux identity"
  assert_grep 'target=@78 ' "$log" "fm-send discarded the verified stable tmux id"
  ! grep -q 'target=recorded:fm-tmux-stable-target ' "$log" \
    || fail "fm-send retargeted through the mutable session label"
  pass "fm-send retains the verified stable tmux identity"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

make_herdr_identity_stub() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "$*" in
  status\ --json*) printf '{"client":{"protocol":14},"server":{"running":true}}\n' ;;
  pane\ get*) printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' ;;
  pane\ list*) printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w2:t2","workspace_id":"w2"}]}}\n' ;;
  workspace\ list*) printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-other"}]}}\n' ;;
  tab\ list*) printf '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-local-task","workspace_id":"w2"}]}}\n' ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

test_explicit_herdr_target_matching_meta_is_identity_bound() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-explicit-meta"; mkdir -p "$dir"
  fb=$(make_herdr_identity_stub "$dir"); home=$(setup_home herdr-explicit-meta)
  err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/local-task.meta" \
    "window=default:w1:p2" "backend=herdr" "kind=ship" \
    "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    "$SEND" default:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "explicit Herdr target matched to local metadata should reject a reused pane"
  if grep -Eq 'pane (send-text|send-keys)' "$log"; then
    fail "identity-mismatched explicit Herdr target received a key"
  fi
  pass "fm-send strict: explicit Herdr targets matched to local metadata retain managed identity"
}

test_metadata_free_explicit_herdr_target_remains_unbound() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-explicit-external"; mkdir -p "$dir"
  fb=$(make_herdr_identity_stub "$dir"); home=$(setup_home herdr-explicit-external)
  err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    "$SEND" default:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "metadata-free explicit Herdr target should remain an unbound escape hatch"
  assert_contains "$(cat "$log")" "pane send-keys w1:p2 enter" "unbound explicit Herdr target should receive the key"
  pass "fm-send strict: metadata-free explicit Herdr targets remain unbound"
}

test_explicit_managed_target_records_steering() {
  local dir fb home err log rc trail
  dir="$TMP_ROOT/managed-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-explicit)
  err="$dir/send.err"; log="$dir/tmux.log"; trail="$home/data/managed-task/steering.md"
  mkdir -p "$home/data/managed-task"
  : > "$log"
  fm_write_meta "$home/state/managed-task.meta" \
    "window=sess:fm-managed-task" "kind=ship" "harness=codex" \
    "generation_id=account:managed-task:attempt-1" "account_profile=codex-2"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:fm-managed-task "Preserve this explicit managed steer." >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "explicit managed target send"
  assert_grep "Preserve this explicit managed steer" "$trail" \
    "explicit managed target delivery was absent from the provider-neutral steering trail: $(cat "$err")"
  pass "fm-send strict: explicit targets resolved to managed metadata are audited"
}

test_unknown_managed_delivery_is_recorded_unconfirmed() {
  local dir fb home err log rc unconfirmed
  dir="$TMP_ROOT/managed-unknown"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-unknown)
  err="$dir/send.err"; log="$dir/tmux.log"; unconfirmed="$home/data/managed-unknown/steering-unconfirmed.md"
  mkdir -p "$home/data/managed-unknown"
  : > "$log"
  fm_write_meta "$home/state/managed-unknown.meta" \
    "window=sess:fm-managed-unknown" "kind=ship" "harness=codex" \
    "generation_id=account:managed-unknown:attempt-1" "account_profile=codex-2"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE_FAIL=1 FM_SEND_SETTLE=0 \
    "$SEND" managed-unknown "Preserve this unknown delivery verbatim." >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "unknown managed delivery should retain the lenient send result"
  assert_present "$unconfirmed" "unknown managed delivery was not durably audited"
  assert_grep 'delivery unconfirmed' "$unconfirmed" "unknown steering audit omitted its delivery verdict"
  assert_grep '> Preserve this unknown delivery verbatim.' "$unconfirmed" \
    "unknown steering audit changed the instruction content"
  assert_absent "$home/data/managed-unknown/steering.md" \
    "unknown delivery was recorded as canonical steering"
  assert_absent "$home/data/managed-unknown/steering-pending.md" \
    "unknown delivery was recorded as delivered pending steering"
  assert_contains "$(cat "$err")" "durably recorded as unconfirmed" \
    "unknown delivery warning omitted its explicit verdict"
  pass "fm-send strict: unknown managed delivery remains explicitly unconfirmed"
}

test_managed_steering_intent_precedes_external_submission() {
  local dir fb home log journal ready proceed sender_pid sender_status intent
  dir="$TMP_ROOT/managed-prejournal"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-prejournal)
  log="$dir/tmux.log"; journal="$home/data/managed-prejournal/steering-journal.md"
  ready="$dir/after-submit.ready"; proceed="$dir/after-submit.proceed"
  mkdir -p "$home/data/managed-prejournal"
  : > "$log"
  fm_write_meta "$home/state/managed-prejournal.meta" \
    "window=sess:fm-managed-prejournal" "kind=ship" "harness=codex" \
    "generation_id=account:managed-prejournal:attempt-1" "account_profile=codex-2"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SEND_TEST_AFTER_SUBMIT_READY="$ready" FM_SEND_TEST_AFTER_SUBMIT_PROCEED="$proceed" \
    "$SEND" managed-prejournal "Journal this before external acceptance." >"$dir/send.out" 2>"$dir/send.err" &
  sender_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; /bin/sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$sender_pid" 2>/dev/null || true; fail "managed steering post-submit gate did not open"; }
  assert_grep 'Journal this before external acceptance.' "$journal" \
    "managed steering was externally accepted without a durable intent"
  intent=$(sed -n 's/.*(intent \([0-9a-f]*\) pending).*/\1/p' "$journal")
  [ -n "$intent" ] || fail "managed steering intent did not have a unique durable key"
  kill -KILL "$sender_pid" 2>/dev/null || true
  if wait "$sender_pid"; then sender_status=0; else sender_status=$?; fi
  [ "$sender_status" -ne 0 ] || fail "managed steering interruption fixture exited successfully"
  assert_grep "intent $intent pending" "$journal" \
    "managed steering interruption lost its pending delivery identity"
  pass "fm-send strict: managed steering is journaled before external submission"
}

test_concurrent_managed_steering_is_serialized_and_atomic() {
  local dir fb home log trail lock pid rc=0 i count
  local pids=()
  dir="$TMP_ROOT/managed-concurrent"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-concurrent)
  log="$dir/tmux.log"; trail="$home/data/managed-concurrent/steering.md"
  lock="$home/state/.account-steering-managed-concurrent.lock"
  mkdir -p "$home/data/managed-concurrent"
  : > "$log"
  fm_write_meta "$home/state/managed-concurrent.meta" \
    "window=sess:fm-managed-concurrent" "kind=ship" "harness=codex" \
    "generation_id=account:managed-concurrent:attempt-1" "account_profile=codex-2"

  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=30 \
      "$SEND" managed-concurrent "Concurrent managed steer $i." >"$dir/send-$i.out" 2>"$dir/send-$i.err" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
  done
  if [ "$rc" -ne 0 ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [ ! -s "$dir/send-$i.err" ] || printf 'send-%s: %s\n' "$i" "$(cat "$dir/send-$i.err")" >&2
    done
    fail "a concurrent managed steer failed"
  fi
  count=$(grep -c '^# Steering trail$' "$trail")
  [ "$count" -eq 1 ] || fail "concurrent steering wrote $count trail headers"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    count=$(grep -F -c "> Concurrent managed steer $i." "$trail")
    [ "$count" -eq 1 ] || fail "concurrent steering retained message $i $count times"
  done
  assert_absent "$lock" "concurrent steering left its serialization lock behind"
  if find "$(dirname "$trail")" -maxdepth 1 -name '.steering.md.*' -print -quit | grep -q .; then
    fail "concurrent steering leaked an atomic staging file"
  fi
  pass "fm-send strict: concurrent managed steering is serialized and atomic"
}

test_managed_send_revalidates_after_respawn_wait() {
  local dir fb home err log lock sender_pid sender_rc staged owner_wait
  dir="$TMP_ROOT/managed-respawn-race"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-respawn-race)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/managed-race.meta" \
    "window=sess:fm-managed-race-old" "kind=ship" "harness=codex" \
    "generation_id=account:managed-race:attempt-1" "account_profile=codex-2"

  lock=$(fm_account_lifecycle_lock_acquire "$home/state" managed-race) \
    || fail "could not hold the managed lifecycle lock for the respawn race"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" managed-race "Do not deliver across respawn." >"$dir/send.out" 2>"$err" &
  sender_pid=$!
  owner_wait=
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    owner_wait=$(find "$home/state" -maxdepth 1 -name '.account-lifecycle-managed-race.owner.*' -print -quit)
    [ -n "$owner_wait" ] && break
    /bin/sleep 0.05
  done
  if [ -z "$owner_wait" ]; then
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    kill "$sender_pid" 2>/dev/null || true
    wait "$sender_pid" 2>/dev/null || true
    fail "managed sender never waited on the lifecycle lock"
  fi
  staged="$home/state/.managed-race.meta.respawn"
  fm_write_meta "$staged" \
    "window=sess:fm-managed-race-new" "kind=ship" "harness=codex" \
    "generation_id=account:managed-race:attempt-2" "account_profile=codex-3"
  mv "$staged" "$home/state/managed-race.meta"
  fm_account_lifecycle_lock_release "$lock" || fail "could not release the respawn race lifecycle lock"
  if wait "$sender_pid"; then sender_rc=0; else sender_rc=$?; fi

  [ "$sender_rc" -ne 0 ] || fail "managed sender accepted replaced metadata after waiting"
  assert_contains "$(cat "$err")" "generation or endpoint changed" \
    "managed sender did not diagnose the replaced generation"
  [ ! -s "$log" ] || fail "managed sender delivered after its generation changed"
  assert_absent "$home/data/managed-race/steering.md" \
    "managed sender audited a steer that was refused before delivery"
  pass "fm-send strict: managed sends reject respawned generations after lifecycle waits"
}

test_managed_key_revalidates_after_respawn_wait() {
  local dir fb home err log lock sender_pid sender_rc staged owner_wait
  dir="$TMP_ROOT/managed-key-respawn-race"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-key-respawn-race)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/managed-key-race.meta" \
    "window=sess:fm-managed-key-race-old" "kind=ship" "harness=codex" \
    "generation_id=account:managed-key-race:attempt-1" "account_profile=codex-2"

  lock=$(fm_account_lifecycle_lock_acquire "$home/state" managed-key-race) \
    || fail "could not hold the managed lifecycle lock for the key respawn race"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" managed-key-race --key C-c >"$dir/send.out" 2>"$err" &
  sender_pid=$!
  owner_wait=
  for _ in $(seq 1 100); do
    owner_wait=$(find "$home/state" -maxdepth 1 -name '.account-lifecycle-managed-key-race.owner.*' -print -quit)
    [ -n "$owner_wait" ] && break
    sleep 0.02
  done
  if [ -z "$owner_wait" ]; then
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
    kill "$sender_pid" 2>/dev/null || true
    wait "$sender_pid" 2>/dev/null || true
    fail "managed key sender never waited on the lifecycle lock"
  fi
  staged="$home/state/.managed-key-race.meta.respawn"
  fm_write_meta "$staged" \
    "window=sess:fm-managed-key-race-new" "kind=ship" "harness=codex" \
    "generation_id=account:managed-key-race:attempt-2" "account_profile=codex-3"
  mv "$staged" "$home/state/managed-key-race.meta"
  fm_account_lifecycle_lock_release "$lock" || fail "could not release the key respawn race lifecycle lock"
  if wait "$sender_pid"; then sender_rc=0; else sender_rc=$?; fi

  [ "$sender_rc" -ne 0 ] || fail "managed key sender accepted replaced metadata after waiting"
  assert_contains "$(cat "$err")" "generation or endpoint changed" \
    "managed key sender did not diagnose the replaced generation"
  [ ! -s "$log" ] || fail "managed key sender delivered to a replacement endpoint"
  pass "fm-send strict: managed keys reject respawned generations after lifecycle waits"
}

test_managed_send_holds_lifecycle_through_audit() {
  local dir fb home log trail ready proceed sender_pid sender_rc teardown_pid teardown_rc delivered
  dir="$TMP_ROOT/managed-teardown-race"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-teardown-race)
  log="$dir/tmux.log"; trail="$home/data/managed-audit-race/steering.md"
  ready="$dir/after-submit.ready"; proceed="$dir/after-submit.proceed"
  mkdir -p "$home/data/managed-audit-race"
  : > "$log"
  fm_write_meta "$home/state/managed-audit-race.meta" \
    "window=sess:fm-managed-audit-race" "kind=ship" "harness=codex" \
    "generation_id=account:managed-audit-race:attempt-1" "account_profile=codex-2"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SEND_TEST_AFTER_SUBMIT_READY="$ready" FM_SEND_TEST_AFTER_SUBMIT_PROCEED="$proceed" \
    "$SEND" managed-audit-race "Audit before teardown." >"$dir/send.out" 2>"$dir/send.err" &
  sender_pid=$!
  delivered=
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$ready" ] && { delivered=1; break; }
    /bin/sleep 0.05
  done
  if [ -z "$delivered" ]; then
    kill "$sender_pid" 2>/dev/null || true
    wait "$sender_pid" 2>/dev/null || true
    fail "managed sender never delivered before the audit gate"
  fi

  (
    lifecycle=$(fm_account_lifecycle_lock_acquire "$home/state" managed-audit-race) || exit 1
    grep -Fq '> Audit before teardown.' "$trail" || exit 2
    : > "$dir/teardown-acquired"
    fm_account_lifecycle_lock_release "$lifecycle"
  ) &
  teardown_pid=$!
  /bin/sleep 0.2
  [ ! -e "$dir/teardown-acquired" ] \
    || fail "teardown acquired the lifecycle lock before managed audit persistence"

  : > "$proceed"
  if wait "$sender_pid"; then sender_rc=0; else sender_rc=$?; fi
  if wait "$teardown_pid"; then teardown_rc=0; else teardown_rc=$?; fi
  expect_code 0 "$sender_rc" "managed send should finish after canonical audit persistence"
  expect_code 0 "$teardown_rc" "teardown waiter should observe the canonical audit before proceeding"
  assert_present "$dir/teardown-acquired" "teardown waiter never acquired lifecycle ownership"
  assert_grep '> Audit before teardown.' "$trail" \
    "managed steering audit was not durable before lifecycle handoff"
  pass "fm-send strict: managed sends hold lifecycle ownership through audit persistence"
}

test_managed_steering_rejects_parent_swap_during_persistence() {
  local dir fb home log task_dir moved outside ready proceed sender_pid sender_rc before
  dir="$TMP_ROOT/managed-steering-parent-race"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home managed-steering-parent-race)
  log="$dir/tmux.log"; : > "$log"
  task_dir="$home/data/managed-steering-parent-race"
  moved="$dir/pinned-task"
  outside="$dir/outside-task"
  ready="$dir/ready"
  proceed="$dir/proceed"
  mkdir -p "$task_dir" "$outside"
  printf '# Steering trail\n\n- original.\n' > "$task_dir/steering.md"
  printf 'outside steering sentinel\n' > "$outside/steering.md"
  before=$(cat "$task_dir/steering.md")
  fm_write_meta "$home/state/managed-steering-parent-race.meta" \
    "window=sess:fm-managed-steering-parent-race" "kind=ship" "harness=codex" \
    "generation_id=account:managed-steering-parent-race:attempt-1" "account_profile=codex-2"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SEND_TEST_AFTER_SUBMIT_READY="$ready" FM_SEND_TEST_AFTER_SUBMIT_PROCEED="$proceed" \
    "$SEND" managed-steering-parent-race "Do not persist through a replaced parent." >"$dir/send.out" 2>"$dir/send.err" &
  sender_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  if [ ! -e "$ready" ]; then
    kill "$sender_pid" 2>/dev/null || true
    wait "$sender_pid" 2>/dev/null || true
    fail "managed steering transaction never pinned its task directory"
  fi
  mv "$task_dir" "$moved"
  ln -s "$outside" "$task_dir"
  : > "$proceed"
  if wait "$sender_pid"; then sender_rc=0; else sender_rc=$?; fi
  expect_code 0 "$sender_rc" \
    "delivered managed steering should retain delivery truth after audit refusal: $(cat "$dir/send.err")"
  [ "$(cat "$outside/steering.md")" = 'outside steering sentinel' ] \
    || fail "managed steering transaction wrote through a raced task parent"
  [ "$(cat "$moved/steering.md")" = "$before" ] \
    || fail "failed managed steering transaction changed the pinned original trail"
  assert_contains "$(cat "$dir/send.err")" "could not be durably recorded" \
    "managed steering parent-race refusal did not preserve delivery-vs-audit truth"
  pass "fm-send strict: steering persistence rejects raced task parents"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

if [ "${FM_TEST_FOCUSED:-}" = managed-steering ]; then
  test_explicit_managed_target_records_steering
  test_managed_steering_intent_precedes_external_submission
  test_concurrent_managed_steering_is_serialized_and_atomic
  test_managed_send_revalidates_after_respawn_wait
  test_managed_send_holds_lifecycle_through_audit
  test_managed_key_revalidates_after_respawn_wait
  test_managed_steering_rejects_parent_swap_during_persistence
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-19 ]; then
  test_unknown_managed_delivery_is_recorded_unconfirmed
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-37 ]; then
  test_managed_steering_intent_precedes_external_submission
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-32 ]; then
  test_managed_tmux_send_rejects_reused_id_in_other_session
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-33 ]; then
  test_managed_tmux_send_rejects_reused_id_in_other_session
  test_managed_tmux_send_retains_verified_stable_id
  exit 0
fi

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_explicit_herdr_target_matching_meta_is_identity_bound
test_metadata_free_explicit_herdr_target_remains_unbound
test_explicit_managed_target_records_steering
test_unknown_managed_delivery_is_recorded_unconfirmed
test_managed_steering_intent_precedes_external_submission
test_concurrent_managed_steering_is_serialized_and_atomic
test_managed_send_revalidates_after_respawn_wait
test_managed_send_holds_lifecycle_through_audit
test_managed_key_revalidates_after_respawn_wait
test_managed_steering_rejects_parent_swap_during_persistence
test_healthy_fm_id_send_still_works
test_managed_tmux_send_rejects_reused_id_in_other_session
test_managed_tmux_send_retains_verified_stable_id
