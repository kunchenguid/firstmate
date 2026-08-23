#!/usr/bin/env bash
# Behavior tests for the unarmed external, idle-aware /stow cadence lab.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB="$ROOT/bin/fm-stow-cadence-lab.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-cadence-lab)
SEND_LOG="$TMP_ROOT/send.log"
ORDER_LOG="$TMP_ROOT/order.log"

make_pair() {  # <name>
  local name=$1 sender target
  sender="$TMP_ROOT/$name-sender"
  target="$TMP_ROOT/$name-target"
  mkdir -p "$sender/state" "$sender/bin" "$target/state" "$target/data"
  mkdir -p "$target/bin"
  printf '%s\n' '# Primary fixture' > "$sender/AGENTS.md"
  git init -q "$sender"
  git -C "$sender" commit -q --allow-empty -m init
  printf '%s\n' '# Firstmate fixture' > "$target/AGENTS.md"
  printf '%s\n' "$name-target" > "$target/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$sender"
  } > "$target/.fm-secondmate-parent"
  printf '%s\n' '# Shared captain preferences' > "$target/data/captain-shared.md"
  chmod 0444 "$target/data/captain-shared.md"
  {
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$target"
  } > "$sender/state/$name-target.meta"
  printf '%s|%s\n' "$sender" "$target"
}

make_primary_pair() {  # <name>
  local name=$1 sender target
  target="$TMP_ROOT/$name-primary"
  sender="$TMP_ROOT/$name-secondmate"
  mkdir -p "$target/state" "$target/bin" "$sender/state" "$sender/bin"
  printf '%s\n' '# Primary fixture' > "$target/AGENTS.md"
  printf '%s\n' '# Secondmate fixture' > "$sender/AGENTS.md"
  git init -q "$target"
  git -C "$target" commit -q --allow-empty -m init
  printf '%s\n' "$name-secondmate" > "$sender/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$target"
  } > "$sender/.fm-secondmate-parent"
  {
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sender"
  } > "$target/state/$name-secondmate.meta"
  printf '%s|%s\n' "$sender" "$target"
}

make_fakes() {
  local fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/probe" <<'SH'
#!/usr/bin/env bash
if [ "${FM_STOW_FAKE_DEAD:-0}" = 1 ]; then exit 1; fi
exit 0
SH
  cat > "$fakebin/send" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --stow-submission-identity-capability ]; then
  [ "${FM_STOW_FAKE_IDENTITY_BOUND:-1}" = 1 ] && exit 0
  printf '%s\n' 'unsupported: no identity-bound submission lifecycle proof' >&2
  exit 3
fi
printf '%s\n' "$*" >> "$SEND_LOG"
if [ "${FM_STOW_FAKE_FAIL_AFTER_OBSERVED:-0}" = 1 ]; then
  due=$(find "$FM_STOW_FAKE_TARGET_HOME/state/stow-cadence/due" -type f -name '*.receipt' -print -quit 2>/dev/null || true)
  [ -n "$due" ] || exit 91
  harness=$(sed -n 's/^harness=//p' "$due")
  backend=$(sed -n 's/^backend=//p' "$due")
  target=$(sed -n 's/^target=//p' "$due")
  case "$harness" in
    claude) invocation='/stow' ;;
    codex) invocation='$stow' ;;
    pi|pi-signed) invocation='/skill:stow' ;;
  esac
  printf '%s\n' "$invocation" | FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity busy \
    --harness "$harness" --backend "$backend" --target "$target" --invocation-stdin >/dev/null
  printf '%s\n' 'error: permission refused after target accepted prompt' >&2
  exit 1
fi
if [ "${FM_STOW_FAKE_PERMISSION_REFUSAL:-0}" = 1 ]; then
  printf '%s\n' 'error: permission refused by target transport' >&2
  exit 1
