#!/usr/bin/env bash
# Behavior tests for fm-provider-reach-probe.sh - the one hard-bounded,
# non-destructive reachability probe of a named provider endpoint.
#
# Two defects this suite pins:
#
# 1. Upstream outage was previously visible only by reading worker panes, so
#    "the endpoint is down" was never a machine-readable finding at an intake.
#    The three outage shapes the fleet actually recorded must each land on their
#    own exit status and wording: no address at all (HTTP 000 / NXDOMAIN), a
#    request that reached the endpoint and was refused (401/403), and an endpoint
#    that answered successfully (2xx). The last two must never be conflated,
#    because a refusal proves routing while proving nothing about usability, and a
#    2xx is recorded as reachable rather than as proof a model or credential works.
#
# 2. A probe must not smuggle in routing knowledge or become a service. Every
#    assertion below runs against local stand-ins only - a fake curl and a fake
#    resolver on PATH - so no third-party endpoint is ever contacted to justify an
#    expected value, and the fake curl records every URL it was handed so
#    "unauthenticated, exactly one request, bounded" are observable facts.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-provider-reach-probe.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-provider-reach-probe-tests)

# A sentinel token the probe must never carry anywhere.
SENTINEL_KEY='SENTINEL-SECRET-MUST-NEVER-APPEAR'

# --- stand-in toolchain -----------------------------------------------------
#
# Fake curl: prints FM_FAKE_CURL_CODE as the HTTP code and logs each call's argv.
# It never opens a socket, so a suite regression cannot turn into real traffic.
# The stand-ins go in <dir> itself and <dir> is prepended to PATH, because
# /usr/bin/curl would otherwise shadow a fakebin subdirectory of the same case.
make_standins() {
  local dir=$1 fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=''
out=/dev/null
printf '%s\n' "$*" >> "${FM_FAKE_CURL_LOG:-/dev/null}"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$*" >> "${FM_FAKE_CURL_LOG:-/dev/null}"
printf '%s\n' "$url" >> "${FM_FAKE_CURL_URL_LOG:-/dev/null}"
# A probe that authenticated would hand the credential on argv or in a header
# file; record both surfaces so the safety claim is checkable.
if [ -n "${FM_FAKE_CURL_SEEN_SECRET:-}" ]; then
  printf 'secret-seen\n' >> "${FM_FAKE_CURL_LOG:-/dev/null}"
fi
case "${FM_FAKE_CURL_MODE:-code}" in
  crash) printf '000\n'; exit 7 ;;
  hang) sleep 30; printf '200\n'; exit 0 ;;
  *) printf '%s\n' "${FM_FAKE_CURL_CODE:-200}" ;;
esac
SH
  chmod +x "$fakebin/curl"

  # Fake resolver: rcode/name output shape driven by env, like the real dig.
  make_fake_dig "$fakebin"

  # Stand-in for a tool that takes the bare authority but is not a name lookup at
  # all. macOS ships /usr/bin/dscacheutil and calls it as `-q host -a <name>`; `host`
  # is not one of its directory-service categories, so it answers EVERY name with its
  # usage block and exit 64. That mis-shaped answer is what an accidentally listed
  # non-lookup tool looks like, so the probe's default path is asserted against this
  # stand-in rather than against live traffic or the host's real binary.
  cat > "$fakebin/dscacheutil" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_DIG_LOG:-/dev/null}"
printf 'Usage: dscacheutil -cachedelete | -flushcache | -L | -q name | -m | [-n network] | -x uid/gid | [ -i | -o ] attribute...\n' >&2
exit 64
SH
  chmod +x "$fakebin/dscacheutil"

  # jq and quota-axi are present so a regression that reintroduced either
  # dependency would be exercised rather than silently satisfied.
  for tool in jq quota-axi; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf 'called: $tool\n' >> "\${FM_FAKE_TOOL_LOG:-/dev/null}"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# make_fake_dig <dir> [argv-log]: the address-answering resolver stand-in. It
