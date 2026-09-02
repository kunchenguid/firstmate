#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock can run fm-session-start.sh first; session start reclaims the
# dead owner; at least two tokenless auto-arm and rewake cycles then complete
# with zero model-issued arm commands; and the cooperative guard consumes no
# forced continuation while the hook's launch is healthy.
# A second isolated session then covers the away-mode return: a real away-mode
# episode is entered with bin/fm-afk-launch.sh, crosses a real turn boundary
# while the away daemon owns supervision, is left with bin/fm-afk-return.sh, and
# the very next Stop must bring the auto-arm back on its own with no model-issued
# arm command. That is the 2026-08-27 lapse, where the epoch ledger stayed frozen
# on the episode's terminal entry and every later turn boundary blocked instead.
# It also guards the vendor-emitted half of the hook's session-identity proof:
# the installed Claude Code must still deliver a session pid and session id to
# its Stop hooks, and the delivered payload must still name the same session,
# because bin/fm-session-lock-lib.sh cannot prove ownership from ancestry alone
# when Claude serves the hook from its shared worker pool. That proof is
# measured on BOTH delivery paths, synchronous and detached asyncRewake, because
# the hook that consumes it is registered asyncRewake and a release that kept
# the signals only on the synchronous path would return the fleet to the
# inert-hook bug with every other check still green. Losing either signal on
# either path fails here, naming the harness and version, instead of silently
# returning the whole fleet to the inert-hook bug.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude Stop auto-arm regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

AFK_HOME="$LAB/afk-home"
AFK_PROJECT="$LAB/afk-project"
AFK_TRANSCRIPT="$LAB/claude-afk.jsonl"
AFK_CAPTAIN_SESSION="fm-autoarm-live-afk-$$"

cleanup() {
  if [ -d "$AFK_PROJECT" ]; then
    FM_HOME="$AFK_HOME" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=unused \
      "$AFK_PROJECT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || true
  fi
  tmux kill-session -t "$AFK_CAPTAIN_SESSION" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart nudge,
# Stop guard, and asyncRewake auto-arm registration.
# The local hooks only record model-issued Bash calls and what Claude hands a
# Stop hook on each delivery path, the synchronous one and the detached
# asyncRewake one the auto-arm itself runs on. Neither acquires the session lock
# or otherwise changes lifecycle behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/stop-identity-probe.sh stop-identity.log" },
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/bin/stop-identity-probe.sh stop-identity-async.log",
            "asyncRewake": true,
            "timeout": 600
          }
        ]
      }
    ]
  }
}
JSON

# Records what the installed Claude Code actually hands a Stop hook. $1 names
# the log for this delivery path, so the synchronous and asyncRewake
# registrations never share a file. It exits 0 silently and holds no lock, so it
# changes no lifecycle behavior on either path.
cat > "$PROJECT/bin/stop-identity-probe.sh" <<'SH'
#!/usr/bin/env bash
PAYLOAD=$(cat 2>/dev/null || true)
{
  printf 'claude_pid=%s\n' "${CLAUDE_PID:-}"
  printf 'env_session_id=%s\n' "${CLAUDE_CODE_SESSION_ID:-}"
  printf 'payload=%s\n' "$PAYLOAD"
} >> "$FM_HOME/state/$1" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/stop-identity-probe.sh"

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Runs 1-2 close actionable; run 3 closes clean so
# a misbehaving session can never loop forever.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: the in-flight need ends on the CYCLE count this test measures,
# not on a drain count. The tracked SessionStart hook runs one digest and the
# prompt has the model run a second, so drains alone are not a stable measure of
# Stop-owned cycles. Ending the need here, in the model's own handling turn,
# also keeps the last cycle from spending its bounded retry on a vanished need.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0)" -ge 2 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='Run exactly `bin/fm-session-start.sh` with Bash as your first tool call. After reading its complete digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

# Vendor-emitted session identity: the second ownership proof in
# bin/fm-session-lock-lib.sh reads these, so a release that stops delivering any
# of them must fail loudly here rather than degrade the whole fleet to an inert
# Stop hook.
IDENTITY_LOG="$HOME_DIR/state/stop-identity.log"
[ -s "$IDENTITY_LOG" ] || fail "Claude $CLAUDE_VERSION delivered no Stop hook identity at all"
PROBE_PID=$(sed -n 's/^claude_pid=//p' "$IDENTITY_LOG" | sed -n '1p')
PROBE_ENV_SESSION=$(sed -n 's/^env_session_id=//p' "$IDENTITY_LOG" | sed -n '1p')
PROBE_PAYLOAD=$(sed -n 's/^payload=//p' "$IDENTITY_LOG" | sed -n '1p')
case "$PROBE_PID" in
  ''|*[!0-9]*) fail "Claude $CLAUDE_VERSION no longer exports a numeric CLAUDE_PID to its Stop hooks (got '$PROBE_PID')" ;;
