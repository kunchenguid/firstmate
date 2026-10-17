#!/usr/bin/env bash
# Behavior tests for bin/fm-doctor.sh: a read-only, exit-coded rendering of the
# facts other owners report, mapped through docs/doctor-checks.json.
#
# The doctor runs real bootstrap (detect-only, network skipped) against a fake
# toolchain, so each case provokes a real bootstrap line and asserts the doctor
# renders it under its inventory id and severity. Fixture inventories pin the
# self-validation and the unmapped-line failure without touching the tracked
# inventory. Every case pins FM_ROOT_OVERRIDE to the non-git case home so the
# ambient checkout (CI runs on a feature branch) cannot leak a TANGLE line.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required for doctor tests" >&2; exit 1; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-doctor-tests)
DOCTOR="$ROOT/bin/fm-doctor.sh"
INVENTORY="$ROOT/docs/doctor-checks.json"
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# A toolchain where every bootstrap-required tool is present and current, so a
# home with no problems makes bootstrap silent.
make_toolchain() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}:${2:-}" = auth:status ] && [ "${FM_FAKE_GH_AUTH:-ok}" != ok ] && exit 1
exit 0
SH
  chmod +x "$fakebin/gh"
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.51
  fm_fake_version_tool "$fakebin" no-mistakes FM_FAKE_NO_MISTAKES_VERSION 'no-mistakes version v1.46.0 (fake)'
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = get ] && [ "${2:-}" = --help ] && printf '%s\n' 'Usage: treehouse get [--lease]'
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:) printf '%s\n' 0.2.6 ;;
  update:--help) printf '%s\n' 'usage: tasks-axi update <id>' '  --archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tasks-axi"
  ln -s "$(command -v jq)" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

new_case() {  # <name> -> case dir with home/ and fakebin/
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data"
  make_toolchain "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# doctor <case-dir> [args...]: run the doctor against the case home; sets
# DOCTOR_OUT, DOCTOR_ERR, and DOCTOR_RC.
doctor() {
  local dir=$1
  shift
  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    "$DOCTOR" "$@" 2>"$dir/stderr") || DOCTOR_RC=$?
  DOCTOR_ERR=$(cat "$dir/stderr")
}

status_of() {  # <json> <check-id>
  printf '%s\n' "$1" | jq -r --arg id "$2" '[.checks[] | select(.id == $id) | .status][0] // "absent"'
}

