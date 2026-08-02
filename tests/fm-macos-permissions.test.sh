#!/usr/bin/env bash
# Behavior tests for fm-macos-permissions.sh's read-only reporting and pane URLs.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-macos-permissions.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_test_tmproot_into TMP_ROOT fm-macos-permissions-tests

make_world() {
  local world="$TMP_ROOT/$1" fakebin
  mkdir -p "$world/home/Library/Mail" "$world/home/.no-mistakes/bin"
  : > "$world/home/.no-mistakes/bin/no-mistakes"
  fakebin=$(fm_fakebin "$world")

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_UNAME:-Darwin}"
SH
  cat > "$fakebin/ls" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_FDA:-missing}" = granted ]; then
  exit 0
fi
printf 'ls: protected path: Operation not permitted\n' >&2
exit 1
SH
  cat > "$fakebin/sqlite3" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -readonly ] || {
  printf '%s\n' 'sqlite3 must be invoked with -readonly' >&2
  exit 98
}
if [ "${FM_FAKE_TCC_READABLE:-no}" != yes ]; then
  printf '%s\n' 'Error: authorization denied' >&2
  exit 1
fi
if [ "${FM_FAKE_TCC_PARTIAL:-no}" = yes ] && [[ "$*" = *'/Library/Application Support/com.apple.TCC/TCC.db'* ]] \
  && [[ "$*" != *"$HOME/Library/Application Support/com.apple.TCC/TCC.db"* ]]; then
  printf '%s\n' 'Error: system TCC database unreadable' >&2
  exit 1
fi
if [ "${FM_FAKE_AUTOMATION_QUERY_PARTIAL:-no}" = yes ] && [[ "$*" = *kTCCServiceAppleEvents* ]] \
  && [[ "$*" = *'/Library/Application Support/com.apple.TCC/TCC.db'* ]] \
  && [[ "$*" != *"$HOME/Library/Application Support/com.apple.TCC/TCC.db"* ]]; then
  printf '%s\n' 'Error: Automation query failed' >&2
  exit 1
fi
case "$*" in
  *kTCCServiceAppleEvents*com.mitchellh.ghostty*)
    printf 'com.mitchellh.ghostty|com.apple.systemevents|2\n'
    if [ "${FM_FAKE_AUTOMATION_CONFLICT:-no}" = yes ]; then
      printf 'com.mitchellh.ghostty|com.apple.systemevents|0\n'
    fi
    ;;
  *kTCCServiceScreenCapture*)
    if [ "${FM_FAKE_MIXED_IDENTITIES:-no}" = yes ] && [[ "$*" != *com.kunchenguid.no-mistakes* ]]; then
      printf '0\n'
    else
      printf '2\n'
    fi
    ;;
  *kTCCServiceAccessibility*) printf '0\n' ;;
  *'SELECT 1 FROM access LIMIT 1;'*) printf '1\n' ;;
esac
SH
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_DAEMON_AUTHORITATIVE:-yes}" = yes ] || exit 1
case "${2:-}" in
  */com.kunchenguid.no-mistakes.daemon.test)
    printf '%s\n' \
      'state = running' \
      "program = $HOME/.no-mistakes/bin/no-mistakes" \
      'arguments = {' \
      "    $HOME/.no-mistakes/bin/no-mistakes" \
      '    daemon' \
      '    run' \
      '}' \
      'pid = 1234'
    ;;
  *)
    printf '%s\n' '1234 0 com.kunchenguid.no-mistakes.daemon.test'
    ;;
esac
SH
  cat > "$fakebin/codesign" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_CODESIGN_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_CODESIGN_LOG"
case "${FM_FAKE_AUTOMATION_ENTITLEMENT:-missing}" in
  present)
    printf '%s\n' '<key>com.apple.security.automation.apple-events</key><true/>'
    ;;
  false)
    printf '%s\n' '<key>com.apple.security.automation.apple-events</key><false/>'
    ;;
  malformed)
    printf '%s\n' '<key>com.apple.security.automation.apple-events</key><string>yes</string>'
    ;;
  unknown)
    printf '%s\n' 'codesign inspection failed' >&2
    exit 1
    ;;
esac
SH
  cat > "$fakebin/open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FAKE_OPEN_LOG"
