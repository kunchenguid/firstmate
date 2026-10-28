#!/usr/bin/env bash
# Live guard for the codex crewmate launch's hook posture.
#
# The verdict here comes from the installed codex, not from a stub: a stub can
# only confirm the assumption already written into it, and what this guard
# protects is exactly a vendor-owned surface. Codex blocks a fresh crewmate
# launch on an unanswerable "Hooks need review" modal whenever the machine's
# ~/.codex/hooks.json or a project's .codex/hooks.json carries a hook it has no
# persisted trust for, so the crewmate launch requests hook disablement
# (bin/fm-spawn.sh's launch template owns the flag and policy limitation).
#
# The guard replays the REAL launch flags fm-spawn builds - captured from a
# spawn driven through a fake pane - against the installed codex and verifies
# that the requested hook disablement remains a recognized flag. Managed
# settings can re-enable hooks after launch, so this guard pins construction
# and capability rather than falsely treating the effective setting as a
# portable invariant.
#
# It spends no model tokens (`codex features list` resolves configuration only),
# so it runs by default wherever codex is installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex jq python3

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id spawn_output
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  printf 'approve-for-me\n' > "$home/config/codex-approval-mode"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  spawn_output=$(CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" 2>&1) || {
    printf 'codex %s: fm-spawn could not build a crewmate launch: %s\n' "$CODEX_VERSION" "$spawn_output" >&2
    return 1
  }
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

test_installed_codex_accepts_requested_hook_disablement_for_the_captured_crewmate_launch() {
  local launch flags listing
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off) || fail "codex $CODEX_VERSION could not capture the crewmate launch"
  flags=$(codex_global_flags "$launch")
  case " $flags " in
    *' --approve-for-me '*) ;;
    *) fail "codex $CODEX_VERSION captured launch omitted --approve-for-me" ;;
  esac
  case " $flags " in
    *' --dangerously-bypass-approvals-and-sandbox '*)
      fail "codex $CODEX_VERSION captured launch retained the complete-bypass posture"
      ;;
  esac

  # The captured flags must remain accepted by the real Codex CLI. A managed
  # setting can override hooks back on, so the effective feature value is not
  # a portable assertion; an unknown feature remains a launch-breaking error.
  listing=$(eval "codex $flags features list" 2>&1) ||
    fail "codex $CODEX_VERSION rejected firstmate's crewmate launch flags: $listing"
  case "$listing" in
    *"Unknown feature flag"*)
      fail "codex $CODEX_VERSION no longer knows the hook feature firstmate disables: $listing"
      ;;
  esac
  printf '%s\n' "$listing" | awk '{ print $1 }' | grep -qx hooks ||
    fail "codex $CODEX_VERSION omitted the hook feature from the captured crewmate launch"

  printf 'ok - codex %s accepts the requested hook disablement for a firstmate crewmate launch\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature() {
  local listing
  listing=$(codex features list 2>&1) ||
    fail "codex $CODEX_VERSION could not list its feature flags: $listing"
  printf '%s\n' "$listing" | awk '{ print $1 }' | grep -qx hooks ||
    fail "codex $CODEX_VERSION no longer publishes a hook feature flag; firstmate's crewmate launch needs a new control"

  printf 'ok - codex %s still publishes the hook feature flag firstmate disables\n' "$CODEX_VERSION"
}

test_catalog_efforts_reach_real_codex_thread() {
  local catalog model effort launch flags
  catalog=$("$ROOT/bin/fm-harness.sh" codex-catalog)
  for effort in max ultra; do
    model=$(printf '%s\n' "$catalog" | jq -r --arg effort "$effort" '[.[] | select(any(.supported_reasoning_levels[]?; .effort == $effort)) | .slug][0] // empty')
    if [ -z "$model" ]; then
      printf 'skip - codex %s catalog has no model advertising %s\n' "$CODEX_VERSION" "$effort"
      continue
    fi
    launch=$(capture_codex_launch "effort-$effort" --mode no-mistakes --yolo off --model "$model" --effort "$effort") || fail "codex $CODEX_VERSION could not capture $model $effort"
    flags=$(codex_global_flags "$launch")
    FM_TEST_FLAGS="$flags" FM_TEST_MODEL="$model" FM_TEST_EFFORT="$effort" python3 - <<'PYCODE' || fail "codex $CODEX_VERSION did not retain $model $effort"
import json, os, shlex, subprocess
flags = shlex.split(os.environ['FM_TEST_FLAGS'])
config = []
for i, flag in enumerate(flags):
    if flag == '-c' and flags[i+1].startswith('model_reasoning_effort='):
        config += ['-c', flags[i+1]]
assert config, 'captured launch omitted reasoning config'
p = subprocess.Popen(['codex', 'app-server', *config], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def request(i, method, params):
    p.stdin.write(json.dumps({'id': i, 'method': method, 'params': params}) + '\n'); p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line: raise RuntimeError('app-server exited')
        reply = json.loads(line)
        if reply.get('id') == i: return reply
try:
    request(1, 'initialize', {'clientInfo': {'name': 'firstmate-test', 'version': '1'}})
    result = request(2, 'thread/start', {'model': os.environ['FM_TEST_MODEL'], 'ephemeral': True})['result']
    assert result['model'] == os.environ['FM_TEST_MODEL'] and result['reasoningEffort'] == os.environ['FM_TEST_EFFORT'], result
finally:
    p.terminate(); p.wait(timeout=5)
PYCODE
    printf 'ok - codex %s thread retains %s %s from the captured launch\n' "$CODEX_VERSION" "$model" "$effort"
  done
}

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_accepts_requested_hook_disablement_for_the_captured_crewmate_launch
test_catalog_efforts_reach_real_codex_thread

echo "# all fm-codex-hook-layer-live-e2e tests passed"