esac
[ -n "$PROBE_ENV_SESSION" ] \
  || fail "Claude $CLAUDE_VERSION no longer exports CLAUDE_CODE_SESSION_ID to its Stop hooks"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"  # for fm_claude_payload_session_id
PROBE_PAYLOAD_SESSION=$(fm_claude_payload_session_id "$PROBE_PAYLOAD") \
  || fail "Claude $CLAUDE_VERSION no longer names a session_id in its Stop payload: $PROBE_PAYLOAD"
[ "$PROBE_PAYLOAD_SESSION" = "$PROBE_ENV_SESSION" ] \
  || fail "Claude $CLAUDE_VERSION delivered a Stop payload for session $PROBE_PAYLOAD_SESSION while exporting $PROBE_ENV_SESSION, so the two identity signals no longer corroborate each other"

# The two proofs must still designate the same process: the session pid Claude
# exports is the pid this session recorded as the home's owner. Without that
# correspondence the identity proof would name a process the lock never records,
# and the hook would go inert again. The decision logic itself is pinned
# portably by tests/fm-claude-stop-autoarm.test.sh with real processes.
RECORDED_OWNER=$(cat "$HOME_DIR/state/.lock" 2>/dev/null || true)
[ "$PROBE_PID" = "$RECORDED_OWNER" ] \
  || fail "Claude $CLAUDE_VERSION exported session pid $PROBE_PID while this session recorded owner $RECORDED_OWNER, so the session-identity proof no longer matches the recorded owner"

# The same proof on the delivery path the auto-arm actually runs on. Claude
# registers bin/fm-claude-stop-autoarm.sh with "asyncRewake": true, so it is
# served detached, which is the very context the shared worker pool broke. A
# release that kept exporting identity to synchronous Stop hooks and stopped on
# the detached ones would leave every check above green while the hook went
# inert again, so the detached path carries its own alarm. An absent log is that
# regression, not a reason to skip.
ASYNC_IDENTITY_LOG="$HOME_DIR/state/stop-identity-async.log"
async_wait=0
while [ "$async_wait" -lt 60 ] && [ ! -s "$ASYNC_IDENTITY_LOG" ]; do
  async_wait=$((async_wait + 1))
  sleep 0.5
done
[ -s "$ASYNC_IDENTITY_LOG" ] \
  || fail "Claude $CLAUDE_VERSION delivered no Stop hook identity at all on the detached asyncRewake path, the path bin/fm-claude-stop-autoarm.sh runs on"
ASYNC_PROBE_PID=$(sed -n 's/^claude_pid=//p' "$ASYNC_IDENTITY_LOG" | sed -n '1p')
ASYNC_PROBE_ENV_SESSION=$(sed -n 's/^env_session_id=//p' "$ASYNC_IDENTITY_LOG" | sed -n '1p')
ASYNC_PROBE_PAYLOAD=$(sed -n 's/^payload=//p' "$ASYNC_IDENTITY_LOG" | sed -n '1p')
case "$ASYNC_PROBE_PID" in
  ''|*[!0-9]*) fail "Claude $CLAUDE_VERSION no longer exports a numeric CLAUDE_PID to its detached asyncRewake Stop hooks (got '$ASYNC_PROBE_PID')" ;;
esac
[ -n "$ASYNC_PROBE_ENV_SESSION" ] \
  || fail "Claude $CLAUDE_VERSION no longer exports CLAUDE_CODE_SESSION_ID to its detached asyncRewake Stop hooks"
ASYNC_PROBE_PAYLOAD_SESSION=$(fm_claude_payload_session_id "$ASYNC_PROBE_PAYLOAD") \
  || fail "Claude $CLAUDE_VERSION no longer names a session_id in the Stop payload it delivers on the detached asyncRewake path: $ASYNC_PROBE_PAYLOAD"
[ "$ASYNC_PROBE_PAYLOAD_SESSION" = "$ASYNC_PROBE_ENV_SESSION" ] \
  || fail "Claude $CLAUDE_VERSION delivered a detached asyncRewake Stop payload for session $ASYNC_PROBE_PAYLOAD_SESSION while exporting $ASYNC_PROBE_ENV_SESSION, so the two identity signals no longer corroborate each other on that path"
