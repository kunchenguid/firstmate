#!/usr/bin/env bash
# Behavioral coverage for optional workspace placement and command execution config.
#
# The fixture keeps FM_HOME/config and PATH isolated, so bootstrap observes only
# the selected optional tools and the existing required-tool contract.
set -u
unset FM_INHERITABLE_CONFIG FM_CONFIG_INHERIT_LIVE

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-workspace-execution-config-tests)

make_bootstrap_toolchain() {
  local dir=$1 with_sbx=${2:-0} fakebin jq_path
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node git gh chrome-devtools-axi
  [ "$with_sbx" = 1 ] && fm_fake_exit0 "$fakebin" sbx
  fm_fake_version_tool "$fakebin" no-mistakes FM_FAKE_NO_MISTAKES_VERSION 'no-mistakes version v1.31.2 (fake)'
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:) printf '%s\n' '0.2.4' ;;
  update:--help) printf '%s\n' 'usage: tasks-axi update <id> --body-file <path> --archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
 esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' '0.1.17'
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  jq_path=$(command -v jq 2>/dev/null) || fail 'jq is required for workspace-execution bootstrap fixtures'
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$jq_path' "\$@"
SH
  chmod +x "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

write_workspace_config() {
  local home=$1 json=$2
  mkdir -p "$home/config"
  printf '%s\n' "$json" > "$home/config/workspace-execution.json"
}

run_bootstrap() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BACKEND=tmux \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

assert_one_workspace_diagnostic() {
  local out=$1 label=$2 needle=${3:-}
  case "$out" in
    *$'\n'*) fail "$label: expected exactly one diagnostic, got multiple lines: $out" ;;
    WORKSPACE_EXECUTION:\ invalid\ config/workspace-execution.json\ -\ *) : ;;
    *) fail "$label: missing WORKSPACE_EXECUTION diagnostic: $out" ;;
  esac
  [ -z "$needle" ] || assert_contains "$out" "$needle" "$label: diagnostic omitted actionable detail"
}

test_absent_config_defaults_are_silent_and_host_local() {
  local home="$TMP_ROOT/absent" config err out
  config="$home/config"
  mkdir -p "$config"
  err="$home/load.err"
  out=$(
    . "$ROOT/bin/fm-workspace-execution-config.sh"
    fm_workspace_execution_config_load "$config" 2>"$err"
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$FM_WORKER_PLACEMENT_ADAPTER" "$FM_WORKER_PLACEMENT_WORKSPACE_MODE" \
      "$FM_SECONDMATE_PLACEMENT_ADAPTER" "$FM_SECONDMATE_PLACEMENT_WORKSPACE_MODE" \
      "$FM_COMMAND_EXECUTION_ADAPTER" "$FM_COMMAND_EXECUTION_PROFILE"
  )
  [ "$out" = $'host\ndirect\nhost\ndirect\nlocal' ] \
    || fail "absent config did not resolve host/direct, host/direct, local/null: $out"
  [ ! -s "$err" ] || fail "absent config emitted an unexpected validation diagnostic: $(cat "$err")"
  pass 'absent workspace-execution config keeps host/direct and local/null defaults silently'
}

test_complete_config_resolves_all_axes() {
  local home="$TMP_ROOT/complete" config out
  config="$home/config"
  mkdir -p "$config"
  cat > "$config/workspace-execution.json" <<'JSON'
{"workerPlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":["python","node"]},"secondmatePlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":["go"]},"commandExecution":{"adapter":"crabbox","profile":"safe-default"}}
JSON
  out=$(
    . "$ROOT/bin/fm-workspace-execution-config.sh"
    fm_workspace_execution_config_load "$config"
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$FM_WORKER_PLACEMENT_ADAPTER" "$FM_WORKER_PLACEMENT_WORKSPACE_MODE" \
      "$FM_SECONDMATE_PLACEMENT_ADAPTER" "$FM_SECONDMATE_PLACEMENT_WORKSPACE_MODE" \
      "$FM_COMMAND_EXECUTION_ADAPTER" "$FM_COMMAND_EXECUTION_PROFILE"
  )
  [ "$out" = $'docker-sandbox\ndirect\ndocker-sandbox\ndirect\ncrabbox\nsafe-default' ] \
    || fail "complete config did not resolve all axes: $out"
  pass 'complete workspace-execution config resolves placement and Crabbox axes'
}

test_empty_and_docker_kits_are_accepted_without_optional_tool_leakage() {
  local home="$TMP_ROOT/kits-valid" fakebin out
  fakebin=$(make_bootstrap_toolchain "$home" 1)
  write_workspace_config "$home" '{"workerPlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":["python","node"]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"local","profile":null}}'
  out=$(run_bootstrap "$home" "$fakebin")
  [ -z "$out" ] || fail "valid Docker kits or empty host kits changed bootstrap required-tool output: $out"
  pass 'Docker accepts nonempty string kits and host accepts empty kits without extra diagnostics'
}

