#!/usr/bin/env bash
# Behavior tests for fm-auth-preflight.sh - the deterministic selected-surface
# authentication verdict used at crew dispatch intake.
#
# The defect this suite pins: one credential store's locally expired timestamp
# was reported as "the captain is signed out" for candidates that never read
# that store. Every case therefore drives the real script with a fake quota-axi
# whose documents are shaped exactly like quota-axi 0.1.16 output, and asserts
# the emitted verdict plus - just as importantly - which vendor CLIs were and
# were not launched.
#
# The fake grok records every invocation's argv and anything it can read from
# stdin, so "never launched for a Pi tuple", "exactly one probe", "argv is fixed
# to `models`", and "stdin stays closed" are observable facts rather than
# comments. Fixtures are nonsecret and carry no credential material.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-auth-preflight-tests)
FIXTURES="$ROOT/tests/fixtures/auth-preflight"
SCRIPT="$ROOT/bin/fm-auth-preflight.sh"
NODE_BIN=$(command -v node 2>/dev/null) || fail "tests require node because it is a common runtime tool"

# A stdin payload the script must never leak into a probed vendor CLI.
STDIN_SENTINEL='SENTINEL-STDIN-MUST-NOT-REACH-VENDOR-CLI'

# --- fake toolchain ---------------------------------------------------------
#
# quota-axi: version, `auth --json`, and `--provider <p> --json` are served from
# fixture files chosen per case. Every invocation is logged so call counts are
# assertable, which is how "exactly one quota retry" is enforced.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  ln -s "$NODE_BIN" "$fakebin/node"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
exit 125
SH
  chmod +x "$fakebin/python3"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_QUOTA_LOG"
if [ "${1:-}" = --version ]; then
  [ "${FM_FAKE_QUOTA_AXI_VERSION_HANG:-}" = 1 ] && sleep 30
  printf '%s\n' "${FM_FAKE_QUOTA_AXI_VERSION:-0.1.16}"
  exit 0
fi
if [ "${1:-}" = auth ]; then
  [ -n "${FM_FAKE_AUTH_DOC:-}" ] || exit 1
  cat "$FM_FAKE_AUTH_DOC"
  exit 0
fi
# Quota read. FM_FAKE_QUOTA_FAIL makes every read fail (transport-failure class).
[ -z "${FM_FAKE_QUOTA_FAIL:-}" ] || exit 1
if [ -n "${FM_FAKE_QUOTA_DOC_RETRY:-}" ] && [ -f "$FM_FAKE_QUOTA_LOG.quota" ]; then
  cat "$FM_FAKE_QUOTA_DOC_RETRY"
  exit 0
fi
: >> "$FM_FAKE_QUOTA_LOG.quota"
[ -n "${FM_FAKE_QUOTA_DOC:-}" ] || exit 1
cat "$FM_FAKE_QUOTA_DOC"
exit 0
SH
  chmod +x "$fakebin/quota-axi"

  cat > "$fakebin/grok" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GROK_LOG"
# Record whatever is readable on stdin. With stdin correctly closed by the
# caller this reads EOF immediately and records nothing.
if IFS= read -r -t 2 leaked; then
  printf '%s\n' "$leaked" >> "$FM_FAKE_GROK_STDIN"
fi
if [ "${1:-}" = --version ]; then
  printf 'grok %s (fakebuild) [stable]\n' "${FM_FAKE_GROK_VERSION:-0.2.112}"
  exit 0
fi
case "${FM_FAKE_GROK_MODE:-authenticated}" in
  authenticated)
    printf '%s\n' 'You are logged in with grok.com.'
    printf '\n%s\n' 'Default model: grok-4.5'
    ;;
  unauthenticated)
    printf '%s\n' 'You are not authenticated.'
    ;;
  garbage)
    printf '%s\n' 'Session status: unknown (0.9.0 rewrote this line)'
    ;;
  leading-blank)
    printf '\n%s\n' 'You are logged in with grok.com.'
    ;;
  empty) : ;;
  hang) sleep 30 ;;
esac
# grok 0.2.112 exits 0 whether or not the session authenticates; the fake keeps
# that property so a regression to exit-status reading fails here.
exit 0
SH
  chmod +x "$fakebin/grok"
  printf '%s\n' "$fakebin"
}

