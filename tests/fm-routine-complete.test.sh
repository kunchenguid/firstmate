#!/usr/bin/env bash
# Behavioral coverage for routine completion after the verification gate.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTINE="$ROOT/bin/fm-routine-complete.sh"
TMP_ROOT=$(fm_test_tmproot fm-routine-complete)

test_verify_accepts_checks_green_with_pr() {
  local home id
  home="$TMP_ROOT/verify-home"
  id=sample-routine-ship
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "kind=ship" \
    "pr=https://github.com/example/sample/pull/1"
  printf 'done: PR https://github.com/example/sample/pull/1 checks green\n' \
    > "$home/state/$id.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROUTINE" verify "$id" >/dev/null || fail "verify rejected an eligible routine ship task"
  pass "verify accepts checks-green status with recorded PR metadata"
}

test_verify_rejects_open_status_decision() {
  local home id rc
  home="$TMP_ROOT/open-decision"
  id=sample-blocked-ship
  mkdir -p "$home/state"
  fm_write_meta "$home/state/$id.meta" \
    "kind=ship" \
    "pr=https://github.com/example/sample/pull/2"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=api-shape]: choose response format
done: PR https://github.com/example/sample/pull/2 checks green
EOF
  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROUTINE" verify "$id" >/dev/null 2>&1
  rc=$?
  set -u
  [ "$rc" -ne 0 ] || fail "verify accepted a task with an open keyed decision"
  pass "verify refuses routine completion while a keyed decision remains open"
}

test_verify_accepts_checks_green_with_pr
test_verify_rejects_open_status_decision

echo "all routine completion tests passed"
