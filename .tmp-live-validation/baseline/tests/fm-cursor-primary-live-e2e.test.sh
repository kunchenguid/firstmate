#!/usr/bin/env bash
# Opt-in live guard for Cursor Agent CLI as a firstmate PRIMARY.
#
# The Cursor primary integration rests on facts only the real cursor-agent can
# answer: that its `stop` hook is awaited so a park can hold the turn boundary,
# that a returned followup_message genuinely starts another turn, that
# `sessionStart` carries additional_context into model context, that Cursor's own
# process appears in the session-lock ancestry, and that an idle Cursor composer
# can be proven empty so an away-mode escalation can be delivered. A stub can
# only confirm the assumption already written into the stub, so this exercises
# the installed binary end to end.
#
# tests/fm-cursor-primary.test.sh and the Cursor cases in
# tests/fm-tmux-agent-liveness.test.sh are the portable regressions that run
# everywhere; this is the harness-and-credential-gated counterpart. Run it after
# every Cursor upgrade and before trusting refreshed per-harness evidence in
# docs/verification/supervision.md and docs/verification/runtime-backends.md.
#
# Isolation: a throwaway firstmate home under a temp dir, a private tmux socket,
# and a Cursor workspace Cursor has never seen. It never touches the fleet's tmux
# server, never writes a user-scope or global hook, and never runs against a live
# home. Cursor still records its own per-project transcript under
# ~/.cursor/projects/<slug of the temp path>, which is keyed to the throwaway
# path and is the only state left outside the temp dir.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CURSOR_PRIMARY_LIVE_E2E tmux jq

REAL_TMUX=$(command -v tmux)
CURSOR_BIN=${FM_CURSOR_BIN:-$(command -v cursor-agent || true)}
[ -n "$CURSOR_BIN" ] && [ -x "$CURSOR_BIN" ] \
  || fail "cursor-agent not found; install it or set FM_CURSOR_BIN. This guard refuses to pass without checking the real harness."
CURSOR_VERSION=$("$CURSOR_BIN" --version 2>/dev/null | head -1)
[ -n "$CURSOR_VERSION" ] || fail "cursor-agent did not report a version; refusing to claim a verified result"
printf 'harness: cursor-agent %s\n' "$CURSOR_VERSION"

HARNESS_LABEL="cursor-agent $CURSOR_VERSION"
harness_fail() {  # <message>
  fail "$1 [harness: $HARNESS_LABEL]"
}

SOCKET="fm-cursor-primary-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-primary.XXXXXX")
HOME_DIR="$LAB/home"
MARKER="FM_CURSOR_LIVE_MARKER_$$"

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A plain (non-worktree) checkout of the CURRENT working tree, so the guard
# tests the code under review rather than whatever is committed.
mkdir -p "$HOME_DIR"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || harness_fail "could not stage the working tree into the throwaway home"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q -m "live-e2e fixture" >/dev/null 2>&1 || true
[ "$(git -C "$HOME_DIR" rev-parse --git-dir)" = "$(git -C "$HOME_DIR" rev-parse --git-common-dir)" ] \
  || harness_fail "the fixture home must be a plain checkout for primary scope to match"
[ -f "$HOME_DIR/.cursor/hooks.json" ] \
  || harness_fail "the working tree ships no .cursor/hooks.json; there is nothing to verify"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
# A unique token the session-start digest must carry into model context.
printf '# Captain\n\nLive marker: %s\n' "$MARKER" > "$HOME_DIR/data/captain.md"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"
# One in-flight task so supervision is genuinely needed, plus a captain-relevant
# status line the watcher's own backstop must surface as a real wake.
cat > "$HOME_DIR/state/probe.meta" <<EOF
id=probe
project=probe
harness=cursor
backend=tmux
window=fm-probe
EOF
printf 'blocked: fixture needs a decision\n' > "$HOME_DIR/state/probe.status"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s primary -x 220 -y 60 -c "$HOME_DIR" \
  "cd '$HOME_DIR' && FM_HOME='$HOME_DIR' FM_HEARTBEAT=30 FM_HEARTBEAT_MAX=30 exec '$CURSOR_BIN' --trust --yolo --workspace '$HOME_DIR'" \
  || harness_fail "could not start the private tmux server"

pane_text() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t primary 2>/dev/null
}

wait_for_file() {  # <path> <seconds> <what>
  local path=$1 limit=$2 what=$3 i=0
  while [ "$i" -lt "$((limit * 2))" ]; do
    [ -e "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  harness_fail "$what did not appear within ${limit}s"
}

wait_for_pane() {  # <needle> <seconds> <what>
  local needle=$1 limit=$2 what=$3 i=0
  while [ "$i" -lt "$((limit * 2))" ]; do
    case "$(pane_text)" in *"$needle"*) return 0 ;; esac
    sleep 0.5
    i=$((i + 1))
  done
  printf 'pane at failure:\n%s\n' "$(pane_text)" >&2
  harness_fail "$what did not appear within ${limit}s"
}

submit() {  # <text>
  "$REAL_TMUX" -L "$SOCKET" send-keys -t primary -l "$1"
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t primary Enter
}

# --- 1. run-tier session start ----------------------------------------------

