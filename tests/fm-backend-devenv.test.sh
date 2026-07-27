#!/usr/bin/env bash
# fm-backend-devenv.test.sh - fixed-argv SSH transport boundaries.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ADAPTER="$ROOT/bin/backends/devenv.sh"
TMP_ROOT=$(fm_test_tmproot fm-backend-devenv)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SSH_LOG="$TMP_ROOT/ssh"
COMMAND_LOG="$TMP_ROOT/external-command-argv"
REQUEST_ID=0123456789abcdef0123456789abcdef
# shellcheck disable=SC2088
REMOTE_HELPER='~/.local/share/firstmate-expanly/current/bin/fm-devenv-remote.sh'
BASE_PATH=$PATH
FM_TEST_REAL_HEAD=$(command -v head)
FM_TEST_REAL_JQ=$(command -v jq)
FM_TEST_REAL_MKTEMP=$(command -v mktemp)
FM_TEST_REAL_RM=$(command -v rm)
FM_TEST_REAL_TR=$(command -v tr)
FM_TEST_REAL_WC=$(command -v wc)
export FM_TEST_REAL_HEAD FM_TEST_REAL_JQ FM_TEST_REAL_MKTEMP FM_TEST_REAL_RM FM_TEST_REAL_TR FM_TEST_REAL_WC

# shellcheck source=bin/backends/devenv.sh
. "$ADAPTER"

mkdir -p "$SSH_LOG"
cat > "$FAKEBIN/fm-log-command" <<'SH'
#!/usr/bin/env bash
set -eu
name=${0##*/}
for arg in "$@"; do
  hex=$(printf '%s' "$arg" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n')
  printf '%s\t%s\n' "$name" "$hex" >> "$FM_TEST_COMMAND_LOG"
done
case "$name" in
  head) exec "$FM_TEST_REAL_HEAD" "$@" ;;
  jq) exec "$FM_TEST_REAL_JQ" "$@" ;;
  mktemp) exec "$FM_TEST_REAL_MKTEMP" "$@" ;;
  rm) exec "$FM_TEST_REAL_RM" "$@" ;;
  tr) exec "$FM_TEST_REAL_TR" "$@" ;;
  wc) exec "$FM_TEST_REAL_WC" "$@" ;;
  *) exit 127 ;;
esac
SH
for command in head jq mktemp rm tr wc; do
  ln -s fm-log-command "$FAKEBIN/$command"
done
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
set -eu
mkdir -p "$FM_TEST_SSH_LOG"
printf '%s\n' "$#" > "$FM_TEST_SSH_LOG/argc"
: > "$FM_TEST_SSH_LOG/argv"
for arg in "$@"; do
  hex=$(printf '%s' "$arg" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n')
  printf 'ssh\t%s\n' "$hex" >> "$FM_TEST_COMMAND_LOG"
  printf '%s\n' "$arg" >> "$FM_TEST_SSH_LOG/argv"
done
cat > "$FM_TEST_SSH_LOG/stdin"
request_id=$($FM_TEST_REAL_JQ -r '.request_id' "$FM_TEST_SSH_LOG/stdin")
if [ -n "${FM_TEST_SSH_RESPONSE:-}" ]; then
  printf '%s' "$FM_TEST_SSH_RESPONSE"
else
  "$FM_TEST_REAL_JQ" -cn --arg request_id "$request_id" '{schema:"firstmate.devenv.v1",request_id:$request_id,ok:true,result:{},error:null}'
fi
SH
chmod +x "$FAKEBIN/fm-log-command" "$FAKEBIN/ssh"

request_json() {
  jq -cn \
    --arg request_id "$REQUEST_ID" \
    --argjson payload "$1" \
    '{
      schema:"firstmate.devenv.v1",
      request_id:$request_id,
      operation:"inspect",
      environment:"reviews",
      vm:"expanly-reviews",
      lease:null,
      payload:$payload
    }'
}

call_adapter() {
  FM_TEST_COMMAND_LOG="$COMMAND_LOG" FM_TEST_SSH_LOG="$SSH_LOG" PATH="$FAKEBIN:$BASE_PATH" \
    fm_backend_devenv_request "$1" "$2"
}