fi
if [ "${FM_STOW_AUTO_COMPLETE:-0}" = 1 ] || [ "${FM_STOW_OBSERVE_ONLY:-0}" = 1 ]; then
  due=$(find "$FM_STOW_FAKE_TARGET_HOME/state/stow-cadence/due" -type f -name '*.receipt' -print -quit 2>/dev/null || true)
  [ -n "$due" ] || { printf '%s\n' 'send observed before due receipt' >&2; exit 91; }
  printf '%s\n' due-before-send >> "$ORDER_LOG"
  harness=$(sed -n 's/^harness=//p' "$due")
  backend=$(sed -n 's/^backend=//p' "$due")
  target=$(sed -n 's/^target=//p' "$due")
  case "$harness" in
    claude) invocation='/stow' ;;
    codex) invocation='$stow' ;;
    pi|pi-signed) invocation='/skill:stow' ;;
  esac
  if [ "${FM_STOW_FAKE_UNRELATED_ONLY:-0}" = 1 ]; then invocation='unrelated prompt'; fi
  if [ "${FM_STOW_FAKE_MANUAL_FIRST:-0}" = 1 ]; then
    printf '%s\n' "$invocation" | FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity busy \
      --harness "$harness" --backend "$backend" --target "$target" --invocation-stdin >/dev/null
    if FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" complete >/dev/null 2>&1; then
      printf '%s\n' manual-completed-before-send >> "$ORDER_LOG"
    fi
  fi
  printf '%s\n' "$invocation" | FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity busy \
    --harness "$harness" --backend "$backend" --target "$target" --invocation-stdin >/dev/null
  if [ "${FM_STOW_AUTO_COMPLETE:-0}" = 1 ]; then
    nohup "$FM_STOW_COMPLETER" "$due" "$harness" "$backend" "$target" "$invocation" \
      >/dev/null 2>&1 </dev/null &
  fi
fi
exit 0
SH
  cat > "$fakebin/complete" <<'SH'
#!/usr/bin/env bash
due=$1 harness=$2 backend=$3 target=$4 invocation=$5
for _ in $(seq 1 100); do
  [ "$(sed -n 's/^status=//p' "$due")" = started ] && break
  sleep 0.01
done
if [ "${FM_STOW_FAKE_ADVANCE:-0}" = 1 ]; then
  FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity busy \
    --harness "$harness" --backend "$backend" --target "$target" >/dev/null
fi
FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" complete >/dev/null
FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity idle \
  --harness "$harness" --backend "$backend" --target "$target" >/dev/null
printf '%s\n' success-after-send >> "$ORDER_LOG"
SH
  cat > "$fakebin/timeout-recheck" <<'SH'
#!/usr/bin/env bash
due=$(find "$FM_STOW_FAKE_TARGET_HOME/state/stow-cadence/due" -type f -name '*.receipt' -print -quit)
harness=$(sed -n 's/^harness=//p' "$due")
backend=$(sed -n 's/^backend=//p' "$due")
target=$(sed -n 's/^target=//p' "$due")
case "$harness" in
  claude) invocation='/stow' ;;
  codex) invocation='$stow' ;;
  pi|pi-signed) invocation='/skill:stow' ;;
esac
if [ "$(sed -n 's/^status=//p' "$due")" = sent ]; then
  printf '%s\n' "$invocation" | FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity busy \
    --harness "$harness" --backend "$backend" --target "$target" --invocation-stdin >/dev/null
fi
FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" complete >/dev/null
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "$1" = display-message ]; then printf '%s\n' 'lab:target'; exit 0; fi
exit 1
SH
  chmod +x "$fakebin/probe" "$fakebin/send" "$fakebin/complete" \
    "$fakebin/timeout-recheck" "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

FAKEBIN=$(make_fakes)

record_turn() {  # <target-home> <harness>
  FM_HOME=$1 "$LAB" activity busy --harness "$2" --backend tmux --target 'lab:target' >/dev/null
  FM_HOME=$1 "$LAB" activity idle --harness "$2" --backend tmux --target 'lab:target' >/dev/null
}

run_lab() {  # <sender-home> <target-home> <harness>
  local sender=$1 target=$2 harness=$3
  shift 3
  env FM_HOME="$sender" \
    FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$FAKEBIN/probe" \
    FM_STOW_FAKE_TARGET_HOME="$target" \
    FM_STOW_LAB="$LAB" FM_STOW_COMPLETER="$FAKEBIN/complete" \
    SEND_LOG="$SEND_LOG" ORDER_LOG="$ORDER_LOG" \
    "$@" \
    "$LAB" run --target-home "$target" --target 'lab:target' \
      --backend tmux --harness "$harness" --wait-seconds 3
}