# run_preflight <case> <harness> <model> [env assignments...]
# Sets RUN_LINE, RUN_RC, RUN_GROK_LOG, RUN_GROK_STDIN, RUN_QUOTA_LOG in the
# caller's shell, so it must not be invoked in a command substitution.
RUN_LINE=
RUN_RC=0
RUN_GROK_LOG=
RUN_GROK_STDIN=
RUN_QUOTA_LOG=
run_preflight() {
  local case_name=$1 harness=$2 model=$3
  shift 3
  local case_dir fakebin out rc=0 assignment
  case_dir="$TMP_ROOT/$case_name"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  RUN_GROK_LOG="$case_dir/grok.log"
  RUN_GROK_STDIN="$case_dir/grok.stdin"
  RUN_QUOTA_LOG="$case_dir/quota.log"
  : > "$RUN_GROK_LOG"
  : > "$RUN_GROK_STDIN"
  : > "$RUN_QUOTA_LOG"
  local -a env_pairs=(
    "PATH=$fakebin:$BASE_PATH"
    "FM_FAKE_GROK_LOG=$RUN_GROK_LOG"
    "FM_FAKE_GROK_STDIN=$RUN_GROK_STDIN"
    "FM_FAKE_QUOTA_LOG=$RUN_QUOTA_LOG"
  )
  for assignment in "$@"; do
    env_pairs+=("$assignment")
  done
  out=$(env "${env_pairs[@]}" "$SCRIPT" --harness "$harness" --model "$model" \
    <<<"$STDIN_SENTINEL" 2>/dev/null) || rc=$?
  RUN_RC=$rc
  RUN_LINE=$out
}

# field <line> <key>
field() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

assert_field() {  # <line> <key> <expected> <label>
  local got
  got=$(field "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: expected $2=$3, got $2=${got:-<absent>}"$'\n'"--- line ---"$'\n'"$1"
}

assert_grok_never_ran() {  # <label>
  [ ! -s "$RUN_GROK_LOG" ] \
    || fail "$1: the Grok CLI must not run for this tuple, but it was invoked with: $(tr '\n' '|' < "$RUN_GROK_LOG")"
}

# Every recorded grok invocation must be one of the two fixed, non-destructive
# argv forms. A login, logout, or bare interactive launch fails here.
assert_grok_argv_safe() {  # <label>
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      models|--version) : ;;
      *) fail "$1: unexpected Grok CLI invocation 'grok $line'" ;;
    esac
  done < "$RUN_GROK_LOG"
}

quota_reads() {  # number of quota reads, excluding auth and version calls
  { grep -cvE '^(auth|--version)' "$RUN_QUOTA_LOG" 2>/dev/null || true; } | head -n 1
}

# --- the reported incident --------------------------------------------------

# The exact reported failure: the standalone Grok CLI token has aged out while
# the Pi xAI credential the candidate actually uses is fine. The candidate must
# stay dispatchable and the Grok CLI must never be consulted.
test_expired_grok_cli_never_blocks_a_pi_xai_candidate() {
  local line reads
  run_preflight expired-grok-pi-ok pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-expired-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "expired Grok CLI must not block a Pi/xAI candidate"
  assert_field "$line" surface pi:xai "Pi/xAI tuple must resolve its own surface"
  assert_field "$line" provider grok "Pi/xAI headroom is measured on the grok provider"
  assert_field "$line" authStatus usable "the Pi xAI credential is available"
  assert_field "$line" headroom 42 "known headroom must be reported"
  assert_field "$line" eligible yes "an authenticated Pi/xAI candidate stays dispatchable"
  assert_field "$line" preflight not-applicable "a Pi tuple has no vendor probe"
  assert_grok_never_ran "expired Grok CLI case"
  assert_field "$line" quotaRetry known "known headroom still receives the single retry"
  reads=$(quota_reads)
  [ "$reads" -eq 2 ] || fail "expected one initial quota read plus one retry, got $reads reads"
  pass "an expired standalone Grok CLI credential never blocks or probes a Pi/xAI candidate"
}

# Same tuple, but the standalone Grok CLI has no credential at all.
test_missing_grok_config_never_blocks_a_pi_xai_candidate() {
  local line
  run_preflight missing-grok-pi-ok pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-missing-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "missing Grok CLI config must not block a Pi/xAI candidate"
  assert_field "$line" surface pi:xai "Pi/xAI tuple must resolve its own surface"
  assert_field "$line" eligible yes "an authenticated Pi/xAI candidate stays dispatchable"
  assert_grok_never_ran "missing Grok config case"
  pass "a missing standalone Grok configuration never blocks or probes a Pi/xAI candidate"
}

