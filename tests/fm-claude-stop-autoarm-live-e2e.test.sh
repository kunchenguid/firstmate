#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock receives the full session-start digest through the tracked
# SessionStart hook; session start reclaims the dead owner; at least two
# tokenless auto-arm and rewake cycles then complete with zero model-issued arm
# commands; and the cooperative guard consumes no forced continuation while the
# hook's launch is healthy.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# Pass --continuation for the credential-free Linux native handoff guard:
# a real left-arrow handoff retains its frontend, then the settled native pids
# and hook ids exercise the shared identity predicate with an explicit ancestry
# list. The portable suite owns ancestry trust and Stop integration; this live
# mode does not claim a credentialed model-issued Stop.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${1:-}" = --continuation ]; then
  fm_live_gate opt-in FM_CLAUDE_CONTINUATION_LIVE claude herdr jq python3
  [ -r /proc/self/environ ] || fail "Claude continuation live guard requires Linux procfs"
  LAB=$(fm_test_tmproot fm-claude-continuation-live)
  PROJECT="$LAB/project"
  CLAUDE_DIR="$LAB/claude"
  LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
  HOME_HELPER=${FM_LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
  SESSION=$("$LAB_HELPER" name claude-bg-session-lock)
  export FM_HERDR_LAB_STATE_DIR="$LAB/herdr-state"
  CLAUDE_VERSION=$(claude --version)
  # shellcheck disable=SC2329 # Invoked by the EXIT trap below.
  cleanup_continuation() {
    local rc=$?
    # Only native pids recorded in this fresh config, still matching both their
    # kernel birth and actual config environment, may be signalled. No shared
    # Claude daemon or global lifecycle command is involved.
    python3 - "$CLAUDE_DIR" <<'PY'
import json,os,signal,sys,time
from pathlib import Path
root=Path(sys.argv[1]); owned=[]
for path in [*root.glob('sessions/*.json'),root/'daemon.lock']:
    try:
        row=json.loads(path.read_text()); pid=row['pid']; birth=row['procStart']
        proc=Path(f'/proc/{pid}')
        if proc.joinpath('stat').read_text().rsplit(')',1)[1].split()[19]!=birth:continue
        env=proc.joinpath('environ').read_bytes().split(b'\0')
        if f'CLAUDE_CONFIG_DIR={root}'.encode() not in env:continue
        owned.append((pid,birth)); os.kill(pid,signal.SIGTERM)
    except (OSError,ValueError,KeyError,IndexError):continue
time.sleep(.2)
for pid,birth in owned:
    try:
        if Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19]==birth:os.kill(pid,signal.SIGKILL)
    except (OSError,IndexError):pass
PY
    "$LAB_HELPER" teardown "$SESSION" || rc=1
    [ ! -d "$PROJECT/state" ] || "$HOME_HELPER" teardown "$PROJECT" || rc=1
    fm_test_cleanup
    exit "$rc"
  }
  trap cleanup_continuation EXIT
  "$LAB_HELPER" provision "$SESSION" || fail "Claude $CLAUDE_VERSION: guarded Herdr provisioning failed"
  "$HOME_HELPER" create "$PROJECT" >/dev/null || fail "cannot create isolated home"
  mkdir -p "$CLAUDE_DIR"
  # No credentials or global hooks are copied. Cached rollout flags let the
  # installed vendor expose its real background transition without signing in.
  # Claude Code 2.1.302 joins ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json for that
  # global file (os.homedir when unset). The daemon/session root remains
  # ${CLAUDE_CONFIG_DIR:-$HOME/.claude} and is a different directory.
  python3 - "$CLAUDE_DIR/.claude.json" <<'PY'
import json,os,sys
from pathlib import Path
source=Path(os.environ.get('CLAUDE_CONFIG_DIR',os.environ['HOME']))/'.claude.json'
doc=json.loads(source.read_text()) if source.exists() else {}
json.dump(dict(hasCompletedOnboarding=True,bypassPermissionsModeAccepted=True,theme='dark',
               cachedGrowthBookFeatures=doc.get('cachedGrowthBookFeatures',{})),open(sys.argv[1],'w'))
PY
  cp -R "$ROOT/bin" "$PROJECT/bin"
  : > "$PROJECT/AGENTS.md"
  : > "$PROJECT/config/supervision-host-off"
  : > "$PROJECT/state/task.meta"
  git -C "$PROJECT" init -q
  CLAUDE_CONFIG_DIR="$CLAUDE_DIR" "$ROOT/bin/fm-claude-trust.sh" --lab-home "$PROJECT" >/dev/null || fail "lab trust registration failed"
  cat > "$PROJECT/hook.sh" <<'SH'
