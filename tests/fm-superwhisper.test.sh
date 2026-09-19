#!/usr/bin/env bash
# Behavior tests for Firstmate Superwhisper primary-only restriction.
#
# Covers the three-layer architecture:
#   1. Pi worker launch opt-out: every Pi/Pi-signed worker, scout, and secondmate
#      passes -ne to disable extension discovery while preserving explicit -e extensions.
#   2. Non-owner Pi silencing: non-owner Pi sessions opened in a Firstmate root
#      automatically silence Superwhisper via session-scoped disabled marker.
#   3. Codex worker silencing: Firstmate-launched Codex workers/secondmates create
#      the plugin's documented cwd-scoped disabled marker for their lifetime and
#      clean it up on exit, leaving admin sessions enabled.
#   4. Bootstrap drift detection: detect-only reporting of accidental global Pi
#      Superwhisper re-enablement.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-superwhisper)
fm_git_identity fmtest fmtest@example.invalid

test_pi_worker_launches_with_no_extensions_and_preserves_explicit_hooks() {
  local case_dir home proj wt fakebin launchlog id out status launch
  id=test-pi-worker-ne
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' "Pi 0.84.0" 'Options: --help --tui-mode <mode>'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/pi"
  fm_test_spawn_home "$home" pi
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$id"

  # 1. Ship worker launch
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "pi ship spawn should succeed: $out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" " -ne " "pi worker launch must include -ne to disable package extension discovery"
  assert_contains "$launch" "-e '$home/state/$id.pi-ext.ts'" "pi worker launch must preserve explicit -e turn-end hook"

  # 2. Scout worker launch
  id=test-pi-scout-ne
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --scout 2>&1)
  status=$?
  expect_code 0 "$status" "pi scout spawn should succeed: $out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" " -ne " "pi scout launch must include -ne to disable package extension discovery"
  assert_contains "$launch" "-e '$home/state/$id.pi-ext.ts'" "pi scout launch must preserve explicit -e turn-end hook"

  # 3. Persistent secondmate launch
  id=test-pi-secondmate-ne
  local sm="$case_dir/sm"
  mkdir -p "$sm/bin" "$sm/state" "$sm/data" "$sm/config" "$sm/projects" "$sm/.pi/extensions"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  cp "$ROOT/AGENTS.md" "$sm/AGENTS.md"
  cp "$ROOT/.tasks.toml" "$sm/.tasks.toml"
  touch "$sm/data/backlog.md"
  printf 'charter\n' > "$sm/data/charter.md"
  touch "$sm/.pi/extensions/fm-primary-turnend-guard.ts" "$sm/.pi/extensions/fm-primary-pi-watch.ts"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$sm" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$sm" --secondmate --harness pi 2>&1)
  status=$?
  expect_code 0 "$status" "pi secondmate spawn should succeed: $out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" " -ne " "pi secondmate launch must include -ne to disable package extension discovery"
  assert_contains "$launch" "-e '$sm/.pi/extensions/fm-primary-turnend-guard.ts'" "pi secondmate launch must preserve explicit primary turn-end guard"
  assert_contains "$launch" "-e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" "pi secondmate launch must preserve explicit primary pi-watch extension"

  pass "pi launches (ship, scout, secondmate) opt out of package discovery with -ne and keep explicit hooks"
}