# records its own argv so an assertion can prove which candidate actually ran.
make_fake_dig() {
  local dir=$1 log=${2-${FM_FAKE_DIG_LOG:-/dev/null}}
  cat > "$dir/dig" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\${FM_FAKE_DIG_MODE:-address}" in
  nxdomain) printf 'status: NXDOMAIN\nno answer\n' ; exit 0 ;;
  empty) printf ';; no addresses\n'; exit 0 ;;
  servfail) printf 'status: SERVFAIL\n'; exit 0 ;;
  timestamp) printf '2026-10-04T12:34:56Z\n'; exit 0 ;;
  ipv6) printf '2001:db8::1\n'; exit 0 ;;
  fail) printf 'connection failed\n'; exit 9 ;;
  hang) sleep 30; printf 'ok\n'; exit 0 ;;
  *) printf '1.2.3.4\n'; exit 0 ;;
esac
SH
  chmod +x "$dir/dig"
}

# run_probe <dir> <args...>: probe with the stand-ins armed and DNS pinned to the
# fake dig, so the resolution phase is deterministic on every host.
run_probe() {
  local dir=$1; shift
  PATH="$dir:$BASE_PATH" \
    FM_PROVIDER_REACH_DNS_TOOL=dig \
    FM_FAKE_CURL_URL_LOG="$dir/urls.log" \
    FM_FAKE_CURL_LOG="$dir/calls.log" \
    FM_FAKE_DIG_LOG="$dir/dig.log" \
    FM_FAKE_TOOL_LOG="$dir/tools.log" \
    "$SCRIPT" "$@"
}

new_case() {
  local dir=$1
  mkdir -p "$dir"
  make_standins "$dir"
  : > "$dir/urls.log"; : > "$dir/calls.log"; : > "$dir/dig.log"; : > "$dir/tools.log"
}

# --- the probe exists and documents its contract ----------------------------
[ -x "$SCRIPT" ] || fail "bin/fm-provider-reach-probe.sh is missing or not executable"

out=$("$SCRIPT" --help 2>&1); rc=$?
expect_code 0 "$rc" "help exits 0"
assert_contains "$out" "routed-auth" "help names the 401/403 verdict"
assert_contains "$out" "unreachable" "help names the unreachable verdict"
assert_contains "$out" "renders no verdict" "help states the probe holds no routing judgment"

# --- HTTP 200: routable and answering, and nothing more ---------------------
tmp=$TMP_ROOT/ok; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  FM_FAKE_TOOL_LOG="$tmp/tools.log" "$SCRIPT" xhy 2>&1); rc=$?
expect_code 0 "$rc" "http 200 probes as reachable (exit 0)"
assert_contains "$out" "result=reachable" "http 200 wording is reachable"
assert_contains "$out" "http=200" "http 200 line carries the code"
assert_contains "$out" "dns=ok" "a resolved name reports dns=ok"
assert_not_contains "$out" "available" "a 2xx is never worded as channel-available"
assert_not_contains "$out" "eligible" "the probe renders no dispatch eligibility"

# --- HTTP 401 / 403: routing proven, usability NOT proven -------------------
for code in 401 403; do
  tmp=$TMP_ROOT/auth-$code; new_case "$tmp"
  out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=$code FM_FAKE_DIG_MODE=address \
    FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
    "$SCRIPT" --host api.example.invalid 2>&1); rc=$?
  expect_code 10 "$rc" "http $code exits 10"
  assert_contains "$out" "result=routed-auth" "http $code wording is routed-auth"
  assert_contains "$out" "http=$code" "http $code line carries the code"
  assert_contains "$out" "dns=ok" "http $code still reports a resolved name"
done

# --- HTTP 000: cannot connect ------------------------------------------------
tmp=$TMP_ROOT/zero; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=000 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "http 000 exits 20"
assert_contains "$out" "result=unreachable" "http 000 wording is unreachable"
assert_contains "$out" "reason=no_connection" "http 000 names the connection failure"
assert_not_contains "$out" "routed-auth" "a dead connection is never reported as reachable routing"