#!/usr/bin/env bash
p=$(cat)
printf '%s\n' "$p" >> "$FM_HOME/state/hooks.jsonl"
source=$(printf '%s' "$p" | jq -r .source)
if [ "$source" = startup ] && ! printf '%s' "$p" | jq -e .agent_type >/dev/null; then
  printf '%s:%s\n' "$CLAUDE_CODE_SESSION_ID" "$CLAUDE_PID" >> "$FM_HOME/state/foregrounds"
  bash "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/lock-start.out" 2>&1
elif [ "$source" = fork ]; then
  printf '%s\n' "$CLAUDE_CODE_SESSION_ID" > "$FM_HOME/state/fork-id"
  printf '%s\n' "$CLAUDE_PID" > "$FM_HOME/state/model-pid"
fi
SH
  chmod +x "$PROJECT/hook.sh"
  jq -n --arg cmd "$PROJECT/hook.sh" '{feedbackDrafts:"off",hooks:{SessionStart:[{hooks:[{type:"command",command:$cmd}]}]}}' > "$PROJECT/settings.json"
  # Start the native daemon before the frontend, so its worker ancestry cannot
  # include that frontend. A cold daemon started beneath the frontend masks the
  # incident by preserving the old ancestry signal.
  DISABLE_AUTOUPDATER=1 CLAUDE_CONFIG_DIR="$CLAUDE_DIR" claude daemon --help > "$LAB/daemon-help"
  grep -q 'Run the supervisor in the foreground' "$LAB/daemon-help" || fail "Claude $CLAUDE_VERSION: native foreground daemon launch unsupported"
  socket=$(python3 - "$CLAUDE_DIR" <<'PY'
import hashlib,os,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
default=Path(os.environ.get('CLAUDE_CONFIG_DIR',str(Path.home()/'.claude'))).resolve()
key=lambda p:hashlib.sha256(str(p).encode()).hexdigest()[:8]
if key(root)==key(default):raise SystemExit('private and user daemon socket identities collide')
socket=Path('/tmp')/f'cc-daemon-{os.getuid()}'/key(root)/'control.sock'
if socket.exists():raise SystemExit('refusing an existing daemon socket')
print(socket)
PY
  ) || fail "cannot prove private daemon socket isolation"
  daemon_ws=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label independent-daemon --no-focus) || fail "cannot create daemon lab workspace"
  daemon_pane=$(printf '%s' "$daemon_ws" | jq -er '.result.root_pane.pane_id') || fail "missing daemon lab pane"
  "$LAB_HELPER" run "$SESSION" pane run "$daemon_pane" "env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN DISABLE_AUTOUPDATER=1 FM_HOME='$PROJECT' CLAUDE_CONFIG_DIR='$CLAUDE_DIR' claude daemon run --json-path '$CLAUDE_DIR/daemon.json' --log-file '$CLAUDE_DIR/daemon.log'" >/dev/null
  i=0
  while [ "$i" -lt 200 ] && { [ ! -S "$socket" ] || [ ! -s "$CLAUDE_DIR/daemon.lock" ]; }; do sleep 0.1; i=$((i+1)); done
  [ -S "$socket" ] || fail "Claude $CLAUDE_VERSION: independent private daemon did not bind its isolated socket: $("$LAB_HELPER" run "$SESSION" pane read "$daemon_pane")"
  python3 - "$CLAUDE_DIR" <<'PY' || fail "private daemon identity did not verify"
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); row=json.loads((root/'daemon.lock').read_text()); proc=Path(f'/proc/{row["pid"]}')
assert row['jsonPath']==str(root/'daemon.json')
assert proc.joinpath('stat').read_text().rsplit(')',1)[1].split()[19]==row['procStart']
assert f'CLAUDE_CONFIG_DIR={root}'.encode() in proc.joinpath('environ').read_bytes().split(b'\0')
print('private daemon config, kernel birth and config-derived socket verified')
PY
  ws=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label continuation --no-focus) || fail "cannot create lab workspace"
  PANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || fail "missing lab pane"
  launch="env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN DISABLE_AUTOUPDATER=1 FM_HOME='$PROJECT' CLAUDE_CONFIG_DIR='$CLAUDE_DIR' claude --dangerously-skip-permissions --setting-sources '' --settings '$PROJECT/settings.json' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --effort low 'Reply READY without tools.'"
  "$LAB_HELPER" run "$SESSION" pane run "$PANE" "$launch" >/dev/null
  i=0
  while [ "$i" -lt 200 ] && [ ! -s "$PROJECT/state/lock-start.out" ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$PROJECT/state/.lock" ] || fail "Claude $CLAUDE_VERSION: foreground did not acquire"
  owner=$(cat "$PROJECT/state/.lock")
  original=$(cat "$PROJECT/state/.lock-session")
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" left >/dev/null
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$PROJECT/state/model-pid" ]; do sleep 0.1; i=$((i+1)); done
  [ -s "$PROJECT/state/model-pid" ] || fail "Claude $CLAUDE_VERSION: left-arrow transition unavailable: $("$LAB_HELPER" run "$SESSION" pane read "$PANE")"
  model=$(cat "$PROJECT/state/model-pid")
  current=$(cat "$PROJECT/state/fork-id")
  i=0
  while [ "$i" -lt 200 ]; do
    pid=$model; ancestry=''
    while [ "$pid" -gt 1 ]; do
      ancestry="$ancestry $pid"
      pid=$(ps -o ppid= -p "$pid" | tr -d ' ') || break
      [ -n "$pid" ] || break
    done
    case " $ancestry " in *" $owner "*) sleep 0.1 ;; *) break ;; esac
    i=$((i+1))
  done
  kill -0 "$owner" || fail "Claude $CLAUDE_VERSION: frontend died before identity proof"
  case " $ancestry " in *" $owner "*) fail "Claude $CLAUDE_VERSION: settled model-loop ancestry did not diverge" ;; esac
  # This is an explicit verified native pid list, not this test shell's ancestry.
  # Production callers obtain the list from their own contiguous ancestry walk.
  if [ -n "${FM_CLAUDE_CONTINUATION_BASELINE_LIB:-}" ]; then
    mkdir -p "$LAB/baseline-bin"
    cp "$FM_CLAUDE_CONTINUATION_BASELINE_LIB" "$LAB/baseline-bin/fm-session-lock-lib.sh"
    cp "$ROOT/bin/fm-cursor-lib.sh" "$LAB/baseline-bin/fm-cursor-lib.sh"
    if CLAUDE_PID="$model" CLAUDE_CODE_SESSION_ID="$current" bash -c \
      '. "$1"; fm_session_lock_same_session "$2" "$CLAUDE_PID"' _ "$LAB/baseline-bin/fm-session-lock-lib.sh" "$PROJECT/state"; then
      fail "original ownership library unexpectedly accepted the new-id continuation"
    fi
    printf 'ok - original ownership library refuses the same settled live continuation topology\n'
  fi
  CLAUDE_PID="$model" CLAUDE_CODE_SESSION_ID="$current" bash -c \
    '. "$1"; fm_session_lock_same_session "$2" "$CLAUDE_PID"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$PROJECT/state" \
    || fail "Claude $CLAUDE_VERSION: settled native continuation identity refused"
  [ "$(cat "$PROJECT/state/.lock")" = "$owner" ] || fail "read-only proof changed anchor"
  [ "$(cat "$PROJECT/state/.lock-session")" = "$original" ] || fail "read-only proof changed sidecar"
  independent_ws=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label independent-conversation --no-focus) || fail "cannot create independent lab workspace"
  independent_pane=$(printf '%s' "$independent_ws" | jq -er '.result.root_pane.pane_id') || fail "missing independent lab pane"
  "$LAB_HELPER" run "$SESSION" pane run "$independent_pane" "$launch" >/dev/null
  i=0
  while [ "$i" -lt 200 ] && [ "$(wc -l < "$PROJECT/state/foregrounds" | tr -d ' ')" -lt 2 ]; do sleep 0.1; i=$((i+1)); done
  [ "$(wc -l < "$PROJECT/state/foregrounds" | tr -d ' ')" -ge 2 ] || fail "independent foreground did not start"
  IFS=: read -r independent_id independent_pid < <(tail -1 "$PROJECT/state/foregrounds")
  if CLAUDE_PID="$independent_pid" CLAUDE_CODE_SESSION_ID="$independent_id" bash -c \
    '. "$1"; fm_session_lock_same_session "$2" "$CLAUDE_PID"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$PROJECT/state"; then
    fail "independent live conversation claimed the owning continuation's home"
  fi
  [ "$(cat "$PROJECT/state/.lock")" = "$owner" ] && [ "$(cat "$PROJECT/state/.lock-session")" = "$original" ] || fail "independent foreground changed ownership"
  if [ -n "${FM_CLAUDE_CONTINUATION_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_CLAUDE_CONTINUATION_EVIDENCE_DIR"
    python3 - "$CLAUDE_DIR" "$owner" "$model" "$independent_pid" "$original" "$socket" > "$FM_CLAUDE_CONTINUATION_EVIDENCE_DIR/native-proof.json" <<'PY' || fail "cannot capture native continuation evidence"
import json,os,sys
from pathlib import Path
root=Path(sys.argv[1]); pids=list(map(int,sys.argv[2:5])); source=sys.argv[5]
def process(pid):
    proc=Path(f'/proc/{pid}'); fields=proc.joinpath('stat').read_text().rsplit(')',1)[1].split()
    try:
        env=dict(row.split('=',1) for row in proc.joinpath('environ').read_bytes().decode().split('\0') if '=' in row)
        cwd=os.readlink(proc/'cwd')
    except (PermissionError, OSError):
        env={}; cwd=None
    return dict(pid=pid,parent=int(fields[1]),birth=fields[19],cwd=cwd,
                config=env.get('CLAUDE_CONFIG_DIR'),home=env.get('FM_HOME'))
def registry(pid):
    row=json.loads((root/'sessions'/f'{pid}.json').read_text())
    return {k:row[k] for k in ['pid','procStart','startedAt','sessionId','kind','cwd','pidDomain','parkedJobId','jobId'] if k in row}
chain=[]; pid=pids[1]
while pid>1 and len(chain)<24:
    try:
        row=process(pid)
    except (PermissionError, OSError, IndexError):
        break
    chain.append(row); pid=row['parent']
transcripts=list(root.glob(f'projects/*/{source}.jsonl'))
links=[json.loads(line) for line in transcripts[0].read_text().splitlines() if json.loads(line).get('type')=='continued-in']
daemon=json.loads((root/'daemon.lock').read_text())
json.dump(dict(processes=[process(pid) for pid in pids],registries=[registry(pid) for pid in pids],
               model_ancestry=chain,continued_in=links,private_socket=sys.argv[6],
               daemon={k:daemon[k] for k in ['pid','procStart','jsonPath','origin','version'] if k in daemon}),sys.stdout,indent=2)
PY
  fi
  printf 'ok - independent live Claude conversation remains excluded from the same home\n'
  printf 'ok - Claude %s: settled native new-id handoff proves identity while frontend remains live outside model ancestry; model-issued Stop not exercised\n' "$CLAUDE_VERSION"
  exit 0
fi

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart run hook,
# Stop guard, and asyncRewake auto-arm registration.
# The only local hook records model-issued Bash calls without acquiring the
# session lock or otherwise changing lifecycle behavior.
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
    ]
  }
}
JSON

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
printf 'pending:downtime:fixture-generation-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: session start invokes it once, then the model invokes it once
# per rewake. The third total drain ends the in-flight need after two complete
# Stop-owned cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='After reading the complete session-start digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
DRAIN_RUNS=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "$DRAIN_RUNS" = 3 ] || fail "expected one session-start drain plus two model wake drains, got $DRAIN_RUNS drains"
REWAKES=$(jq -r '
  select(.type == "user")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT" 2>/dev/null | awk '/^Stop hook feedback:/{count++} END{print count+0}')
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ -s "$HOME_DIR/state/tool-calls.log" ] \
  || fail "Claude emitted no logged Bash tool calls"