# The inverse scoping error: a healthy Grok CLI must not vouch for an expired Pi
# credential either. quota-axi has no Grok remedy for Pi-owned expiry, so this
# reports an aged-out session rather than asking the captain to log in anywhere.
test_pi_expiry_is_scoped_to_pi_and_never_probes_grok() {
  local line
  run_preflight pi-expired pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-available-pi-expired.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "a vendor-renewable Pi credential is not a captain action"
  assert_field "$line" surface pi:xai "Pi expiry must be read on the Pi surface"
  assert_field "$line" authStatus expired "the Pi xAI credential has aged out"
  assert_field "$line" eligible yes "an aged-out renewable session is not a sign-out"
  assert_field "$line" reason auth-expired-vendor-renews "expiry must not be worded as a login need"
  assert_grok_never_ran "Pi expiry case"
  pass "Pi credential expiry stays scoped to Pi and never launches the Grok CLI"
}

# --- usable authentication with unmeasurable headroom -----------------------

test_usable_auth_with_unknown_quota_stays_eligible() {
  local line
  run_preflight usable-unknown-quota pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-unavailable-auth-usable.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "unreadable headroom must not disqualify an authenticated candidate"
  assert_field "$line" authStatus usable "authentication is fine"
  assert_field "$line" headroom unknown "headroom is unmeasured, not invented"
  assert_field "$line" eligible yes "usable auth with unknown quota stays dispatchable"
  assert_field "$line" reason auth-usable-headroom-unknown "the unknown headroom must be disclosed"
  pass "usable authentication with unmeasurable headroom stays eligible and discloses the unknown"
}

# A stale report keeps raw windows for diagnostics; they are never headroom, and
# staleness must never acquire credential wording.
test_stale_quota_is_never_headroom_and_never_credential_wording() {
  local line
  run_preflight stale-quota pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-stale-auth-usable.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "a stale quota report is not an authentication problem"
  assert_field "$line" authStatus usable "stale quota says nothing about authentication"
  assert_field "$line" headroom unknown "stale raw windows must not become headroom"
  assert_field "$line" eligible yes "stale quota keeps an authenticated candidate dispatchable"
  pass "stale quota stays diagnostic, never headroom and never credential wording"
}

test_mixed_known_and_unknown_scopes_stay_unknown() {
  local line reads
  run_preflight mixed-scopes pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-mixed-known-unknown.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "mixed quota scopes must not disqualify usable authentication"
  assert_field "$line" headroom unknown "one unknown applicable scope makes aggregate headroom unknown"
  assert_field "$line" quotaRetry unknown "the retry must preserve mixed-scope uncertainty"
  reads=$(quota_reads)
  [ "$reads" -eq 2 ] || fail "expected one initial quota read plus one retry, got $reads reads"
  pass "mixed known and unknown quota scopes stay conservatively unknown"
}

# Transport-class failure: both the first read and the single retry fail.
test_quota_endpoint_failure_retries_once_and_stays_eligible() {
  local line reads
  run_preflight quota-transport-failure pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_FAIL=1"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "a failing billing endpoint is not a credential problem"
  assert_field "$line" authStatus usable "a transport failure says nothing about authentication"
  assert_field "$line" headroom unknown "a failed read yields unknown headroom"
  assert_field "$line" quotaRetry failed "the single retry must be recorded"
  assert_field "$line" eligible yes "a transient endpoint failure keeps the candidate dispatchable"
  reads=$(quota_reads)
  [ "$reads" -eq 2 ] || fail "expected exactly one quota read plus one retry, got $reads reads"
  pass "a failing quota endpoint retries exactly once and never becomes credential wording"
}

# The retry is what turns a transient failure back into known headroom.
test_quota_retry_recovers_known_headroom() {
  local line reads
  run_preflight quota-retry-recovers pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-unavailable-auth-usable.json" \
    "FM_FAKE_QUOTA_DOC_RETRY=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "a recovered read must stay eligible"
  assert_field "$line" headroom 42 "the retry's known headroom must win"
  assert_field "$line" quotaRetry known "a recovered retry must be recorded"
  reads=$(quota_reads)
  [ "$reads" -eq 2 ] || fail "expected exactly two quota reads, got $reads"
  pass "the single quota retry recovers known headroom without a third read"
}

