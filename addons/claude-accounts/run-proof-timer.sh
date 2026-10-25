#!/usr/bin/env bash
# run-proof-timer.sh: the refresh timer proof for done-done. Installs the units into a throwaway XDG tree with a
# stub systemctl, lets systemd-analyze verify the generated units, shows the real dry run for the real home
# (writes nothing) and runs the fixture test. The host's timers are never touched.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/bin" "$work/home"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/systemctl"
chmod +x "$work/bin/systemctl"
{
  echo "== dry run for a home (nothing written)"
  "$repo/claude-accounts/install-timer.sh" --dry-run "${FM_HOME:-$work/home}"
  echo "== units written into a throwaway tree, verified by systemd-analyze"
  env PATH="$work/bin:$PATH" XDG_DATA_HOME="$work/data" XDG_CONFIG_HOME="$work/cfg" "$repo/claude-accounts/install-timer.sh" "$work/home"
  systemd-analyze --user verify "$work/cfg/systemd/user/fm-claude-accounts-quota.timer" "$work/cfg/systemd/user/fm-claude-accounts-quota.service"
  echo "verify: ok"
  cat "$work/cfg/systemd/user/fm-claude-accounts-quota.timer"
  echo "== fixture test"
  bash "$repo/claude-accounts/tests/claude-accounts-timer.test.sh"
} >"$evidence/timer.txt" 2>&1
cat "$evidence/timer.txt"
