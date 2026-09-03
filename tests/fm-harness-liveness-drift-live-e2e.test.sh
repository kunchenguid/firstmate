#!/usr/bin/env bash
# tests/fm-harness-liveness-drift-live-e2e.test.sh - opt-in drift guard proving
# every INSTALLED harness is still classified `alive` by the tmux liveness
# probe (bin/backends/tmux.sh).
#
# Why this file exists: liveness classification depends on how a harness names
# its own process, which is a surface the harness vendor controls and changes
# without notice. Claude Code began reporting its version string as its process
# name and became unattributable, which silently degraded supervision. A
# regression that only a real harness release can cause needs a check that runs
# real harnesses; a stubbed agent cannot see it, and neither can a table of
# names transcribed from a previous release.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. The launch uses whatever credentials the harness already has; an
# unauthenticated harness still starts its process, which is all the liveness
# probe reads.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. The portable counterpart in
# tests/fm-tmux-agent-liveness.test.sh pins the classifier logic in CI. Run this
# guard after any harness upgrade and before trusting refreshed evidence.
set -u

if [ "${FM_HARNESS_LIVENESS_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_HARNESS_LIVENESS_DRIFT=1 to run the installed-harness liveness drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-liveness-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness-drift.XXXXXX")
SESSION=drift

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cursor-lib.sh"
# The single resolver both real-harness drift guards launch through, so neither
# can measure a different binary than the other or than a real spawn.
# shellcheck source=tests/harness-binary-helpers.sh
. "$ROOT/tests/harness-binary-helpers.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

CHECKED=0
SKIPPED=

# The verified adapters, in the order the harness-adapters skill router records
# them. An adapter that gains a verified launch path belongs here too.
# muse matters most of all here: its launcher execs a VERSION-SUFFIXED binary,
# so the live process name changes on every auto-update and its install path
# carries no `muse` component to fall back on. That is precisely the drift this
# guard exists to catch, and only a real muse release can produce it.
# cursor matters for the same reason muse does, from the other direction: it
# runs as a bundled node script, so its pane title is a bare `node` that no name
# pattern can own, and identity has to come from its install path or argv[0].
for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if ! bin_path=$(fm_test_resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its classification is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  # cursor blocks on a workspace-trust prompt in a directory it has never seen,
  # which would hang this probe rather than classify anything; --trust is the
  # same flag fm-spawn passes for the same reason.
  launch_args=""
  [ "$harness" = cursor ] && launch_args="--trust"
  # shellcheck disable=SC2086  # deliberate: an empty value must add no argument
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" $launch_args \
    || fail "$harness ($version): could not launch a window for the liveness probe"

  state=
  for _ in $(seq 1 300); do
    state=$(fm_backend_agent_state tmux "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done

  title=$(fm_backend_tmux_current_command "$target")
  comms=$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')

  [ "$state" = alive ] || fail \
    "LIVENESS DRIFT: $harness $version is running but classifies '$state', not 'alive'. Supervision and lifecycle control treat this endpoint as unattributable. Observed process title '$title'; observed foreground process names [$comms]. Teach bin/backends/tmux.sh's fm_backend_tmux_classify_process_name the identity this release actually reports."

  note "$harness $version: title='$title' foreground=[$comms]"

  pass "harness liveness: $harness $version classifies alive"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
