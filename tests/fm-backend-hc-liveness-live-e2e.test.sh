#!/usr/bin/env bash
# tests/fm-backend-hc-liveness-live-e2e.test.sh - default-on drift guard proving
# every INSTALLED harness is still classified `alive` by the hc adapter's
# liveness probe (bin/backends/hc.sh fm_backend_hc_agent_state).
#
# Why this file exists: that verdict rests on two surfaces nobody here controls.
# herdr-core decides which process it reports as a terminal's `foreground`, and
# each harness vendor decides how its process is named. A launcher that runs the
# harness as a child (measured on hc 0.1.13: a `hats run --` wrapper around
# Claude Code) is what hc reports, so the adapter also reads the rest of that
# process group. A stub cannot show either surface drifting.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. Every terminal lives in a private core: a unique HC_SESSION, scratch
# XDG directories, and no inherited HC_TERMINAL_* routing, so the captain's own
# core is never touched. The private core is stopped on exit.
# tests/fm-backend-hc.test.sh pins the classifier logic with a fake hc.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HC_LIVENESS_DRIFT hc jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# hc's socket must fit a unix socket path, so the private root sits under /tmp.
LAB=$(mktemp -d /tmp/fmhl.XXXXXX) || { echo "skip: no scratch directory"; exit 0; }
mkdir -p "$LAB/wt" "$LAB/config" "$LAB/data" "$LAB/cache" "$LAB/home"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
export HC_SESSION="fmhl$$"
export XDG_STATE_HOME="$LAB" XDG_RUNTIME_DIR="$LAB" XDG_CONFIG_HOME="$LAB/config"
export XDG_DATA_HOME="$LAB/data" XDG_CACHE_HOME="$LAB/cache"
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home"
# A real claude started under a scratch XDG_DATA_HOME can self-update into it and
# repoint the operator's ~/.local/bin/claude there; the link dangles once $LAB is gone.
export DISABLE_AUTOUPDATER=1

cleanup_all() {
  if [ "${XDG_STATE_HOME:-}" = "$LAB" ] && [ "${HC_SESSION:-}" = "fmhl$$" ]; then
    hc server stop --json >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB"
}
trap cleanup_all EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
note() { printf '# %s\n' "$1"; }

hc server status --json >/dev/null 2>&1 || fail "a private hc core could not start"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "fm_backend_source hc failed"

CHECKED=0
SKIPPED=
HC_VERSION=$(hc --version 2>/dev/null | head -1)
for harness in claude codex opencode pi grok kimi; do
  bin_path=$(command -v "$harness" 2>/dev/null || true)
  if [ -z "$bin_path" ] || [ ! -x "$bin_path" ]; then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine"
    continue
  fi
  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version=unknown
  address=$(fm_backend_hc_cli "$HC_SESSION" run --bg --json --no-parent --outlive-parent --no-notify \
    --cwd "$LAB/wt" --label "firstmate.task=fm-$harness" --label "firstmate.home=$(fm_backend_hometag)" \
    "$bin_path" | jq -r '.address // empty')
  fm_backend_hc_address_valid "$address" || fail "$harness ($version): hc did not start a terminal"
  target="$HC_SESSION:$address"
  state=
  for _ in $(seq 1 150); do
    state=$(fm_backend_agent_state hc "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done
  foreground=$(fm_backend_hc_cli "$HC_SESSION" get --json "$address" | jq -c '.foreground')
  fm_backend_kill hc "$target" || fail "$harness ($version): kill did not close $target"
  [ "$state" = alive ] || fail \
    "LIVENESS DRIFT: $harness $version in $HC_VERSION classifies '$state', not 'alive'. hc reported foreground $foreground. Teach bin/fm-agent-process-lib.sh or bin/backends/hc.sh the identity this release reports."
  note "$harness $version: foreground=$foreground"
  pass "hc liveness: $harness $version classifies alive in $HC_VERSION"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail "no verified harness is installed here, so this run proved nothing"
[ -z "$SKIPPED" ] || note "unverified on this machine (not installed):$SKIPPED"
note "checked $CHECKED installed harness(es)"
echo FM_TEST_COMPLETE