test_sender_without_identity_capability_defers() {
  local pair sender target out rc=0
  pair=$(make_pair identity-capability); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_FAKE_IDENTITY_BOUND=0 2>&1) || rc=$?
  expect_code 3 "$rc" "a sender without identity-bound lifecycle proof must defer"
  assert_contains "$out" "unsupported" "the identity capability refusal must be explicit"
  [ ! -s "$SEND_LOG" ] || fail "an unsupported sender attempted a stow submission"
  if find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit 2>/dev/null | grep -q .; then
    fail "an unsupported sender published a cadence due receipt"
  fi
  pass "senders without identity-bound lifecycle proof fail closed"
}

test_endpoint_must_belong_to_authorized_home() {
  local pair sender target out rc=0
  pair=$(make_pair endpoint); sender=${pair%%|*}; target=${pair#*|}
  record_turn "$target" claude
  out=$(env FM_HOME="$sender" FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$FAKEBIN/probe" "$LAB" run \
    --target-home "$target" --target 'lab:unrelated' --backend tmux \
    --harness claude --wait-seconds 1 2>&1) || rc=$?
  expect_code 4 "$rc" "an unrelated endpoint must fail authorization"
  assert_contains "$out" "not bound" "endpoint refusal must explain the identity mismatch"
  pass "the target endpoint must be bound to the authorized home"
}

test_unvalidated_sender_is_refused() {
  local pair target rogue out rc=0
  pair=$(make_pair sender-validation); target=${pair#*|}
  rogue="$TMP_ROOT/rogue-sender"
  mkdir -p "$rogue/state" "$rogue/bin"
  printf '%s\n' '# Forged sender' > "$rogue/AGENTS.md"
  printf '%s\n' rogue > "$rogue/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$target"
  } > "$rogue/.fm-secondmate-parent"
  record_turn "$target" claude
  out=$(env FM_HOME="$rogue" FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$FAKEBIN/probe" "$LAB" run \
    --target-home "$target" --target 'lab:target' --backend tmux \
    --harness claude --wait-seconds 1 2>&1) || rc=$?
  expect_code 4 "$rc" "an unvalidated sender home must stop authorization"
  assert_contains "$out" "sender home is not a validated" "sender refusal must identify the invalid home"
  pass "forged secondmate markers cannot authorize an external sender"
}

test_unvalidated_target_is_refused() {
  local pair sender forged out rc=0
  pair=$(make_pair target-validation); sender=${pair%%|*}
  forged="$TMP_ROOT/forged-target"
  mkdir -p "$forged/state" "$forged/bin" "$forged/data"
  printf '%s\n' '# Forged target' > "$forged/AGENTS.md"
  printf '%s\n' forged > "$forged/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$sender"
  } > "$forged/.fm-secondmate-parent"
  FM_HOME="$forged" "$LAB" activity busy --harness claude \
    --backend tmux --target 'lab:target' >/dev/null
  FM_HOME="$forged" "$LAB" activity idle --harness claude \
    --backend tmux --target 'lab:target' >/dev/null
  out=$(env FM_HOME="$sender" FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$FAKEBIN/probe" "$LAB" run \
    --target-home "$forged" --target 'lab:target' --backend tmux \
    --harness claude --wait-seconds 1 2>&1) || rc=$?
  expect_code 4 "$rc" "an unvalidated target home must stop authorization"
  assert_contains "$out" "target home is not a validated" "target refusal must identify the invalid home"
  pass "forged secondmate targets cannot receive cadence injection"
}

test_concurrent_runs_send_once() {
  local pair sender target first second sends
  pair=$(make_pair concurrent); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  env FM_HOME="$sender" FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$FAKEBIN/probe" FM_STOW_FAKE_TARGET_HOME="$target" \
    FM_STOW_LAB="$LAB" SEND_LOG="$SEND_LOG" ORDER_LOG="$ORDER_LOG" \
    "$LAB" run --target-home "$target" --target 'lab:target' --backend tmux \
    --harness claude --wait-seconds 1 >"$TMP_ROOT/concurrent-1.out" 2>&1 & first=$!
  env FM_HOME="$sender" FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$FAKEBIN/probe" FM_STOW_FAKE_TARGET_HOME="$target" \
    FM_STOW_LAB="$LAB" SEND_LOG="$SEND_LOG" ORDER_LOG="$ORDER_LOG" \
    "$LAB" run --target-home "$target" --target 'lab:target' --backend tmux \
    --harness claude --wait-seconds 1 >"$TMP_ROOT/concurrent-2.out" 2>&1 & second=$!
  wait "$first" || true
  wait "$second" || true
  sends=$(wc -l < "$SEND_LOG")
  [ "$sends" -eq 1 ] || fail "concurrent scans sent $sends invocations instead of one"
  pass "concurrent scans atomically claim one activity generation"
}

test_endpoint_binding_is_rechecked_at_claim() {
  local pair sender target out rc=0 probe
  pair=$(make_pair endpoint-race); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  probe="$TMP_ROOT/endpoint-race-probe"
  cp "$FAKEBIN/probe" "$probe"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # shellcheck disable=SC2016 # Literal probe body; variables expand inside the generated script.
    printf '%s\n' 'FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity busy --harness claude --backend tmux --target lab:new >/dev/null'
    # shellcheck disable=SC2016 # Literal probe body; variables expand inside the generated script.
    printf '%s\n' 'FM_HOME="$FM_STOW_FAKE_TARGET_HOME" "$FM_STOW_LAB" activity idle --harness claude --backend tmux --target lab:new >/dev/null'
  } > "$probe"
  chmod +x "$probe"
  out=$(env FM_HOME="$sender" FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$probe" FM_STOW_FAKE_TARGET_HOME="$target" \
    FM_STOW_LAB="$LAB" SEND_LOG="$SEND_LOG" "$LAB" run --target-home "$target" \
    --target 'lab:target' --backend tmux --harness claude --wait-seconds 1 2>&1) || rc=$?
  expect_code 4 "$rc" "an endpoint change before claim must stop authorization"
  [ ! -s "$SEND_LOG" ] || fail "endpoint race reached the sender"
  pass "endpoint binding is revalidated under the activity claim lock"
}

test_completion_preserves_newer_activity() {
  local pair sender target out rc=0 latest
  pair=$(make_pair completion-race); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_AUTO_COMPLETE=1 FM_STOW_FAKE_ADVANCE=1 2>&1) || rc=$?
  expect_code 3 "$rc" "completion after newer activity must remain deferred"
  if find "$target/state/stow-cadence/success" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "completion consumed activity newer than its due generation"
  fi
  latest=$(sed -n 's/^seq=//p' "$target/state/stow-cadence/activity.receipt")
  [ "$latest" -gt 1 ] || fail "newer semantic activity was not preserved"
  pass "completion refuses to consume newer semantic activity"
}

test_semantic_busy_defers() {
  local pair sender target out rc=0
  pair=$(make_pair busy); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  FM_HOME="$target" "$LAB" activity busy --harness claude \
    --backend tmux --target 'lab:target' >/dev/null
  out=$(run_lab "$sender" "$target" claude 2>&1) || rc=$?
  expect_code 3 "$rc" "a semantically busy target must defer"
  assert_contains "$out" "deferred: busy" "busy deferral must be reported"
  [ ! -s "$SEND_LOG" ] || fail "busy deferral invoked the sender"
  if find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "busy deferral created a due receipt"
  fi
  find "$target/state/stow-cadence/failure" -type f -name '*busy*.receipt' -print -quit | grep -q . \
    || fail "busy deferral did not leave a per-home failure receipt"
  pass "stow cadence lab defers a semantically busy home without sending"
}

test_duplicate_suppression_and_success_ordering() {
  local pair sender target out rc=0 before
  pair=$(make_pair duplicate); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"; : > "$ORDER_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_AUTO_COMPLETE=1 2>&1) || rc=$?
  expect_code 0 "$rc" "the first eligible idle activity should stow successfully"
  assert_contains "$out" "success:" "the successful receipt must be reported"
  assert_contains "$(cat "$ORDER_LOG")" "due-before-send" "due receipt must precede invocation"
  for _ in $(seq 1 100); do
    grep -Fq success-after-send "$ORDER_LOG" && break
    sleep 0.01
  done
  assert_contains "$(cat "$ORDER_LOG")" "success-after-send" "success receipt must follow invocation"
  find "$target/state/stow-cadence/success" -type f -name '*.receipt' -print -quit | grep -q . \
    || fail "successful stow did not leave a success receipt"
  if find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "successful completion left or recreated a due receipt"
  fi
  before=$(wc -l < "$SEND_LOG")
  out=$(run_lab "$sender" "$target" claude 2>&1) || rc=$?
  expect_code 0 "$rc" "a duplicate scan should be a successful no-op"
  assert_contains "$out" "unchanged:" "duplicate suppression must be explicit"
  [ "$(wc -l < "$SEND_LOG")" -eq "$before" ] || fail "duplicate scan sent /stow again"
  pass "success receipt ordering is due-before-send-before-success and suppresses duplicates"
}

test_permission_refusal_is_durable() {
  local pair sender target out rc=0
  pair=$(make_pair permission); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_FAKE_PERMISSION_REFUSAL=1 2>&1) || rc=$?
  expect_code 3 "$rc" "permission refusal must defer"
  assert_contains "$out" "permission-refused" "permission refusal must be classified"
  find "$target/state/stow-cadence/failure" -type f -name '*permission-refused*.receipt' -print -quit | grep -q . \
    || fail "permission refusal did not leave a failure receipt"
  if find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "permission refusal left the activity generation wedged"
  fi
  rc=0
  out=$(run_lab "$sender" "$target" claude FM_STOW_AUTO_COMPLETE=1 2>&1) || rc=$?
  expect_code 0 "$rc" "a recovered sender must retry the failed activity generation"
  pass "sender permission refusal is durable and retryable after recovery"
}

