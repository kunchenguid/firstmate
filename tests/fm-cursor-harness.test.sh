#!/usr/bin/env bash
# tests/fm-cursor-harness.test.sh - the portable regression for the Cursor
# Agent CLI crewmate/scout adapter.
#
# Cursor's identity, liveness, and busy checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, an env marker, a
# transcript record). This suite pins the LOGIC with real processes, real
# symlink trees, and real transcript files and NO cursor installed, so CI
# enforces it everywhere; the live-harness guard in
# tests/fm-harness-liveness-drift-live-e2e.test.sh is what catches vendor drift
# against a real cursor-agent. Neither replaces the other.
#
# The load-bearing contracts:
#   1. `agent` and `node` are far too generic to trust by name. Cursor identity
#      requires Cursor's own name or install tree in the path or argv[0].
#   2. An unrelated `node`/`agent` pane classifies `other`, which the liveness
#      callers fold into `ambiguous` - NEVER `dead`.
#   3. Cursor's env marker outranks an inherited CLAUDECODE, because cursor does
#      not clear it and whichever marker is tested first wins.
#   4. The transcript fold brackets a turn: a trailing turn_ended is idle, a
#      later role:user is busy, and an unresolvable binding is unknown.
#   5. Cursor is a crewmate/scout adapter only and refuses a secondmate launch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

# A fake cursor install tree with BOTH installed names, shaped exactly like the
# real one: ~/.local/share/cursor-agent/versions/<version>/cursor-agent with
# `cursor-agent` and the legacy `agent` alias symlinked at it.
make_cursor_tree() {  # <root> -> echoes <bindir>
  local root=$1 ver
  ver="$root/share/cursor-agent/versions/2026.08.11-e8db854"
  mkdir -p "$ver" "$root/bin"
  printf '#!/bin/sh\necho "Start the Cursor Agent"\n' > "$ver/cursor-agent"
  chmod +x "$ver/cursor-agent"
  ln -sf "$ver/cursor-agent" "$root/bin/cursor-agent"
  ln -sf "$ver/cursor-agent" "$root/bin/agent"
  printf '%s' "$root/bin"
}

# --- 1. Process identity, against REAL processes ----------------------------

test_identity_accepts_cursor_shapes_rejects_lookalikes() {
  local tree bin real_node_pid impostor_dir out
  tree="$TMP_ROOT/tree1"; bin=$(make_cursor_tree "$tree")

  # Positive: the two real shapes measured on a live pane. tmux reports the
  # pane command as a bare `node` while `ps -o comm=` carries the install path,
  # so BOTH must identify, and neither field may be load-bearing alone.
  fm_cursor_process_matches node '' "$bin/cursor-agent" \
    || fail "tmux's node + cursor-agent argv[0] must identify as cursor"
  fm_cursor_process_matches "$bin/cursor-agent" '' '' \
    || fail "ps's cursor-agent install path must identify as cursor"
  fm_cursor_process_matches cursor-agent '' '' \
    || fail "a bare cursor-agent command name must identify as cursor"
  # The legacy alias identifies only THROUGH the install tree it resolves into.
  fm_cursor_process_matches agent '' "$bin/agent" \
    || fail "the legacy agent alias resolving into cursor's tree must identify"

  # Negative: a REAL unrelated node process, and a REAL executable named agent.
  impostor_dir="$TMP_ROOT/impostor"; mkdir -p "$impostor_dir"
  printf '#!/bin/sh\nsleep 30\n' > "$impostor_dir/agent"; chmod +x "$impostor_dir/agent"
  "$impostor_dir/agent" & local impostor_pid=$!
  if command -v node >/dev/null 2>&1; then
    node -e 'setTimeout(function(){}, 30000)' & real_node_pid=$!
    out=$(LC_ALL=C ps -p "$real_node_pid" -o comm= 2>/dev/null || true)
    if [ -n "$out" ]; then
      ! fm_cursor_process_matches "$out" '' "$out" \
        || fail "a REAL unrelated node process must not identify as cursor (comm='$out')"
    fi
    kill "$real_node_pid" 2>/dev/null || true
  fi
  out=$(LC_ALL=C ps -p "$impostor_pid" -o comm= 2>/dev/null || true)
  if [ -n "$out" ]; then
    ! fm_cursor_process_matches "$out" '' "$out" \
      || fail "a REAL unrelated executable named agent must not identify (comm='$out')"
  fi
  kill "$impostor_pid" 2>/dev/null || true

  # A path with a directory component merely named `agent/` is never enough.
  ! fm_cursor_process_matches node '' /opt/agent/bin/runner \
    || fail "an 'agent/' directory component must not identify as cursor"
  ! fm_cursor_process_matches MainThread '' '' \
    || fail "a bare MainThread with no cursor evidence must not identify"
  ! fm_cursor_process_matches node '' '' \
    || fail "a node with no argv[0] evidence must not identify"
  pass "fm_cursor_process_matches: cursor's real shapes identify; real node/agent lookalikes do not"
}

