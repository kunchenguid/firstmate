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
# tokens. Every terminal lives in a lab core session provisioned by
# bin/fm-hc-lab.sh: a unique fm-hclab-* HC_SESSION, scratch XDG roots, a
# pinned FM_HC_SOCKET, a real-fleet tripwire, and a teardown that sweeps the
# session's serve/hold daemons (and their harness children) by their
# HC_SESSION env marker, so the captain's own core is never touched.
# tests/hc-test-safety.sh owns the only sanctioned teardown path.
# tests/fm-backend-hc.test.sh pins the classifier logic with a fake hc.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Binary resolution identical to the adapter, installer, and lab: FM_HC_BIN
# wins, then herdr-core, then the hc alias. The resolved binary's directory
# goes on PATH so the live gate can verify it by name.
HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
HC_TOOL=hc
if [ -n "$HC_BIN" ] && [ -x "$HC_BIN" ]; then
  export FM_HC_BIN=$HC_BIN
  PATH="$(dirname "$HC_BIN"):$PATH"
  HC_TOOL=$(basename "$HC_BIN")
fi
fm_live_gate default-on FM_HC_LIVENESS_DRIFT "$HC_TOOL" jq
export FM_HC_BIN=${FM_HC_BIN:-$HC_BIN}

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-liveness)

HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name liveness)

# The teardown's own result propagates: a fleet-tripwire failure or surviving
# session processes keep this run nonzero even on an otherwise-clean pass.
cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
note() { printf '# %s\n' "$1"; }

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with ${HC_BIN:-no binary}"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"
hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

# The adapter routes through FM_HC_SOCKET; pinning the lab's XDG roots as well
# means even an auto-spawned serve (server down mid-call) lands inside the
# lab dir rather than the real state root.
HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
mkdir -p "$HC_LAB_DIR/wt"

FM_HOME_DIR=$TMP_ROOT/home
mkdir -p "$FM_HOME_DIR"
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$FM_HOME_DIR
# A real claude started under a scratch XDG_DATA_HOME can self-update into it
# and repoint the operator's ~/.local/bin/claude there; the lab dir is
# removed on teardown, so the link must never be created.
export DISABLE_AUTOUPDATER=1

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "fm_backend_source hc failed"

CHECKED=0
SKIPPED=
HC_VERSION=$("$HC_TOOL" --version 2>/dev/null | head -1)
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
    --cwd "$HC_LAB_DIR/wt" --label "firstmate.task=fm-$harness" --label "firstmate.home=$(fm_backend_hometag)" \
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