# --- HTTP 5xx: answered but unhealthy ---------------------------------------
tmp=$TMP_ROOT/server; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=502 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig "$SCRIPT" xhy 2>&1); rc=$?
expect_code 11 "$rc" "http 502 exits 11"
assert_contains "$out" "result=server-error" "http 502 wording is server-error"

# --- NXDOMAIN: no address, so the request phase is skipped ------------------
tmp=$TMP_ROOT/nxdomain; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=nxdomain FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "NXDOMAIN exits 20"
assert_contains "$out" "dns=nxdomain" "NXDOMAIN is reported as its own finding"
assert_contains "$out" "result=unreachable" "NXDOMAIN wording is unreachable"
assert_contains "$out" "http=none" "NXDOMAIN requests nothing over HTTP"
[ ! -s "$tmp/urls.log" ] || fail "NXDOMAIN path still issued an HTTP request: $(cat "$tmp/urls.log")"

# --- a resolvable name with no address is the same finding ------------------
tmp=$TMP_ROOT/empty-answer; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=empty FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "an addressless answer exits 20"
assert_contains "$out" "dns=nxdomain" "an addressless answer is the no-address class"

# --- a failing resolver is a lookup failure, never a success claim ----------
tmp=$TMP_ROOT/dns-fail; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=fail FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_URL_LOG="$tmp/urls.log" "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "a failed lookup exits 20"
assert_contains "$out" "dns=fail" "a failed lookup is its own dns class"
assert_contains "$out" "result=unreachable" "a failed lookup wording is unreachable"

# --- resolver errors and successful no-address answers are distinct ----------
tmp=$TMP_ROOT/dns-servfail; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=servfail FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "SERVFAIL exits 20"
assert_contains "$out" "dns=fail" "SERVFAIL is a resolver error"

tmp=$TMP_ROOT/timestamp-not-address; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=timestamp FM_PROVIDER_REACH_DNS_TOOL=dig \
  "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "timestamp-only answer exits 20"
assert_contains "$out" "dns=nxdomain" "timestamp digits are not classified as an IP address"

tmp=$TMP_ROOT/ipv6-address; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=ipv6 FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_FAKE_CURL_CODE=200 "$SCRIPT" xhy 2>&1); rc=$?
expect_code 0 "$rc" "IPv6 address answer proceeds to HTTP"
assert_contains "$out" "dns=ok" "an IPv6 address record is recognized"

# --- the default resolver path never mistakes a non-lookup tool's usage block
# --- for a name answer --------------------------------
# macOS ships /usr/bin/dscacheutil, which this probe must not call: `-q host` is not
# one of its categories, so it answers every name with its usage block and exit 64.
# A build that led its candidate list with it recorded "the resolver errored"
# (dns=fail dns_detail=rc=64) for names dig and host both report as NXDOMAIN. The
# guard below is behavioral: it runs the DEFAULT resolution path - no resolver
# override at all - against an isolated stand-in of that exact shape, so it proves
# what the probe reports rather than what its source text happens to contain.
usage_dir=$TMP_ROOT/usage-only-resolver
mkdir -p "$usage_dir"
cat > "$usage_dir/dscacheutil" <<'SH'
#!/usr/bin/env bash
printf 'Usage: dscacheutil -cachedelete | -flushcache | -L | -q name | -m\n' >&2
exit 64
SH
chmod +x "$usage_dir/dscacheutil"
: > "$usage_dir/noise.log"
# `host` is named after the directory-service category dscacheutil was once called
# with, so if a future default list ever leads with that call shape the stand-in
# captures it verbatim and the last assertion below fails loudly instead of quietly.
out=$(PATH="$usage_dir:$BASE_PATH" env -u FM_PROVIDER_REACH_DNS_TOOL \
  FM_FAKE_CURL_URL_LOG="$usage_dir/noise.log" FM_FAKE_DIG_LOG="$usage_dir/noise.log" \
  "$SCRIPT" --host api.example.invalid 2>&1); rc=$?