test_identity_signals_diverge() {
  # Two independent signals carry a positive verdict: the executable NAME and
  # the install-tree PATH. Drive them apart so neither is silently load-bearing:
  # a cursor-named executable OUTSIDE any cursor tree, and a non-cursor-named
  # executable INSIDE one. Both must identify.
  local odd="$TMP_ROOT/odd" tree bin
  mkdir -p "$odd"
  printf '#!/bin/sh\nexit 0\n' > "$odd/cursor-agent"; chmod +x "$odd/cursor-agent"
  fm_cursor_process_matches "$odd/cursor-agent" '' '' \
    || fail "name signal alone (cursor-agent outside any cursor tree) must identify"
  tree="$TMP_ROOT/tree2"; bin=$(make_cursor_tree "$tree")
  fm_cursor_process_matches agent '' "$bin/agent" \
    || fail "path signal alone (alias named 'agent' inside cursor's tree) must identify"
  # And the divergence itself: these two really are different signals.
  [ "$(basename "$odd/cursor-agent")" = cursor-agent ] \
    || fail "name-signal fixture lost its cursor-agent basename"
  case "/$(fm_cursor_canonical_path "$bin/agent")/" in
    */cursor-agent/*) : ;;
    *) fail "path-signal fixture must canonicalize into a cursor-agent tree" ;;
  esac
  pass "fm_cursor_process_matches: name and install-tree signals each carry a verdict alone"
}

test_verify_executable_refuses_unrelated_agent() {
  local tree bin odd="$TMP_ROOT/verify"
  tree="$TMP_ROOT/tree3"; bin=$(make_cursor_tree "$tree")
  mkdir -p "$odd"
  printf '#!/bin/sh\necho unrelated\n' > "$odd/agent"; chmod +x "$odd/agent"
  fm_cursor_verify_executable "$bin/agent" \
    || fail "the alias inside cursor's install tree must verify"
  ! fm_cursor_verify_executable "$odd/agent" \
    || fail "an unrelated executable named agent must NOT verify as cursor"
  pass "fm_cursor_verify_executable: the legacy alias is accepted only with cursor evidence"
}

test_resolve_binary_prefers_stable_path() {
  # The canonical path carries a version cursor replaces on its own auto-update,
  # so resolution must print the STABLE launcher even though identity is proven
  # through canonicalization.
  local tree bin out
  tree="$TMP_ROOT/tree4"; bin=$(make_cursor_tree "$tree")
  out=$(PATH="$bin:$PATH" fm_cursor_resolve_binary) \
    || fail "resolve must succeed when cursor-agent is on PATH"
  [ "$out" = "$bin/cursor-agent" ] \
    || fail "resolve must print the stable launcher, got '$out'"
  case "$out" in *versions*) fail "resolve must not pin the versioned install path" ;; esac
  pass "fm_cursor_resolve_binary: prints the stable launcher, not the versioned target"
}

# --- 2. tmux pane liveness ---------------------------------------------------

test_tmux_classifies_cursor_pane_without_inferring_dead() {
  local tree bin
  tree="$TMP_ROOT/tree5"; bin=$(make_cursor_tree "$tree")
  # shellcheck source=bin/backends/tmux.sh
  ( FM_BACKEND_LIB_DIR="$ROOT/bin"; . "$ROOT/bin/backends/tmux.sh"
    [ "$(fm_backend_tmux_classify_process_name node "$bin/cursor-agent")" = agent ] \
      || fail "a cursor pane reported as node must classify agent"
    [ "$(fm_backend_tmux_classify_process_name '' "$bin/cursor-agent")" = agent ] \
      || fail "the argv[0]-only call must classify a cursor pane agent"
    # The safety half: an unrelated node is `other`, and the callers turn
    # `other` into `ambiguous`, never `dead`.
    [ "$(fm_backend_tmux_classify_process_name node /usr/bin/node)" = other ] \
      || fail "an unrelated node must stay 'other', never agent"
    [ "$(fm_backend_tmux_classify_process_name agent /usr/local/bin/agent)" = other ] \
      || fail "an unrelated agent must stay 'other', never agent"
    # Neighbours must not regress.
    [ "$(fm_backend_tmux_classify_process_name claude '')" = agent ] || fail "claude regressed"
    [ "$(fm_backend_tmux_classify_process_name zsh '')" = shell ] || fail "zsh regressed"
  ) || exit 1
  pass "tmux liveness: a cursor pane is agent; an unrelated node/agent is other, never dead"
}

# --- 3. Detection ordering ---------------------------------------------------

test_cursor_marker_outranks_inherited_claudecode() {
  local out
  # This is the exact hazard: cursor does NOT clear an inherited CLAUDECODE, so
  # a cursor worker under a claude primary carries both markers.
  out=$(CLAUDECODE=1 CURSOR_AGENT=1 "$HARNESS")
  [ "$out" = cursor ] || fail "CLAUDECODE + CURSOR_AGENT must detect cursor, got '$out'"
  out=$(CLAUDECODE=1 CURSOR_INVOKED_AS=cursor-agent "$HARNESS")
  [ "$out" = cursor ] || fail "CLAUDECODE + CURSOR_INVOKED_AS must detect cursor, got '$out'"
  # Both cursor markers stand alone, and neither steals a plain claude session.
  out=$(env -u CLAUDECODE CURSOR_AGENT=1 "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT alone must detect cursor, got '$out'"
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  # A CURSOR_* variable that is not the invocation identity proves nothing.
  out=$(env -u CURSOR_AGENT CLAUDECODE=1 CURSOR_API_ENDPOINT=https://example \
        CURSOR_INVOKED_AS=something-else "$HARNESS")
  [ "$out" = claude ] \
    || fail "an unrelated CURSOR_* setting must not claim the cursor identity, got '$out'"
  pass "fm-harness.sh: cursor's marker outranks an inherited CLAUDECODE"
}

test_identity_accepts_cursor_shapes_rejects_lookalikes
test_identity_signals_diverge
test_verify_executable_refuses_unrelated_agent
test_resolve_binary_prefers_stable_path
test_tmux_classifies_cursor_pane_without_inferring_dead
test_cursor_marker_outranks_inherited_claudecode