# --- the captain-approved standalone Grok preflight -------------------------

test_standalone_grok_expired_probe_authenticates_and_stays_eligible() {
  local line probes
  run_preflight grok-expired-authenticated grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-expired.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_GROK_MODE=authenticated"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "a preflight that authenticates keeps the candidate dispatchable"
  assert_field "$line" surface auth-json "a standalone Grok tuple uses the Grok CLI credential"
  assert_field "$line" preflight authenticated "the probe verdict comes from the first stdout line"
  assert_field "$line" eligible yes "an authenticated preflight resolves the expiry"
  assert_field "$line" reason auth-usable-preflight "the verdict must name the preflight"
  assert_grok_argv_safe "authenticated probe"
  probes=$(grep -cx models "$RUN_GROK_LOG" || true)
  [ "$probes" -eq 1 ] || fail "expected exactly one bounded probe, got $probes"
  pass "a standalone Grok tuple runs exactly one bounded probe and proceeds when it authenticates"
}

test_standalone_grok_unauthenticated_probe_reports_the_candidate() {
  local line probes reads
  run_preflight grok-unauthenticated grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-missing.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-auth-required.json" \
    "FM_FAKE_GROK_MODE=unauthenticated"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "a genuinely unauthenticated surface must not be dispatchable"
  assert_field "$line" preflight unauthenticated "the probe must classify the documented output"
  assert_field "$line" eligible no "a proven-unauthenticated candidate is reported"
  assert_field "$line" reason auth-unusable-preflight "the verdict must name the preflight"
  assert_field "$line" providerAuthStatus unusable "the aggregate status corroborates"
  assert_grok_argv_safe "unauthenticated probe"
  probes=$(grep -cx models "$RUN_GROK_LOG" || true)
  [ "$probes" -eq 1 ] || fail "expected exactly one bounded probe, got $probes"
  reads=$(quota_reads)
  [ "$reads" -eq 2 ] || fail "expected one quota read plus exactly one post-preflight retry, got $reads"
  pass "truly missing credentials are reported only after one bounded probe and one quota retry"
}

# The exit status is deliberately not the verdict, so a rewritten status line
# must read as indeterminate rather than as a successful authentication.
test_unrecognized_probe_output_is_never_read_as_authenticated() {
  local line
  run_preflight grok-garbage grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-missing.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-auth-required.json" \
    "FM_FAKE_GROK_MODE=garbage"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "unrecognized probe output must fail closed"
  assert_field "$line" preflight indeterminate "unrecognized output is indeterminate"
  assert_field "$line" eligible no "indeterminate output must never be read as authenticated"
  assert_field "$line" reason preflight-indeterminate "the verdict must name the indeterminate probe"
  pass "unrecognized probe output is indeterminate and never reads as authenticated"
}

test_blank_first_probe_line_is_indeterminate() {
  local line reads
  run_preflight grok-leading-blank grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-expired.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_GROK_MODE=leading-blank"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "a blank first stdout line must not authenticate"
  assert_field "$line" preflight indeterminate "only literal stdout line one may authenticate"
  assert_field "$line" eligible no "a later authenticated-looking line must be ignored"
  assert_field "$line" reason preflight-indeterminate "the blank first line must fail closed"
  reads=$(quota_reads)
  [ "$reads" -eq 2 ] || fail "expected one initial quota read plus one retry, got $reads reads"
  pass "a blank first probe line is not skipped or treated as authenticated"
}

test_empty_probe_output_is_indeterminate() {
  local line
  run_preflight grok-empty grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-missing.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-auth-required.json" \
    "FM_FAKE_GROK_MODE=empty"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "silent probe output must fail closed"
  assert_field "$line" preflight indeterminate "silent output is indeterminate"
  pass "silent probe output is indeterminate rather than a silent pass"
}

# The probe must be a bound, not a wedge: a hanging vendor CLI is killed and
# reported, and the script still returns a verdict line.
test_hanging_probe_is_bounded_and_reported() {
  local line started finished
  started=$(date +%s)
  run_preflight grok-hang grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-expired.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_GROK_MODE=hang" \
    "FM_AUTH_PREFLIGHT_TIMEOUT=2"
  line=$RUN_LINE
  finished=$(date +%s)
  expect_code 3 "$RUN_RC" "a timed-out probe must fail closed"
  assert_field "$line" preflight timeout "a hit bound must be reported as a timeout"
  assert_field "$line" reason preflight-timeout "the verdict must name the timeout"
  [ $((finished - started)) -lt 25 ] \
    || fail "the probe was not bounded: took $((finished - started))s against a 2s bound"
  pass "a hanging vendor CLI is hard-bounded, reported, and cannot wedge the intake"
}

