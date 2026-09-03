#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$grok_home"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  grok_home=$(cd "$grok_home" && pwd -P)
  GROK_HOME="$grok_home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" grok --mode no-mistakes --yolo off
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_fresh_abort_retires_provisional_wiring() {
  local rec case_dir home proj wt fakebin grok_home id out status=0 real_chmod auth_file
  rec=$(make_spawn_case fresh-abort-wiring)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  real_chmod=$(command -v chmod)
  {
    cat <<'SH'
#!/usr/bin/env bash
set -u
target=${!#}
case "$target" in
  *.meta.*) exit 1 ;;
esac
SH
    printf 'exec %q "$@"\n' "$real_chmod"
  } > "$fakebin/chmod"
  chmod +x "$fakebin/chmod"

  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "metadata publication failure unexpectedly spawned Grok"
  assert_absent "$home/state/$id.meta" "fresh abort retained provisional metadata"
  assert_absent "$home/state/$id.grok-turnend-token" "fresh abort retained Grok's token sidecar"
  assert_absent "$wt/.fm-grok-turnend" "fresh abort retained Grok's worktree pointer"
  auth_file=
  if [ -d "$grok_home/hooks/fm-turn-end.d" ]; then
    auth_file=$(find "$grok_home/hooks/fm-turn-end.d" -type f -name 'fm.*' -print -quit)
  fi
  [ -z "$auth_file" ] || fail "fresh abort retained Grok's global authorization: $auth_file"
  pass "grok fresh abort retires provisional harness wiring"
}

test_grok_crash_recovers_provisional_authorization() {
  local rec case_dir home proj wt fakebin grok_home id out status=0 real_chmod marker old_auth auth_count
  local endpoint endpoint_original endpoint_tmp receipt journal digest meta transaction dispatch launch_hash launch_path
  rec=$(make_spawn_case crash-wiring)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  real_chmod=$(command -v chmod)
  marker="$case_dir/killed-during-wiring"
  {
    cat <<SH
#!/usr/bin/env bash
set -u
target=\${!#}
case "\$target" in
  */hooks/fm-turn-end.sh)
    if [ ! -e "$marker" ]; then
      : > "$marker"
      kill -KILL "\$PPID"
      exit 0
    fi
    ;;
esac
SH
    printf 'exec %q "$@"\n' "$real_chmod"
  } > "$fakebin/chmod"
  chmod +x "$fakebin/chmod"

  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "interrupted provisional Grok wiring unexpectedly spawned"
  assert_present "$home/state/$id.harness-wiring-provisional.json" \
    "interrupted Grok wiring lost its durable receipt"
  old_auth=$(find "$grok_home/hooks/fm-turn-end.d" -type f -name 'fm.*' -print -quit)
  [ -n "$old_auth" ] || fail "interrupted Grok wiring did not reach authorization creation"
  endpoint="$home/state/$id.spawn-endpoint.json"
  receipt="$home/state/$id.harness-wiring-provisional.json"
  endpoint_original=$(cat "$endpoint")
  journal="$home/state/.$id.harness-wiring-provisional.json.no-clobber-journal"
  digest=$(shasum -a 256 "$receipt" | awk '{print $1}')
  printf 'v2\n%s\n%s\n%s\npublishing\n' \
    "$id.harness-wiring-provisional.json.publishing" \
    ".$id.harness-wiring-provisional.json.no-clobber-pin.0123456789abcdef" \
    "$digest" > "$journal"
  endpoint_tmp="$home/state/.$id.endpoint-invalid"
  printf '%s\n' "$endpoint_original" | jq -S -c '.endpoint.details.session = ""' > "$endpoint_tmp"
  mv "$endpoint_tmp" "$endpoint"
  status=0
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "semantically invalid endpoint details unexpectedly recovered"
  assert_present "$old_auth" "invalid endpoint details removed provisional authorization"
  assert_present "$receipt" "invalid endpoint details retired provisional receipt"
  assert_present "$journal" "invalid endpoint details mutated provisional publication recovery"

  printf '%s\n' "$endpoint_original" | jq -S -c --arg worktree "$case_dir" \
    '.worktree = $worktree' > "$endpoint_tmp"
  mv "$endpoint_tmp" "$endpoint"
  status=0
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "non-worktree endpoint binding unexpectedly recovered"
  assert_contains "$out" "recorded spawn worktree is invalid or cross-project" \
    "non-worktree endpoint refusal did not reach exact binding validation"
  assert_present "$old_auth" "invalid worktree binding removed provisional authorization"
  assert_present "$receipt" "invalid worktree binding retired provisional receipt"
  assert_present "$journal" "invalid worktree binding mutated provisional publication recovery"

  printf '%s\n' "$endpoint_original" > "$endpoint_tmp"
  mv "$endpoint_tmp" "$endpoint"
  meta="$home/state/$id.meta"
  dispatch="$home/data/$id/work-identity-dispatch.json"
  cp "$dispatch" "$case_dir/dispatch-before-unsafe-meta"
  transaction=$(jq -r '.transaction_id' "$receipt")
  launch_hash=$(jq -r '.instructions.sha256' "$dispatch")
  launch_path=$(jq -r '.instructions.path' "$dispatch")
  {
    printf 'work_identity_dispatch_transaction=%s\n' "$transaction"
    printf 'launch_brief=%s\n' "$launch_path"
    printf 'launch_brief_sha256=%s\n' "$launch_hash"
    printf 'work_identity_schema=fm-work-identity.v1\n'
    printf 'work_identity_status=unlinked\n'
  } > "$meta"
  status=0
  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_FAKE_TMUX_CURRENT_COMMAND=bash \
    run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "mismatched task metadata unexpectedly recovered provisional wiring"
  assert_contains "$out" "published task metadata is unsafe or mismatched" \
    "mismatched metadata was treated as absent"
  assert_present "$old_auth" "mismatched metadata removed provisional authorization"
  assert_present "$receipt" "mismatched metadata retired provisional receipt"
  assert_absent "$journal" "validated endpoint did not recover interrupted receipt publication"
  rm "$meta"
  cp "$case_dir/dispatch-before-unsafe-meta" "$dispatch"

  {
    cat <<'SH'
#!/usr/bin/env bash
set -u
target=${!#}
case "$target" in
  *.meta.*) exit 1 ;;
esac
SH
    printf 'exec %q "$@"\n' "$real_chmod"
  } > "$fakebin/chmod"
  chmod +x "$fakebin/chmod"
  status=0
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "missing interrupted Grok endpoint unexpectedly recovered"
  assert_contains "$out" "recorded spawn endpoint is not safely recoverable" \
    "missing endpoint recovery did not reach endpoint reconciliation"
  assert_absent "$old_auth" "missing endpoint recovery orphaned the interrupted authorization"
  assert_absent "$home/state/$id.harness-wiring-provisional.json" \
    "missing endpoint recovery retained its provisional wiring receipt"
  auth_count=$(find "$grok_home/hooks/fm-turn-end.d" -type f -name 'fm.*' | wc -l | tr -d ' ')
  [ "$auth_count" -eq 0 ] || fail "missing endpoint recovery retained $auth_count authorizations"
  pass "grok spawn recovers authorization before endpoint refusal"
}

