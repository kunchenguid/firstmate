#!/usr/bin/env bash
# Behavior tests for the opt-in ACPX worker lifecycle client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLIENT="$ROOT/bin/fm-acp-client.sh"
TMP_ROOT=$(fm_test_tmproot fm-acp-client)

make_fake_acpx() {  # <dir> -> fakebin
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/acpx" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_ACPX_VERSION:-0.13.2}"
  exit 0
fi
printf '%s\n' "$*" >> "$FM_ACPX_LOG"
if printf '%s\n' "$*" | grep -q ' status '; then
  printf '{"action":"status_snapshot","status":"%s"}\n' "${FM_FAKE_ACPX_STATUS:-idle}"
fi
SH
  chmod +x "$fakebin/acpx"
  printf '%s\n' "$fakebin"
}

run_client() {  # <fakebin> <log> <action> <harness> <worktree> <session> [payload] [model] [effort]
  PATH="$1:$PATH" FM_ACPX_LOG="$2" "$CLIENT" "${@:3}"
}

test_lifecycle_uses_poc_pins_and_one_named_session() {
  local dir fakebin log worktree got
  dir="$TMP_ROOT/lifecycle"; mkdir -p "$dir"
  fakebin=$(make_fake_acpx "$dir")
  log="$dir/acpx.log"; : > "$log"
  worktree="$dir/worktree"; mkdir -p "$worktree"
  printf 'brief\n' > "$dir/brief"
  printf 'steer\n' > "$dir/steer"

  run_client "$fakebin" "$log" ensure codex "$worktree" fm-acp-task >/dev/null
  run_client "$fakebin" "$log" run codex "$worktree" fm-acp-task "$dir/brief" gpt-5.6-sol high >/dev/null
  run_client "$fakebin" "$log" send codex "$worktree" fm-acp-task "$dir/steer" >/dev/null
  FM_FAKE_ACPX_STATUS=running run_client "$fakebin" "$log" status codex "$worktree" fm-acp-task > "$dir/status"
  run_client "$fakebin" "$log" cancel codex "$worktree" fm-acp-task >/dev/null

  got=$(cat "$log")
  assert_contains "$got" '@agentclientprotocol/codex-acp@1.10.0' "codex ACP adapter must be exact-pinned"
  assert_contains "$got" 'sessions ensure --name fm-acp-task' "ensure must use the stored session id"
  assert_contains "$got" '--ttl 0 prompt -s fm-acp-task --file' "run must keep a resumable queue owner"
  assert_contains "$got" 'prompt -s fm-acp-task --no-wait --file' "send must queue through the same session"
  assert_contains "$got" 'status -s fm-acp-task' "status must address the same session"
  assert_contains "$got" 'cancel -s fm-acp-task' "cancel must address the same session"
  assert_contains "$(cat "$dir/status")" '"status":"running"' "status must preserve ACPX JSON for consumers"
  pass "ACP client uses one pinned, named session for lifecycle operations"
}

test_rejects_unpinned_client_and_unsupported_harness() {
  local dir fakebin log worktree out rc
  dir="$TMP_ROOT/refusals"; mkdir -p "$dir"
  fakebin=$(make_fake_acpx "$dir")
  log="$dir/acpx.log"; : > "$log"
  worktree="$dir/worktree"; mkdir -p "$worktree"

  out=$(FM_FAKE_ACPX_VERSION=0.15.0 run_client "$fakebin" "$log" ensure codex "$worktree" fm-acp-task 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a newer unverified ACPX version should be refused"
  assert_contains "$out" 'requires acpx@0.13.2' "version refusal should name the required pin"
  out=$(run_client "$fakebin" "$log" ensure agy "$worktree" fm-acp-task 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported ACP harness should be refused"
  assert_contains "$out" 'supports only claude or codex' "harness refusal should be explicit"
  pass "ACP client fails closed outside the POC-supported surface"
}

test_lifecycle_uses_poc_pins_and_one_named_session
test_rejects_unpinned_client_and_unsupported_harness
