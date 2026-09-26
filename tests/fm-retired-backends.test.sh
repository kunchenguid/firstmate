#!/usr/bin/env bash
# Retired selections and historical identities never control a Herdr endpoint.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-retired-backends)
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/data" "$TMP_ROOT/home/config" "$TMP_ROOT/bin" "$TMP_ROOT/work"
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config"
export FM_DATA_OVERRIDE="$TMP_ROOT/home/data" FM_ENDPOINT_LOG="$TMP_ROOT/endpoints"
unset FM_ROOT_OVERRIDE FM_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_SESSION
for tool in herdr tmux cmux zellij orca treehouse; do
  cat > "$TMP_ROOT/bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$FM_ENDPOINT_LOG"
exit 97
EOF
  chmod +x "$TMP_ROOT/bin/$tool"
done
export PATH="$TMP_ROOT/bin:$PATH"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
[ "$(fm_backend_name)" = herdr ] || fail "new intake must default to Herdr"
fm_backend_validate_spawn herdr || fail "Herdr must remain accepted"
for backend in tmux cmux zellij orca unknown; do
  printf '%s\n' "$backend" > "$FM_CONFIG_OVERRIDE/backend"
  [ "$(fm_backend_name)" = "$backend" ] || fail "explicit configuration must not be coerced"
  fm_backend_validate_spawn "$backend" > "$TMP_ROOT/refusal" 2>&1 && fail "retired selection was accepted"
  FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "new-$backend" "$TMP_ROOT/work" --scout --harness pi > "$TMP_ROOT/refusal" 2>&1 && fail "retired new spawn accepted"
  assert_absent "$FM_STATE_OVERRIDE/new-$backend.meta" "refused spawn created metadata"
  fm_backend_capture "$backend" 'default:w1:p1' 1 > "$TMP_ROOT/refusal" 2>&1 && fail "retired capture reached a provider"
  fm_backend_send_key "$backend" 'default:w1:p1' Enter > "$TMP_ROOT/refusal" 2>&1 && fail "retired key reached a provider"
  fm_backend_kill "$backend" 'default:w1:p1' > "$TMP_ROOT/refusal" 2>&1 && fail "retired kill reached a provider"
done
assert_absent "$FM_ENDPOINT_LOG" "selection refusal must make zero endpoint calls"
pass "new Herdr intake and explicit retired/unknown refusal"
rm "$FM_CONFIG_OVERRIDE/backend"
for backend in absent tmux cmux zellij orca unknown; do
  id="old-$backend"
  meta="$FM_STATE_OVERRIDE/$id.meta"
  printf 'window=default:w1:p1\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=pi\nkind=scout\n' "$id" "$TMP_ROOT/work" "$TMP_ROOT/work" > "$meta"
  [ "$backend" = absent ] || printf 'backend=%s\n' "$backend" >> "$meta"
  printf 'historical evidence\n' > "$FM_STATE_OVERRIDE/$id.status"
  mkdir -p "$FM_DATA_OVERRIDE/$id"
  printf 'historical report\n' > "$FM_DATA_OVERRIDE/$id/report.md"
  cp "$meta" "$TMP_ROOT/snapshot"
  expected=$backend; [ "$backend" != absent ] || expected=tmux
  [ "$(fm_backend_of_meta "$meta")" = "$expected" ] || fail "historical identity changed"
  fm_backend_validate_task_endpoint "$meta" "$id" > "$TMP_ROOT/refusal" 2>&1 && fail "historical endpoint was accepted"
  state=$("$ROOT/bin/fm-crew-state.sh" "$id" 2>&1)
  assert_contains "$state" 'unsupported' "state must name unsupported historical identity: $state"
  for verb in interrupt exit relaunch; do
    "$ROOT/bin/fm-control.sh" "$id" "$verb" > "$TMP_ROOT/refusal" 2>&1 && fail "historical $verb was accepted"
  done
  "$ROOT/bin/fm-peek.sh" "$id" > "$TMP_ROOT/refusal" 2>&1 && fail "historical peek was accepted"
  PI_CODING_AGENT=true "$ROOT/bin/fm-teardown.sh" "$id" > "$TMP_ROOT/refusal" 2>&1 && fail "historical teardown was accepted"
  assert_absent "$FM_STATE_OVERRIDE/.fm-lease-command.lock" "refused teardown leaked the Pi supervision command lock"
  FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$TMP_ROOT/work" --scout --harness pi > "$TMP_ROOT/refusal" 2>&1 && fail "new intake overwrote historical identity"
  cmp "$meta" "$TMP_ROOT/snapshot" || fail "historical metadata mutated"
  assert_present "$FM_STATE_OVERRIDE/$id.status" "history disappeared"
  assert_present "$FM_DATA_OVERRIDE/$id/report.md" "report disappeared"
done
assert_absent "$FM_ENDPOINT_LOG" "historical operations must make zero endpoint calls"
pass "legacy backend-less and retired metadata survive state/peek/control/teardown"

for selector in 'firstmate:fm-unknown' 'default:old-pane'; do
  "$ROOT/bin/fm-peek.sh" "$selector" > "$TMP_ROOT/refusal" 2>&1 && fail "unrecorded legacy peek accepted"
  "$ROOT/bin/fm-send.sh" "$selector" example > "$TMP_ROOT/refusal" 2>&1 && fail "unrecorded legacy send accepted"
done
assert_absent "$FM_ENDPOINT_LOG" "legacy raw selectors must not start or query Herdr"
pass "unrecorded historical selectors refuse without provider calls"

# Changing only the terminal selector cannot transfer historical copy ownership.
meta="$FM_STATE_OVERRIDE/mixed-owner.meta"
printf 'backend=herdr\nwindow=fixture:w1:p1\nendpoint_task_id=mixed-owner\nworktree=%s\nproject=%s\nherdr_session=fixture\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nharness=pi\nkind=scout\n' "$TMP_ROOT/work" "$TMP_ROOT/work" > "$meta"
for ownership in orca_worktree_id=old-copy cleanup_recovery=orca; do
  cp "$meta" "$TMP_ROOT/mixed-base"
  printf '%s\n' "$ownership" >> "$meta"
  cp "$meta" "$TMP_ROOT/mixed-before"
  "$ROOT/bin/fm-teardown.sh" mixed-owner --force > "$TMP_ROOT/refusal" 2>&1 && fail "mixed provider ownership accepted"
  cmp "$meta" "$TMP_ROOT/mixed-before" || fail "mixed provider record changed"
  assert_present "$TMP_ROOT/work" "historical copy disappeared"
  assert_absent "$FM_ENDPOINT_LOG" "mixed ownership reached a provider"
  mv "$TMP_ROOT/mixed-base" "$meta"
done
pass "historical Orca ownership refuses even with a hand-edited Herdr selector"
