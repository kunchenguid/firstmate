#!/usr/bin/env bash
# Exercise the registered Codex Stop hooks with real watcher processes and a
# deterministic queue transport. Native delivery is covered by the opt-in E2E.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/codex-harness"
cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
case "$*" in
  --version) printf 'codex-cli %s\n' "${CODEX_TEST_VERSION:-0.154.0}"; exit 0 ;;
  'features list') printf 'hooks stable true\n'; exit 0 ;;
  'queue --help') printf 'Usage: codex queue --thread <THREAD> --message <TEXT>\n'; exit 0 ;;
esac
[ "${QUEUE_FAIL:-0}" != 1 ] || exit 1
printf '%s\n' "$*" >> "$FM_HOME/queued"
SH
chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/.codex"
  git init -q "$home"
  cp -R "$ROOT/bin" "$home/bin"
  cp "$ROOT/.codex/hooks.json" "$home/.codex/hooks.json"
  : > "$home/AGENTS.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/probe.check.sh"
  chmod 0700 "$home/state/probe.check.sh"
  FM_HOME="$home" "$home/bin/fm-check-register.sh" probe >/dev/null || fail registration
  printf '%s\n' "$home"
}

test_registered_stop_keeps_watch_and_delivers() {
  local home rc=0
  home=$(make_home registered)
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999 \
    "$FAKEBIN/codex-harness" -c '
      cd "$FM_HOME" || exit 1
      printf "%s\n" "$$" > state/.lock
      payload='"'"'{"session_id":"test-session","turn_id":"test-turn","stop_hook_active":false}'"'"'
      hook=$(jq -r '"'"'.hooks.Stop[].hooks[] | select(.async == true) | .command'"'"' .codex/hooks.json)
      [ -n "$hook" ] || { echo "no automatic Codex Stop owner"; exit 1; }
      printf "%s\n" "$payload" | bash -c "$hook" >hook.out 2>hook.err &
      owner=$!
      trap '"'"'kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true'"'"' EXIT
      for _ in $(seq 1 100); do
        [ -f state/.watch.lock/pid ] && break
        sleep 0.1
      done
      guard=$(jq -r '"'"'.hooks.Stop[].hooks[] | select(.async != true) | .command'"'"' .codex/hooks.json)
      printf "%s\n" "$payload" | bash -c "$guard" || exit 1
      # A concurrent Stop must defer to the existing native callback owner.
      printf "%s\n" "$payload" | bash -c "$hook" || exit 1
      sleep 2
      kill -0 "$(cat state/.watch.lock/pid)" || exit 1
      printf "done: native stop regression\n" > state/demo.status
      for _ in $(seq 1 200); do
        [ -s queued ] && break
        sleep 0.1
      done
      [ -s queued ] || { cat hook.err; exit 1; }
      grep -q -- "--thread test-session" queued || exit 1
      grep -q "demo.status" state/.wake-queue || exit 1
      wait "$owner" || exit 1
      [ "$(wc -l < queued)" -eq 1 ] || exit 1
    ' > "$home/result" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "registered Stop did not supervise and deliver: $(cat "$home/result")"
  pass "registered Codex Stop keeps a quiet watcher alive and queues one durable wake"
}

test_inert_without_authority() {
  local home foreign_pid
  home=$(make_home foreign)
  "$FAKEBIN/codex-harness" -c 'sleep 60' &
  foreign_pid=$!
  printf '%s\n' "$foreign_pid" > "$home/state/.lock"
  printf '%s\n' '{"session_id":"test-session","turn_id":"foreign"}' \
    | FM_HOME="$home" "$home/bin/fm-codex-stop-autoarm.sh" || fail "foreign hook failed"
  assert_absent "$home/state/.codex-autoarm.json" "foreign session published a claim"
  assert_absent "$home/state/.watch.lock/pid" "foreign session armed the watcher"
  kill "$foreign_pid" 2>/dev/null || true
  wait "$foreign_pid" 2>/dev/null || true
  pass "a foreign session cannot arm or queue for this home"
}

