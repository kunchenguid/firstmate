#!/usr/bin/env bash
# Credentialed GitHub Copilot CLI worker guard. Opt in with FM_COPILOT_SIGNALS_LIVE=1.
# FM_COPILOT_MODEL optionally chooses a catalog model id (default: the account's own).
# Drives the real copilot binary in a private pty with the plugin that
# bin/fm-copilot-plugin.sh writes, so it needs no multiplexer and touches no
# shared endpoint. It spends one tiny prompt of the caller's own Copilot quota
# and edits nothing under ~/.copilot or the repository.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_COPILOT_SIGNALS_LIVE copilot python3 jq
VERSION="copilot $(copilot --version 2>/dev/null | head -1)"
START="$(mktemp "${TMPDIR:-/tmp}/cpl-start.XXXXXX")"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cpl.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "$LAB" "$START"' EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
STATE="$LAB/state"
WORK="$LAB/work"
mkdir -p "$STATE" "$WORK"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live) || fail 'busy arm failed'
"$ROOT/bin/fm-copilot-plugin.sh" "$STATE" live "$gen" "$WORK" || fail 'plugin writer failed'
export COPILOT_HOME="$STATE/live.copilot-home"
# Test-only handshake: the submit hook holds the turn open after it has written
# busy, until the driver has seen that record and touched the release file. The
# latest-value record file can then never be missed by sampling.
RELEASE="$LAB/release"
release_q=$(printf '%q' "$RELEASE")
hooks="$STATE/live.copilot-plugin/hooks/hooks.json"
jq --arg wait "; n=0; while [ ! -e $release_q ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n+1)); done" \
  '.hooks.userPromptSubmitted[0].bash += $wait | .hooks.userPromptSubmitted[0].timeoutSec = 90' "$hooks" > "$hooks.new" \
  || fail 'handshake wiring failed'
mv "$hooks.new" "$hooks" || fail 'handshake wiring failed'
model_args=()
[ -z "${FM_COPILOT_MODEL:-}" ] || model_args=(--model "$FM_COPILOT_MODEL")

# The driver prints "<comm>\t<argv0>" of the live copilot process once the first
# turn has settled, then starts a long second turn, cancels it with the double
# Escape fm-control sends, types /exit and reports the child's exit status.
IFS= read -r -d '' driver <<'PY' || true
import os, pty, subprocess, select, struct, fcntl, termios, sys, time, signal
state, plugin, work, release = sys.argv[1:5]
extra = sys.argv[5:]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(work)
    os.environ['TERM'] = 'xterm-256color'
    os.environ['COPILOT_ALLOW_ALL'] = 'true'
    os.execvp('copilot', ['copilot', '--allow-all', '--no-auto-update', '--plugin-dir', plugin] + extra + ['-i', 'Reply with the single word PONG'])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 45, 140, 0, 0))
def pump(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                if not os.read(fd, 65536): return False
            except OSError:
                return False
    return True
def rec():
    try:
        return open(os.path.join(state, 'live.busy-state')).read()
    except OSError:
        return ''
# The arm wrote busy from fm-spawn; only the vendor's own userPromptSubmitted
# delivery can produce state=busy from copilot-hook, so watch for exactly that.
seen_busy = False
deadline = time.time() + 120
while time.time() < deadline:
    r = rec()
    if ' state=busy ' in r and ' source=copilot-hook ' in r:
        seen_busy = True
        open(release, 'w').close()
    if seen_busy and ' state=idle ' in r:
        break
    pump(0.2)
def ps(field):
    return subprocess.check_output(['ps', '-o', field + '=', '-p', str(pid)]).decode().strip()
comm = ps('comm')
argv0 = ps('args').split(' ')[0]
print('%s\t%s\t%s' % (comm, argv0, 'busy-seen' if seen_busy else 'busy-missed'), flush=True)
pump(2)
os.write(fd, b'Run the shell command: sleep 120'); pump(1); os.write(fd, b'\r')
deadline = time.time() + 60
while ' state=busy ' not in rec() and time.time() < deadline:
    pump(0.2)
pump(5)
os.write(fd, b'\x1b'); pump(0.05); os.write(fd, b'\x1b')
pump(3)
os.write(fd, b'/exit'); pump(1); os.write(fd, b'\r')
pump(15)
done = 0
for _ in range(100):
    done, status = os.waitpid(pid, os.WNOHANG)
    if done: break
    time.sleep(0.1)
if not done:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    print('exit-timeout', flush=True)
else:
    print('exit-%d' % (os.waitstatus_to_exitcode(status)), flush=True)
PY
identity=$(cd "$LAB" && python3 -I -c "$driver" "$STATE" "$STATE/live.copilot-plugin" "$WORK" "$RELEASE" ${model_args[@]+"${model_args[@]}"}) \
  || fail 'driver failed'
exit_note=$(printf '%s\n' "$identity" | tail -1)
identity=$(printf '%s\n' "$identity" | head -1)
comm=${identity%%$'\t'*}
rest=${identity#*$'\t'}
argv0=${rest%%$'\t'*}
busy_note=${rest#*$'\t'}
[ "$busy_note" = busy-seen ] || fail 'a real prompt never produced busy copilot-hook (userPromptSubmitted not delivered)'
[ "$exit_note" = exit-0 ] || fail "/exit did not end copilot cleanly: $exit_note"
[ "$(fm_agent_process_classify "$comm" "$argv0" "$argv0")" = agent ] \
  || fail "liveness did not recognize the live process (comm=$comm argv0=$argv0)"
echo "ok - $VERSION: live process comm=$comm argv0=$argv0 classified as an agent"
[ "$(fm_busy_classify tmux fake:w copilot live "$STATE")" = 'idle copilot-hook' ] \
  || fail "busy record did not end idle: $(cat "$STATE/live.busy-state" 2>/dev/null)"
assert_present "$STATE/live.turn-ended" 'agentStop raised no turn-end notification'
echo "ok - $VERSION: a real prompt produced busy copilot-hook, agentStop closed it and raised the turn-end notification, /exit ended cleanly"
# The cancel is recorded only in the session transcript, in a format Copilot does
# not document, so this is the one place a release that renames the event shows up.
# This reads the private COPILOT_HOME exported above, so only this test's own
# session can be found and concurrent Copilot use in the caller's home cannot
# change the result; the plugin writer copied the caller's login into that home.
events=
for f in "${COPILOT_HOME:-$HOME/.copilot}"/session-state/*/events.jsonl; do
  [ -f "$f" ] && [ "$f" -nt "$START" ] || continue
  if [ -z "$events" ] || [ "$f" -nt "$events" ]; then events=$f; fi
done
[ -n "$events" ] || fail 'no session transcript (events.jsonl) was written under the Copilot home'
[ "$(fm_copilot_abort_count "$events")" -ge 1 ] \
  || fail "a double Escape on a busy turn wrote no abort event ($FM_COPILOT_ABORT_EVENT at line start) to $events"
echo "ok - $VERSION: a double Escape cancelled the turn and the transcript recorded an abort event"
