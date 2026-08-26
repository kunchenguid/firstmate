#!/usr/bin/env bash
# tests/fm-sessionstart-regeln.test.sh - behavior test for the Kernregeln
# block bin/fm-sessionstart-run.sh appends after the digest, per AGENTS.md
# "Rule database and drift brake": "SessionStart injects the core set
# (bin/fm-sessionstart-run.sh -> fm-regeln session-start)".
#
# Runs the REAL bin/fm-sessionstart-run.sh (and the small set of libs it
# sources: fm-gate-refuse-lib.sh, fm-primary-scope-lib.sh,
# fm-session-lock-lib.sh, fm-hook-host-lib.sh) inside a throwaway fixture
# root, with bin/fm-session-start.sh replaced by a trivial stub - the digest
# body itself is tests/fm-sessionstart-nudge.test.sh's territory; this file
# owns only the Kernregeln append. fm-regeln resolution is mocked via
# FM_REGELN_BIN, the same override bin/fm-prompt-regeln.sh already uses for
# its own tests, so this fixture never touches a real venv/DB.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-regeln)
fm_git_identity fmtest fmtest@example.invalid

MISSING_LINE='WRIT_FM: MISSING - Kernregeln nicht geladen (bin/fm-regeln ingest)'
STUB_DIGEST='SESSION START STUB DIGEST'

# A bare PATH, so a fixture that expects fm-regeln to be UNRESOLVABLE cannot
# accidentally pick up a real one from the host, and so `command -v timeout`
# still finds coreutils.
RUN_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# make_fixture <dir>: a primary root the run wrapper accepts (git repo on
# main, bin/, state/, AGENTS.md - the same minimal shape
# tests/fm-sessionstart-nudge.test.sh's make_run_primary uses), carrying the
# REAL fm-sessionstart-run.sh plus its sourced libs, and a stub
# fm-session-start.sh so this test exercises only the Kernregeln append, not
# the full digest.
make_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-sessionstart-run.sh" "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" \
    "$ROOT/bin/fm-proctree-lib.sh" \
    "$dir/bin/"
  cat > "$dir/bin/fm-session-start.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$STUB_DIGEST"
SH
  chmod +x "$dir/bin/"*.sh
}

# make_mock_regeln <path> <exit-code> <stdout-line> [record-file]: a stand-in
# for bin/fm-regeln that fm-sessionstart-run.sh's FM_REGELN_BIN resolution
# picks up ahead of any colocated or PATH copy - the same precedence
# bin/fm-prompt-regeln.sh documents and this file's header repeats.
make_mock_regeln() {
  local path=$1 rc=$2 line=$3 record=${4:-}
  {
    printf '#!/usr/bin/env bash\n'
    [ -n "$record" ] && printf 'printf "%%s\\n" "$*" >> %q\n' "$record"
    [ -n "$line" ] && printf 'printf "%%s\\n" %q\n' "$line"
    printf 'exit %s\n' "$rc"
  } > "$path"
  chmod +x "$path"
}

run_hook() {  # <root> [FM_REGELN_BIN override or empty] -- <extra env...>
  local root=$1 regeln_bin=$2
  shift 2
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u GROK_HOOK_EVENT \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$RUN_PATH" \
    ${regeln_bin:+FM_REGELN_BIN="$regeln_bin"} "$@" \
    "$root/bin/fm-sessionstart-run.sh" --source startup </dev/null
}

test_working_fm_regeln_delivers_kernregeln() {
  local root="$TMP_ROOT/mit-fm-regeln" out status=0
  local mock="$TMP_ROOT/mock-ok.sh" record="$TMP_ROOT/mock-ok.record"
  make_fixture "$root"
  make_mock_regeln "$mock" 0 'MOCKED_KERNREGEL_TEXT_LINE' "$record"

  out=$(run_hook "$root" "$mock") || status=$?
  expect_code 0 "$status" "run wrapper with a working fm-regeln"
  assert_contains "$out" "$STUB_DIGEST" "the stub digest itself did not print"
  assert_contains "$out" "MOCKED_KERNREGEL_TEXT_LINE" \
    "a working fm-regeln's core rule set was not appended to session start"
  assert_not_contains "$out" "$MISSING_LINE" \
    "a working fm-regeln still printed the MISSING diagnostic"
  [ -f "$record" ] || fail "the mock fm-regeln was never invoked"
  [ "$(cat "$record")" = "session-start --geltung firstmate" ] \
    || fail "fm-sessionstart-run.sh did not call fm-regeln with the documented arguments, got: $(cat "$record" 2>/dev/null)"
  pass "run wrapper: a working fm-regeln's core VERFASSUNG set is appended after the digest"
}

test_unresolvable_fm_regeln_reports_missing() {
  local root="$TMP_ROOT/ohne-fm-regeln" out status=0
  make_fixture "$root"
  # No FM_REGELN_BIN, no colocated bin/fm-regeln in the fixture, and a bare
  # PATH with nothing named fm-regeln on it - resolution must fail entirely.
  out=$(run_hook "$root" "") || status=$?
  expect_code 0 "$status" "run wrapper with no resolvable fm-regeln"
  assert_contains "$out" "$STUB_DIGEST" "session start must still run when fm-regeln is unresolvable"
  assert_contains "$out" "$MISSING_LINE" \
    "an unresolvable fm-regeln did not report the fail-open MISSING line"
  [ "$(printf '%s\n' "$out" | grep -Fc "$MISSING_LINE")" = 1 ] \
    || fail "the MISSING line must appear exactly once, got: $out"
  pass "run wrapper: an unresolvable fm-regeln fails open with exactly one MISSING line, exit 0"
}

test_failing_fm_regeln_reports_missing() {
  local root="$TMP_ROOT/kaputte-db" out status=0
  local mock="$TMP_ROOT/mock-fail.sh"
  make_fixture "$root"
  make_mock_regeln "$mock" 1 ''

  out=$(run_hook "$root" "$mock") || status=$?
  expect_code 0 "$status" "run wrapper with a failing fm-regeln (e.g. missing DB)"
  assert_contains "$out" "$MISSING_LINE" \
    "a non-zero fm-regeln exit (missing/unbuilt DB) did not report the MISSING line"
  pass "run wrapper: a failing fm-regeln (missing DB) fails open with the MISSING line"
}

test_empty_success_is_silent_not_missing() {
  local root="$TMP_ROOT/leere-kernregeln" out status=0
  local mock="$TMP_ROOT/mock-empty.sh"
  make_fixture "$root"
  make_mock_regeln "$mock" 0 ''

  out=$(run_hook "$root" "$mock") || status=$?
  expect_code 0 "$status" "run wrapper with a clean-exit empty fm-regeln answer"
  assert_contains "$out" "$STUB_DIGEST" "the stub digest itself did not print"
  assert_not_contains "$out" "$MISSING_LINE" \
    "a clean exit with no core rules configured must not be reported as MISSING"
  pass "run wrapper: a clean exit with no core rules is silent, not MISSING"
}

test_working_fm_regeln_delivers_kernregeln
test_unresolvable_fm_regeln_reports_missing
test_failing_fm_regeln_reports_missing
test_empty_success_is_silent_not_missing