assert_not_contains "$out" "dns=fail" "the default resolver path never reports the usage block as a failed lookup"
assert_not_contains "$out" "rc=64" "a usage-block exit 64 from a non-lookup tool is never surfaced as a resolver status"
assert_not_contains "$out" "Usage:" "the probe line never carries a tool's usage text"
case $out in
  *dns=ok*|*dns=nxdomain*|*dns=skipped*) : ;;
  *) fail "the default resolver path reported an undeclared dns class: $out" ;;
esac
assert_not_contains "$out" "http=200" "this case resolves nothing real, so no verdict may come from an HTTP answer"
if [ -s "$usage_dir/noise.log" ]; then
  fail "the default resolver list calls a tool it cannot pass correctly: $(cat "$usage_dir/noise.log")"
fi
if [ -x /usr/bin/dscacheutil ]; then
  # First-hand proof of why it is excluded: the call this probe used answers usage.
  ds_out=$(/usr/bin/dscacheutil -q host -a api.example.invalid 2>&1); ds_rc=$?
  assert_contains "$ds_out" "Usage:" "dscacheutil rejects the category this probe passed"
  [ "$ds_rc" -ne 0 ] || fail "dscacheutil returned success where it was expected to error"
fi

# --- a preference list tries every entry until one is installed -------------
# The configured value is one tool OR a whitespace-separated list, so availability
# is decided per entry. A build that tested the whole string as a single executable
# skipped the resolver that was actually on PATH and reported `dns=skipped`
# `dns_tool_missing=dig host` for a name that resolves through dig.
later_dir=$TMP_ROOT/list-second-entry; new_case "$later_dir"
mkdir -p "$later_dir/onlydig"
make_fake_dig "$later_dir/onlydig" "$later_dir/pref.log"
: > "$later_dir/pref.log"
out=$(PATH="$later_dir/onlydig:$later_dir:$BASE_PATH" FM_FAKE_CURL_CODE=200 \
  FM_PROVIDER_REACH_DNS_TOOL='nosuchresolver dig' \
  FM_FAKE_CURL_URL_LOG="$later_dir/urls.log" "$SCRIPT" xhy 2>&1); rc=$?
expect_code 0 "$rc" "a usable later entry in the list still gets its HTTP phase"
assert_contains "$out" "dns=ok" "an installed entry further down the list is tried, not skipped"
assert_contains "$out" "dns_detail=1.2.3.4" "the tried entry's own answer is reported"
assert_not_contains "$out" "dns_tool_missing" "a partially usable list is never disclosed as a missing resolver"
assert_not_contains "$out" "dns=fail" "an absent earlier entry is skipped, not reported as a lookup failure"
[ "$(grep -c . "$later_dir/pref.log")" = 1 ] || fail "expected exactly one resolver call, got: $(cat "$later_dir/pref.log")"
assert_contains "$(cat "$later_dir/pref.log")" "api.xhyapi.com" "the tried resolver was handed the probed authority"

# --- every entry missing is disclosed as a skipped lookup -------------------
# The same preference-list semantics, from the other end: when no listed entry is
# installed, nothing was looked up, and that stays a disclosure rather than becoming
# an outage claim. The probe must still complete its HTTP phase.
tmp=$TMP_ROOT/no-dns-tool; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_PROVIDER_REACH_DNS_TOOL=no-such-resolver \
  "$SCRIPT" xhy 2>&1); rc=$?
expect_code 0 "$rc" "a missing resolver does not block the HTTP phase"
assert_contains "$out" "dns=skipped" "a missing resolver reports dns=skipped"
assert_contains "$out" "dns_tool_missing" "a missing resolver is disclosed in the line"
assert_not_contains "$out" "dns_tool_missing=no-such-resolver" "the disclosure names no usable resolver without echoing the list back"
if [ -s "$tmp/urls.log" ]; then
  fail "a missing resolver skipped the HTTP phase instead of reporting its verdict: $(cat "$tmp/urls.log")"
