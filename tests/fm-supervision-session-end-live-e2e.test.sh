#!/usr/bin/env bash
# Token-free installed Claude Code guard for bin/fm-supervision-session-end.sh.
#
# The hook's verdicts rest on two things only the real binary can show: the
# SessionEnd payload's reason (clear after /clear, when the same process runs on;
# something else when the process ends) and that a child the hook detaches with
# nohup into a process group of its own outlives the Claude process. This guard
# drives an interactive `claude` on a pseudo-terminal through /clear then /exit,
# and through a closed terminal, with a SessionEnd hook that records each payload
# and detaches a sleeper.
#
# The launch gets a clean environment, a private config directory, a synthetic
# API key, and an unreachable API endpoint, and submits no prompt, so it needs no
# login and spends no tokens. Enabled by default wherever claude and python3 are
# installed; FM_SUPERVISION_SESSION_END_LIVE=1 makes an absent tool a failure,
# and =0 skips.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_SUPERVISION_SESSION_END_LIVE claude python3

TMP_ROOT=$(fm_test_tmproot fm-supervision-session-end-live)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
trap 'for f in "$TMP_ROOT"/*/out/child.*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; fm_test_cleanup' EXIT

KEY=sk-ant-api03-fmsessionendlivesynthetickey000000000000

cat > "$TMP_ROOT/hook.sh" <<'SH'
#!/usr/bin/env bash
out=$(dirname "$0")/out
n=$(find "$out" -name 'payload.*' | wc -l | tr -d ' ')
cat > "$out/payload.$n.json"
set -m
nohup bash -c 'echo $$ > "$1"; exec sleep 600' _ "$out/child.$n.pid" >/dev/null 2>&1 </dev/null &
set +m
SH
chmod +x "$TMP_ROOT/hook.sh"

cat > "$TMP_ROOT/drive.py" <<'PY'
import os, pty, select, sys, time
lab, steps = sys.argv[1], sys.argv[2:]
env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"], "TERM": "xterm-256color",
       "CLAUDE_CONFIG_DIR": lab + "/cfg", "ANTHROPIC_API_KEY": os.environ["FM_LIVE_KEY"],
       "ANTHROPIC_BASE_URL": "http://127.0.0.1:9", "DISABLE_AUTOUPDATER": "1",
       "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}
pid, fd = pty.fork()
if pid == 0:
    os.chdir(lab + "/proj")
    os.execvpe("claude", ["claude", "--settings", lab + "/settings.json"], env)
def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                if not os.read(fd, 65536):
                    return
            except OSError:
                return
pump(8)
for step in steps:
    if step == "HANGUP":
        os.close(fd)
        break
    os.write(fd, step.encode())
    time.sleep(0.5)
    os.write(fd, b"\r")
    pump(6)
for _ in range(100):
    if os.waitpid(pid, os.WNOHANG)[0]:
        sys.exit(0)
    time.sleep(0.1)
os.kill(pid, 9)
sys.exit(1)
PY

# run_lab <name> <steps...>: one interactive session; its payload reasons, in
# order, land in $TMP_ROOT/<name>/reasons.
run_lab() {
  local lab=$TMP_ROOT/$1 proj n
  shift
  mkdir -p "$lab/proj" "$lab/out" "$lab/cfg"
  proj=$(cd "$lab/proj" && pwd -P)
  printf '{"hasCompletedOnboarding":true,"theme":"dark","customApiKeyResponses":{"approved":["%s"],"rejected":[]},"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' \
    "${KEY: -20}" "$proj" > "$lab/cfg/.claude.json"
  ln -s "$TMP_ROOT/hook.sh" "$lab/hook.sh"
  printf '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"%s","timeout":30}]}]}}\n' "$lab/hook.sh" > "$lab/settings.json"
  FM_LIVE_KEY=$KEY python3 -I "$TMP_ROOT/drive.py" "$lab" "$@" \
    || fail "claude ($CLAUDE_VERSION) did not exit after: $*"
  sleep 2
  n=0
  while [ -f "$lab/out/payload.$n.json" ]; do
    jq -r '.reason // "<none>"' "$lab/out/payload.$n.json"
    n=$((n + 1))
  done > "$lab/reasons"
}

# The hook's detached child must outlive the Claude process that ran the hook.
assert_children_survived() {  # <lab>
  local f pid n=0
  for f in "$TMP_ROOT/$1"/out/child.*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f")
    kill -0 "$pid" 2>/dev/null || fail "claude ($CLAUDE_VERSION): the detached child of a SessionEnd hook died with the session"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || fail "claude ($CLAUDE_VERSION): no SessionEnd hook ran in $1"
}

run_lab clear-exit /clear /exit
[ "$(cat "$TMP_ROOT/clear-exit/reasons")" = "clear
prompt_input_exit" ] || fail "claude ($CLAUDE_VERSION): /clear then /exit gave SessionEnd reasons: $(tr '\n' ' ' < "$TMP_ROOT/clear-exit/reasons")"
assert_children_survived clear-exit
pass "claude ($CLAUDE_VERSION): /clear ends a session with reason clear, /exit with prompt_input_exit, and a detached hook child survives"

run_lab hangup HANGUP
reason=$(cat "$TMP_ROOT/hangup/reasons")
case "$reason" in
  ''|clear|resume|*$'\n'*) fail "claude ($CLAUDE_VERSION): a closed terminal gave SessionEnd reasons: $(printf '%s' "$reason" | tr '\n' ' ')" ;;
esac
assert_children_survived hangup
pass "claude ($CLAUDE_VERSION): a closed terminal ends the session with reason $reason, and a detached hook child survives"