test_send_failure_preserves_observed_start() {
  local pair sender target due out rc=0 sends
  pair=$(make_pair observed-failure); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_FAKE_FAIL_AFTER_OBSERVED=1 2>&1) || rc=$?
  expect_code 3 "$rc" "a transport failure after target acceptance must defer"
  due=$(find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit)
  [ -n "$due" ] || fail "transport failure discarded the observed lifecycle claim"
  [ "$(sed -n 's/^status=//p' "$due")" = failed-observed ] \
    || fail "transport failure did not preserve the unconfirmed observation"
  sends=$(wc -l < "$SEND_LOG")
  rc=0
  out=$(FM_HOME="$target" "$LAB" complete 2>&1) || rc=$?
  expect_code 1 "$rc" "an unacknowledged observation must not publish cadence success"
  if find "$target/state/stow-cadence/success" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "an unacknowledged manual stow produced cadence success"
  fi
  [ "$(wc -l < "$SEND_LOG")" -eq "$sends" ] || fail "reconciliation injected a duplicate stow"
  FM_HOME="$target" "$LAB" activity idle --harness claude \
    --backend tmux --target 'lab:target' >/dev/null
  record_turn "$target" claude
  rc=0
  out=$(run_lab "$sender" "$target" claude FM_STOW_AUTO_COMPLETE=1 2>&1) || rc=$?
  expect_code 0 "$rc" "a reconciled failure must not wedge newer activity"
  pass "failed transport rejects manual success without wedging the home"
}