assert_status() {  # <json> <check-id> <status> <label>
  local got
  got=$(status_of "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: $2 expected $3, got $got"$'\n'"$1"
}

test_silent_home_maps_every_line() {
  local dir id
  dir=$(new_case silent)
  doctor "$dir" --json
  for id in doctor/jq doctor/inventory doctor/bootstrap doctor/unmapped-line \
    tools/missing tools/missing-manual tools/presentation tools/provenance no-mistakes/agents permissions/claude-fm-scripts backend/invalid backend/herdr-launcher \
    config/crew-dispatch fleet/tangle fleet/backlog-reconcile fleet/home-summary \
    fleet/secondmate-handoff fleet/info config/role; do
    assert_status "$DOCTOR_OUT" "$id" ok "silent home"
  done
  assert_status "$DOCTOR_OUT" auth/github skip "network checks skip"
  assert_status "$DOCTOR_OUT" config/startup-memory-budget skip "sweep-only lines skip"
  [ "$(printf '%s\n' "$DOCTOR_OUT" | jq -r .verdict)" != fail ] || fail "silent home verdict failed: $DOCTOR_OUT"
  [ "$DOCTOR_RC" -eq 0 ] || fail "silent home exited $DOCTOR_RC"
  pass "a silent bootstrap renders every mapped check ok and exits 0"
}

test_provoked_lines_render_their_ids() {
  local dir
  dir=$(new_case missing-tool)
  rm -f "$dir/fakebin/quota-axi"
  doctor "$dir" --json
  assert_status "$DOCTOR_OUT" tools/missing fail "missing tool"
  [ "$DOCTOR_RC" -eq 1 ] || fail "a failed check must exit 1, got $DOCTOR_RC"
  assert_contains "$(printf '%s\n' "$DOCTOR_OUT" | jq -r '.checks[] | select(.id == "tools/missing") | .evidence')" \
    "MISSING: quota-axi" "missing tool evidence"

  dir=$(new_case floor)
  doctor_env_floor() {
    DOCTOR_RC=0
    DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
      FM_FAKE_GH_AXI_VERSION=0.1.0 FM_FAKE_LAVISH_AXI_VERSION=0.1.0 "$DOCTOR" --json 2>/dev/null) || DOCTOR_RC=$?
  }
  doctor_env_floor
  assert_status "$DOCTOR_OUT" tools/missing fail "floor miss"
  assert_status "$DOCTOR_OUT" tools/presentation warn "lavish floor miss"

  dir=$(new_case backend)
  printf '%s\n' bogus > "$dir/home/config/backend"
  doctor "$dir" --json
  assert_status "$DOCTOR_OUT" backend/invalid fail "bad backend"

  dir=$(new_case dispatch)
  printf '%s\n' '{"rules":[' > "$dir/home/config/crew-dispatch.json"
  doctor "$dir" --json
  assert_status "$DOCTOR_OUT" config/crew-dispatch fail "bad crew dispatch"

  dir=$(new_case summary)
  printf '%s\n' '[2026-10-01T00:00:00Z] first failure' '[2026-10-02T00:00:00Z] second failure' \
    > "$dir/home/state/.home-summary-refresh.log"
  doctor "$dir" --json
  assert_status "$DOCTOR_OUT" fleet/home-summary warn "home summary"

  dir=$(new_case handoff)
  mkdir -p "$dir/home/data/handoff"
  printf '%s\n' '- [ ] queued item' > "$dir/home/data/handoff/mate.outbox.md"
  doctor "$dir" --json
  assert_status "$DOCTOR_OUT" fleet/secondmate-handoff warn "pending handoff"

  dir=$(new_case provenance)
  mkdir -p "$dir/upstream"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/upstream/pinned-tool"
  chmod +x "$dir/upstream/pinned-tool"
  ln -s "$dir/upstream/pinned-tool" "$dir/fakebin/pinned-tool"
  printf 'pinned-tool %s/patched/\n' "$dir" > "$dir/home/config/tool-provenance"
  doctor "$dir" --json
  assert_status "$DOCTOR_OUT" tools/provenance warn "replaced pinned build"

  dir=$(new_case nm-agents)
  mkdir -p "$dir/nm"
  printf '%s\n' 'agent: [nosuchagent]' > "$dir/nm/config.yaml"
  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_BOOTSTRAP_NO_MISTAKES_HOME="$dir/nm" "$DOCTOR" --json 2>/dev/null) || DOCTOR_RC=$?
  assert_status "$DOCTOR_OUT" no-mistakes/agents warn "missing no-mistakes agent"

  dir=$(new_case claude-perms)
  printf '%s\n' '{"permissions":{"defaultMode":"auto"}}' > "$dir/user-settings.json"
  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_BOOTSTRAP_CLAUDE_USER_SETTINGS="$dir/user-settings.json" \
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=claude "$DOCTOR" --json 2>/dev/null) || DOCTOR_RC=$?
  assert_status "$DOCTOR_OUT" permissions/claude-fm-scripts warn "auto mode without a bin/fm-* rule"

  dir=$(new_case herdr-launcher)
  printf '%s\n' herdr > "$dir/home/config/backend"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "session list") printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s"}]}\n' "$HERDR_SOCKET_PATH" ;;
  "pane get") exit 1 ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    HERDR_PANE_ID=w1:p9 HERDR_SOCKET_PATH="$dir/herdr.sock" "$DOCTOR" --json 2>/dev/null) || DOCTOR_RC=$?
  assert_status "$DOCTOR_OUT" backend/herdr-launcher fail "stale launcher pane"
  [ "$DOCTOR_RC" -eq 1 ] || fail "a stale launcher pane must exit 1, got $DOCTOR_RC"
  assert_status "$DOCTOR_OUT" doctor/unmapped-line ok "provoked lines are all mapped"
  pass "provoked bootstrap lines render under their inventory ids and severities"
}

test_tangle_is_rendered() {
  local dir repo
  dir=$(new_case tangle)
  repo="$dir/primary"
  fm_git_identity
  git init -q -b main "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" checkout -q -b feature
  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$repo" \
    "$DOCTOR" --json 2>/dev/null) || DOCTOR_RC=$?
  assert_status "$DOCTOR_OUT" fleet/tangle fail "tangled primary"
  [ "$DOCTOR_RC" -eq 1 ] || fail "tangle must exit 1, got $DOCTOR_RC"
  pass "a tangled primary renders fleet/tangle as a failure"
}

# mutate <name> <jq-filter>: a fixture inventory derived from the tracked one.
mutate() {
  local out="$TMP_ROOT/inventory-$1.json"
  jq "$2" "$INVENTORY" > "$out"
  printf '%s\n' "$out"
}

