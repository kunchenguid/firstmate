#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
#
# Two real Claude sessions share one isolated Firstmate home.
# The lock-owning session stays active while a read-only competing session ends
# a turn with work in flight and no watcher. The competing auto-arm must trace
# its live-owner gate, and its matching guard must let that read-only session
# finish instead of trapping it in a continuation loop. When the owner ends its
# own turn, its Stop hook must claim the home and restore supervision without a
# model-issued arm command or human intervention.
#
# The project and FM_HOME are isolated under this disposable test directory.
# Claude uses its existing managed authentication; no live fleet home, worktree,
# or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads prompt literals
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
command -v jq >/dev/null 2>&1 || fail "jq not found"

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
OWNER_TRANSCRIPT="$LAB/owner.jsonl"
COMPETING_TRANSCRIPT="$LAB/competing.jsonl"
CLAUDE_VERSION=$(claude --version)
OWNER_PID=
COMPETING_PID=

cleanup() {
  [ -z "$COMPETING_PID" ] || kill "$COMPETING_PID" 2>/dev/null || true
  [ -z "$OWNER_PID" ] || kill "$OWNER_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

wait_for_path() {  # <path> <process-pid> <tenths>
  local path=$1 pid=$2 remaining=$3
  while [ ! -e "$path" ] && [ "$remaining" -gt 0 ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    remaining=$((remaining - 1))
  done
  [ -e "$path" ]
}

wait_for_exit() {  # <process-pid> <tenths>
  local pid=$1 remaining=$2
  while kill -0 "$pid" 2>/dev/null && [ "$remaining" -gt 0 ]; do
    sleep 0.1
    remaining=$((remaining - 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
# A clone carries only committed state, so copy the working-tree surfaces under
# test, including the instrumentation and candidate fix being validated.
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"

cat > "$PROJECT/bin/owner-hold.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/owner-hold-started"
while [ ! -e "$FM_HOME/state/release-owner" ]; do
  sleep 0.1
done
SH
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm-run pid=%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: live-owner-recovery\n'
SH
cat > "$PROJECT/bin/finish-live.sh" <<'SH'
#!/usr/bin/env bash
rm -f "$FM_HOME/state/task.meta"
SH
chmod +x "$PROJECT/bin/owner-hold.sh" "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/finish-live.sh"

OWNER_PROMPT='Use Bash to run exactly `bin/owner-hold.sh` and wait for it. After it returns, reply exactly OWNER_RELEASED and end the turn. If Stop hook feedback then wakes you, use Bash to run exactly `bin/finish-live.sh`, reply exactly OWNER_RECOVERED, and end. Never run an arm command or any other tool.'
(
  cd "$PROJECT" || exit 1
  exec env FM_HOME="$HOME_DIR" FM_GATE_REFUSE_BYPASS=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$OWNER_PROMPT" --dangerously-skip-permissions --effort low \
      --output-format stream-json --verbose --include-hook-events
) > "$OWNER_TRANSCRIPT" 2>&1 &
OWNER_PID=$!

wait_for_path "$HOME_DIR/state/.lock" "$OWNER_PID" 600 \
  || fail "lock-owning Claude session did not acquire the isolated home: $(tail -20 "$OWNER_TRANSCRIPT")"
wait_for_path "$HOME_DIR/state/owner-hold-started" "$OWNER_PID" 600 \
  || fail "lock-owning Claude session did not enter the controlled active turn: $(tail -20 "$OWNER_TRANSCRIPT")"
LOCK_OWNER=$(cat "$HOME_DIR/state/.lock" 2>/dev/null || true)
kill -0 "$LOCK_OWNER" 2>/dev/null || fail "recorded session-lock owner is not alive"

COMPETING_PROMPT='Reply exactly COMPETING_READ_ONLY and end the turn without using tools.'
(
  cd "$PROJECT" || exit 1
  exec env FM_HOME="$HOME_DIR" FM_GATE_REFUSE_BYPASS=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$COMPETING_PROMPT" --dangerously-skip-permissions --effort low \
      --output-format stream-json --verbose --include-hook-events
) > "$COMPETING_TRANSCRIPT" 2>&1 &
COMPETING_PID=$!

remaining=600
while kill -0 "$COMPETING_PID" 2>/dev/null \
  && [ ! -e "$HOME_DIR/state/.turnend-claude-blocks" ] \
  && [ "$remaining" -gt 0 ]; do
  sleep 0.1
  remaining=$((remaining - 1))
done
if [ -e "$HOME_DIR/state/.turnend-claude-blocks" ]; then
  fail "read-only Claude session was trapped by the blind-turn guard: $(cat "$HOME_DIR/state/.turnend-claude-blocks")"
fi
wait_for_exit "$COMPETING_PID" 300 \
  || fail "read-only Claude session did not finish after deferring supervision to the live lock owner"
wait "$COMPETING_PID" || fail "read-only Claude session exited unsuccessfully: $(tail -20 "$COMPETING_TRANSCRIPT")"
COMPETING_PID=
jq -e -s 'any(.[];
  .type == "assistant"
  and any(.message.content[]?; .type == "text" and .text == "COMPETING_READ_ONLY")
)' "$COMPETING_TRANSCRIPT" >/dev/null \
  || fail "read-only Claude session did not produce its exact completion response"

grep -q 'event=gate-live-session-owner' "$HOME_DIR/state/.claude-autoarm-entry-trace" \
  || fail "real competing Stop hook did not trace the live-session-owner gate"
[ "$(cat "$HOME_DIR/state/.lock")" = "$LOCK_OWNER" ] \
  || fail "read-only Stop hooks displaced the live session-lock owner"
[ ! -e "$HOME_DIR/state/arm-ran" ] \
  || fail "read-only Stop hook armed despite deferring recovery to the lock owner"

: > "$HOME_DIR/state/release-owner"
wait_for_exit "$OWNER_PID" 900 \
  || fail "lock-owning Claude session did not finish its Stop-owned recovery"
wait "$OWNER_PID" || fail "lock-owning Claude recovery session failed: $(tail -20 "$OWNER_TRANSCRIPT")"
OWNER_PID=

[ "$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')" = 1 ] \
  || fail "expected exactly one owner-hook arm cycle: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
grep -q 'event=claimed' "$HOME_DIR/state/.claude-autoarm-entry-trace" \
  || fail "lock-owning Stop hook never traced its auto-arm claim"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "lock-owning Stop hook did not record outcome=rewake: $(cat "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)"
jq -e -s 'any(.[];
  .type == "system"
  and .subtype == "hook_response"
  and .hook_event == "Stop"
  and .exit_code == 2
  and ((.output // "") | contains("firstmate watcher wake"))
)' "$OWNER_TRANSCRIPT" >/dev/null \
  || fail "owner-hook actionable result was not delivered as a real exit-2 Stop response"
jq -e -s 'any(.[];
  .type == "assistant"
  and any(.message.content[]?; .type == "text" and .text == "OWNER_RECOVERED")
)' "$OWNER_TRANSCRIPT" >/dev/null \
  || fail "real Stop feedback did not continue the owner session through recovery"
[ ! -e "$HOME_DIR/state/task.meta" ] \
  || fail "live fixture did not complete its in-flight supervision need"

printf 'ok - Claude %s live E2E let the read-only competing session finish, then restored supervision from the lock-owning Stop hook without human intervention\n' "$CLAUDE_VERSION"