test_grok_provisional_receipt_refuses_concurrent_record() {
  local rec case_dir home proj wt fakebin grok_home id out status=0 real_chmod receipt
  rec=$(make_spawn_case receipt-no-clobber)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  real_chmod=$(command -v chmod)
  receipt="$home/state/$id.harness-wiring-provisional.json"
  {
    cat <<SH
#!/usr/bin/env bash
set -u
target=\${!#}
case "\$target" in
  */.$id.harness-wiring-provisional.*)
    printf '%s\\n' competing-record > "$receipt"
    ;;
esac
SH
    printf 'exec %q "$@"\n' "$real_chmod"
  } > "$fakebin/chmod"
  chmod +x "$fakebin/chmod"

  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "concurrent provisional receipt was overwritten"
  [ "$(cat "$receipt")" = competing-record ] \
    || fail "provisional receipt publication clobbered a concurrent record"
  assert_contains "$out" "could not journal provisional grok wiring" \
    "concurrent provisional receipt was not refused"
  pass "grok provisional receipt publication is no-clobber"
}

test_grok_authorization_removal_is_inode_conditional() {
  local case_dir root auth expected fakebin real_python out status=0
  case_dir="$TMP_ROOT/auth-remove-race"
  mkdir -p "$case_dir"
  case_dir=$(cd "$case_dir" && pwd -P)
  root="$case_dir/grok/hooks/fm-turn-end.d"
  auth="$root/fm.0123456789ab"
  expected="$case_dir/state/task.turn-ended"
  fakebin="$case_dir/fakebin"
  real_python=$(command -v python3)
  mkdir -p "$root" "$fakebin"
  printf '%s\n' "$expected" > "$auth"
  cat > "$fakebin/python3" <<SH
#!/usr/bin/env bash
set -u
if [ "\${2:-}" = describe-digest ]; then
  "$real_python" "\$@" || exit \$?
  mv "$auth" "$auth.original"
  printf '%s\\n' competing-authorization > "$auth"
  exit 0
fi
exec "$real_python" "\$@"
SH
  chmod +x "$fakebin/python3"
  out=$(PATH="$fakebin:$PATH" bash -c \
    '. "$1"; fm_control_harness_turnend_auth_remove_exact grok "" "$2" "$3"' \
    _ "$ROOT/bin/fm-control-lib.sh" "$auth" "$expected" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "authorization replacement race unexpectedly removed a competing record"
  [ "$(cat "$auth")" = competing-authorization ] \
    || fail "conditional authorization removal changed the competing record"
  assert_present "$auth.original" "authorization race lost the originally validated inode"
  pass "grok authorization removal is conditional on exact inode"
}

test_grok_authorization_removal_rejects_wrong_size_before_digest() {
  local case_dir root auth expected out status=0
  case_dir="$TMP_ROOT/auth-remove-size"
  root="$case_dir/grok/hooks/fm-turn-end.d"
  auth="$root/fm.0123456789ab"
  expected="$case_dir/state/task.turn-ended"
  mkdir -p "$root"
  case_dir=$(cd "$case_dir" && pwd -P)
  root="$case_dir/grok/hooks/fm-turn-end.d"
  auth="$root/fm.0123456789ab"
  expected="$case_dir/state/task.turn-ended"
  printf '%s\nextra\n' "$expected" > "$auth"

  out=$(bash -c \
    '. "$1"; fm_control_harness_turnend_auth_remove_exact grok "" "$2" "$3"' \
    _ "$ROOT/bin/fm-control-lib.sh" "$auth" "$expected" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "oversized authorization was removed"
  assert_contains "$out" "owned destination size does not match expected size" \
    "oversized authorization was hashed instead of rejected by size"
  assert_present "$auth" "oversized authorization refusal removed the record"
  pass "grok authorization cleanup bounds digest input by exact size"
}

test_grok_recovery_refuses_changed_authorization() {
  local rec case_dir home proj wt fakebin grok_home id out status=0 real_chmod marker old_auth receipt
  rec=$(make_spawn_case changed-authorization)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  real_chmod=$(command -v chmod)
  marker="$case_dir/killed-during-wiring"
  {
    cat <<SH
#!/usr/bin/env bash
set -u
target=\${!#}
case "\$target" in
  */hooks/fm-turn-end.sh)
    if [ ! -e "$marker" ]; then
      : > "$marker"
      kill -KILL "\$PPID"
      exit 0
    fi
    ;;
esac
SH
    printf 'exec %q "$@"\n' "$real_chmod"
  } > "$fakebin/chmod"
  chmod +x "$fakebin/chmod"

  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "interrupted Grok authorization fixture unexpectedly spawned"
  receipt="$home/state/$id.harness-wiring-provisional.json"
  old_auth=$(find "$grok_home/hooks/fm-turn-end.d" -type f -name 'fm.*' -print -quit)
  [ -n "$old_auth" ] || fail "interrupted Grok wiring did not create authorization"
  printf '%s\n' competing-content > "$old_auth"

  status=0
  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_FAKE_TMUX_CURRENT_COMMAND=bash \
    run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "changed Grok authorization was accepted during recovery"
  [ "$(cat "$old_auth")" = competing-content ] \
    || fail "recovery removed or changed a non-owned authorization"
  assert_present "$receipt" "recovery retired the receipt for a changed authorization"
  assert_contains "$out" "provisional harness authorization is unsafe or mismatched" \
    "changed authorization recovery was not refused"
  pass "grok recovery preserves changed authorization records"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  rm "$home/state/$id.grok-turnend-token"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown resumes after token-sidecar removal"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

case "${FM_TEST_ONLY:-}" in
  provisional-wiring-crash)
    test_grok_crash_recovers_provisional_authorization
    test_grok_provisional_receipt_refuses_concurrent_record
    test_grok_recovery_refuses_changed_authorization
    test_grok_authorization_removal_is_inode_conditional
    test_grok_authorization_removal_rejects_wrong_size_before_digest
    exit 0
    ;;
  wiring-cleanup-recovery)
    test_grok_fresh_abort_retires_provisional_wiring
    test_grok_crash_recovers_provisional_authorization
    test_grok_provisional_receipt_refuses_concurrent_record
    test_grok_recovery_refuses_changed_authorization
    test_grok_authorization_removal_is_inode_conditional
    test_grok_authorization_removal_rejects_wrong_size_before_digest
    test_grok_teardown_removes_pointer_and_token
    exit 0
    ;;
esac

test_grok_hook_requires_registered_token
test_grok_fresh_abort_retires_provisional_wiring
test_grok_crash_recovers_provisional_authorization
test_grok_provisional_receipt_refuses_concurrent_record
test_grok_recovery_refuses_changed_authorization
test_grok_authorization_removal_is_inode_conditional
test_grok_authorization_removal_rejects_wrong_size_before_digest
test_grok_teardown_removes_pointer_and_token
test_fm_lock_recognizes_grok_holder
