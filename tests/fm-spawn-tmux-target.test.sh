#!/usr/bin/env bash
# Regression tests for fm-spawn.sh tmux target disambiguation.
#
# Bug guarded against: tmux parses a bare token passed to `-t` ambiguously - a
# NUMERIC session name (a captain session literally named "7") resolves as a
# window INDEX of the current session instead of the session itself, so
# `new-window -t "$SES"` lands the crewmate window in an unrelated session or
# fails outright on an occupied index (observed 2026-07-01, tmux 3.4). fm-spawn
# now uses the exact-match session form `-t "=$SES:"` ('=' pins exact-name
# matching, the trailing ':' pins session interpretation) and
# `has-session -t '=firstmate'`.
#
# These tests run fm-spawn END TO END against a real tmux server on a private
# socket (tmux -L), like tests/fm-afk-inject-e2e.test.sh: a decoy session and a
# session literally named "7" with its window index 7 occupied reproduce the
# ambiguous world, a pane-PATH fake treehouse moves the pane into a real git
# worktree so the isolation guard passes, and a fake claude keeps the launch a
# no-op. The first check documents the raw tmux ambiguity itself, so if a future
# tmux changes bare-target parsing the guard's premise is re-examined loudly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Skip gracefully if tmux is not installed (CI requires it; a dev box may not).
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-spawn-tt-$$"
TMP_ROOT=$(fm_test_tmproot fm-spawn-tmux-target)

ID_NUM="tt-numses-z1"
ID_OUT="tt-outside-z2"

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "/tmp/fm-$ID_NUM" "/tmp/fm-$ID_OUT"
  fm_test_cleanup
}
trap cleanup EXIT

tt() { "$REAL_TMUX" -L "$SOCKET" "$@"; }

# --- world ------------------------------------------------------------------

HOME_DIR="$TMP_ROOT/home"
PANEBIN="$TMP_ROOT/panebin"
SHIMBIN="$TMP_ROOT/shimbin"
WT_PTR="$TMP_ROOT/wt-pointer"
mkdir -p "$HOME_DIR/data" "$PANEBIN" "$SHIMBIN"

fm_git_init_commit "$HOME_DIR/projects/alpha"
git -C "$HOME_DIR/projects/alpha" worktree add --detach "$TMP_ROOT/wt-num" >/dev/null 2>&1 \
  || fail "could not create fixture worktree wt-num"
git -C "$HOME_DIR/projects/alpha" worktree add --detach "$TMP_ROOT/wt-out" >/dev/null 2>&1 \
  || fail "could not create fixture worktree wt-out"

for id in "$ID_NUM" "$ID_OUT"; do
  mkdir -p "$HOME_DIR/data/$id"
  printf 'test brief\n' > "$HOME_DIR/data/$id/brief.md"
done

# Pane-side fakes. The pane shell's PATH is pinned to PANEBIN via default-command
# below, so every pane resolves these: 'treehouse get' moves the pane into the
# worktree named by the pointer file (the real subshell behavior fm-spawn waits
# for), and 'claude' makes the typed launch command a no-op instead of starting a
# real agent. Pinning is deterministic on purpose: relying on the tmux server
# inheriting PANEBIN through its environment is fragile (it broke in CI, where no
# real 'treehouse' exists to mask a missing fake), so the pane PATH is set
# explicitly rather than inherited.
cat > "$PANEBIN/treehouse" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = get ] || exit 0
wt=\$(cat '$WT_PTR')
cd "\$wt" && exec bash --noprofile --norc
SH
cat > "$PANEBIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$PANEBIN/treehouse" "$PANEBIN/claude"

# tmux shim for the outside-tmux case: fm-spawn with TMUX unset must still talk
# to the private server, never the developer's real one.
cat > "$SHIMBIN/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
SH
chmod +x "$SHIMBIN/tmux"

# Private server: decoy session first, then a session literally named "7" so it
# is the server's current session; occupy its window indices 1..7 to make the
# historical bare `-t 7` collide deterministically. default-command pins PANEBIN
# onto every pane's PATH (and keeps panes rc-free), so a typed `treehouse`/`claude`
# resolves to the fakes regardless of the server's inherited environment.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s other -x 200 -y 50 \
  || fail "could not start private tmux server"
tt set-option -g default-command "PATH=\"$PANEBIN\":\$PATH exec bash --noprofile --norc"
tt new-session -d -s 7 -x 200 -y 50
for i in 1 2 3 4 5 6 7; do tt new-window -d -t "=7:$i"; done

SOCK_PATH=$(tt display-message -p '#{socket_path}')
FAKE_TMUX_ENV="$SOCK_PATH,$$,0"

# Precondition: with TMUX pointing at the private socket, the current session is
# the numeric one, exactly the world fm-spawn resolves SES from.
[ "$(TMUX="$FAKE_TMUX_ENV" "$REAL_TMUX" display-message -p '#S')" = "7" ] \
  || fail "precondition: current session on the private server is not '7'"

