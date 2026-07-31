#!/usr/bin/env bash
# Behavior tests for fm-vendor-auth-probe.sh - the one hard-bounded,
# non-destructive authentication probe of a named vendor CLI.
#
# Two defects this suite pins:
#
# 1. The script must render no dispatch verdict and hold no routing knowledge.
#    Its predecessor resolved a candidate's credential surface from a hard-coded
#    harness-to-provider table plus a `pi:<model-prefix>` source-id matcher, and
#    emitted `eligible=`. A supported Pi model in a provider family with no such
#    prefixed source was therefore dropped as unresolved while the family's own
#    quota and credentials were healthy. The tests below prove the script now has
#    no harness, model, or provider input surface at all, so no such mapping can
#    influence it, and that both probe outcomes exit alike because neither is a
#    verdict.
#
# 2. The captain-approved probe envelope must not depend on agent memory: fixed
#    argv, stdin closed, a hard positive bound, and raw vendor output never
#    printed. The fake grok records every invocation's argv and anything it can
#    read from stdin, so "argv is fixed to `models`", "no login or logout", and
#    "stdin stays closed" are observable facts rather than comments.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-vendor-auth-probe-tests)
SCRIPT="$ROOT/bin/fm-vendor-auth-probe.sh"

# A stdin payload the script must never leak into a probed vendor CLI.
STDIN_SENTINEL='SENTINEL-STDIN-MUST-NOT-REACH-VENDOR-CLI'

# --- fake toolchain ---------------------------------------------------------
#
# quota-axi is present on PATH and logs every invocation. The script must never
# call it: reading quota is the dispatch owner's job against one intake snapshot,
# and a probe that re-read it would reintroduce the retired coupling.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_QUOTA_LOG"
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
  printf 'grok %s (fakebuild) [stable]\n' "${FM_FAKE_GROK_VERSION:-0.2.117}"
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
# grok 0.2.117 exits 0 whether or not the session authenticates; the fake keeps
# that property so a regression to exit-status reading fails here.
exit 0
SH
  chmod +x "$fakebin/grok"
  printf '%s\n' "$fakebin"
}

# run_probe <case> [args...] -- [env assignments...]
# Sets RUN_LINE, RUN_RC, RUN_GROK_LOG, RUN_GROK_STDIN, RUN_QUOTA_LOG in the
# caller's shell, so it must not be invoked in a command substitution.
RUN_LINE=
RUN_RC=0
RUN_GROK_LOG=
RUN_GROK_STDIN=
RUN_QUOTA_LOG=
run_probe() {
  local case_name=$1
  shift
  local case_dir fakebin out rc=0 arg
  local -a script_args=() env_pairs=()
  case_dir="$TMP_ROOT/$case_name"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  RUN_GROK_LOG="$case_dir/grok.log"
  RUN_GROK_STDIN="$case_dir/grok.stdin"
  RUN_QUOTA_LOG="$case_dir/quota.log"
  : > "$RUN_GROK_LOG"
  : > "$RUN_GROK_STDIN"
  : > "$RUN_QUOTA_LOG"
  local seen_separator=0
  for arg in "$@"; do
    if [ "$seen_separator" -eq 0 ] && [ "$arg" = -- ]; then
      seen_separator=1
      continue
    fi
    if [ "$seen_separator" -eq 0 ]; then
      script_args+=("$arg")
    else
      env_pairs+=("$arg")
    fi
  done
  out=$(env "PATH=$fakebin:$BASE_PATH" \
    "FM_FAKE_GROK_LOG=$RUN_GROK_LOG" \
    "FM_FAKE_GROK_STDIN=$RUN_GROK_STDIN" \
    "FM_FAKE_QUOTA_LOG=$RUN_QUOTA_LOG" \
    "${env_pairs[@]+"${env_pairs[@]}"}" \
    "$SCRIPT" "${script_args[@]+"${script_args[@]}"}" \
    <<<"$STDIN_SENTINEL" 2>/dev/null) || rc=$?
  RUN_RC=$rc
  RUN_LINE=$out
}

