#!/usr/bin/env bash
# Opt-in live guard for Devin CLI as a firstmate PRIMARY.
#
# The Devin primary integration rests on facts only the real devin can answer:
# that its `Stop` hook is awaited so a park can hold the turn boundary, that a
# stdout {"decision":"block"} object genuinely starts a continuation inside the
# same turn, that SessionStart carries additionalContext into model context,
# that the per-session `devin acp` process appears in the session-lock ancestry,
# that tracked `.devin/config.json` really disables the Claude hook import, and
# that a queued captain message stands the park down instead of waiting out the
# hook. A stub can only confirm the assumption already written into the stub, so
# this exercises the installed binary end to end.
#
# tests/fm-devin-primary.test.sh is the portable regression that runs
# everywhere; this is the harness-and-credential-gated counterpart. Run it after
# every Devin upgrade and before trusting refreshed per-harness evidence in
# docs/verification/devin.md and docs/verification/supervision.md.
#
# Isolation: a throwaway firstmate home under a temp dir, a private tmux socket,
# and the user's real Devin login read-only. It never touches the fleet's tmux
# server, never writes a user-scope or global hook, and never runs against a
# live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_DEVIN_PRIMARY_LIVE devin tmux jq

REAL_TMUX=$(command -v tmux)
DEVIN_BIN=${FM_DEVIN_BIN:-$(command -v devin || true)}
[ -n "$DEVIN_BIN" ] && [ -x "$DEVIN_BIN" ] \
  || fail "devin not found; install it or set FM_DEVIN_BIN. This guard refuses to pass without checking the real harness."
VERSION=$("$DEVIN_BIN" --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || fail "devin did not report a version; refusing to claim a verified result"
if ! "$DEVIN_BIN" auth status 2>/dev/null | grep -q '^Logged in'; then
  printf 'skip: live: %s is signed out; run devin auth login\n' "$VERSION"
  exit 0
fi
printf 'harness: %s\n' "$VERSION"

HARNESS_LABEL="$VERSION"
harness_fail() {  # <message>
  fail "$1 [harness: $HARNESS_LABEL]"
}

SOCKET="fm-devin-primary-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-devin-primary.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
HOME_DIR="$LAB/home"
MARKER="FM_DEVIN_LIVE_MARKER_$$"

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # The lab dir is the evidence for this run; keep it and report the path
  # rather than discarding it like an ordinary fixture.
  [ -n "${LAB:-}" ] && printf 'artifacts: %s\n' "$LAB" >&2
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
[ -f "$HOME_DIR/.devin/hooks.v1.json" ] \
  || harness_fail "the working tree ships no .devin/hooks.v1.json; there is nothing to verify"
[ "$(jq -r '.read_config_from.claude' "$HOME_DIR/.devin/config.json" 2>/dev/null)" = false ] \
  || harness_fail "the working tree's .devin/config.json does not disable the Claude import"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
# A unique token the session-start digest must carry into model context.
printf '# Captain\n\nLive marker: %s\n' "$MARKER" > "$HOME_DIR/data/captain.md"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"
# One in-flight task so supervision is genuinely needed, plus a captain-relevant
# status line the watcher's own backstop must surface as a real wake.
cat > "$HOME_DIR/state/probe.meta" <<EOF
id=probe
project=probe
harness=devin
backend=tmux
window=fm-probe
EOF
printf 'blocked: fixture needs a decision\n' > "$HOME_DIR/state/probe.status"

# A project-scope .claude/settings.json logger. With
# read_config_from.claude=false Devin must never fire it; if it does, the
# Claude SessionStart/Stop/UserPromptSubmit hooks are double-running beside
# Devin's own registrations.
mkdir -p "$HOME_DIR/.claude"
jq -n --arg cmd "cat >> '$LAB/claude-hooks.log'; printf '\n' >> '$LAB/claude-hooks.log'" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: $cmd}]}], UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}], Stop: [{hooks: [{type: "command", command: $cmd}]}]}}' \
  > "$HOME_DIR/.claude/settings.json"

# A project-scope Devin UPS logger, kept out of the tracked registration
# (UserPromptSubmit is deliberately unregistered there), so prompt identity is
# observable without changing the shipped surface.
jq -n --arg cmd "cat >> '$LAB/devin-hooks.log'; printf '\n' >> '$LAB/devin-hooks.log'" \
  '{hooks: {UserPromptSubmit: [{matcher: "", hooks: [{type: "command", command: $cmd}]}]}}' \
  > "$HOME_DIR/.devin/config.local.json"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s primary -x 220 -y 60 -c "$HOME_DIR" \
  "cd '$HOME_DIR' && FM_HOME='$HOME_DIR' FM_DEVIN_PARK_POLL=1 exec '$DEVIN_BIN' --permission-mode dangerous --respect-workspace-trust false --model '${FM_DEVIN_MODEL:-swe-2-medium}'" \
  || harness_fail "could not start the private tmux server"

pane_text() {
  # Full scrollback, not just the visible screen: hook-delivered text and tool
  # echoes scroll past on a small pane but stay valid evidence.
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -S - -t primary 2>/dev/null
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

park_seq() {
  sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$HOME_DIR/state/.devin-park-owner" 2>/dev/null
}

wait_for_park_seq() {  # <min-seq> <seconds> <what>
  local want=$1 limit=$2 what=$3 i=0 seq
  while [ "$i" -lt "$((limit * 2))" ]; do
    seq=$(park_seq)
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    [ "$seq" -ge "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  harness_fail "$what did not reach park generation $want within ${limit}s"
}

# --- 1. run-tier session start ----------------------------------------------

wait_for_file "$HOME_DIR/state/.lock" 240 "the fleet session lock"
LOCK_PID=$(cat "$HOME_DIR/state/.lock" 2>/dev/null)
LOCK_ARGS=$(ps -o args= -p "$LOCK_PID" 2>/dev/null || true)
case "$LOCK_ARGS" in
  *'devin acp'*|*'devin'*acp*) ;;
  *) harness_fail "the session lock must be owned by the per-session devin acp process (lock=$LOCK_PID args=$LOCK_ARGS); devin is not resolving in the session-lock ancestry" ;;
