#!/usr/bin/env bash
# Tests for the local, opt-in Moshi notification owner.
# The suite uses a fake curl transport and never contacts Moshi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-moshi-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-moshi-notify)

make_case() {
  local name=$1 dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/config" "$dir/home/state" "$dir/fakebin"
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
payload=
header_file=
key=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data-binary) payload=${2:-}; shift 2 ;;
    --header)
      case "${2:-}" in
        @*) header_file=${2#@} ;;
        Idempotency-Key:*) key=${2#Idempotency-Key: } ;;
        X-Idempotency-Key:*) key=${2#X-Idempotency-Key: } ;;
      esac
      shift 2
      ;;
    --output) shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${FM_MOSHI_TEST_PAYLOAD:-}" ]; then
  printf '%s' "$payload" > "$FM_MOSHI_TEST_PAYLOAD"
fi
if [ -n "${FM_MOSHI_TEST_HEADER_SEEN:-}" ] && [ -n "$header_file" ] &&
  grep -q '^Authorization: Bearer ' "$header_file"; then
  : > "$FM_MOSHI_TEST_HEADER_SEEN"
fi
if [ -n "${FM_MOSHI_TEST_KEY:-}" ] && [ -n "$key" ]; then
  printf '%s\n' "$key" > "$FM_MOSHI_TEST_KEY"
fi
if [ -n "${FM_MOSHI_TEST_CALLS:-}" ]; then
  printf 'call\n' >> "$FM_MOSHI_TEST_CALLS"
fi
exit "${FM_MOSHI_TEST_CURL_RC:-0}"
SH
  chmod +x "$dir/fakebin/curl"
  printf '%s\n' "$dir"
}

run_notify() {
  local dir=$1
  shift
  FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$PATH" \
    "$NOTIFY" "$@"
}

write_safe_token() {
  local dir=$1
  printf 'fixture-value\n' > "$dir/home/config/moshi-webhook-token"
  chmod 600 "$dir/home/config/moshi-webhook-token"
}

assert_no_call() {
  local dir=$1 label=$2
  [ ! -e "$dir/calls" ] || fail "$label: unsafe or absent token caused a webhook call"
}

test_token_file_safety() {
  local dir kind
  for kind in missing symlink directory readable fifo; do
    dir=$(make_case "token-$kind")
    case "$kind" in
      symlink)
        printf 'fixture-value\n' > "$dir/target"
        chmod 600 "$dir/target"
        ln -s "$dir/target" "$dir/home/config/moshi-webhook-token"
        ;;
      directory) mkdir "$dir/home/config/moshi-webhook-token" ;;
      readable)
        write_safe_token "$dir"
        chmod 644 "$dir/home/config/moshi-webhook-token"
        ;;
      fifo)
        mkfifo "$dir/home/config/moshi-webhook-token"
        ;;
    esac
    FM_MOSHI_TEST_CALLS="$dir/calls" run_notify "$dir" \
      pr-ready "safety-$kind" 'PR ready' 'safe test message' \
      || fail "token-$kind: notification helper returned failure"
    assert_no_call "$dir" "token-$kind"
  done
  pass 'unsafe and absent token files are silent no-ops'
}

test_payload_escaping_and_authentication() {
  local dir payload title message
  dir=$(make_case payload)
  write_safe_token "$dir"
  title='PR "ready" \\"escaped"'
  message=$'line one\nline "two" and \\tail'
  FM_MOSHI_TEST_PAYLOAD="$dir/payload.json" \
    FM_MOSHI_TEST_HEADER_SEEN="$dir/header-seen" \
    FM_MOSHI_TEST_KEY="$dir/idempotency-key" \
    run_notify "$dir" pr-ready payload-key "$title" "$message" \
    || fail 'payload: helper returned failure'
  payload=$(cat "$dir/payload.json")
  jq -e --arg title "$title" --arg message "$message" \
    '.title == $title and .message == $message' "$dir/payload.json" >/dev/null \
    || fail 'payload: title or message was not JSON-encoded exactly'
  [ -e "$dir/header-seen" ] || fail 'payload: authorization header was not supplied'
  [ -s "$dir/idempotency-key" ] || fail 'payload: idempotency key was not supplied'
  ! grep -qF 'fixture-value' "$dir/payload.json" \
    || fail 'payload: token appeared in the JSON payload'
  pass 'payload escaping and authorization keep the token out of JSON'
}

test_deduplication() {
  local dir calls
  dir=$(make_case deduplication)
  write_safe_token "$dir"
  FM_MOSHI_TEST_CALLS="$dir/calls" run_notify "$dir" \
    pr-merged same-event 'PR merged' 'same event' \
    || fail 'deduplication: first notification failed'
  FM_MOSHI_TEST_CALLS="$dir/calls" run_notify "$dir" \
    pr-merged same-event 'PR merged' 'same event' \
    || fail 'deduplication: repeated notification failed'
  calls=$(wc -l < "$dir/calls" | tr -d '[:space:]')
  [ "$calls" = 1 ] || fail "deduplication: expected one request, saw $calls"
  pass 'repeated lifecycle calls produce one request'
}

test_best_effort_failure() {
  local dir rc
  dir=$(make_case best-effort)
  write_safe_token "$dir"
  set +e
  FM_MOSHI_TEST_CURL_RC=22 FM_MOSHI_TEST_CALLS="$dir/calls" \
    run_notify "$dir" attention failed-request 'Firstmate blocker' 'transport is unavailable'
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail 'best-effort: transport failure escaped the helper'
  [ -s "$dir/calls" ] || fail 'best-effort: fake transport was not exercised'
  pass 'transport failures remain best-effort and non-fatal'
}

test_token_file_safety
test_payload_escaping_and_authentication
test_deduplication
test_best_effort_failure
printf 'all fm-moshi-notify tests passed\n'