field() {  # <line> <key>
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

assert_field() {  # <line> <key> <expected> <label>
  local got
  got=$(field "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: expected $2=$3, got $2=${got:-<absent>}"$'\n'"--- line ---"$'\n'"$1"
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

assert_grok_never_ran() {  # <label>
  [ ! -s "$RUN_GROK_LOG" ] \
    || fail "$1: no vendor CLI may run, but grok was invoked with: $(tr '\n' '|' < "$RUN_GROK_LOG")"
}

assert_quota_never_read() {  # <label>
  [ ! -s "$RUN_QUOTA_LOG" ] \
    || fail "$1: the probe must never call quota-axi, but it ran: $(tr '\n' '|' < "$RUN_QUOTA_LOG")"
}

# --- the retired dispatch coupling ------------------------------------------

# The core retirement: the probe carries no candidate identity, so no
# harness-to-provider table, model prefix matcher, or provider-family mapping can
# exist behind it. Every shape of candidate input is a usage error, and none of
# them reaches a vendor CLI.
test_probe_accepts_no_candidate_identity() {
  local label
  local -a args
  # Both shapes matter. Without a probe name, candidate identity must not stand
  # in for one. WITH a valid probe name, candidate identity must still be
  # refused rather than quietly accepted and ignored - a silently tolerated
  # `--model` is exactly the seam a routing mapping would grow back through.
  for label in harness-flag model-flag provider-flag tuple positional-model \
    probe-with-harness probe-with-model probe-with-tuple probe-with-provider; do
    case "$label" in
      harness-flag) args=(--harness pi) ;;
      model-flag) args=(--model openai-codex/gpt-5.6-terra) ;;
      provider-flag) args=(--provider codex) ;;
      tuple) args=(--harness pi --model openai-codex/gpt-5.6-terra) ;;
      positional-model) args=(grok openai-codex/gpt-5.6-terra) ;;
      probe-with-harness) args=(grok --harness pi) ;;
      probe-with-model) args=(grok --model openai-codex/gpt-5.6-terra) ;;
      probe-with-tuple) args=(grok --harness pi --model openai-codex/gpt-5.6-terra) ;;
      probe-with-provider) args=(grok --provider codex) ;;
    esac
    run_probe "identity-$label" "${args[@]}"
    expect_code 2 "$RUN_RC" "$label must be a usage error, not a candidate verdict"
    [ -z "$RUN_LINE" ] || fail "$label must not emit a fact line: $RUN_LINE"
    assert_grok_never_ran "identity-$label"
    assert_quota_never_read "identity-$label"
  done
  pass "the probe accepts no harness, model, or provider and so can hold no routing mapping"
}

# The retired script read quota to decide eligibility. This one must not, so an
# intake keeps exactly one snapshot and the probe cannot re-derive a route.
test_probe_never_reads_quota() {
  local mode
  for mode in authenticated unauthenticated; do
    run_probe "no-quota-$mode" grok -- "FM_FAKE_GROK_MODE=$mode"
    assert_quota_never_read "no-quota-$mode"
  done
  pass "the probe never reads quota, leaving one intake snapshot to the dispatch owner"
}

# Neither outcome is a verdict, so neither may be encoded in the exit status. A
# caller that branched on the exit status would be reinventing the eligibility
# gate this script was narrowed to remove.
test_probe_result_is_never_an_exit_status_verdict() {
  local mode
  for mode in authenticated unauthenticated garbage empty; do
    run_probe "rc-$mode" grok -- "FM_FAKE_GROK_MODE=$mode"
    expect_code 0 "$RUN_RC" "probe result '$mode' must not be encoded in the exit status"
    [ -n "$RUN_LINE" ] || fail "probe result '$mode' must still print its fact line"
  done
  pass "every probe result exits alike because the script renders no verdict"
}

test_unregistered_probe_is_a_usage_error() {
  local name
  for name in openai codex claude pi ''; do
    if [ -z "$name" ]; then
      run_probe "unregistered-empty"
    else
      run_probe "unregistered-$name" "$name"
    fi
    expect_code 2 "$RUN_RC" "an unregistered probe name must be a usage error"
    assert_grok_never_ran "unregistered-${name:-empty}"
  done
  pass "only a registered probe name runs, and an unregistered one is a usage error"
}