fi

# --- the bound is real, on both phases --------------------------------------
tmp=$TMP_ROOT/hang-http; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_MODE=hang FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_PROVIDER_REACH_PROBE_TIMEOUT=1 "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "a hanging endpoint is bounded to unreachable"
assert_contains "$out" "result=unreachable" "a hanging endpoint wording is unreachable"

tmp=$TMP_ROOT/hang-dns; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_DIG_MODE=hang FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_PROVIDER_REACH_PROBE_TIMEOUT=1 "$SCRIPT" xhy 2>&1); rc=$?
expect_code 20 "$rc" "a hanging resolver is bounded"
assert_contains "$out" "dns=fail" "a hanging resolver reports a lookup failure"

# --- unauthenticated, single request, no credential surface -----------------
tmp=$TMP_ROOT/unauth; new_case "$tmp"
PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  FM_FAKE_CURL_LOG="$tmp/calls.log" FM_FAKE_TOOL_LOG="$tmp/tools.log" \
  API_KEY="$SENTINEL_KEY" TYPESAFE_API_KEY="$SENTINEL_KEY" \
  "$SCRIPT" xhy >/dev/null 2>&1 || true
urls=$(cat "$tmp/urls.log")
assert_contains "$urls" "https://api.xhyapi.com/v1/models" "the registered target probes its recorded base URL"
[ "$(printf '%s\n' "$urls" | grep -c .)" = 1 ] || fail "expected exactly one HTTP request, got: $urls"
calls=$(cat "$tmp/calls.log")
assert_contains "$calls" "-q" "curl receives -q to ignore user curl configuration"
assert_not_contains "$calls" "-H" "the probe sends no auth header"
assert_not_contains "$calls" "Authorization" "the probe sends no Authorization header"
assert_not_contains "$calls" "$SENTINEL_KEY" "no ambient credential value reaches the request"
assert_not_contains "$urls" "key=" "the probe URL carries no query credential"
[ ! -s "$tmp/tools.log" ] || fail "the probe read quota or jq: $(cat "$tmp/tools.log")"

# --- unknown target and malformed input are refusals, never silent guesses ---
tmp=$TMP_ROOT/unknown-target; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig "$SCRIPT" nosuchprovider 2>&1); rc=$?
expect_code 2 "$rc" "an unregistered target is refused"
assert_contains "$out" "no probe is registered" "the refusal names the missing registration"
assert_contains "$out" "nosuchprovider" "the refusal echoes what was asked"

tmp=$TMP_ROOT/bad-timeout; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" xhy --timeout 0 2>&1); rc=$?
expect_code 2 "$rc" "--timeout 0 is refused rather than becoming no deadline"
assert_contains "$out" "positive integer" "the timeout refusal explains the requirement"

tmp=$TMP_ROOT/dup-timeout; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" xhy --timeout 3 --timeout 4 2>&1); rc=$?
expect_code 2 "$rc" "a repeated --timeout is refused"

tmp=$TMP_ROOT/extra-arg; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" xhy extra 2>&1); rc=$?
expect_code 2 "$rc" "an unexpected extra argument is refused"

tmp=$TMP_ROOT/both-targets; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" xhy --host api.example.invalid 2>&1); rc=$?
expect_code 2 "$rc" "a target and --host together are refused"