hex_of() {
  printf '%s' "$1" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n'
}

test_fixed_remote_argv_and_stdin_only_payload() {
  local attack payload request response host_line command_line argv marker marker_hex
  # shellcheck disable=SC2016
  attack=$'quotes '\''"\n$() `backticks`; semicolon;\n--leading-dashes'
  payload=$(jq -cn --arg value "$attack" '{probe:$value}')
  request=$(request_json "$payload")
  : > "$COMMAND_LOG"

  response=$(call_adapter expanly-reviews "$request") \
    || fail "valid request did not cross the fake SSH transport"
  printf '%s\n' "$response" | jq -e '.ok == true' >/dev/null \
    || fail "adapter rejected the fake SSH response"

  [ "$(cat "$SSH_LOG/argc")" = 6 ] || fail "SSH argv did not contain exactly four options, host, and fixed helper"
  host_line=$(sed -n '5p' "$SSH_LOG/argv")
  command_line=$(sed -n '6p' "$SSH_LOG/argv")
  [ "$host_line" = expanly-reviews ] || fail "validated host was not the SSH destination"
  [ "$command_line" = "$REMOTE_HELPER" ] || fail "remote argv was not the one fixed helper path"
  argv=$(cat "$SSH_LOG/argv")
  assert_not_contains "$argv" "quotes" "payload text entered SSH argv"
  # shellcheck disable=SC2016
  assert_not_contains "$argv" '$()' "command substitution bytes entered SSH argv"
  # shellcheck disable=SC2016
  assert_not_contains "$argv" '`backticks`' "backtick bytes entered SSH argv"
  assert_not_contains "$argv" '--leading-dashes' "leading-dash payload entered SSH argv"
  [ "$(cat "$SSH_LOG/stdin")" = "$request" ] || fail "request bytes were not passed only through stdin"
  # shellcheck disable=SC2016
  assert_contains "$(cat "$SSH_LOG/stdin")" '$()' "adversarial payload was missing from stdin"
  # shellcheck disable=SC2016
  for marker in "quotes '\"" $'\n$()' '$()' '`backticks`' '; semicolon;' '--leading-dashes'; do
    marker_hex=$(hex_of "$marker")
    assert_no_grep "$marker_hex" "$COMMAND_LOG" \
      "adversarial payload bytes entered an external command argv: $marker"
  done
  pass "devenv backend: payload bytes stay byte-identical on stdin and out of every external command argv"
}

test_invalid_host_is_refused_before_ssh() {
  local request rc
  request=$(request_json '{}')
  rm -f "$SSH_LOG/argv"
  call_adapter $'expanly-reviews\nmalicious' "$request" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "invalid host was accepted"
  [ ! -e "$SSH_LOG/argv" ] || fail "invalid host reached SSH"
  pass "devenv backend: invalid hosts are rejected before SSH"
}

test_response_refusal_table() {
  local request response rc large
  request=$(request_json '{}')

  for response in \
    'not-json' \
    '{"schema":"firstmate.devenv.v1","request_id":"ffffffffffffffffffffffffffffffff","ok":true,"result":{},"error":null}' \
    '{"schema":"firstmate.devenv.v1","request_id":"0123456789abcdef0123456789abcdef","ok":true,"result":{},"error":null,"extra":true}'
  do
    FM_TEST_SSH_RESPONSE="$response" call_adapter expanly-reviews "$request" >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || fail "invalid response was accepted: $response"
  done

  large=$(jq -cn --arg request_id "$REQUEST_ID" --arg data "$(printf '%070000d' 0)" \
    '{schema:"firstmate.devenv.v1",request_id:$request_id,ok:true,result:{data:$data},error:null}')
  FM_TEST_SSH_RESPONSE="$large" call_adapter expanly-reviews "$request" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "oversized response was accepted"
  pass "devenv backend: non-JSON, mismatched, extra-field, and oversized responses are rejected"
}

test_fixed_remote_argv_and_stdin_only_payload
test_invalid_host_is_refused_before_ssh
test_response_refusal_table