test_failed_delivery_retains_wake() {
  local home rc=0
  home=$(make_home failed-delivery)
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'durable pending event\n' > "$FM_HOME/state/.wake-queue"
printf 'check: fixture wake\n'
SH
  FM_HOME="$home" QUEUE_FAIL=1 "$FAKEBIN/codex-harness" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" '"'"'{"session_id":"test-session","turn_id":"failed"}'"'"' \
      | "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
  ' > "$home/output" 2>&1 || rc=$?
  expect_code 1 "$rc" "queue failure"
  assert_contains "$(cat "$home/state/.wake-queue")" 'durable pending event' 'wake was lost'
  [ "$(jq -r .phase "$home/state/.codex-autoarm.json")" = failed ] || fail 'failure read as health'
  assert_absent "$home/queued" 'failed queue reported delivery'
  pass "failed native delivery preserves the durable wake and records failure"
}

test_queue_receipt_is_bound_and_expires() {
  local home rc=0
  home=$(make_home receipt)
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'check: receipt fixture\n'
SH
  FM_HOME="$home" "$FAKEBIN/codex-harness" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" '"'"'{"session_id":"test-session","turn_id":"origin"}'"'"' \
      | "$FM_HOME/bin/fm-codex-stop-autoarm.sh" || exit 1
    owner="$FM_HOME/bin/fm-codex-stop-autoarm.sh"
    "$owner" --ready test-session origin || exit 1
    "$owner" --handling || exit 1
    if "$owner" --ready foreign origin; then exit 1; fi
    if "$owner" --ready test-session next-turn; then exit 1; fi
    jq ".time = 0" "$FM_HOME/state/.codex-autoarm.json" > "$FM_HOME/expired"
    mv "$FM_HOME/expired" "$FM_HOME/state/.codex-autoarm.json"
    if "$owner" --ready test-session origin; then exit 1; fi
    if "$owner" --handling; then exit 1; fi
  ' || rc=$?
  expect_code 0 "$rc" 'receipt binding and expiry'
  pass "queued receipt is bound to the session and Stop turn, and both guard tolerances expire"
}

test_legacy_fallback_is_inert_and_keeps_guard() {
  local home rc=0
  home=$(make_home legacy)
  cp -R "$ROOT/docs" "$home/docs"
  FM_HOME="$home" CODEX_TEST_VERSION=0.153.0 FM_HARNESS=codex "$FAKEBIN/codex-harness" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    cd "$FM_HOME" || exit 1
    payload='"'"'{"session_id":"legacy","turn_id":"fallback","stop_hook_active":false}'"'"'
    printf "%s\n" "$payload" | bin/fm-codex-stop-autoarm.sh || exit 1
    [ ! -e state/.codex-autoarm.json ] || exit 1
    [ ! -e state/.watch.lock ] || exit 1
    [ ! -e queued ] || exit 1
    if bin/fm-codex-stop-autoarm.sh --ready legacy fallback; then exit 1; fi
    if bin/fm-codex-stop-autoarm.sh --handling; then exit 1; fi
    . bin/fm-wake-lib.sh
    [ "$(fm_supervision_model)" = persistent ] || exit 1
    status=0
    printf "%s\n" "$payload" | bin/fm-turnend-guard.sh --codex > guard.out 2>&1 || status=$?
    [ "$status" -eq 2 ] || { cat guard.out; exit 1; }
    grep -q fm-watch-checkpoint.sh guard.out || { cat guard.out; exit 1; }
    printf "%s\n" '"'"'{"stop_hook_active":true}'"'"' | bin/fm-turnend-guard.sh --codex || exit 1
  ' > "$home/result" 2>&1 || rc=$?
  expect_code 0 "$rc" "legacy callback/model/guard: $(cat "$home/result")"
  pass 'unsupported Codex keeps the checkpoint model and blocking repair guard, without native state or queue'
}

test_legacy_fallback_is_inert_and_keeps_guard
test_registered_stop_keeps_watch_and_delivers
test_inert_without_authority
test_failed_delivery_retains_wake
test_queue_receipt_is_bound_and_expires