test_missing_vendor_cli_is_reported_not_assumed() {
  local case_dir fakebin line rc=0
  case_dir="$TMP_ROOT/grok-absent"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  rm -f "$fakebin/grok"
  line=$(env "PATH=$fakebin:$BASE_PATH" \
    "FM_FAKE_QUOTA_LOG=$case_dir/quota.log" \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-missing.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-auth-required.json" \
    "$SCRIPT" --harness grok --model grok-4.5 </dev/null 2>/dev/null) || rc=$?
  expect_code 3 "$rc" "an absent vendor CLI must fail closed"
  assert_field "$line" preflight unavailable "an absent probe command must be reported"
  assert_field "$line" reason preflight-unavailable "the verdict must name the unavailable probe"
  pass "an absent vendor CLI is reported rather than assumed authenticated"
}

# The discriminator strings are un-owned vendor UI text. A version change does
# not silently invalidate the verdict, but it is disclosed so it can be re-verified.
test_probe_version_change_is_disclosed() {
  local line
  run_preflight grok-version-drift grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-expired.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_GROK_MODE=authenticated" \
    "FM_FAKE_GROK_VERSION=0.9.0"
  line=$RUN_LINE
  assert_field "$line" probeVersion 0.9.0 "the probed CLI version must be recorded"
  assert_field "$line" probeVersionVerified no "an unverified version must be disclosed"
  pass "a vendor CLI version change is recorded and disclosed for re-verification"
}

test_probe_version_match_is_recorded() {
  local line
  run_preflight grok-version-pinned grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-expired.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_GROK_MODE=authenticated"
  line=$RUN_LINE
  assert_field "$line" probeVersionVerified yes "the pinned verified version must be recognized"
  pass "the pinned verified vendor version is recognized"
}

# --- safety invariants ------------------------------------------------------

test_probe_never_inherits_caller_stdin() {
  local line
  run_preflight grok-stdin grok grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-expired.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_GROK_MODE=authenticated"
  line=$RUN_LINE
  [ -n "$line" ] || fail "expected a verdict line"
  [ ! -s "$RUN_GROK_STDIN" ] \
    || fail "the probe inherited caller stdin: $(cat "$RUN_GROK_STDIN")"
  pass "the bounded probe runs with stdin closed and cannot read caller input"
}

# quota-axi's value at every intake rests on it never mutating what it measures.
# The preflight must therefore only ever read from it, whatever the tuple.
test_quota_axi_is_only_ever_read() {
  local case_name line
  for case_name in readonly-usable readonly-probe; do
    if [ "$case_name" = readonly-usable ]; then
      run_preflight "$case_name" pi xai/grok-4.5 \
        "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
        "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
    else
      run_preflight "$case_name" grok grok-4.5 \
        "FM_FAKE_AUTH_DOC=$FIXTURES/auth-both-expired.json" \
        "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
        "FM_FAKE_GROK_MODE=authenticated"
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        --version|auth\ --json|--provider\ *\ --json) : ;;
        *) fail "$case_name: unexpected quota-axi invocation 'quota-axi $line'" ;;
      esac
    done < "$RUN_QUOTA_LOG"
  done
  pass "the preflight only ever reads from quota-axi, never a mutating verb"
}

test_verdict_line_carries_no_credential_material() {
  local line
  run_preflight sanitized pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-expired-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  assert_not_contains "$line" "/fixture/home" "the verdict must not leak a credential path"
  assert_not_contains "$line" ".grok/auth.json" "the verdict must not leak a credential path"
  assert_not_contains "$line" "You are logged in" "the verdict must not echo raw vendor output"
  case "$line" in
    *$'\n'*) fail "the verdict must be exactly one line" ;;
  esac
  pass "the verdict line is one sanitized line with no credential material or raw vendor output"
}

