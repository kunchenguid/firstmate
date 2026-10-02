#!/usr/bin/env bash
# tests/fm-sandbox-live.test.sh - live guard for the opt-in worker command
# sandbox against a real Anthropic sandbox-runtime (`srt`).
#
# Token-free and default-on: it runs wherever `srt` and `jq` are installed and
# skips otherwise, naming the absent tool. It proves the wrapper's fail-closed
# probe accepts a working runtime, and that a real sandboxed command is allowed
# inside its write allowlist and denied for a denied read and a denied write.
# It uses no real secrets or credentials.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_LIVE_SANDBOX srt jq

SANDBOX="$ROOT/bin/fm-sandbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-sandbox-live)

home="$TMP_ROOT/home"
secret="$TMP_ROOT/secret.txt"
denied_dir="$TMP_ROOT/denied"
allowed="$TMP_ROOT/allowed.txt"
mkdir -p "$home/config" "$denied_dir"
: > "$home/config/worker-sandbox"
printf 'fm-sandbox-live-secret\n' > "$secret"
printf '%s\n' \
  "{\"filesystem\":{\"denyRead\":[\"$secret\"],\"allowRead\":[],\"allowWrite\":[\"$TMP_ROOT\"],\"denyWrite\":[\"$denied_dir\"]},\"network\":{\"allowedDomains\":[],\"deniedDomains\":[]}}" \
  > "$home/config/worker-sandbox-settings.json"

out=$(FM_HOME="$home" "$SANDBOX" probe 2>&1) ||
  fail "the live sandbox probe must pass on this host: $out"
assert_contains "$out" "worker sandbox ready" "the live probe must report readiness"

FM_HOME="$home" "$SANDBOX" exec -- /bin/sh -c "printf ok > '$allowed'" ||
  fail "the live sandbox must permit a write inside its allowlist"
assert_present "$allowed" "the allowlisted write should have created its file"

if FM_HOME="$home" "$SANDBOX" exec -- /bin/sh -c "printf x > '$denied_dir/denied.txt'" >/dev/null 2>&1; then
  fail "the live sandbox must deny a write its settings deny even inside the allowlist"
fi
assert_absent "$denied_dir/denied.txt" "a denied write must not create its file"

out=$(FM_HOME="$home" "$SANDBOX" exec -- /bin/sh -c "cat '$secret'" 2>/dev/null) || true
assert_equals "" "$out" "the live sandbox must hide denied file contents"

pass "live worker sandbox: the real runtime permits an allowlisted write and denies a denied read and write"
