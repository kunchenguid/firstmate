#!/usr/bin/env bash
# Live guard for Codex worker hook posture and secondmate execution isolation.
#
# The verdict here comes from the installed codex, not from a stub: a stub can
# only confirm the assumption already written into it, and what this guard
# protects is exactly a vendor-owned surface. Codex blocks a fresh crewmate
# launch on an unanswerable "Hooks need review" modal whenever the machine's
# ~/.codex/hooks.json or a project's .codex/hooks.json carries a hook it has no
# persisted trust for, so the crewmate launch disables codex's hook layer
# outright (bin/fm-spawn.sh's launch template owns the flag).
#
# The guard replays the REAL launch flags fm-spawn builds - captured from a
# spawn driven through a fake pane - against the installed codex and asks codex
# itself whether hooks ended up disabled. If a codex release renames or drops
# the feature, the flag becomes a hard "Unknown feature flag" error and this
# guard fails naming the harness and version instead of letting the modal
# silently come back.
#
# It spends no model tokens (configuration reads and a pre-startup CLI refusal),
# so it runs by default wherever codex is installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a Codex agent
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  if [ "$name" = secondmate ]; then
    proj=$wt
    mkdir -p "$proj/bin" "$proj/data"
    printf '# Firstmate\n' > "$proj/AGENTS.md"
    printf '%s\n' "$id" > "$proj/.fm-secondmate-home"
    printf '# Test charter\n' > "$proj/data/charter.md"
  fi
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a $name launch"
  cat "$launchlog"
}

# This checks the installed TUI's connection policy without a model request,
# an actual daemon, or access to the operator's daemon/account. The conflict is
# rejected before startup: the emitted secondmate flags must forbid --remote.
test_secondmate_launch_refuses_shared_server_attachment() {
  local launch flags out status
  launch=$(capture_codex_launch secondmate --secondmate)
  flags=$(codex_global_flags "$launch")
  mkdir -p "$TMP_ROOT/isolated-codex"
  out=$(
    export CODEX_HOME="$TMP_ROOT/isolated-codex"
    eval "codex $flags --remote unix://$TMP_ROOT/unused.sock" </dev/null 2>&1
  ); status=$?
  [ "$status" -ne 0 ] || fail "codex $CODEX_VERSION allowed a secondmate to attach to a shared server"
  assert_contains "$out" '--no-daemon cannot be used with --remote' \
    "codex $CODEX_VERSION did not enforce secondmate daemon isolation: $out"
  assert_not_contains "$flags" '--disable hooks' "secondmates must retain primary hooks"
  printf 'ok - codex %s rejects shared-server attachment for the emitted secondmate launch without disabling hooks\n' "$CODEX_VERSION"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

test_installed_codex_disables_hooks_for_the_captured_crewmate_launch() {
  local launch flags state
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")

  # The whole point: every flag firstmate will launch with, handed to the real
  # codex, must leave the hook layer off. `features list` reports the effective
  # state after those flags are applied and contacts no model.
  state=$(eval "codex $flags features list" 2>&1) ||
    fail "codex $CODEX_VERSION rejected firstmate's crewmate launch flags: $state"
  case "$state" in
    *"Unknown feature flag"*)
      fail "codex $CODEX_VERSION no longer knows the hook feature firstmate disables: $state"
      ;;
  esac
  printf '%s\n' "$state" | awk '$1 == "hooks" { print $NF }' | grep -qx false ||
    fail "codex $CODEX_VERSION left hooks enabled for firstmate's crewmate launch flags, so a fresh launch can park on the hook-trust modal"

  printf 'ok - codex %s runs a firstmate crewmate launch with its hook layer disabled\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature() {
  local listing
  listing=$(codex features list 2>&1) ||
    fail "codex $CODEX_VERSION could not list its feature flags: $listing"
  printf '%s\n' "$listing" | awk '{ print $1 }' | grep -qx hooks ||
    fail "codex $CODEX_VERSION no longer publishes a hook feature flag; firstmate's crewmate launch needs a new control"

  printf 'ok - codex %s still publishes the hook feature flag firstmate disables\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_disables_hooks_for_the_captured_crewmate_launch
test_secondmate_launch_refuses_shared_server_attachment

echo "# all fm-codex-hook-layer-live-e2e tests passed"