! grep -q 'fm-session-start.sh' "$HOME_DIR/state/tool-calls.log" \
  || fail "model issued a redundant session-start command: $(cat "$HOME_DIR/state/tool-calls.log")"
DIGEST_EVENTS=$(jq -c --arg heading "SESSION START - $HOME_DIR" '
  select(.type == "system" and .subtype == "hook_response" and .hook_event == "SessionStart")
  | select(.stdout | contains($heading))
' "$TRANSCRIPT" 2>/dev/null)
[ "$(printf '%s' "$DIGEST_EVENTS" | jq -s 'length')" = 1 ] \
  || fail "expected exactly one SessionStart hook_response carrying the session-start digest"
DIGEST=$(printf '%s' "$DIGEST_EVENTS" | jq -r '.stdout')
printf '%s' "$DIGEST" | grep -q '^lock acquired: harness pid [0-9][0-9]*$' \
  || fail "SessionStart hook digest lacks the stale-lock reclaim"
! printf '%s' "$DIGEST" | grep -q '^●  STARTUP TRUNCATED - ' \
  || fail "SessionStart hook digest was truncated"
printf '%s' "$DIGEST" | grep -q '^The digest above is complete for this session start\.' \
  || fail "SessionStart hook digest lacks its completion marker"
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

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary\n' "$CLAUDE_VERSION"
