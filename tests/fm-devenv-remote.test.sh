#!/usr/bin/env bash
# fm-devenv-remote.test.sh - versioned remote helper protocol boundaries.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

REMOTE="$ROOT/bin/fm-devenv-remote.sh"
TMP_ROOT=$(fm_test_tmproot fm-devenv-remote)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/.local/state/firstmate-expanly/reviews"
MARKER="$STATE_DIR/lease.json"
CHECKOUT="$HOME_DIR/expanly-platform"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REQUEST_ID=0123456789abcdef0123456789abcdef
TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STALE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

mkdir -p "$STATE_DIR"
fm_git_init_commit "$CHECKOUT"
git -C "$CHECKOUT" checkout -qb fm/fm-example

cat > "$FAKEBIN/hostname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' expanly-reviews
SH
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "session list --json" ]; then
  printf '%s\n' '{"sessions":[{"name":"firstmate-expanly-reviews","running":true}]}'
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/hostname" "$FAKEBIN/herdr"

lease_json() {
  jq -cn \
    --arg token "$1" \
    '{
      schema:"firstmate.devenv.lease.v1",
      generation_token:$token,
      environment:"reviews",
      vm:"expanly-reviews",
      task_id:"fm-example",
      branch:"fm/fm-example",
      lease_state:"leased",
      issued_at:"2026-07-27T12:00:00Z"
    }'
}

request_json() {
  jq -cn \
    --arg request_id "$REQUEST_ID" \
    --arg operation "$1" \
    --argjson lease "$2" \
    --argjson payload "${3:-{}}" \
    '{
      schema:"firstmate.devenv.v1",
      request_id:$request_id,
      operation:$operation,
      environment:"reviews",
      vm:"expanly-reviews",
      lease:$lease,
      payload:$payload
    }'
}

run_remote() {
  HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$REMOTE"
}

assert_response_shape() {
  local response=$1 expected_ok=$2
  printf '%s\n' "$response" | jq -e \
    --arg request_id "$REQUEST_ID" \
    --argjson expected_ok "$expected_ok" '
      type == "object"
      and keys == ["error","ok","request_id","result","schema"]
      and .schema == "firstmate.devenv.v1"
      and .request_id == $request_id
      and .ok == $expected_ok
      and (
        if $expected_ok then
          (.result | type == "object") and .error == null
        else
          .result == null
          and (.error | type == "object")
          and (.error | keys == ["code","message"])
          and (.error.code | type == "string" and length > 0 and length <= 64)
          and (.error.message | type == "string" and length > 0 and length <= 160)
        end
      )' >/dev/null || fail "response did not match the exact protocol shape: $response"
}

assert_bounded_result() {
  local response=$1
  printf '%s\n' "$response" | jq -e '
    .result
    | keys == ["agent_present","git","herdr_session_present","lease","runtime_version"]
      and (.runtime_version == null or (.runtime_version | type == "string" and length <= 64))
      and (.lease == null or (
        (.lease | type == "object")
        and (.lease | keys == ["branch","environment","issued_at","lease_state","task_id","vm"])
      ))
      and (.git | type == "object" and keys == ["branch","clean"])
      and (.git.branch == null or (.git.branch | type == "string" and length <= 256))
      and (.git.clean == null or (.git.clean | type == "boolean"))
      and (.agent_present == null or (.agent_present | type == "boolean"))
      and (.herdr_session_present == null or (.herdr_session_present | type == "boolean"))' \
    >/dev/null || fail "result exposed an unbounded or unknown field: $response"
  case "$response" in
    *generation_token*|*credential*|*environment_variables*|*transcript*|*command_line*)
      fail "result exposed a forbidden sensitive field"
      ;;
  esac
}

test_operation_table() {
  local operation lease response
  rm -f "$MARKER"
  for operation in inspect claim status release; do
    case "$operation" in
      inspect) lease=null ;;
      claim) lease=$(lease_json "$TOKEN") ;;
      status|release) lease=$(jq -cn --arg token "$TOKEN" '{generation_token:$token}') ;;
    esac
    response=$(request_json "$operation" "$lease" | run_remote) \
      || fail "$operation did not return a structured response"
    assert_response_shape "$response" true
    assert_bounded_result "$response"
    printf '%s\n' "$response" | jq -e \
      '.result.herdr_session_present == true and .result.agent_present == true' >/dev/null \
      || fail "$operation did not report the dedicated Herdr session as known agent presence"
    case "$operation" in
      inspect) [ ! -e "$MARKER" ] || fail "inspect created a lease marker" ;;
      claim|status)
        [ -f "$MARKER" ] || fail "$operation did not preserve the lease marker"
        [ "$(jq -r '.generation_token' "$MARKER")" = "$TOKEN" ] \
          || fail "$operation changed the generation token"
        ;;
      release) [ ! -e "$MARKER" ] || fail "release left the lease marker" ;;
    esac
  done
  pass "devenv remote: inspect, claim, status, and release use one exact bounded response schema"
}

assert_refused() {
  local label=$1 request=$2 response rc
  response=$(printf '%s\n' "$request" | run_remote)
  rc=$?
  expect_code 0 "$rc" "$label structured refusal"
  assert_response_shape "$response" false
}

test_protocol_refusal_table() {
  local valid claim status before malformed overlong
  valid=$(request_json inspect null)
  claim=$(request_json claim "$(lease_json "$TOKEN")")
  status=$(request_json status "$(jq -cn --arg token "$TOKEN" '{generation_token:$token}')")

  assert_refused "unknown schema" "$(printf '%s' "$valid" | jq -c '.schema = "firstmate.devenv.v2"')"
  assert_refused "unknown operation" "$(printf '%s' "$valid" | jq -c '.operation = "execute"')"
  assert_refused "extra top-level field" "$(printf '%s' "$valid" | jq -c '.unexpected = true')"
  assert_refused "environment mismatch" "$(printf '%s' "$valid" | jq -c '.environment = "other"')"
  assert_refused "VM mismatch" "$(printf '%s' "$valid" | jq -c '.vm = "expanly-other"')"
  assert_refused "payload wrong type" "$(printf '%s' "$valid" | jq -c '.payload = "wrong"')"

  rm -f "$MARKER"
  printf '%s\n' "$claim" | run_remote >/dev/null || fail "refusal fixture claim failed"
  before=$(cat "$MARKER")
  assert_refused "missing token" "$(printf '%s' "$status" | jq -c '.lease = null')"
  assert_refused "stale token" "$(printf '%s' "$status" | jq -c --arg token "$STALE_TOKEN" '.lease.generation_token = $token')"
  [ "$(cat "$MARKER")" = "$before" ] || fail "a refused token request changed the lease marker"

  malformed=$before
  printf '{\n' > "$MARKER"
  assert_refused "malformed local marker" "$status"
  [ "$(cat "$MARKER")" = "{" ] || fail "malformed marker refusal changed local state"
  printf '%s\n' "$malformed" > "$MARKER"

  overlong=$(printf '%0300d' 0)
  printf '%s\n' "$malformed" | jq --arg task_id "$overlong" '.task_id = $task_id' > "$MARKER"
  assert_refused "unbounded local marker" "$valid"
  pass "devenv remote: malformed envelopes, identity mismatches, and invalid lease authority are refused"
}

test_operation_table
test_protocol_refusal_table