esac
pass "devin primary: the SessionStart hook takes the fleet lock as the devin acp process"

wait_for_file "$HOME_DIR/state/.session-start-complete" 300 "the completed session-start record"
pass "devin primary: the run-tier session start completes every stage"

submit "Answer only from the context you were given at session start. Do not run any command. Reply with the exact live marker token you can see, and nothing else."
wait_for_pane "$MARKER" 240 "the session-start digest marker quoted back from model context"
pass "devin primary: SessionStart additionalContext reaches model context before the first turn"

# --- 2. the Stop-hook park ----------------------------------------------------

# The turn that just ended must have parked, armed a watcher, and delivered a
# real wake as one block continuation. Devin does not echo the block reason
# back to the pane, so prove the wake with the durable loop record (one emitted
# block) plus the model visibly running the wake drain the reason directs.
LOOP_FILE="$HOME_DIR/state/.devin-park-loops"
i=0
while [ "$i" -lt 600 ]; do
  grep -q '^count=[1-9]' "$LOOP_FILE" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -q '^count=[1-9]' "$LOOP_FILE" 2>/dev/null \
  || harness_fail "no Stop-hook block was ever emitted within 300s (state/.devin-park-loops: $(cat "$LOOP_FILE" 2>/dev/null))"
wait_for_pane "fm-wake-drain.sh" 300 "the model running the wake drain the block continuation directed"
pass "devin primary: the Stop-hook park delivers a real watcher wake as one block continuation"

wait_for_file "$HOME_DIR/state/.devin-park-owner" 60 "the park ownership record"
BEAT="$HOME_DIR/state/.last-watcher-beat"
[ -e "$BEAT" ] || harness_fail "the park armed no watcher: there is no liveness beacon"
pass "devin primary: the park owns an arm cycle with a live watcher beacon"

# --- 3. queued captain input stands the park down ----------------------------

# Wait for a fresh park after the wake turn, then type a captain message into
# it: Devin renders the message as queued, the park's own-pane poll must see the
# queue marker, kill the arm, and exit so the turn closes and the queue drains.
wait_for_park_seq 1 120 "the first needed park"
BEFORE_SEQ=$(park_seq)
# Never submit the expected reply verbatim: full scrollback contains the
# captain's prompt echo even when the queued turn has not run. A per-run joined
# token can only appear after Devin processes the split-token instruction.
QUEUE_REPLY_SUFFIX="DRAINED_$$_$RANDOM"
QUEUE_REPLY="QUEUE_$QUEUE_REPLY_SUFFIX"
QUEUE_PROMPT="PING-CAPTAIN Do not run any command. Join the two strings QUEUE_ and $QUEUE_REPLY_SUFFIX with no separator, and reply with only the joined token."
case "$QUEUE_PROMPT" in
  *"$QUEUE_REPLY"*) harness_fail "the queued response probe must not contain its expected reply" ;;
esac
case "$(pane_text)" in
  *"$QUEUE_REPLY"*) harness_fail "the queued response token appeared before its prompt was submitted" ;;
esac
submit "$QUEUE_PROMPT"
wait_for_pane "$QUEUE_REPLY" 300 "the queued captain message answered with the joined token as its own turn"
AFTER_SEQ=$BEFORE_SEQ
i=0
while [ "$i" -lt 240 ]; do
  AFTER_SEQ=$(park_seq)
  case "$AFTER_SEQ" in ''|*[!0-9]*) AFTER_SEQ=0 ;; esac
  [ "$AFTER_SEQ" -gt "$BEFORE_SEQ" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "$AFTER_SEQ" -gt "$BEFORE_SEQ" ] \
  || harness_fail "the turn after a queued captain message must claim a newer park generation (before=$BEFORE_SEQ after=$AFTER_SEQ)"
sleep 4
LIVE_PARKS=$(pgrep -f "$HOME_DIR/bin/fm-turnend-guard-devin.sh" 2>/dev/null | wc -l | tr -d ' ')
[ "${LIVE_PARKS:-0}" -le 1 ] \
  || harness_fail "an older park leaked after the newer stop claim: $LIVE_PARKS park processes are alive"
[ -e "$LAB/devin-hooks.log" ] || harness_fail "the local UserPromptSubmit logger saw no prompt; the queued message did not drain as its own turn"
QUEUED_PROMPTS=$(jq -r '.prompt_id // empty' "$LAB/devin-hooks.log" 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ "${QUEUED_PROMPTS:-0}" -ge 2 ] \
  || harness_fail "the queued captain message did not arrive as its own prompt: $(cat "$LAB/devin-hooks.log" 2>/dev/null)"
pass "devin primary: queued captain input stands the park down, drains as its own turn, and the next stop re-parks"

# --- 4. Claude import stays off ----------------------------------------------

[ ! -e "$LAB/claude-hooks.log" ] \
  || harness_fail "the project .claude/settings.json hooks fired under Devin: $(head -c 300 "$LAB/claude-hooks.log")"
pgrep -f "$HOME_DIR/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1 \
  && harness_fail "the Claude auto-arm ran under Devin; it would park the turn synchronously for its multi-hour timeout"
pass "devin primary: read_config_from.claude=false held - no Claude-shaped hook or auto-arm ran"

cleanup_all
trap - EXIT