# --- probe classification ---------------------------------------------------

test_authenticated_session_is_reported() {
  run_probe authenticated grok -- "FM_FAKE_GROK_MODE=authenticated"
  expect_code 0 "$RUN_RC" "a completed probe prints its fact"
  assert_field "$RUN_LINE" probe grok "the probe name must be echoed"
  assert_field "$RUN_LINE" status authenticated "an authenticated first line must be recognized"
  assert_grok_argv_safe "authenticated case"
  pass "an authenticated vendor session is reported as ground truth"
}

test_unauthenticated_session_is_reported() {
  run_probe unauthenticated grok -- "FM_FAKE_GROK_MODE=unauthenticated"
  assert_field "$RUN_LINE" status unauthenticated "an unauthenticated first line must be recognized"
  assert_grok_argv_safe "unauthenticated case"
  pass "an unauthenticated vendor session is reported as ground truth"
}

# The exit status is deliberately not the verdict, so a rewritten status line
# must read as indeterminate rather than as a successful authentication.
test_unrecognized_output_is_indeterminate() {
  local mode
  for mode in garbage leading-blank empty; do
    run_probe "indeterminate-$mode" grok -- "FM_FAKE_GROK_MODE=$mode"
    assert_field "$RUN_LINE" status indeterminate "'$mode' output must never read as authenticated"
  done
  pass "unrecognized, blank-led, and silent probe output is indeterminate, never authenticated"
}

test_missing_vendor_cli_is_reported_not_assumed() {
  local case_dir fakebin line rc=0
  case_dir="$TMP_ROOT/grok-absent"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  rm -f "$fakebin/grok"
  line=$(env "PATH=$fakebin:$BASE_PATH" \
    "FM_FAKE_QUOTA_LOG=$case_dir/quota.log" \
    "$SCRIPT" grok </dev/null 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "an absent vendor CLI is a fact, not a usage error"
  assert_field "$line" status unavailable "an absent probe command must be reported"
  assert_field "$line" version none "an absent CLI has no version to report"
  assert_field "$line" versionVerified none "an absent CLI cannot be version-verified"
  pass "an absent vendor CLI is reported rather than assumed authenticated"
}

# --- the bounded, non-destructive envelope ----------------------------------

test_hanging_probe_is_bounded_and_reported() {
  local started finished
  started=$(date +%s)
  run_probe grok-hang grok -- "FM_FAKE_GROK_MODE=hang" "FM_VENDOR_AUTH_PROBE_TIMEOUT=2"
  finished=$(date +%s)
  assert_field "$RUN_LINE" status timeout "a hit bound must be reported as a timeout"
  [ $((finished - started)) -lt 25 ] \
    || fail "the probe was not bounded: took $((finished - started))s against a 2s bound"
  pass "a hanging vendor CLI is hard-bounded, reported, and cannot wedge an intake"
}

# `timeout 0` and the Perl fallback's `alarm 0` both mean "no deadline", so a
# zero bound passed through would silently remove the hard bound entirely. The
# fake hangs for 30s, longer than the 20s default it must fall back to, so the
# two outcomes are distinguishable.
test_zero_bound_falls_back_to_a_real_bound() {
  local started finished value
  for value in 0 00; do
    started=$(date +%s)
    run_probe "bound-zero-$value" grok -- "FM_FAKE_GROK_MODE=hang" "FM_VENDOR_AUTH_PROBE_TIMEOUT=$value"
    finished=$(date +%s)
    assert_field "$RUN_LINE" status timeout "a zero bound must fall back to the default bound, not to no bound"
    [ $((finished - started)) -lt 28 ] \
      || fail "a zero bound removed the hard bound: took $((finished - started))s"
  done
  pass "zero and all-zero bounds fall back to the default instead of removing the hard bound"
}

# A bogus bound must be replaced, not forwarded: `timeout abc` and `timeout -1`
# fail outright, which would turn a healthy probe into a false indeterminate.
test_malformed_bound_is_replaced_not_forwarded() {
  local value
  for value in -1 abc 1.5 ' '; do
    run_probe "bound-${value// /space}" grok -- "FM_FAKE_GROK_MODE=authenticated" "FM_VENDOR_AUTH_PROBE_TIMEOUT=$value"
    assert_field "$RUN_LINE" status authenticated "bound '$value' must be replaced, not forwarded to the bounding command"
  done
  pass "a malformed bound is replaced by the default rather than forwarded"
}

test_probe_never_inherits_caller_stdin() {
  run_probe grok-stdin grok -- "FM_FAKE_GROK_MODE=authenticated"
  [ -n "$RUN_LINE" ] || fail "expected a fact line"
  [ ! -s "$RUN_GROK_STDIN" ] \
    || fail "the probe inherited caller stdin: $(cat "$RUN_GROK_STDIN")"
  pass "the bounded probe runs with stdin closed and cannot read caller input"
}

test_probe_argv_is_fixed_and_non_destructive() {
  local mode
  for mode in authenticated unauthenticated garbage; do
    run_probe "argv-$mode" grok -- "FM_FAKE_GROK_MODE=$mode"
    assert_grok_argv_safe "argv-$mode"
    [ "$(grep -c . "$RUN_GROK_LOG")" -eq 2 ] \
      || fail "argv-$mode: expected exactly one --version and one models call, got: $(tr '\n' '|' < "$RUN_GROK_LOG")"
  done
  pass "the vendor CLI is invoked only through its two fixed, non-destructive argv forms"
}

test_fact_line_carries_no_vendor_output_or_credential_material() {
  run_probe sanitized grok -- "FM_FAKE_GROK_MODE=authenticated"
  assert_not_contains "$RUN_LINE" "You are logged in" "the fact line must not echo raw vendor output"
  assert_not_contains "$RUN_LINE" "grok.com" "the fact line must not echo raw vendor output"
  assert_not_contains "$RUN_LINE" "auth.json" "the fact line must not name a credential path"
  assert_not_contains "$RUN_LINE" "$STDIN_SENTINEL" "the fact line must not echo caller stdin"
  case "$RUN_LINE" in
    *$'\n'*) fail "the fact line must be exactly one line" ;;
  esac
  pass "the fact line is one sanitized line with no raw vendor output or credential material"
}

