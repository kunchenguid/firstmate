#!/usr/bin/env bash
# Live guard for the codex crewmate launch's hook posture.
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

fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
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
  printf 'approve-for-me\n' > "$home/config/codex-approval-mode"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
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
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off)
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

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_accepts_requested_hook_disablement_for_the_captured_crewmate_launch

echo "# all fm-codex-hook-layer-live-e2e tests passed"