# Fail fast, with a clear message, if a pane cannot resolve the fake treehouse -
# the exact CI failure mode (fm-spawn otherwise just times out after 60s on the
# missing worktree handoff). Runs one throwaway pane through the pinned PATH.
probe_pane_resolves_fake_treehouse() {
  local probe="$TMP_ROOT/probe.out" flag="$TMP_ROOT/probe.flag"
  rm -f "$probe" "$flag"
  tt new-window -d -t '=7:' -n fm-probe
  tt send-keys -t '=7:fm-probe' \
    "command -v treehouse > '$probe' 2>&1; printf done > '$flag'" Enter
  local _
  for _ in $(seq 1 40); do [ -f "$flag" ] && break; sleep 0.25; done
  tt kill-window -t '=7:fm-probe' 2>/dev/null || true
  grep -qx "$PANEBIN/treehouse" "$probe" 2>/dev/null
}
probe_pane_resolves_fake_treehouse \
  || fail "pane shell cannot resolve the fake treehouse (PANEBIN not on pane PATH); test world misconfigured"

wait_for_window() { # <session> <window-name> -> 0 once present within ~15s
  local ses=$1 name=$2
  for _ in $(seq 1 30); do
    if tt list-windows -t "=$ses:" -F '#{window_name}' 2>/dev/null | grep -qx "$name"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# --- 1. the raw tmux ambiguity this fix guards against -----------------------
# Documents the premise: a bare numeric -t target is parsed as a window index of
# the current session (here: occupied index 7 -> hard failure), while the exact
# session form lands in session "7" at the next free index. If a future tmux
# resolves the bare form to the session, say so instead of failing: the fix is
# then belt-and-braces rather than load-bearing.
test_raw_tmux_ambiguity() {
  local out
  if out=$(TMUX="$FAKE_TMUX_ENV" "$REAL_TMUX" new-window -d -t 7 -n rawbare 2>&1); then
    if tt list-windows -t '=7:' -F '#{window_name}' | grep -qx rawbare; then
      pass "raw tmux: bare numeric -t now resolves to the session (fix is belt-and-braces on this tmux)"
      return
    fi
    fail "raw tmux: bare -t 7 created 'rawbare' outside session 7 and outside index interpretation: $out"
  fi
  assert_contains "$out" "index 7 in use" "bare -t 7 failed for an unexpected reason"
  TMUX="$FAKE_TMUX_ENV" "$REAL_TMUX" new-window -d -t '=7:' -n rawexact \
    || fail "raw tmux: exact form '=7:' failed"
  tt list-windows -t '=7:' -F '#{window_name}' | grep -qx rawexact \
    || fail "raw tmux: exact form '=7:' did not land in session 7"
  tt kill-window -t '=7:rawexact'
  pass "raw tmux: bare numeric -t collides with a window index; exact form '=7:' pins the session"
}

# --- 2. fm-spawn inside tmux with a numeric session name ---------------------
# The acceptance case: firstmate runs inside a session literally named "7" with
# its window index 7 occupied; the spawned window must land in session 7 with no
# collision, and nothing may leak into the decoy session.
test_spawn_numeric_session() {
  local out
  printf '%s\n' "$TMP_ROOT/wt-num" > "$WT_PTR"
  out=$(TMUX="$FAKE_TMUX_ENV" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$ID_NUM" projects/alpha claude 2>&1) \
    || fail "fm-spawn failed in numeric session: $out"
  assert_contains "$out" "window=7:fm-$ID_NUM" "spawn did not report the numeric-session window"
  wait_for_window 7 "fm-$ID_NUM" \
    || fail "window fm-$ID_NUM did not appear in session 7"
  tt list-windows -t '=other:' -F '#{window_name}' | grep -q "^fm-$ID_NUM$" \
    && fail "window fm-$ID_NUM leaked into the decoy session 'other'"
  assert_grep "window=7:fm-$ID_NUM" "$HOME_DIR/state/$ID_NUM.meta" \
    "meta did not record the numeric-session window target"
  pass "fm-spawn in a session named '7' lands its window in session 7 despite occupied index 7"
}

# --- 3. fm-spawn outside tmux keeps the dedicated-session path ---------------
# Existing behavior must keep working: with TMUX unset, fm-spawn creates/uses the
# 'firstmate' session (now via exact-match has-session) and spawns there.
test_spawn_outside_tmux() {
  local out
  printf '%s\n' "$TMP_ROOT/wt-out" > "$WT_PTR"
  out=$(env -u TMUX PATH="$SHIMBIN:$PATH" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$ID_OUT" projects/alpha claude 2>&1) \
    || fail "fm-spawn failed outside tmux: $out"
  assert_contains "$out" "window=firstmate:fm-$ID_OUT" "spawn did not report the firstmate-session window"
  tt has-session -t '=firstmate' 2>/dev/null \
    || fail "outside-tmux spawn did not create the 'firstmate' session"
  wait_for_window firstmate "fm-$ID_OUT" \
    || fail "window fm-$ID_OUT did not appear in the firstmate session"
  pass "fm-spawn outside tmux still creates and targets the dedicated 'firstmate' session"
}

test_raw_tmux_ambiguity
test_spawn_numeric_session
test_spawn_outside_tmux

echo "all fm-spawn tmux target tests passed"