test_receipt_timeout_is_retryable() {
  local pair sender target due out rc=0 sends
  pair=$(make_pair timeout); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude 2>&1) || rc=$?
  expect_code 3 "$rc" "an unobserved transport must time out without releasing its claim"
  due=$(find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit)
  [ "$(sed -n 's/^status=//p' "$due")" = sent ] || fail "acknowledged timeout lost its sent claim"
  sends=$(wc -l < "$SEND_LOG")
  rc=0
  out=$(run_lab "$sender" "$target" claude 2>&1) || rc=$?
  expect_code 3 "$rc" "an acknowledged timeout must suppress duplicate delivery"
  [ "$(wc -l < "$SEND_LOG")" -eq "$sends" ] || fail "acknowledged timeout resent the invocation"
  FM_STOW_FAKE_TARGET_HOME="$target" FM_STOW_LAB="$LAB" "$FAKEBIN/timeout-recheck"
  if find "$target/state/stow-cadence/success" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "a manual stow completed an acknowledged timed-out cadence claim"
  fi
  [ "$(sed -n 's/^status=//p' "$due")" = sent ] || fail "manual stow changed the acknowledged claim"
  pass "acknowledged timeouts suppress duplicate and manual stow claims"
}

test_timeout_rechecks_racing_success() {
  local pair sender target out rc=0
  pair=$(make_pair timeout-race); sender=${pair%%|*}; target=${pair#*|}
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_OBSERVE_ONLY=1 \
    FM_STOW_TIMEOUT_RECHECK_BIN="$FAKEBIN/timeout-recheck" 2>&1) || rc=$?
  expect_code 0 "$rc" "success published at the timeout boundary must win atomically"
  assert_contains "$out" "success:" "the timeout recheck must report durable success"
  FM_HOME="$target" "$LAB" activity idle --harness claude \
    --backend tmux --target 'lab:target' >/dev/null
  pass "timeout reconciliation rechecks racing durable success"
}

