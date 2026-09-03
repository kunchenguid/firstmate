#!/usr/bin/env bash
# tests/fm-pi-spawn-probe-live-e2e.test.sh - opt-in guard proving that
# bin/fm-spawn.sh's Pi TUI capability probe reaches a conclusive verdict against
# every INSTALLED Pi-family executable (pi, pi-signed).
#
# Why this file exists: probe_pi_tui_mode decides from the vendor's own --help
# text whether to pass --tui-mode regular, and refuses to launch when that text
# is failed, empty, unrecognizable, malformed, or mode-ambiguous. A Pi release
# that rewords its banner or restructures its help therefore makes every Pi
# spawn refuse until the probe is re-verified. tests/fm-spawn-dispatch-profile.test.sh
# pins the classifier against a stub whose help was transcribed from one
# release; only the real executable can show that the transcription still
# holds. This guard runs the real bin/fm-spawn.sh against the real executable
# with a recording tmux stub, so no Pi process is started and no model tokens
# are spent: the launch command is captured, never typed into a pane.
#
# Two independent readings decide each verdict: the spawn's own conclusive
# result (exit 0 with a composed launch naming the probed executable), and this
# guard's own read of the same --help for the --tui-mode option. They must agree
# on whether exactly one --tui-mode regular is present, so a probe that drifted
# to the wrong conclusive branch is caught as well as one that refuses.
#
# Standard CI has no harness binaries, so this real-harness guard is opt-in and
# on-demand. Run it after every Pi upgrade and before trusting refreshed
# evidence in docs/verification/runtime-backends.md.
set -u

if [ "${FM_PI_SPAWN_PROBE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_PI_SPAWN_PROBE_LIVE=1 to run the installed-Pi spawn probe guard"
  exit 0
fi

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-spawn-probe-live)

note() { printf '# %s\n' "$1"; }

CHECKED=0
SKIPPED=

for harness in pi pi-signed; do
  bin_path=$(type -P -- "$harness" 2>/dev/null || true)
  if [ -z "$bin_path" ] || [ ! -x "$bin_path" ]; then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its spawn probe is unverified here"
    continue
  fi
  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r')
  [ -n "$version" ] || version=unknown

  # The guard's own reading of the vendor surface the probe reads.
  if ! help=$("$bin_path" --help 2>&1); then
    fail "$harness $version: --help exited non-zero, so no conclusive verdict is possible: $(printf '%s' "$help" | head -3 | tr '\n' ' ')"
  fi
  if printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--tui-mode([[:space:]=]|$)'; then
    expected=1
  else
    expected=0
  fi

  id="probe-live-$harness"
  case_dir="$TMP_ROOT/$harness"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$harness"
  fm_test_spawn_brief "$home" "$id"
  : > "$launchlog"

  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "PROBE DRIFT: $harness $version: bin/fm-spawn.sh refused the launch (exit $status): $(printf '%s\n' "$out" | grep -E '^error:' | tail -1). Teach probe_pi_tui_mode the help shape this release prints, then refresh tests/lib.sh's fm_fake_pi."
  fi
  launch=$(cat "$launchlog")
  [ -n "$launch" ] || fail "$harness $version: spawn exited 0 but typed no launch command"
  case "$launch" in
    *"'$bin_path'"*) ;;
    *) fail "$harness $version: the launch does not name the probed executable '$bin_path': $launch" ;;
  esac
  count=$(printf '%s\n' "$launch" | grep -o -- '--tui-mode regular' | wc -l | tr -d ' ')
  if [ "$count" -ne "$expected" ]; then
    if [ "$expected" -eq 1 ]; then
      fail "PROBE DRIFT: $harness $version: its help advertises --tui-mode but the launch carries $count '--tui-mode regular' flag(s): $launch"
    fi
    fail "PROBE DRIFT: $harness $version: its help does not advertise --tui-mode but the launch carries $count '--tui-mode regular' flag(s): $launch"
  fi

  note "$harness $version at $bin_path: --tui-mode regular x$count"
  pass "spawn probe: $harness $version reaches a conclusive verdict that agrees with its own help"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no Pi-family executable is installed here, so this run proved nothing; install pi or pi-signed before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed Pi-family executable(s)"