[ "$ASYNC_PROBE_PID" = "$RECORDED_OWNER" ] \
  || fail "Claude $CLAUDE_VERSION exported session pid $ASYNC_PROBE_PID to its detached asyncRewake Stop hooks while this session recorded owner $RECORDED_OWNER, so the session-identity proof no longer matches the recorded owner on the path the hook runs on"

ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
MODEL_DRAINS=$(grep -c 'bin/fm-wake-drain.sh' "$HOME_DIR/state/tool-calls.log" 2>/dev/null || true)
[ "${MODEL_DRAINS:-0}" = 2 ] \
  || fail "expected the model to handle exactly two Stop-owned wakes, got ${MODEL_DRAINS:-0}: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
REWAKES=$(grep -c 'Stop hook feedback' "$TRANSCRIPT" 2>/dev/null || true)
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ "$(sed -n '1p' "$HOME_DIR/state/tool-calls.log" 2>/dev/null)" = 'bin/fm-session-start.sh' ] \
  || fail "fresh Claude session did not run session start first: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

# Live-owner negative control: a separate supported-harness process owns a
# second isolated home while another Stop hook fires from the same primary
# project. The competing hook must not replace the session lock, arm, write an
# epoch, or rewake.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
"$FAKE_CLAUDE" -c 'sleep 3; :' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" || LIVE_OWNER_RC=$?
[ "$LIVE_OWNER_RC" -eq 0 ] || fail "competing Stop hook returned $LIVE_OWNER_RC while another live session owned the home"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing Stop hook replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/arm-ran" ] || fail "competing Stop hook armed while another live session owned the home"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-autoarm-epoch" ] || fail "competing Stop hook wrote an epoch while another live session owned the home"
[ ! -s "$LAB/live-owner.out" ] && [ ! -s "$LAB/live-owner.err" ] || fail "competing Stop hook produced a rewake while another live session owned the home"
wait "$LIVE_OWNER_PID"

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, preserved the competing-live-owner boundary, and still delivers the session identity the ownership proof depends on\n' "$CLAUDE_VERSION"

# --- away-mode return ---------------------------------------------------------
# The second isolated session. It enters away mode for real, ends a turn while
# the away daemon owns supervision, returns through the real return gate, and
# must then have supervision back at the very next Stop with no model-issued arm.
command -v tmux >/dev/null 2>&1 || fail "tmux not found; the away-mode lab needs the verified reference backend"

git clone -q "$ROOT" "$AFK_PROJECT"
cp -R "$ROOT/bin/." "$AFK_PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$AFK_PROJECT/.claude/settings.json"
cp "$PROJECT/.claude/settings.local.json" "$AFK_PROJECT/.claude/settings.local.json"
cp "$PROJECT/bin/stop-identity-probe.sh" "$AFK_PROJECT/bin/stop-identity-probe.sh"
cp "$PROJECT/bin/tool-logger.sh" "$AFK_PROJECT/bin/tool-logger.sh"