test_unrelated_prompt_cannot_start_due_receipt() {
  local pair sender target out rc=0
  pair=$(make_pair unrelated-prompt); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_AUTO_COMPLETE=1 \
    FM_STOW_FAKE_UNRELATED_ONLY=1 2>&1) || rc=$?
  expect_code 3 "$rc" "an unrelated prompt must not prove the cadence invocation started"
  if find "$target/state/stow-cadence/success" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "an unrelated prompt completed the cadence due receipt"
  fi
  pass "only the exact adapter invocation can start a due receipt"
}

test_manual_stow_before_transport_cannot_claim_receipt() {
  local pair sender target out rc=0
  pair=$(make_pair manual-first); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"; : > "$ORDER_LOG"
  record_turn "$target" claude
  out=$(run_lab "$sender" "$target" claude FM_STOW_AUTO_COMPLETE=1 \
    FM_STOW_FAKE_MANUAL_FIRST=1 2>&1) || rc=$?
  expect_code 3 "$rc" "activity preceding the transport-owned invocation must remain unstowed"
  if grep -Fq manual-completed-before-send "$ORDER_LOG"; then
    fail "a manual exact stow claimed the cadence receipt before transport acknowledgement"
  fi
  if find "$target/state/stow-cadence/success" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "a manual exact stow produced a cadence success receipt"
  fi
  pass "manual exact stow cannot claim a receipt before transport acknowledgement"
}

test_shared_memory_is_read_only() {
  local pair sender target before after due out rc=0
  pair=$(make_pair shared); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" pi
  before=$(sha256sum "$target/data/captain-shared.md")
  out=$(run_lab "$sender" "$target" pi FM_STOW_AUTO_COMPLETE=1 2>&1) || rc=$?
  expect_code 0 "$rc" "an unchanged inherited shared file should permit success"
  after=$(sha256sum "$target/data/captain-shared.md")
  [ "$before" = "$after" ] || fail "cadence changed captain-shared bytes"
  [ "$(stat -c %a "$target/data/captain-shared.md")" = 444 ] || fail "cadence changed captain-shared mode"

  record_turn "$target" pi
  run_lab "$sender" "$target" pi FM_STOW_OBSERVE_ONLY=1 >/dev/null 2>&1 || true
  due=$(find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit)
  chmod 0644 "$target/data/captain-shared.md"
  printf '%s\n' 'mutated locally' >> "$target/data/captain-shared.md"
  FM_HOME="$target" "$LAB" complete >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "completion accepted mutated primary-owned shared memory"
  [ -f "$due" ] || fail "shared-memory refusal discarded the due receipt"
  find "$target/state/stow-cadence/failure" -type f -name '*shared-memory*.receipt' -print -quit | grep -q . \
    || fail "shared-memory mutation did not leave a failure receipt"
  pass "secondmate captain-shared bytes and read-only mode are guarded at success"
}

test_dead_target_defers_before_send() {
  local pair sender target out rc=0
  pair=$(make_pair dead); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  record_turn "$target" codex
  out=$(run_lab "$sender" "$target" codex FM_STOW_FAKE_DEAD=1 2>&1) || rc=$?
  expect_code 3 "$rc" "a dead target must defer"
  assert_contains "$out" "deferred: dead" "target death must be reported"
  [ ! -s "$SEND_LOG" ] || fail "dead target invoked the sender"
  if find "$target/state/stow-cadence/due" -type f -name '*.receipt' -print -quit | grep -q .; then
    fail "dead target created a due receipt"
  fi
  find "$target/state/stow-cadence/failure" -type f -name '*dead*.receipt' -print -quit | grep -q . \
    || fail "target death did not leave a failure receipt"
  pass "dead targets defer before any invocation and leave a failure receipt"
}