test_unmapped_line_fails() {
  local dir inventory
  dir=$(new_case unmapped)
  rm -f "$dir/fakebin/quota-axi"
  inventory=$(mutate unmapped 'del(.checks[] | select(.prefix == "MISSING"))')
  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_DOCTOR_INVENTORY="$inventory" "$DOCTOR" --json 2>/dev/null) || DOCTOR_RC=$?
  assert_status "$DOCTOR_OUT" doctor/unmapped-line fail "unknown prefix"
  [ "$DOCTOR_RC" -eq 1 ] || fail "an unmapped line must exit 1, got $DOCTOR_RC"
  pass "a bootstrap line the inventory does not map fails instead of passing silently"
}

test_invalid_inventories_fail() {
  local dir label filter expected inventory
  dir=$(new_case invalid)
  while IFS='^' read -r label filter expected; do
    [ -n "$label" ] || continue
    inventory=$(mutate "$label" "$filter")
    DOCTOR_RC=0
    DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
      FM_DOCTOR_INVENTORY="$inventory" "$DOCTOR" --json 2>/dev/null) || DOCTOR_RC=$?
    assert_status "$DOCTOR_OUT" doctor/inventory fail "$label"
    assert_contains "$(printf '%s\n' "$DOCTOR_OUT" | jq -r '.checks[] | select(.id == "doctor/inventory") | .detail[]')" \
      "$expected" "$label"
    [ "$DOCTOR_RC" -eq 1 ] || fail "$label: invalid inventory must exit 1, got $DOCTOR_RC"
    [ "$(printf '%s\n' "$DOCTOR_OUT" | jq '[.checks[] | select(.area != "doctor")] | length')" = 0 ] \
      || fail "$label: checks ran against an invalid inventory"
  done <<'ROWS'
duplicate-id^.checks += [.checks[0]]^duplicate check id tools/missing
unknown-area^.checks[0].area = "nowhere" | .checks[0].id = "nowhere/missing"^unknown area nowhere
missing-owner^.checks[0].owner = "bin/fm-no-such-owner.sh"^owner bin/fm-no-such-owner.sh does not exist
owner-outside-bin^.checks[0].owner = "../evil.sh"^owner ../evil.sh is not under bin/
mutating-bootstrap^del(.sources.bootstrap.env.FM_BOOTSTRAP_DETECT_ONLY)^must run with FM_BOOTSTRAP_DETECT_ONLY=1
bad-version^.version = 2^version must be 1
ROWS
  pass "fixture inventories with duplicate ids, unknown areas, bad owners, or a mutating source fail validation"
}

# write_network_report <home> <phases> [line...]: a published deferred-network
# record, as bin/fm-startup-network.sh leaves it after a finished run.
write_network_report() {
  local home=$1 phases=$2
  shift 2
  printf '%s\n' generation=1 state=done started=100 finished=105 "phases=$phases" \
    report_published=1 locked=1 > "$home/state/.startup-network.status"
  : > "$home/state/.startup-network.report"
  [ $# -eq 0 ] || printf '%s\n' "$@" > "$home/state/.startup-network.report"
}

test_network_checks() {
  local dir
  dir=$(new_case network)
  write_network_report "$dir/home" probe,sweeps \
    'FLEET_SYNC: alpha: STUCK: on feature, 3 commits behind main - needs attention'
  doctor "$dir" --json
  assert_status "$DOCTOR_OUT" auth/github skip "auth without --network"
  assert_status "$DOCTOR_OUT" fleet/sync skip "report without --network"
  doctor "$dir" --json --network
  assert_status "$DOCTOR_OUT" auth/github ok "fresh auth probe"
  assert_status "$DOCTOR_OUT" fleet/sync warn "STUCK clone in the last report"
  assert_status "$DOCTOR_OUT" fleet/secondmate-sync ok "finished report without the prefix"
  assert_status "$DOCTOR_OUT" doctor/unmapped-line ok "report prose is not an unmapped bootstrap line"

  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_FAKE_GH_AUTH=fail "$DOCTOR" --json --network 2>/dev/null) || DOCTOR_RC=$?
  assert_status "$DOCTOR_OUT" auth/github fail "failed auth probe"
  [ "$DOCTOR_RC" -eq 1 ] || fail "failed auth must exit 1, got $DOCTOR_RC"

  write_network_report "$dir/home" probe
  doctor "$dir" --json --network
  assert_status "$DOCTOR_OUT" fleet/sync skip "probe-only report cannot clear sweep checks"

  rm -f "$dir/home/state/.startup-network.status" "$dir/home/state/.startup-network.report"
  doctor "$dir" --json --network
  assert_status "$DOCTOR_OUT" fleet/secondmate-liveness skip "no report yet"
  assert_status "$DOCTOR_OUT" supervision/startup-network info "no report yet is informational"
  pass "--network adds a fresh auth probe and reads the last finished network report"
}