test_codex_worker_and_secondmate_launches_set_cwd_disabled_marker() {
  local case_dir home proj wt fakebin launchlog id out status launch
  id=test-codex-worker-cwd
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/codex" <<'SH'
#!/bin/sh
set -eu
sw_dir=${SUPERWHISPER_AGENT_STATE_DIR:-/tmp/superwhisper-agent}
cwd_hash=$(if command -v md5 >/dev/null 2>&1; then printf %s "$PWD" | md5 -q; else printf %s "$PWD" | md5sum | awk '{print $1}'; fi)
if [ -f "$sw_dir/disabled-$cwd_hash" ]; then
  result=MARKER_EXISTS
else
  result=MARKER_MISSING
fi
printf '%s\n' "$result" > "$FM_SW_RESULT"
SH
  chmod +x "$fakebin/codex"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$id"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "codex ship spawn should succeed: $out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "disabled-" "codex launch must construct disabled cwd marker"
  assert_contains "$launch" "trap" "codex launch must register EXIT trap to remove disabled marker"
  assert_contains "$launch" "SUPERWHISPER_AGENT_STATE_DIR=\"\${SUPERWHISPER_AGENT_STATE_DIR:-/tmp/superwhisper-agent}\" sh -c" \
    "codex launch must pass a non-empty marker directory into the nested shell"

  # Execute the exact launch payload captured from the fake tmux interface.
  local sw_test_dir="$case_dir/sw-state"
  local result_file="$case_dir/codex-result"
  mkdir -p "$sw_test_dir"
  local run_out
  run_out=$(cd "$wt" && SUPERWHISPER_AGENT_STATE_DIR="$sw_test_dir" FM_SW_RESULT="$result_file" \
    PATH="$fakebin:$BASE_PATH" /bin/sh -c "$launch" 2>&1)
  [ "$(cat "$result_file")" = "MARKER_EXISTS" ] \
    || fail "captured codex launch did not create its cwd marker before Codex ran: $run_out"

  # The EXIT trap must remove the marker after the worker command exits.
  local remaining
  remaining=$(find "$sw_test_dir" -name "disabled-*" 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" = "0" ] || fail "cwd marker was not removed on worker exit; $remaining marker(s) left"

  # An explicitly empty ambient value exercises the live relaunch failure mode.
  # The wrapper's own default must still reach the nested shell, never an empty
  # mkdir target or a root-level /disabled-* redirection.
  local fallback_state=/tmp/superwhisper-agent
  local cwd_hash fallback_marker fallback_result
  cwd_hash=$(printf %s "$wt" | md5 -q)
  fallback_marker="$fallback_state/disabled-$cwd_hash"
  fallback_result="$case_dir/codex-fallback-result"
  rm -f "$fallback_marker"
  run_out=$(cd "$wt" && SUPERWHISPER_AGENT_STATE_DIR='' FM_SW_RESULT="$fallback_result" \
    PATH="$fakebin:$BASE_PATH" /bin/sh -c "$launch" 2>&1)
  [ "$(cat "$fallback_result")" = "MARKER_EXISTS" ] \
    || fail "empty ambient marker directory did not use the wrapper default: $run_out"
  [ ! -e "$fallback_marker" ] \
    || fail "fallback cwd marker survived the captured worker launch"
  rm -f "$fallback_marker"

  pass "captured codex launch creates and cleans its cwd marker, including an empty ambient state directory"
}

test_codex_agent_hook_respects_cwd_disabled_marker_when_present() {
  local hook_bin="/Applications/superwhisper.app/Contents/Resources/agent-hook"
  if [ ! -x "$hook_bin" ]; then
    echo "skip: superwhisper agent-hook binary not present"
    return 0
  fi

  local test_dir="$TMP_ROOT/hook-test"
  local sw_state_dir="/tmp/superwhisper-agent"
  mkdir -p "$test_dir" "$sw_state_dir"

  local cwd_hash marker
  cwd_hash=$(printf %s "$test_dir" | md5 -q)
  marker="$sw_state_dir/disabled-$cwd_hash"

  # With marker present: agent-hook must report superwhisper disabled for cwd.
  touch "$marker"
  local out
  out=$(printf '{"session_id":"test-codex-session","cwd":"%s","hook_event_name":"Stop"}' "$test_dir" | "$hook_bin" codex 2>&1 || true)
  assert_contains "$out" "Exiting: superwhisper disabled for cwd=$test_dir" \
    "agent-hook did not silence codex when cwd disabled marker was present"

  # With marker removed: agent-hook must not exit for cwd.
  rm -f "$marker"
  out=$(printf '{"session_id":"test-codex-session","cwd":"%s","hook_event_name":"Stop"}' "$test_dir" | "$hook_bin" codex 2>&1 || true)
  assert_not_contains "$out" "Exiting: superwhisper disabled for cwd=" \
    "agent-hook silenced codex when cwd disabled marker was absent"

  rm -rf "$test_dir"
  pass "codex agent-hook silences Firstmate task worktree with marker and remains enabled elsewhere"
}

test_non_owner_pi_session_silences_superwhisper_via_session_marker() {
  command -v node >/dev/null 2>&1 || { echo "skip: node required"; return 0; }

  local fixture="$TMP_ROOT/non-owner-pi"
  mkdir -p "$fixture/state" "$fixture/.pi/extensions"
  local ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"

  # Simulate a foreign lock: state/.lock held by a live process that is not our node process.
  printf '%s\n' '1' > "$fixture/state/.lock"

  # Run a node script that loads fm-primary-turnend-guard.ts and triggers session_start.
  local result
  result=$(FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" node --input-type=module <<EOF
import guardExtension from '$ext';
import { existsSync, unlinkSync } from 'node:fs';

let sessionStartHandler;
let sessionShutdownHandler;

const mockPi = {
  on: (event, handler) => {
    if (event === 'session_start') sessionStartHandler = handler;
    if (event === 'session_shutdown') sessionShutdownHandler = handler;
  },
  registerTool: () => {},
  registerCommand: () => {},
};

guardExtension(mockPi);

const mockCtx = {
  sessionManager: {
    getSessionFile: () => '/fake/sessions/2026-09-19T00-00-00-000Z_test-non-owner.jsonl',
    getSessionId: () => 'test-non-owner-uuid',
    getSessionName: () => 'test-session',
  },
};

sessionStartHandler({ reason: 'startup' }, mockCtx);

const marker = '/tmp/superwhisper-agent/disabled-2026-09-19T00-00-00-000Z_test-non-owner.jsonl';
const pidMarker = \`/tmp/superwhisper-agent/disabled-pi-\${process.pid}\`;

const existsBefore = existsSync(marker) && existsSync(pidMarker);

sessionShutdownHandler({}, mockCtx);

const existsAfter = existsSync(marker) || existsSync(pidMarker);

// Cleanup in case test failed
try { unlinkSync(marker); } catch {}
try { unlinkSync(pidMarker); } catch {}

if (existsBefore && !existsAfter) {
  console.log('OK_SILENCED_AND_CLEANED');
} else {
  console.log(\`FAILED existsBefore=\${existsBefore} existsAfter=\${existsAfter}\`);
}
EOF
)
  [ "$result" = "OK_SILENCED_AND_CLEANED" ] \
    || fail "non-owner Pi session did not create and clean up Superwhisper session marker: $result"

  pass "non-owner ordinary Pi session silences Superwhisper and removes marker on shutdown"
}

test_owner_primary_pi_session_leaves_superwhisper_enabled() {
  command -v node >/dev/null 2>&1 || { echo "skip: node required"; return 0; }

  local fixture="$TMP_ROOT/owner-primary-pi"
  mkdir -p "$fixture/state" "$fixture/.pi/extensions"
  local ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"

  # Simulate lock owned by this node process.
  local result
  result=$(FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" node --input-type=module <<EOF
import guardExtension from '$ext';
import { existsSync, writeFileSync, unlinkSync } from 'node:fs';

writeFileSync('$fixture/state/.lock', \`\${process.pid}\n\`);

let sessionStartHandler;
const mockPi = {
  on: (event, handler) => {
    if (event === 'session_start') sessionStartHandler = handler;
  },
  registerTool: () => {},
  registerCommand: () => {},
};

guardExtension(mockPi);

const mockCtx = {
  sessionManager: {
    getSessionFile: () => '/fake/sessions/2026-09-19T00-00-00-000Z_test-owner.jsonl',
    getSessionId: () => 'test-owner-uuid',
    getSessionName: () => 'primary-session',
  },
};

sessionStartHandler({ reason: 'startup' }, mockCtx);

const marker = '/tmp/superwhisper-agent/disabled-2026-09-19T00-00-00-000Z_test-owner.jsonl';
const pidMarker = \`/tmp/superwhisper-agent/disabled-pi-\${process.pid}\`;

const markerWritten = existsSync(marker) || existsSync(pidMarker);

try { unlinkSync(marker); } catch {}
try { unlinkSync(pidMarker); } catch {}

if (!markerWritten) {
  console.log('OK_SUPERWHISPER_ENABLED');
} else {
  console.log('FAILED_PRIMARY_WAS_SILENCED');
}
EOF
)
  [ "$result" = "OK_SUPERWHISPER_ENABLED" ] \
    || fail "lock-owning primary session wrote Superwhisper disabled marker: $result"

  pass "lock-owning primary Pi session leaves Superwhisper enabled"
}

test_pi_cli_no_extensions_isolates_discovery_and_preserves_explicit_extension() {
  command -v pi >/dev/null 2>&1 || { echo "skip: pi required"; return 0; }

  local fixture="$TMP_ROOT/pi-cli-ne-proof"
  mkdir -p "$fixture/.pi/extensions"

  cat > "$fixture/.pi/extensions/auto-discovered.ts" <<'EOF'
export default function() {
  process.stderr.write("AUTO_DISCOVERED_LOADED\n");
}
EOF
  cat > "$fixture/explicit.ts" <<'EOF'
export default function() {
  process.stderr.write("EXPLICIT_HOOK_LOADED\n");
}
EOF

  local out
  # Test with -a (discovery on): both load.
  out=$(cd "$fixture" && pi -a -e "$fixture/explicit.ts" --help 2>&1 || true)
  assert_contains "$out" "EXPLICIT_HOOK_LOADED" "explicit -e extension did not load without -ne"
  assert_contains "$out" "AUTO_DISCOVERED_LOADED" "auto-discovered extension did not load without -ne"

  # Test with -a -ne (discovery off): only explicit loads.
  out=$(cd "$fixture" && pi -a -ne -e "$fixture/explicit.ts" --help 2>&1 || true)
  assert_contains "$out" "EXPLICIT_HOOK_LOADED" "explicit -e extension did not load under -ne"
  assert_not_contains "$out" "AUTO_DISCOVERED_LOADED" "auto-discovered extension loaded despite -ne"

  rm -rf "$fixture"
  pass "Pi CLI -ne halts extension discovery while preserving explicit -e extensions"
}

test_pi_worker_launches_with_no_extensions_and_preserves_explicit_hooks
test_codex_worker_and_secondmate_launches_set_cwd_disabled_marker
test_codex_agent_hook_respects_cwd_disabled_marker_when_present
test_non_owner_pi_session_silences_superwhisper_via_session_marker
test_owner_primary_pi_session_leaves_superwhisper_enabled
test_pi_cli_no_extensions_isolates_discovery_and_preserves_explicit_extension