# Records, per Stop, whether the away-mode flag was still set and what the epoch
# ledger read, so the ORDER of the episode is provable rather than assumed.
cat > "$AFK_PROJECT/bin/stop-episode-probe.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'afk=%s ledger=%s\n' \
  "$([ -e "$FM_HOME/state/.afk" ] && echo yes || echo no)" \
  "$(sed -n 1p "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null)" \
  >> "$FM_HOME/state/stop-episode.log" 2>/dev/null
exit 0
SH
chmod +x "$AFK_PROJECT/bin/stop-episode-probe.sh"
# The episode probe rides the same local Stop registration as the identity probe.
python3 - "$AFK_PROJECT/.claude/settings.local.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    settings = json.load(fh)
settings["hooks"]["Stop"][0]["hooks"].insert(
    0, {"type": "command",
        "command": '"$CLAUDE_PROJECT_DIR"/bin/stop-episode-probe.sh'})
with open(path, "w") as fh:
    json.dump(settings, fh)
PY

# Arm fixture: never starts a real watcher and never reports a healthy one, so
# the guard's verdict depends only on what the auto-arm actually claims.
cat > "$AFK_PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
printf 'arm-run=%s afk=%s\n' "$N" "$([ -e "$FM_HOME/state/.afk" ] && echo yes || echo no)" \
  >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: afk-lab-%s\n' "$N"
exit 0
SH
# Watcher fixture: the away daemon runs this as its own child, so it must be
# bounded or the daemon's SIGTERM shutdown would sit in the return gate.
cat > "$AFK_PROJECT/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
touch "${FM_HOME:-.}/state/.last-watcher-beat" 2>/dev/null || true
sleep 2
exit 0
SH
# The in-flight need must survive the whole episode: bin/fm-afk-return.sh drains
# the queue itself and the tracked SessionStart hook runs a digest that drains
# too, so a drain-counted end would retire the work before the post-return Stop
# and the auto-arm would leave through its "nothing left to supervise" gate with
# nothing proven. It ends once a cycle has actually run after the return.
cat > "$AFK_PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if grep -q 'afk=no' "$FM_HOME/state/arm-ran" 2>/dev/null; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: afk-lab drained\n'
SH
chmod +x "$AFK_PROJECT/bin/fm-watch-arm.sh" "$AFK_PROJECT/bin/fm-watch.sh" \
  "$AFK_PROJECT/bin/fm-wake-drain.sh"

mkdir -p "$AFK_HOME/state" "$AFK_HOME/config" "$AFK_HOME/data"
printf 'tmux\n' > "$AFK_HOME/config/backend"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$AFK_HOME/state/task.meta"

# The away daemon injects into the captain pane it is handed, so the lab owns an
# isolated tmux session for that and never touches a real one.
tmux new-session -d -s "$AFK_CAPTAIN_SESSION" \
  || fail "could not create the isolated away-mode lab captain session"
AFK_CAPTAIN_PANE=$(tmux list-panes -t "$AFK_CAPTAIN_SESSION" \
  -F '#{session_name}:#{window_index}.#{pane_index}' | sed -n '1p')
[ -n "$AFK_CAPTAIN_PANE" ] || fail "could not resolve the lab captain pane"

AFK_PROMPT='Run exactly `bin/fm-afk-launch.sh start` with Bash as your first tool call, then reply with exactly AFKON and stop. The next time anything wakes you, run exactly `bin/fm-afk-return.sh` once with Bash, then reply with exactly AFKOFF and stop. After that, whenever something wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$AFK_PROJECT" || exit 1
  FM_HOME="$AFK_HOME" FM_SUPERVISOR_TARGET="$AFK_CAPTAIN_PANE" FM_SUPERVISOR_BACKEND=tmux \
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$AFK_PROMPT" --dangerously-skip-permissions --effort low \
      --output-format stream-json --verbose
) > "$AFK_TRANSCRIPT" 2>&1 || fail "Claude away-mode session failed: $(tail -20 "$AFK_TRANSCRIPT")"

# The detached auto-arm of the last Stop finishes after the session returns.
afk_wait=0
while [ "$afk_wait" -lt 60 ]; do
  case "$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$AFK_HOME/state/.claude-autoarm-epoch" 2>/dev/null)" in
    rewake|clean|failed|failed-suppressed) break ;;
  esac
  afk_wait=$((afk_wait + 1))
  sleep 0.5
done

EPISODE_LOG="$AFK_HOME/state/stop-episode.log"
[ -s "$EPISODE_LOG" ] || fail "the away-mode lab session ended no turn at all"
grep -q '^afk=yes ' "$EPISODE_LOG" \
  || fail "the away-mode episode never crossed a turn boundary, so this run proves nothing: $(cat "$EPISODE_LOG")"
grep -q '^afk=no ' "$EPISODE_LOG" \
  || fail "the away-mode return never happened, so the next Stop was never the post-return one: $(cat "$EPISODE_LOG")"
[ ! -e "$AFK_HOME/state/.afk" ] || fail "bin/fm-afk-return.sh left the home in away mode"

AFK_LEDGER=$(sed -n '1p' "$AFK_HOME/state/.claude-autoarm-epoch" 2>/dev/null || true)
[ -n "$AFK_LEDGER" ] \
  || fail "the Stop-owned auto-arm never claimed this home after the away-mode return (empty ledger); supervision would have stayed down"
case "$AFK_LEDGER" in
  *outcome=afk*) fail "the auto-arm stayed frozen on the away-mode episode's own entry after the return: $AFK_LEDGER" ;;
esac
grep -q 'afk=no' "$AFK_HOME/state/arm-ran" \
  || fail "no watcher cycle ran after the away-mode return: $(cat "$AFK_HOME/state/arm-ran" 2>/dev/null)"
if [ -f "$AFK_HOME/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$AFK_HOME/state/tool-calls.log" \
    || fail "the model re-armed the watcher by hand after the away-mode return, the exact incident behavior: $(cat "$AFK_HOME/state/tool-calls.log")"
fi
grep -q 'bin/fm-afk-return.sh' "$AFK_HOME/state/tool-calls.log" 2>/dev/null \
  || fail "the lab session never ran the away-mode return: $(cat "$AFK_HOME/state/tool-calls.log" 2>/dev/null)"

printf 'ok - Claude %s live E2E entered away mode, crossed a turn boundary while the away daemon owned supervision, returned through the real return gate, and had the Stop-owned auto-arm claim the home again at the next Stop with no model-issued arm\n' "$CLAUDE_VERSION"