test_toon_and_json_agree() {
  local dir json toon ids_json ids_toon
  dir=$(new_case parity)
  rm -f "$dir/fakebin/quota-axi"
  doctor "$dir" --json
  json=$DOCTOR_OUT
  doctor "$dir"
  toon=$DOCTOR_OUT
  [ "$DOCTOR_RC" -eq 1 ] || fail "TOON run must keep the failing exit status"
  assert_contains "$toon" "verdict: fail" "TOON verdict"
  assert_contains "$toon" "findings[" "TOON findings"
  assert_contains "$toon" "help[" "TOON help"
  ids_json=$(printf '%s\n' "$json" | jq -r '.checks[] | "\(.id),\(.status)"')
  ids_toon=$(printf '%s\n' "$toon" | sed -n '/^checks\[/,/^[a-z]/p' | sed -n 's/^  \([^,]*\),\([a-z]*\),.*/\1,\2/p')
  [ "$ids_json" = "$ids_toon" ] || fail "TOON and JSON disagree on checks"$'\n'"$ids_json"$'\n---\n'"$ids_toon"
  pass "TOON and --json render the same checks and statuses"
}

test_area_and_usage() {
  local dir
  dir=$(new_case area)
  doctor "$dir" --json --area tools
  [ "$(printf '%s\n' "$DOCTOR_OUT" | jq -r '[.checks[] | .area] | unique | join(",")')" = "doctor,tools" ] \
    || fail "--area tools ran other areas: $DOCTOR_OUT"
  doctor "$dir" --area nowhere
  [ "$DOCTOR_RC" -eq 2 ] || fail "unknown area must exit 2, got $DOCTOR_RC"
  assert_contains "$DOCTOR_ERR" "unknown area nowhere" "unknown area message"
  doctor "$dir" --bogus
  [ "$DOCTOR_RC" -eq 2 ] || fail "unknown option must exit 2, got $DOCTOR_RC"
  doctor "$dir" --area
  [ "$DOCTOR_RC" -eq 2 ] || fail "--area without a name must exit 2, got $DOCTOR_RC"
  pass "--area limits the run; usage errors exit 2"
}

test_help_contract() {
  local dir before after lines
  dir=$(new_case help)
  before=$(find "$dir/home" | sort)
  doctor "$dir" --help
  after=$(find "$dir/home" | sort)
  [ "$DOCTOR_RC" -eq 0 ] || fail "--help exited $DOCTOR_RC"
  [ -z "$DOCTOR_ERR" ] || fail "--help wrote stderr: $DOCTOR_ERR"
  lines=$(printf '%s\n' "$DOCTOR_OUT" | wc -l | tr -d ' ')
  [ "$lines" -le 15 ] || fail "--help is $lines lines, over 15"
  assert_contains "$DOCTOR_OUT" "Usage: fm-doctor.sh" "--help usage line"
  [ "$before" = "$after" ] || fail "--help changed the home"
  pass "--help is short, stdout-only, and leaves the home untouched"
}

test_run_is_read_only() {
  local dir before after
  dir=$(new_case readonly)
  printf '%s\n' '[2026-10-01T00:00:00Z] one' > "$dir/home/state/.home-summary-refresh.log"
  write_network_report "$dir/home" probe,sweeps
  before=$(cd "$dir/home" && find . -exec ls -ld {} + | sort)
  doctor "$dir"
  doctor "$dir" --json --network
  after=$(cd "$dir/home" && find . -exec ls -ld {} + | sort)
  [ "$before" = "$after" ] || fail "a doctor run changed the home"$'\n'"$before"$'\n---\n'"$after"
  pass "a doctor run writes nothing to the home"
}

test_missing_jq_is_a_plain_failure() {
  local dir nojq tool
  dir=$(new_case nojq)
  nojq="$dir/nojq-bin"
  mkdir -p "$nojq"
  for tool in bash dirname env; do
    ln -s "$(command -v "$tool")" "$nojq/$tool"
  done
  DOCTOR_RC=0
  DOCTOR_OUT=$(PATH="$nojq" FM_HOME="$dir/home" "$(command -v bash)" "$DOCTOR" 2>/dev/null) || DOCTOR_RC=$?
  [ "$DOCTOR_RC" -eq 1 ] || fail "missing jq must exit 1, got $DOCTOR_RC"
  assert_contains "$DOCTOR_OUT" "doctor/jq,fail" "missing jq check"
  pass "without jq the doctor prints a plain doctor/jq failure"
}

test_silent_home_maps_every_line
test_provoked_lines_render_their_ids
test_tangle_is_rendered
test_unmapped_line_fails
test_invalid_inventories_fail
test_network_checks
test_toon_and_json_agree
test_area_and_usage
test_help_contract
test_run_is_read_only
test_missing_jq_is_a_plain_failure