# --- version disclosure -----------------------------------------------------

# The discriminator strings are un-owned vendor UI text. A version change does
# not silently invalidate the fact, but it is disclosed so it can be re-verified.
test_probe_version_change_is_disclosed() {
  run_probe version-drift grok -- "FM_FAKE_GROK_MODE=authenticated" "FM_FAKE_GROK_VERSION=0.9.0"
  assert_field "$RUN_LINE" version 0.9.0 "the probed CLI version must be recorded"
  assert_field "$RUN_LINE" versionVerified no "an unverified version must be disclosed"
  pass "a vendor CLI version change is recorded and disclosed for re-verification"
}

test_probe_version_match_is_recorded() {
  run_probe version-pinned grok -- "FM_FAKE_GROK_MODE=authenticated"
  assert_field "$RUN_LINE" versionVerified yes "the pinned verified version must be recognized"
  pass "the pinned verified vendor version is recognized"
}

test_help_succeeds_and_names_the_registered_probes() {
  local out rc=0
  out=$("$SCRIPT" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "grok" "--help must name the registered probes"
  pass "--help succeeds and names the registered probes"
}

test_probe_accepts_no_candidate_identity
test_probe_never_reads_quota
test_probe_result_is_never_an_exit_status_verdict
test_unregistered_probe_is_a_usage_error
test_authenticated_session_is_reported
test_unauthenticated_session_is_reported
test_unrecognized_output_is_indeterminate
test_missing_vendor_cli_is_reported_not_assumed
test_hanging_probe_is_bounded_and_reported
test_zero_bound_falls_back_to_a_real_bound
test_malformed_bound_is_replaced_not_forwarded
test_probe_never_inherits_caller_stdin
test_probe_argv_is_fixed_and_non_destructive
test_fact_line_carries_no_vendor_output_or_credential_material
test_probe_version_change_is_disclosed
test_probe_version_match_is_recorded
test_help_succeeds_and_names_the_registered_probes
