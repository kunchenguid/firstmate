#!/usr/bin/env bash
# tests/fm-harness-liveness-drift-live-e2e.test.sh - default-on drift guard proving
# every INSTALLED harness is still classified `alive` by the tmux liveness
# probe (bin/backends/tmux.sh) AND still identified by the harness-detection
# ancestry walk (bin/fm-harness.sh).
#
# Why this file exists: both verdicts depend on how a harness names its own
# process, which is a surface the harness vendor controls and changes without
# notice. Claude Code began reporting its version string as its process name and
# became unattributable, which silently degraded supervision. A regression that
# only a real harness release can cause needs a check that runs real harnesses;
# a stubbed agent cannot see it, and neither can a table of names transcribed
# from a previous release.
#
# Detection carries the same exposure for a second reason: a structural ancestor
# now outranks an environment marker (bin/fm-harness.sh owns that boundary), so
# a harness whose process name stops matching no longer merely loses a fast
# path - the walk keeps climbing and can reach a DIFFERENT harness that really
# is further up the tree. This guard is what catches that at the release that
# causes it.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. The launch uses whatever credentials the harness already has; an
# unauthenticated harness still starts its process, which is all the liveness
# probe reads.
#
# Portable serial CI installs the public Pi package but no credentials, so this
# guard checks that available token-free surface there and runs against every installed
# harness on more capable hosts. The portable counterpart in
# tests/fm-tmux-agent-liveness.test.sh pins the classifier logic in CI. Run this
# guard after any harness upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HARNESS_LIVENESS_DRIFT tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

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
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

resolve_harness_binary() { command -v "$1"; }

CHECKED=0
SKIPPED=

# Retained tmux-capable adapters; TraeX is Herdr-only.
for harness in codex pi; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
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
    "LIVENESS DRIFT: $harness $version is running but classifies '$state', not 'alive'. Supervision and lifecycle control treat this endpoint as unattributable. Observed process title '$title'; observed foreground process names [$comms]. Teach bin/fm-agent-process-lib.sh's fm_agent_process_classify_name the identity this release actually reports."

  note "$harness $version: title='$title' foreground=[$comms]"

  pass "harness liveness: $harness $version classifies alive"

  # Detection: ask the ancestry walk what it makes of this real harness process.
  # Both Pi identities share one launcher name, so ancestry can only ever prove
  # the family; only the launch-boundary marker selects the signed identity.
  expect_harness=$harness
  pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_pid}' 2>/dev/null | tr -d ' ')
  [ -n "$pane_pid" ] || fail "$harness ($version): could not read the pane pid for the detection probe"
  # Probe from BELOW the pane process, not the pane process alone. The shipped
  # guarantee is a strength claim: detect_own hands an args-strength verdict back
  # to a retained foreign marker, so a harness is only protected where the walk
  # reaches it at comm strength. A harness that ships as a thin interpreter shim
  # spawning its native binary as a CHILD is args strength from the pane process
  # and comm strength from below that child - which is where firstmate's own
  # detection actually runs, as a tool subprocess. Probing only the pane would
  # therefore pass on evidence the guarantee does not rest on, and would keep
  # passing if a release stopped spawning the native child at all.
  #
  # The vantage set is the UPWARD path from the deepest foreground descendant, not
  # every descendant in the subtree, because harness_ancestry only ever climbs: a
  # sibling branch is a vantage firstmate's own detection can never occupy.
  # Restricting the deepest descendant to the pane tty's foreground process group
  # keeps a process left running in the background out of the selection as well.
  #
  # The reject-other-harness cross-check below judges COMM-strength vantages only.
  # An args-strength verdict is path-ambiguous by construction: harness_ancestry's
  # bare-interpreter branch matches a harness name anywhere in the script path, so a
  # harness-spawned MCP server running as `node <home>/.claude/mcp/<server>.js`
  # answers `args claude` purely from the .claude path component, and such a server
  # is normally a child of the agent binary rather than a sibling of it, so it can
  # be the deepest descendant and sit ON this path. That ambiguity is the sole source
  # of the false failure; a comm-strength verdict carries the real process name and
  # cannot be produced that way. The comm-strength REQUIREMENT is unchanged - some
  # vantage on the path must still name the expected harness at comm strength,
  # because detect_own hands an args-strength verdict straight back to a retained
  # foreign marker.
  # The native binary can take a moment to appear, so poll for it.
  pane_tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_tty}' 2>/dev/null | tr -d ' ')
  verdicts=
  for _ in $(seq 1 150); do
    fg_pids=
    if [ -n "$pane_tty" ]; then
      fg_pids=$(LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null \
        | while read -r fg_pid fg_pgid fg_tpgid; do
            [ -n "$fg_pid" ] || continue
            [ "$fg_pgid" = "$fg_tpgid" ] || continue
            printf '%s ' "$fg_pid"
          done)
    fi
    # shellcheck disable=SC2086  # deliberate: the foreground pids are separate arguments
    verdicts=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" $fg_pids 2>/dev/null || true)
    case "$verdicts" in *"comm $expect_harness"*) break ;; esac
    sleep 0.2
  done

  drift_context="Observed process title '$title'; observed foreground process names [$comms]; observed ancestry verdicts [$(printf '%s' "$verdicts" | tr '\n' ';')]."

  [ -n "$verdicts" ] || fail \
    "DETECTION DRIFT: $harness $version is running but the ancestry walk reports nothing from the pane process or any vantage below it, so firstmate cannot identify this session at all. $drift_context Teach bin/fm-harness.sh's harness_ancestry the name this release actually reports."

  SAW_COMM=0
  while read -r strength named; do
    [ -n "$strength" ] || continue
    [ "$strength" = comm ] || continue
    [ "$named" = "$expect_harness" ] || fail \
      "DETECTION DRIFT: $harness $version is running but a comm-strength vantage point on the upward path through its own session resolves to '$named', not '$expect_harness'. bin/fm-harness.sh lets a structural ancestor outrank an environment marker, so an unmatched process name can resolve to a DIFFERENT harness further up the tree instead of merely losing a fast path. $drift_context Teach bin/fm-harness.sh's harness_ancestry the name this release actually reports."
    SAW_COMM=1
  done <<EOF
$verdicts
EOF

  [ "$SAW_COMM" = 1 ] || fail \
    "DETECTION DRIFT: $harness $version is identified only at interpreter-args strength, from no vantage point on the upward path through its session at comm strength. detect_own hands an args-strength verdict back to a retained foreign marker, so a stale CLAUDECODE would silently rename this session even though this guard sees the right identity. $drift_context Restore a process name bin/fm-harness.sh's harness_ancestry can match structurally, or teach it the name this release reports."

  note "$harness $version: ancestry verdicts=[$(printf '%s' "$verdicts" | tr '\n' ';')]"
  pass "harness detection: $harness $version is identified by the ancestry walk at comm strength"
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