# Fixtures back every negative assertion above, so they must stay nonsecret.
test_fixtures_are_nonsecret() {
  local file blob
  for file in "$FIXTURES"/*.json; do
    blob=$(cat "$file")
    for marker in 'sk-' 'Bearer ' 'access_token' 'refresh_token' 'authorization'; do
      assert_not_contains "$blob" "$marker" "fixture $(basename "$file") carries credential-shaped material"
    done
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" \
      || fail "fixture $(basename "$file") is not valid JSON"
  done
  pass "auth-preflight fixtures are valid JSON and carry no credential-shaped material"
}

# --- unresolved candidates --------------------------------------------------

test_unknown_harness_is_unresolved() {
  local line
  run_preflight unknown-harness unverified anthropic/claude-opus-5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-other-providers.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "a harness with no modelled auth surface must fail closed"
  assert_field "$line" authStatus unresolved "an unmodelled harness is unresolved, not assumed healthy"
  assert_field "$line" reason surface-unresolved "the verdict must name the unresolved surface"
  assert_grok_never_ran "unknown harness case"
  pass "a harness with no modelled authentication surface is unresolved rather than guessed"
}

test_opencode_without_auth_surface_stays_eligible() {
  local line reads
  run_preflight opencode-no-auth-evidence opencode anthropic/claude-opus-5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-other-providers.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 0 "$RUN_RC" "a verified OpenCode tuple without a quota surface stays eligible"
  assert_field "$line" provider none "OpenCode must not guess a quota provider"
  assert_field "$line" surface none "OpenCode must disclose no selected auth surface"
  assert_field "$line" authStatus unknown "OpenCode auth evidence is unknown, not usable"
  assert_field "$line" providerAuthStatus none "OpenCode must not claim provider auth status"
  assert_field "$line" headroom unknown "OpenCode headroom is unmeasured"
  assert_field "$line" preflight not-applicable "OpenCode has no registered vendor probe"
  assert_field "$line" quotaRetry none "OpenCode has no quota provider to retry"
  assert_field "$line" eligible yes "missing OpenCode auth evidence must not drop a verified tuple"
  assert_field "$line" reason no-auth-evidence "the no-evidence condition must be explicit"
  assert_grok_never_ran "OpenCode no-auth-evidence case"
  reads=$(quota_reads)
  [ "$reads" -eq 0 ] || fail "OpenCode must not read a guessed quota provider, got $reads reads"
  pass "a verified OpenCode tuple stays eligible with explicit unknown auth evidence"
}

test_opencode_malformed_model_relationships_are_unresolved() {
  local line label model
  for label in empty-provider whitespace-provider empty-model whitespace-model extra-separator; do
    case "$label" in
      empty-provider) model='/claude-opus-5' ;;
      whitespace-provider) model='   /claude-opus-5' ;;
      empty-model) model='anthropic/' ;;
      whitespace-model) model='anthropic/   ' ;;
      extra-separator) model='anthropic//claude-opus-5' ;;
    esac
    run_preflight "opencode-malformed-$label" opencode "$model" \
      "FM_FAKE_AUTH_DOC=$FIXTURES/auth-other-providers.json" \
      "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
    line=$RUN_LINE
    expect_code 3 "$RUN_RC" "an OpenCode $label relationship must fail closed"
    assert_field "$line" authStatus unresolved "an OpenCode $label relationship is unresolved"
    assert_field "$line" reason surface-unresolved "the OpenCode $label relationship must be named"
    assert_grok_never_ran "malformed OpenCode $label relationship case"
    [ "$(quota_reads)" -eq 0 ] || fail "malformed OpenCode $label relationship must not read quota"
  done
  pass "malformed OpenCode provider/model relationships remain ineligible"
}

test_absent_provider_is_unresolved() {
  local line
  run_preflight absent-provider pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-no-grok-provider.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "an unlisted source must fail closed"
  assert_field "$line" authStatus unresolved "an unlisted source cannot be assumed usable"
  assert_grok_never_ran "absent provider case"
  pass "a tuple whose auth source no provider lists is unresolved rather than assumed usable"
}

test_pi_model_without_provider_prefix_is_unresolved() {
  local line
  run_preflight pi-no-prefix pi grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "a Pi model with no provider prefix must fail closed"
  assert_field "$line" authStatus unresolved "a bare model name must not infer a provider"
  assert_grok_never_ran "Pi model without prefix"
  pass "a Pi model with no provider prefix is unresolved instead of guessing a credential"
}

# --- toolchain floor --------------------------------------------------------

# 0.1.15 reports neither per-credential auth sources nor state.authStatus, so it
# cannot scope a surface at all. Refusing beats emitting a confident wrong verdict.
test_stale_quota_axi_refuses_rather_than_guessing() {
  local line
  run_preflight stale-toolchain pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_QUOTA_AXI_VERSION=0.1.15"
  line=$RUN_LINE
  expect_code 3 "$RUN_RC" "a below-floor toolchain must fail closed"
  assert_field "$line" reason quota-axi-below-0.1.16 "the verdict must name the version floor"
  assert_grok_never_ran "below-floor toolchain"
  pass "a quota-axi below the 0.1.16 floor refuses instead of emitting an unscoped verdict"
}

test_hanging_quota_axi_version_is_bounded() {
  local line started finished
  started=$(date +%s)
  run_preflight quota-version-hang pi xai/grok-4.5 \
    "FM_FAKE_AUTH_DOC=$FIXTURES/auth-grok-cli-and-pi-available.json" \
    "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json" \
    "FM_FAKE_QUOTA_AXI_VERSION_HANG=1" \
    "FM_AUTH_PREFLIGHT_TIMEOUT=2"
  line=$RUN_LINE
  finished=$(date +%s)
  expect_code 3 "$RUN_RC" "a hanging quota-axi version check must fail closed"
  assert_field "$line" reason quota-axi-below-0.1.16 "a failed version check must not emit a candidate verdict"
  [ $((finished - started)) -lt 25 ] \
    || fail "the quota-axi version check was not bounded: took $((finished - started))s against a 2s bound"
  pass "a hanging quota-axi version check is hard-bounded before the preflight verdict"
}

test_usage_errors_are_distinct_from_verdicts() {
  local rc=0
  "$SCRIPT" --harness grok >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing --model is a usage error, not a verdict"
  rc=0
  "$SCRIPT" --harness grok --model grok-4.5 --bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown flag is a usage error, not a verdict"
  rc=0
  "$SCRIPT" --help >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "--help must succeed"
  pass "usage errors exit 2 and stay distinct from an eligibility verdict"
}

# --- other harnesses must not regress ---------------------------------------

test_other_harness_surfaces_resolve_without_probing() {
  local line harness
  for harness in claude codex kimi; do
    run_preflight "surface-$harness" "$harness" some-model \
      "FM_FAKE_AUTH_DOC=$FIXTURES/auth-other-providers.json" \
      "FM_FAKE_QUOTA_DOC=$FIXTURES/quota-grok-fresh.json"
    line=$RUN_LINE
    assert_field "$line" provider "$harness" "$harness must resolve its own provider"
    assert_field "$line" preflight not-applicable "$harness has no registered vendor probe"
    assert_field "$line" eligible yes "$harness with an available credential stays dispatchable"
    assert_grok_never_ran "$harness surface"
  done
  pass "claude, codex, and kimi resolve their own surfaces without any vendor probe"
}

test_expired_grok_cli_never_blocks_a_pi_xai_candidate
test_missing_grok_config_never_blocks_a_pi_xai_candidate
test_pi_expiry_is_scoped_to_pi_and_never_probes_grok
test_usable_auth_with_unknown_quota_stays_eligible
test_stale_quota_is_never_headroom_and_never_credential_wording
test_mixed_known_and_unknown_scopes_stay_unknown
test_quota_endpoint_failure_retries_once_and_stays_eligible
test_quota_retry_recovers_known_headroom
test_standalone_grok_expired_probe_authenticates_and_stays_eligible
test_standalone_grok_unauthenticated_probe_reports_the_candidate
test_unrecognized_probe_output_is_never_read_as_authenticated
test_blank_first_probe_line_is_indeterminate
test_empty_probe_output_is_indeterminate
test_hanging_probe_is_bounded_and_reported
test_missing_vendor_cli_is_reported_not_assumed
test_probe_version_change_is_disclosed
test_probe_version_match_is_recorded
test_probe_never_inherits_caller_stdin
test_quota_axi_is_only_ever_read
test_verdict_line_carries_no_credential_material
test_fixtures_are_nonsecret
test_unknown_harness_is_unresolved
test_opencode_without_auth_surface_stays_eligible
test_opencode_malformed_model_relationships_are_unresolved
test_absent_provider_is_unresolved
test_hanging_quota_axi_version_is_bounded
test_pi_model_without_provider_prefix_is_unresolved
test_stale_quota_axi_refuses_rather_than_guessing
test_usage_errors_are_distinct_from_verdicts
test_other_harness_surfaces_resolve_without_probing