SH
  cat > "$fakebin/tccutil" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'tccutil must never be invoked' >> "$FM_FAKE_MUTATION_LOG"
exit 99
SH
  chmod +x "$fakebin"/* "$world/home/.no-mistakes/bin/no-mistakes"
  ln -s "$world/home/.no-mistakes/bin/no-mistakes" "$fakebin/no-mistakes"
  printf '%s\n' "$world"
}

run_report() {
  local world=$1
  shift
  HOME="$world/home" PATH="$world/fakebin:$BASE_PATH" \
    FM_FAKE_DAEMON_AUTHORITATIVE="${FM_FAKE_DAEMON_AUTHORITATIVE:-yes}" \
    __CFBundleIdentifier=com.mitchellh.ghostty "$SCRIPT" "$@"
}

test_missing_probe_is_honest() {
  local world out
  world=$(make_world missing)
  out=$(FM_FAKE_FDA=missing FM_FAKE_TCC_READABLE=no run_report "$world")

  assert_contains "$out" 'current invocation protected-path probe: DENIED' \
    'protected-path denial was not reported'
  assert_contains "$out" 'readable TCC databases: 0' \
    'TCC database chicken-and-egg was hidden'
  assert_contains "$out" 'Stored permission statuses therefore remain UNKNOWN' \
    'undetectable grants were guessed'
  assert_contains "$out" 'Automation status is always PER TARGET' \
    'Automation was presented as a blanket grant'
  assert_contains "$out" 'configured path cannot prove the running process image entitlement' \
    'daemon filesystem state was promoted to loaded-image capability'
  pass 'missing and undetectable grants are reported honestly'
}

test_permission_guidance_requires_observed_attribution() {
  local world out docs
  world=$(make_world attribution-guidance)
  out=$(run_report "$world")
  docs=$(<"$ROOT/docs/macos-permissions.md")

  assert_contains "$out" \
    'Protected-path work needs the exact responsible entry macOS observes; add Ghostty only when macOS names it.' \
    'Ghostty Full Disk Access guidance assumed responsibility'
  assert_contains "$out" \
    'The first-use Allow dialog establishes the exact controller-to-target pair for terminal-driven app automation' \
    'terminal Automation guidance assumed a controller-to-target pair'
  assert_contains "$out" \
    'approve Claude only when macOS names it as controller' \
    'Claude Automation guidance assumed the controller identity'
  assert_contains "$docs" \
    'only when macOS attributes that protected-path service to Ghostty.' \
    'documentation assumed Ghostty Full Disk Access responsibility'
  assert_contains "$docs" \
    'use the first-use Allow dialog to identify the exact controller-to-target pair macOS observes.' \
    'documentation did not require observed Automation attribution'
  case "$out$docs" in
    *'Apple Events from Ghostty to System Events'*|*'The relationship is Claude Code controlling'*)
      fail 'fixed controller or target attribution remained in guidance'
      ;;
  esac
  pass 'permission guidance requires macOS-observed attribution'
}

test_readable_database_reports_stored_rows() {
  local world out ghostty_section daemon_section
  world=$(make_world readable)
  mkdir -p "$world/home/Library/Application Support/com.apple.TCC"
  : > "$world/home/Library/Application Support/com.apple.TCC/TCC.db"

  out=$(FM_FAKE_FDA=granted FM_FAKE_TCC_READABLE=yes run_report "$world")
  ghostty_section=$(printf '%s\n' "$out" | sed -n '/^Ghostty (terminal launcher)/,/^$/p')
  daemon_section=$(printf '%s\n' "$out" | sed -n '/^no-mistakes daemon configured target/,/^$/p')

  assert_contains "$out" 'current invocation protected-path probe: ACCESSIBLE' \
    'successful behavioral Full Disk Access probe was lost'
  assert_contains "$ghostty_section" 'status=UNKNOWN (STORED ALLOW ONLY)' \
    'stored Ghostty Screen Recording allow was presented as effective'
  assert_contains "$ghostty_section" 'status=UNKNOWN (STORED DENIAL ONLY)' \
    'stored Ghostty Accessibility denial was presented as effective'
  printf '%s\n' "$daemon_section" \
    | grep -E 'Screen Recording +requirement=REQUIRED FOR COMPUTER USE +status=UNKNOWN' >/dev/null \
    || fail 'daemon Screen Recording identity was inferred from stored or cross-service evidence'
  printf '%s\n' "$daemon_section" \
    | grep -E 'Accessibility +requirement=REQUIRED FOR COMPUTER USE +status=UNKNOWN' >/dev/null \
    || fail 'daemon Accessibility identity was inferred from stored or cross-service evidence'
  assert_contains "$daemon_section" 'exact Screen Recording entry macOS observes' \
    'daemon Screen Recording guidance lacked a service-specific identity boundary'
  assert_contains "$daemon_section" 'exact Accessibility entry macOS observes' \
    'daemon Accessibility guidance reused another service identity'
  assert_contains "$out" 'com.mitchellh.ghostty -> com.apple.systemevents: UNKNOWN (STORED ALLOW ONLY)' \
    'stored Ghostty-to-System Events relationship was presented as effective'
  pass 'stored TCC rows remain unknown effective status'
}

test_mixed_identity_evidence_is_unknown() {
  local world out daemon_section
  world=$(make_world mixed-identities)
  mkdir -p "$world/home/Library/Application Support/com.apple.TCC"
  : > "$world/home/Library/Application Support/com.apple.TCC/TCC.db"

  out=$(FM_FAKE_FDA=granted FM_FAKE_TCC_READABLE=yes FM_FAKE_MIXED_IDENTITIES=yes \
    run_report "$world")
  daemon_section=$(printf '%s\n' "$out" | sed -n '/^no-mistakes daemon/,/^$/p')

  printf '%s\n' "$daemon_section" \
    | grep -E 'Screen Recording +requirement=REQUIRED FOR COMPUTER USE +status=UNKNOWN' >/dev/null \
    || fail 'mixed candidate identities produced a conclusive stored status'
  pass 'mixed candidate identity evidence remains unknown'
}

test_partial_database_evidence_is_unknown() {
  local world out
  world=$(make_world partial-database)
  mkdir -p "$world/home/Library/Application Support/com.apple.TCC"
  : > "$world/home/Library/Application Support/com.apple.TCC/TCC.db"

  out=$(FM_FAKE_FDA=granted FM_FAKE_TCC_READABLE=yes FM_FAKE_TCC_PARTIAL=yes \
    run_report "$world")

  assert_contains "$out" 'readable TCC databases: 1 (at least one expected database is unreadable)' \
    'partial TCC visibility was not disclosed'
  assert_contains "$out" 'UNKNOWN (not all expected TCC databases are readable in this context)' \
    'partial TCC evidence produced conclusive Automation relationships'
  pass 'partial database evidence remains unknown'
}

test_failed_entitlement_probe_is_unknown() {
  local world out codex_section
  world=$(make_world entitlement-unknown)
  : > "$world/fakebin/codex"
  chmod +x "$world/fakebin/codex"

  out=$(FM_FAKE_AUTOMATION_ENTITLEMENT=unknown run_report "$world")
  codex_section=$(printf '%s\n' "$out" | sed -n '/^Codex PATH command target/,/^$/p')

  printf '%s\n' "$codex_section" \
    | grep -E 'Automation +requirement=CONDITIONAL +status=UNKNOWN' >/dev/null \
    || fail 'failed entitlement inspection was reported conclusively'
  assert_contains "$codex_section" 'could not be inspected' \
    'failed entitlement inspection lacked an honest explanation'
  pass 'failed entitlement inspection remains unknown'
}

test_entitlement_boolean_is_parsed() {
  local world out codex_section
  world=$(make_world entitlement-values)
  : > "$world/fakebin/codex"
  chmod +x "$world/fakebin/codex"

  out=$(FM_FAKE_AUTOMATION_ENTITLEMENT=false run_report "$world")
  codex_section=$(printf '%s\n' "$out" | sed -n '/^Codex PATH command target/,/^$/p')
  assert_contains "$codex_section" 'codesign reports no true Apple Events entitlement' \
    'false Apple Events entitlement was treated as present'
  printf '%s\n' "$codex_section" \
    | grep -E 'Automation +requirement=CONDITIONAL +status=UNKNOWN' >/dev/null \
    || fail 'PATH command entitlement was promoted to controller capability'

  out=$(FM_FAKE_AUTOMATION_ENTITLEMENT=malformed run_report "$world")
  codex_section=$(printf '%s\n' "$out" | sed -n '/^Codex PATH command target/,/^$/p')
  printf '%s\n' "$codex_section" \
    | grep -E 'Automation +requirement=CONDITIONAL +status=UNKNOWN' >/dev/null \
    || fail 'non-Boolean Apple Events entitlement was reported conclusively'
  pass 'Apple Events entitlement requires an explicit Boolean value'
}

test_partial_automation_query_is_unknown() {
  local world out
  world=$(make_world automation-query-partial)
  mkdir -p "$world/home/Library/Application Support/com.apple.TCC"
  : > "$world/home/Library/Application Support/com.apple.TCC/TCC.db"

  out=$(FM_FAKE_TCC_READABLE=yes FM_FAKE_AUTOMATION_QUERY_PARTIAL=yes run_report "$world")

  assert_contains "$out" 'UNKNOWN (the TCC schema could not be queried completely)' \
    'partial Automation query evidence was not marked unknown'
  case "$out" in
    *'com.mitchellh.ghostty -> com.apple.systemevents: GRANTED'*)
      fail 'partial Automation query evidence produced a conclusive relationship'
      ;;
  esac
  pass 'partial Automation query evidence remains unknown'
}

test_bundle_hint_does_not_override_stored_evidence() {
  local world out ghostty_section
  world=$(make_world bundle-hint)
  mkdir -p "$world/home/Library/Application Support/com.apple.TCC"
  : > "$world/home/Library/Application Support/com.apple.TCC/TCC.db"

  out=$(FM_FAKE_FDA=granted FM_FAKE_TCC_READABLE=yes run_report "$world")
  ghostty_section=$(printf '%s\n' "$out" | sed -n '/^Ghostty (terminal launcher)/,/^$/p')

  assert_contains "$out" 'unverified bundle environment hint: com.mitchellh.ghostty (not used for attribution)' \
    'bundle environment value was not marked unverified'
  printf '%s\n' "$ghostty_section" \
    | grep -E 'Full Disk Access +requirement=CONDITIONAL +status=UNKNOWN \(NO MATCHING STORED ROW\)' >/dev/null \
    || fail 'bundle environment hint overrode stored Ghostty evidence'
  pass 'bundle environment hint never controls permission attribution'
}

test_daemon_path_requires_running_launch_job() {
  local world out daemon_section
  world=$(make_world daemon-unresolved)

  out=$(FM_FAKE_DAEMON_AUTHORITATIVE=no run_report "$world")
  daemon_section=$(printf '%s\n' "$out" | sed -n '/^no-mistakes daemon/,/^$/p')

  assert_contains "$daemon_section" 'UNKNOWN: active launch job not resolved' \
    'interactive PATH was presented as the daemon identity'
  assert_contains "$daemon_section" 'authoritative launch job: UNKNOWN' \
    'missing launch-job evidence was not disclosed'
  printf '%s\n' "$daemon_section" | grep -E 'status=(ENTITLEMENT NOT PRESENT|PER TARGET)' >/dev/null \
    && fail 'unresolved daemon path produced a conclusive entitlement status'
  pass 'daemon identity requires one running authoritative launch job'
}

test_active_daemon_entitlement_stays_unknown() {
  local world out daemon_section codesign_log
  world=$(make_world daemon-entitlement)
  codesign_log="$world/codesign.log"

  out=$(FM_FAKE_AUTOMATION_ENTITLEMENT=present FM_FAKE_CODESIGN_LOG="$codesign_log" \
    run_report "$world")
  daemon_section=$(printf '%s\n' "$out" | sed -n '/^no-mistakes daemon configured target/,/^$/p')

  printf '%s\n' "$daemon_section" \
    | grep -E 'Automation +requirement=CONDITIONAL +status=UNKNOWN' >/dev/null \
    || fail 'configured daemon path produced a conclusive loaded-image capability'
  [ ! -e "$codesign_log" ] || fail 'configured daemon path was inspected as the loaded process image'
  pass 'active daemon entitlement remains unknown without live-image proof'
}

test_path_absence_is_not_installation_status() {
  local world out
  world=$(make_world path-absence)
  unlink "$world/fakebin/no-mistakes"

  out=$(run_report "$world")

  assert_contains "$out" 'Claude Code PATH command target (UNKNOWN: not found on PATH)' \
    'Claude PATH absence was reported as installation state'
  assert_contains "$out" 'Codex PATH command target (UNKNOWN: not found on PATH)' \
    'Codex PATH absence was reported as installation state'
  assert_contains "$out" 'no-mistakes CLI PATH entry (UNKNOWN: not found on PATH)' \
    'no-mistakes PATH absence was reported as installation state'
  case "$out" in
    *'not installed'*) fail 'PATH absence was reported as not installed' ;;
  esac
  pass 'PATH absence remains a limited unknown observation'
}

test_conflicting_automation_rows_are_unknown() {
  local world out
  world=$(make_world automation-conflict)
  mkdir -p "$world/home/Library/Application Support/com.apple.TCC"
  : > "$world/home/Library/Application Support/com.apple.TCC/TCC.db"

  out=$(FM_FAKE_TCC_READABLE=yes FM_FAKE_AUTOMATION_CONFLICT=yes run_report "$world")

  assert_contains "$out" \
    'com.mitchellh.ghostty -> com.apple.systemevents: UNKNOWN (CONFLICTING STORED ROWS)' \
    'conflicting Automation records were not collapsed to unknown'
  case "$out" in
    *'com.mitchellh.ghostty -> com.apple.systemevents: UNKNOWN (STORED ALLOW ONLY)'*)
      fail 'conflicting Automation records also emitted a conclusive-looking allow row'
      ;;
  esac
  pass 'conflicting Automation records collapse to one unknown relationship'
}

test_exact_settings_urls_and_no_other_mutation() {
  local world pane expected log mutation_log out
  world=$(make_world panes)
  log="$world/open.log"
  mutation_log="$world/mutation.log"
  : > "$log"

  while IFS='|' read -r pane expected; do
    out=$(FM_FAKE_OPEN_LOG="$log" FM_FAKE_MUTATION_LOG="$mutation_log" \
      run_report "$world" --open "$pane")
    if [ "$pane" = automation ]; then
      assert_contains "$out" "Opened $expected; review or change target-specific relationships there." \
        'Automation pane was presented as the first-use approval flow'
    elif [ "$pane" = screen-recording ]; then
      assert_contains "$out" "Opened $expected; review, change, or manually add screen-recording access there." \
        'Screen Recording pane was presented as the only first-use approval flow'
    else
      assert_contains "$out" "Opened $expected; the human must make the grant." \
        "$pane did not report the human approval boundary"
    fi
  done <<'EOF'
full-disk-access|x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
automation|x-apple.systempreferences:com.apple.preference.security?Privacy_Automation
screen-recording|x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
accessibility|x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
EOF

  [ "$(wc -l < "$log" | tr -d ' ')" -eq 4 ] || fail 'unexpected number of open calls'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles' "$log" >/dev/null \
    || fail 'Full Disk Access URL drifted'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_Automation' "$log" >/dev/null \
    || fail 'Automation URL drifted'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' "$log" >/dev/null \
    || fail 'Screen Recording URL drifted'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' "$log" >/dev/null \
    || fail 'Accessibility URL drifted'
  [ ! -e "$mutation_log" ] || fail 'the helper invoked tccutil'
  pass 'only the exact requested System Settings panes are opened'
}

test_non_macos_refuses() {
  local world out code
  world=$(make_world non-macos)
  set +e
  out=$(FM_FAKE_UNAME=Linux run_report "$world" 2>&1)
  code=$?
  set -e

  [ "$code" -eq 1 ] || fail "non-macOS exit was $code instead of 1"
  assert_contains "$out" 'supports macOS only' 'non-macOS refusal was unclear'
  pass 'non-macOS hosts fail clearly without probing or opening settings'
}

test_missing_probe_is_honest
test_permission_guidance_requires_observed_attribution
test_readable_database_reports_stored_rows
test_mixed_identity_evidence_is_unknown
test_partial_database_evidence_is_unknown
test_failed_entitlement_probe_is_unknown
test_entitlement_boolean_is_parsed
test_partial_automation_query_is_unknown
test_bundle_hint_does_not_override_stored_evidence
test_daemon_path_requires_running_launch_job
test_active_daemon_entitlement_stays_unknown
test_path_absence_is_not_installation_status
test_conflicting_automation_rows_are_unknown
test_exact_settings_urls_and_no_other_mutation
test_non_macos_refuses