# --- an authority-less registered target is its own verdict, never a guess ----
# The guard lives on the registered-target path. Its base URL is recorded data, so
# the suite reaches the defect through the documented FM_PROVIDER_REACH_TARGET_BASE
# seam - armed only under FM_TEST_SEAM, replacing the recorded URL of an already
# registered target and registering nothing.
tmp=$TMP_ROOT/target-no-authority; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_PROVIDER_REACH_TARGET_BASE='https://' "$SCRIPT" xhy 2>&1); rc=$?
expect_code 2 "$rc" "a registered target with no authority exits 2"
assert_contains "$out" "result=invalid-target" "an authority-less target says invalid-target"
assert_contains "$out" "base_url_has_no_authority" "it names why"
assert_contains "$out" "probe=xhy" "the line still identifies the probed target"
assert_contains "$out" "dns=skipped http=none" "an invalid target resolves nothing and requests nothing"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "expected exactly one probe line, got: $out"
[ ! -s "$tmp/dig.log" ] || fail "an invalid target still ran a resolver: $(cat "$tmp/dig.log")"
[ ! -s "$tmp/urls.log" ] || fail "an invalid target still issued an HTTP request: $(cat "$tmp/urls.log")"

# The seam must not become a way to register a target: an unregistered name stays a
# usage refusal, and an unset seam leaves the recorded URL in charge.
tmp=$TMP_ROOT/seam-registers-nothing; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig \
  FM_PROVIDER_REACH_TARGET_BASE='https://api.example.invalid/v1/models' \
  "$SCRIPT" nosuchprovider 2>&1); rc=$?
expect_code 2 "$rc" "a base URL alone does not register a target"
assert_contains "$out" "no probe is registered" "the refusal still names the missing registration"

# Outside an armed suite the seam is inert, so a leaked variable cannot silently
# redirect a registered target at another endpoint.
tmp=$TMP_ROOT/seam-inert; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_FAKE_CURL_CODE=200 FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_CURL_URL_LOG="$tmp/urls.log" \
  env -u FM_TEST_SEAM FM_PROVIDER_REACH_TARGET_BASE='https://seam.example.invalid' \
  "$SCRIPT" xhy 2>&1); rc=$?
expect_code 0 "$rc" "an unarmed seam changes nothing"
assert_contains "$out" "http=200" "an unarmed seam still completes the probe"
assert_contains "$(cat "$tmp/urls.log")" "https://api.xhyapi.com/v1/models" "an unarmed seam keeps the recorded base URL"
assert_not_contains "$(cat "$tmp/urls.log")" "seam.example.invalid" "an unarmed seam does not redirect the request"

tmp=$TMP_ROOT/host-userinfo; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" "$SCRIPT" --host user:pass@api.example.invalid 2>&1); rc=$?
expect_code 2 "$rc" "a host with userinfo is refused"
assert_contains "$out" "must not contain userinfo" "userinfo refusal is explicit"
[ ! -s "$tmp/urls.log" ] || fail "userinfo host reached curl: $(cat "$tmp/urls.log")"

# --- a missing curl is its own outcome, never another one -------------------
# The curl-absent branch cannot be reached by shrinking PATH on a host whose real
# curl sits in /usr/bin, which the case directory does not shadow. The suite seam
# named in the script's header points the request at a missing executable while
# the PATH `command -v curl` guard still sees the host's own curl, so what is
# observed is "no usable curl", never a fabricated verdict.
NO_CURL_SENTINEL=$TMP_ROOT/no-such-curl-xyz
assert_absent "$NO_CURL_SENTINEL" "the curl stand-in path must not exist"
tmp=$TMP_ROOT/no-curl; new_case "$tmp"
out=$(PATH="$tmp:$BASE_PATH" FM_PROVIDER_REACH_DNS_TOOL=dig FM_FAKE_DIG_MODE=address \
  FM_PROVIDER_REACH_CURL_CMD="$NO_CURL_SENTINEL" "$SCRIPT" --host api.example.invalid 2>&1); rc=$?
expect_code 64 "$rc" "an unusable curl exits 64"
assert_contains "$out" "result=tool-missing" "an unusable curl says the tool is absent"
assert_contains "$out" "dns=ok" "an unusable curl keeps the DNS finding already made"
assert_not_contains "$out" "result=reachable" "an unusable curl is never reported as a good probe"
assert_not_contains "$out" "result=unreachable" "an unusable curl is never reported as an outage"

pass "fm-provider-reach-probe.sh distinguishes 000, 401/403, and 200 with stable wording"