test_invalid_configs_emit_one_actionable_diagnostic() {
  local label json needle home fakebin out
  while IFS='|' read -r label json needle; do
    home="$TMP_ROOT/invalid-$label"
    fakebin=$(make_bootstrap_toolchain "$home" 0)
    write_workspace_config "$home" "$json"
    out=$(run_bootstrap "$home" "$fakebin")
    assert_one_workspace_diagnostic "$out" "$label" "$needle"
  done <<'CASES'
unknown-top|{"workerPlacement":{"adapter":"host","workspaceMode":"direct"},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct"},"commandExecution":{"adapter":"local","profile":null},"unexpected":true}|unknown
missing-top|{"workerPlacement":{"adapter":"host","workspaceMode":"direct"},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct"}}|missing
extra-placement-key|{"workerPlacement":{"adapter":"host","workspaceMode":"direct","extra":true},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct"},"commandExecution":{"adapter":"local","profile":null}}|unknown
invalid-type|{"workerPlacement":{"adapter":7,"workspaceMode":"direct"},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct"},"commandExecution":{"adapter":"local","profile":null}}|must be a string
unsupported-clone-mode|{"workerPlacement":{"adapter":"host","workspaceMode":"clone"},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct"},"commandExecution":{"adapter":"local","profile":null}}|direct
host-nonempty-kits|{"workerPlacement":{"adapter":"host","workspaceMode":"direct","kits":["python"]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"local","profile":null}}|kits
malformed-empty-kit|{"workerPlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":[""]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"local","profile":null}}|kits
malformed-typed-kit|{"workerPlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":[7]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"local","profile":null}}|kits
malformed-newline-kit|{"workerPlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":["a\nb"]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"local","profile":null}}|kits
malformed-tab-kit|{"workerPlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":["a\tb"]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"local","profile":null}}|kits
CASES
  pass 'unknown, missing, extra, type-invalid, clone-mode, and malformed kits configs each emit one diagnostic'
}

test_selected_missing_optional_tools_use_manual_diagnostics() {
  local home fakebin out
  home="$TMP_ROOT/missing-sbx"
  fakebin=$(make_bootstrap_toolchain "$home" 0)
  write_workspace_config "$home" '{"workerPlacement":{"adapter":"docker-sandbox","workspaceMode":"direct","kits":[]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"local","profile":null}}'
  out=$(run_bootstrap "$home" "$fakebin")
  [ "$out" = 'MISSING_MANUAL: sbx (instructions: https://docs.docker.com/ai/sandboxes/)' ] \
    || fail "selected Docker sandbox did not emit exactly one existing-style manual diagnostic: $out"

  home="$TMP_ROOT/missing-crabbox"
  fakebin=$(make_bootstrap_toolchain "$home" 0)
  write_workspace_config "$home" '{"workerPlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"secondmatePlacement":{"adapter":"host","workspaceMode":"direct","kits":[]},"commandExecution":{"adapter":"crabbox","profile":"safe-default"}}'
  out=$(run_bootstrap "$home" "$fakebin")
  [ "$out" = 'MISSING_MANUAL: crabbox (instructions: https://github.com/openclaw/crabbox)' ] \
    || fail "selected Crabbox did not emit exactly one existing-style manual diagnostic: $out"
  pass 'selected Docker sandbox and Crabbox report one manual diagnostic each'
}

test_unselected_optional_tools_are_silent() {
  local home="$TMP_ROOT/unselected" fakebin out
  fakebin=$(make_bootstrap_toolchain "$home" 0)
  mkdir -p "$home/config"
  out=$(run_bootstrap "$home" "$fakebin")
  [ -z "$out" ] || fail "unselected sbx/crabbox changed host/local bootstrap output: $out"
  pass 'unselected sbx and Crabbox remain silent under absent host/local config'
}

test_inheritance_copies_workspace_config_exactly() {
  local home="$TMP_ROOT/inherit" dest src out items
  home="$home/primary"
  dest="$TMP_ROOT/inherit/secondmate"
  mkdir -p "$home/config" "$home/data" "$dest"
  src="$home/config/workspace-execution.json"
  cat > "$src" <<'JSON'
{
  "workerPlacement": {"adapter": "docker-sandbox", "workspaceMode": "direct", "kits": ["python"]},
  "secondmatePlacement": {"adapter": "host", "workspaceMode": "direct", "kits": []},
  "commandExecution": {"adapter": "local", "profile": null}
}
JSON
  out=$(
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    propagate_inheritable_config "$home/config" "$dest/config"
  )
  [ -z "$out" ] || fail "config inheritance wrote unexpected stdout: $out"
  # shellcheck disable=SC2031 # src/dest are parent-shell values; sourced inheritance call is isolated in a command substitution
  cmp -s "$src" "$dest/config/workspace-execution.json" \
    || fail 'inherited workspace-execution.json did not preserve exact source bytes'
  # shellcheck disable=SC2031 # src/dest are parent-shell values; sourced inheritance call is isolated in a command substitution
  [ ! -e "$dest/config/crew-harness" ] || fail 'inheritance unexpectedly changed a universal/bootstrap config item'
  # shellcheck disable=SC2031 # src/dest are parent-shell values; sourced inheritance call is isolated in a command substitution
  [ ! -e "$dest/config/backend" ] || fail 'inheritance unexpectedly changed backend tool selection'
  items=$(
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    fm_config_inherit_items
  )
  assert_contains "$items" $'config/workspace-execution.json' 'inheritance allowlist omitted workspace-execution.json'
  assert_not_contains "$items" $'config/secondmate-harness' 'secondmate-only launcher config leaked into inheritance allowlist'
  pass 'config inheritance includes workspace-execution.json byte-for-byte without changing required tools'
}

test_absent_config_defaults_are_silent_and_host_local
test_complete_config_resolves_all_axes
test_empty_and_docker_kits_are_accepted_without_optional_tool_leakage
test_invalid_configs_emit_one_actionable_diagnostic
test_selected_missing_optional_tools_use_manual_diagnostics
test_unselected_optional_tools_are_silent
test_inheritance_copies_workspace_config_exactly