test_adapter_invocations_and_unsupported_cursor() {
  local pair sender target harness expected out rc=0 before
  pair=$(make_pair adapters); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  for harness in claude codex pi pi-signed; do
    rc=0
    case "$harness" in
      claude) expected='/stow' ;;
      codex) expected=$(printf '%s' "\$stow") ;;
      pi|pi-signed) expected='/skill:stow' ;;
    esac
    record_turn "$target" "$harness"
    out=$(run_lab "$sender" "$target" "$harness" FM_STOW_AUTO_COMPLETE=1 2>&1) || rc=$?
    expect_code 0 "$rc" "$harness invocation should complete"
    [ "$(tail -1 "$SEND_LOG")" = "lab:target $expected" ] \
      || fail "$harness did not receive exactly its adapter-verified stow invocation"
    tail -1 "$SEND_LOG" | grep -F -- '/compact' >/dev/null \
      && fail "$harness received forbidden /compact" || true
  done
  record_turn "$target" cursor-agent
  before=$(wc -l < "$SEND_LOG")
  rc=0
  out=$(run_lab "$sender" "$target" cursor-agent 2>&1) || rc=$?
  expect_code 3 "$rc" "Cursor scheduling must remain unsupported"
  assert_contains "$out" "deferred: unsupported" "Cursor exclusion must be reported"
  [ "$(wc -l < "$SEND_LOG")" -eq "$before" ] || fail "Cursor exclusion still sent an invocation"
  pass "Claude, Codex, Pi, and Pi Signed use only verified stow commands while Cursor defers"
}

test_same_home_sender_is_refused() {
  local pair sender target out rc=0
  pair=$(make_pair self); sender=${pair%%|*}; target=${pair#*|}
  record_turn "$target" claude
  out=$(env FM_HOME="$target" FM_STOW_SEND_BIN="$FAKEBIN/send" \
    FM_STOW_TARGET_PROBE_BIN="$FAKEBIN/probe" "$LAB" run \
    --target-home "$target" --target 'lab:target' --backend tmux \
    --harness claude --wait-seconds 1 2>&1) || rc=$?
  expect_code 4 "$rc" "same-home self-injection must stop"
  assert_contains "$out" "separate sender cannot be authorized" "self-injection refusal must explain the boundary"
  pass "the lab refuses same-home self-injection without an authorized separate agent"
}

test_secondmate_can_authorize_parent_primary_target() {
  local pair sender target out rc=0
  pair=$(make_primary_pair reverse); sender=${pair%%|*}; target=${pair#*|}
  : > "$SEND_LOG"
  env FM_HOME="$target" TMUX_PANE='%7' PATH="$FAKEBIN:$PATH" \
    "$LAB" activity busy --harness codex >/dev/null
  env FM_HOME="$target" TMUX_PANE='%7' PATH="$FAKEBIN:$PATH" \
    "$LAB" activity idle --harness codex >/dev/null
  out=$(run_lab "$sender" "$target" codex FM_STOW_AUTO_COMPLETE=1 2>&1) || rc=$?
  expect_code 0 "$rc" "a validated secondmate should authorize its parent primary target"
  assert_contains "$out" "success:" "parent primary stow must produce a success receipt"
  [ "$(tail -1 "$SEND_LOG")" = "lab:target \$stow" ] \
    || fail "parent Codex primary did not receive exactly the verified invocation"
  pass "the same lab path covers a parent primary through its authorized secondmate"
}

test_semantic_busy_defers
test_sender_without_identity_capability_defers
test_duplicate_suppression_and_success_ordering
test_permission_refusal_is_durable
test_send_failure_preserves_observed_start
test_receipt_timeout_is_retryable
test_timeout_rechecks_racing_success
test_unrelated_prompt_cannot_start_due_receipt
test_manual_stow_before_transport_cannot_claim_receipt
test_shared_memory_is_read_only
test_dead_target_defers_before_send
test_adapter_invocations_and_unsupported_cursor
test_same_home_sender_is_refused
test_secondmate_can_authorize_parent_primary_target
test_endpoint_must_belong_to_authorized_home
test_unvalidated_sender_is_refused
test_unvalidated_target_is_refused
test_concurrent_runs_send_once
test_endpoint_binding_is_rechecked_at_claim
test_completion_preserves_newer_activity