wait_for_file "$HOME_DIR/state/.lock" 180 "the fleet session lock"
LOCK_PID=$(cat "$HOME_DIR/state/.lock" 2>/dev/null)
PANE_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t primary '#{pane_pid}' 2>/dev/null)
[ -n "$LOCK_PID" ] && [ "$LOCK_PID" = "$PANE_PID" ] \
  || harness_fail "the session lock must be owned by the Cursor pane process (lock=$LOCK_PID pane=$PANE_PID); Cursor is not resolving in the session-lock ancestry"
pass "cursor primary: the sessionStart hook takes the fleet lock as the Cursor process itself"

wait_for_file "$HOME_DIR/state/.session-start-complete" 240 "the completed session-start record"
pass "cursor primary: the run-tier session start completes every stage"

submit "Answer only from the context you were given at session start. Do not run any command. Reply with the exact live marker token you can see, and nothing else."
wait_for_pane "$MARKER" 180 "the session-start digest marker quoted back from model context"
pass "cursor primary: sessionStart additional_context reaches model context before the first turn"

# --- 2. the stop-hook park ---------------------------------------------------

# The turn that just ended must have parked, armed a watcher, and delivered a
# real wake as one follow-up carrying the operational watcher kind.
wait_for_pane "FIRSTMATE_OP: v1 watcher:" 300 "a watcher wake delivered as a stop-hook follow-up"
pass "cursor primary: the stop-hook park delivers a real watcher wake as one follow-up"

wait_for_file "$HOME_DIR/state/.cursor-park-owner" 60 "the park ownership record"
PARK_PID=$(sed -n 's/^seq=[0-9][0-9]* pid=\([0-9][0-9]*\) .*/\1/p' "$HOME_DIR/state/.cursor-park-owner")
[ -n "$PARK_PID" ] || harness_fail "the park never recorded an owner pid"
BEAT="$HOME_DIR/state/.last-watcher-beat"
[ -e "$BEAT" ] || harness_fail "the park armed no watcher: there is no liveness beacon"
pass "cursor primary: the park owns exactly one arm cycle with a live watcher beacon"

# --- 3. supersession ---------------------------------------------------------

park_seq() {
  sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$HOME_DIR/state/.cursor-park-owner" 2>/dev/null
}

BEFORE_SEQ=$(park_seq)
submit "Reply with exactly the token CAPTAIN_INTERRUPT and nothing else. Do not run any command."
wait_for_pane "CAPTAIN_INTERRUPT" 180 "the captain message answered while the hook was parked"
# The new park claims only when that answering turn ENDS, so wait for the baton
# rather than racing it.
AFTER_SEQ=$BEFORE_SEQ
i=0
while [ "$i" -lt 240 ]; do
  AFTER_SEQ=$(park_seq)
  [ -n "$AFTER_SEQ" ] && [ "$AFTER_SEQ" -gt "$BEFORE_SEQ" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -n "$AFTER_SEQ" ] && [ "$AFTER_SEQ" -gt "$BEFORE_SEQ" ] \
  || harness_fail "a captain message mid-park must claim a newer park generation (before=$BEFORE_SEQ after=$AFTER_SEQ)"
# Give the older park one poll interval to observe the newer stop's claim.
sleep 5
LIVE_PARKS=$(pgrep -f "$HOME_DIR/bin/fm-turnend-guard-cursor.sh" 2>/dev/null | wc -l | tr -d ' ')
[ "${LIVE_PARKS:-0}" -le 1 ] \
  || harness_fail "an older park leaked after the newer stop claim: $LIVE_PARKS park processes are alive, and each could deliver a stale duplicate wake"
pass "cursor primary: the captain keeps control and the older park stands down after the next stop claim"

# --- 4. away-mode escalation delivery ---------------------------------------

: > "$HOME_DIR/state/.afk"
AWAY_TOKEN="AWAY_ACK_$$"
INJECT_RC=0
cat > "$LAB/inject.sh" <<EOS
#!/usr/bin/env bash
set -u
tmux() { command "$REAL_TMUX" -L "$SOCKET" "\$@"; }
export -f tmux 2>/dev/null || true
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_SUPERVISOR_TARGET=primary
export FM_SUPERVISOR_BACKEND=tmux
export FM_DAEMON_PRIMARY_HARNESS=cursor
. "$HOME_DIR/bin/fm-supervise-daemon.sh"
composer=\$(fm_backend_composer_state tmux primary)
printf 'composer=%s\n' "\$composer"
[ "\$composer" = empty ] || exit 3
inject_msg "AWAY PROBE - reply with exactly the token $AWAY_TOKEN and nothing else." "$HOME_DIR/state"
EOS
chmod +x "$LAB/inject.sh"
COMPOSER_OUT=$(bash "$LAB/inject.sh" 2>&1) || INJECT_RC=$?
case "$COMPOSER_OUT" in
  *composer=empty*) ;;
  *) harness_fail "an idle Cursor composer must be provably empty for away mode; got: $COMPOSER_OUT" ;;
esac
[ "$INJECT_RC" -eq 0 ] \
  || harness_fail "the away-mode escalation could not confirm delivery into the Cursor pane (rc=$INJECT_RC): $COMPOSER_OUT"
wait_for_pane "$AWAY_TOKEN" 180 "the away-mode escalation processed by the Cursor primary"
pass "cursor primary: an away-mode escalation is delivered, confirmed, and processed"

rm -f "$HOME_DIR/state/.afk"

cleanup_all
trap - EXIT
