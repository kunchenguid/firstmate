#!/usr/bin/env bash
# Opt-in real kiro-cli resume continuity e2e.
#
# A Kiro session resumed with plain `kiro-cli --resume-id` carries none of the
# Firstmate launcher environment. This guard drives the real interactive V3 TUI
# through a pseudo-terminal, with no tmux or Herdr pane, because kiro-cli 2.22.1
# runs no workspace hooks under `--no-interactive`. It proves:
#   - worker: the hooks bin/fm-kiro-lib.sh generates bind a launched incarnation
#     to its task; the same conversation resumed from a scrubbed environment and
#     a foreign KIRO_HOME still reaches that task's busy, progress, and
#     turn-ended state; after a relaunch arms a new generation, resuming the
#     older conversation leaves busy state untouched;
#   - primary: after the launched primary exits, the same conversation resumed
#     from a scrubbed environment retakes the home lock on its first prompt,
#     because Kiro fires SessionStart only for a conversation's first prompt.
# It submits six small prompts, so it spends credits and is opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIRO_RESUME_LIVE_E2E kiro-cli python3 git tar jq

KIRO_BIN=$(command -v kiro-cli) || fail "kiro-cli not found"
KIRO_VERSION=$("$KIRO_BIN" --version 2>/dev/null)
case "$KIRO_VERSION" in
  'kiro-cli '*) ;;
  *) fail "resolved kiro-cli is not the Kiro CLI (got '$KIRO_VERSION')" ;;
esac

LAB=$(fm_test_tmproot fm-kiro-resume-live)
LOGIN_HOME=${FM_KIRO_LIVE_LOGIN_HOME:-$HOME}
TIMEOUT=${FM_KIRO_RESUME_LIVE_TIMEOUT:-300}
MODEL_ARGS=()
[ -z "${FM_KIRO_LIVE_MODEL:-}" ] || MODEL_ARGS=(--model "$FM_KIRO_LIVE_MODEL")
# V3 authentication belongs to the operator's login HOME, not KIRO_HOME.
BASE_ENV=(HOME="$LOGIN_HOME" PATH="$PATH" TERM=xterm-256color LANG=C.UTF-8 USER="${USER:-}")

# Run argv under a pseudo-terminal in <cwd> until every --until-file exists and
# every --until-regex matched the ANSI-stripped screen stream, then type /quit.
PTY="$LAB/kiro-pty.py"
cat > "$PTY" <<'PY'
import argparse, fcntl, os, pty, re, select, signal, struct, sys, termios, time

ANSI = re.compile(rb'\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_]')
ap = argparse.ArgumentParser()
ap.add_argument('--cwd', required=True)
ap.add_argument('--log', required=True)
ap.add_argument('--pid-file', required=True)
ap.add_argument('--timeout', type=float, required=True)
ap.add_argument('--settle', type=float, default=5.0)
ap.add_argument('--until-file', action='append', default=[])
ap.add_argument('--until-regex', action='append', default=[])
ap.add_argument('argv', nargs=argparse.REMAINDER)
a = ap.parse_args()
argv = a.argv[1:] if a.argv[:1] == ['--'] else a.argv
pid, fd = pty.fork()
if pid == 0:
    os.chdir(a.cwd)
    os.execvp(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 200, 0, 0))
with open(a.pid_file, 'w') as f:
    f.write(f'{pid}\n')
raw = bytearray()
deadline = time.time() + a.timeout
quit_deadline = None
exited = False
while True:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            raw += os.read(fd, 65536)
        except OSError:
            pass
    if os.waitpid(pid, os.WNOHANG)[0]:
        exited = True
        break
    now = time.time()
    text = ANSI.sub(b'', bytes(raw)).decode('utf-8', 'replace')
    if quit_deadline is None and all(os.path.exists(p) for p in a.until_file) \
            and all(re.search(r, text) for r in a.until_regex):
        time.sleep(a.settle)
        for piece in ('/quit', '\r'):
            os.write(fd, piece.encode())
            time.sleep(0.3)
        quit_deadline = now + 60
    if now > (quit_deadline or deadline):
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        break
with open(a.log, 'wb') as f:
    f.write(ANSI.sub(b'', bytes(raw)))
sys.exit(0 if exited and quit_deadline is not None else 1)
PY

only_session_id() {  # <workspace>
  (cd "$1" && env -i "${BASE_ENV[@]}" KIRO_HOME="$FOREIGN_HOME" "$KIRO_BIN" chat --list-sessions --format json 2>/dev/null) \
    | jq -r '[.[].sessions[].sessionId] | if length == 1 then .[0] else empty end'
}

newest_session_id() {  # <workspace>
  (cd "$1" && env -i "${BASE_ENV[@]}" KIRO_HOME="$FOREIGN_HOME" "$KIRO_BIN" chat --list-sessions --format json 2>/dev/null) \
    | jq -r '[.[].sessions[]] | sort_by(.updatedAt) | last | .sessionId // empty'
}

diagnose_fail() {  # <log> <message>
  printf '# screen log %s:\n' "$1" >&2
  tail -c 3000 "$1" >&2 2>/dev/null || true
  fail "$2"
}

# shellcheck source=bin/fm-kiro-lib.sh
. "$ROOT/bin/fm-kiro-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
FOREIGN_HOME="$LAB/foreign-kiro-home"
fm_kiro_write_settings "$FOREIGN_HOME" || fail "could not prepare the foreign KIRO_HOME"

# --- worker ------------------------------------------------------------------

ID="kiro-resume-live-$$"
PROJ="$LAB/project"
STATE="$LAB/fmhome/state"
KH="$STATE/$ID.kiro-home"
mkdir -p "$PROJ" "$STATE"
fm_git_init_commit "$PROJ"
fm_kiro_build_task_home "$KH" "" "$STATE/$ID.turn-ended" >/dev/null || fail "could not build the task KIRO_HOME"
fm_kiro_install_v3_project_config "$PROJ" "$ID" "$KH" || fail "could not install the task's V3 project hooks"

busy_seq() { sed -n 's/.* seq=\([0-9][0-9]*\) .*/\1/p' "$STATE/$ID.busy-state"; }
classify() { fm_busy_classify tmux fake:win kiro-cli "$ID" "$STATE" 'no rendered anchors'; }

launch_worker() {  # <generation> <log> <prompt>
  rm -f "$STATE/$ID.turn-ended"
  env -i "${BASE_ENV[@]}" FM_KIRO_TASK_ID="$ID" FM_KIRO_STATE="$STATE" FM_KIRO_BUSY_GEN="$1" \
    KIRO_HOME="$KH" KIRO_DATA_DIR="$KH/data" KIRO_CHAT_LOG_FILE="$KH/chat.log" \
    python3 "$PTY" --cwd "$PROJ" --log "$2" --pid-file "$2.pid" --timeout "$TIMEOUT" \
      --until-file "$STATE/$ID.turn-ended" -- \
      "$KIRO_BIN" chat --v3 -a --agent "firstmate-kiro-$ID" --effort low ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "$3" \
    || diagnose_fail "$2" "the launched Kiro worker never ended its turn"
}

resume_worker() {  # <session-id> <log> <prompt> [until-file]
  env -i "${BASE_ENV[@]}" KIRO_HOME="$FOREIGN_HOME" \
    python3 "$PTY" --cwd "$PROJ" --log "$2" --pid-file "$2.pid" --timeout "$TIMEOUT" \
      --until-file "${4:-$STATE/$ID.turn-ended}" -- \
      "$KIRO_BIN" chat --v3 -a --resume-id "$1" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "$3" \
    || diagnose_fail "$2" "the resumed Kiro worker never ended its turn"
}

GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") || fail "could not arm the worker generation"
launch_worker "$GEN" "$LAB/worker-launch.log" \
  'Reply with the word FIRST immediately followed by the word OK, written as one word, and then stop. Do not use any tools.'
[ "$(classify)" = "idle kiro-hook" ] || fail "the launched worker's Stop did not close busy state: $(classify)"
SID_A=$(only_session_id "$PROJ")
[ -n "$SID_A" ] || fail "Kiro did not list exactly one worker session after the first launch"
[ "$(cat "$KH/.fm-kiro-session")" = "$GEN $SID_A" ] \
  || fail "the launched incarnation did not record its own Kiro session ($(cat "$KH/.fm-kiro-session" 2>/dev/null))"
pass "live worker: a launched incarnation's hooks bind to its task and record its Kiro session"

seq_before=$(busy_seq)
rm -f "$STATE/$ID.turn-ended" "$STATE/$ID.progress"
resume_worker "$SID_A" "$LAB/worker-resume.log" \
  'Run the shell command true with your shell tool, then reply with the word SECOND immediately followed by the word OK, written as one word.'
[ "$(classify)" = "idle kiro-hook" ] || fail "the resumed worker's Stop did not close busy state: $(classify)"
[ "$(busy_seq)" -ge $((seq_before + 2)) ] \
  || fail "the resumed worker's prompt and Stop did not both reach busy state (seq $seq_before -> $(busy_seq))"
assert_present "$STATE/$ID.progress" "the resumed worker's tool use did not publish progress"
assert_present "$STATE/$ID.turn-ended" "the resumed worker's Stop did not notify its task"
pass "live worker: the conversation resumed without launcher environment reaches its task"

fm_kiro_build_task_home "$KH" "" "$STATE/$ID.turn-ended" >/dev/null || fail "could not rebuild the task KIRO_HOME for the relaunch"
fm_kiro_install_v3_project_config "$PROJ" "$ID" "$KH" || fail "the relaunch could not reinstall identical V3 project hooks"
GEN_B=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") || fail "could not arm the replacement generation"
launch_worker "$GEN_B" "$LAB/worker-relaunch.log" \
  'Reply with the word THIRD immediately followed by the word OK, written as one word, and then stop. Do not use any tools.'
SID_B=$(newest_session_id "$PROJ")
[ -n "$SID_B" ] && [ "$SID_B" != "$SID_A" ] || fail "the relaunch did not start a new Kiro session"
[ "$(cat "$KH/.fm-kiro-session")" = "$GEN_B $SID_B" ] || fail "the replacement incarnation did not record its own session"
seq_before=$(busy_seq)
rm -f "$STATE/$ID.turn-ended" "$STATE/$ID.progress"
resume_worker "$SID_A" "$LAB/worker-stale.log" \
  'Run the shell command true with your shell tool, then reply with the word FOURTH immediately followed by the word OK, written as one word.'
[ "$(busy_seq)" = "$seq_before" ] || fail "resuming the older conversation after a relaunch changed busy state"
assert_absent "$STATE/$ID.progress" "resuming the older conversation after a relaunch published progress"
pass "live worker: after a relaunch the older conversation cannot write busy state"

# --- primary -----------------------------------------------------------------

PRIMARY="$LAB/firstmate"
mkdir -p "$PRIMARY"
# Read the current working files, not HEAD, so this guard verifies a branch
# before commit.
git -C "$ROOT" ls-files -z | tar -C "$ROOT" --null -T - -cf - | tar -C "$PRIMARY" -xf -
git -C "$PRIMARY" init -q
git -C "$PRIMARY" symbolic-ref HEAD refs/heads/main
mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects"

env -i "${BASE_ENV[@]}" FM_HOME="$PRIMARY" \
  python3 "$PTY" --cwd "$PRIMARY" --log "$LAB/primary-launch.log" --pid-file "$LAB/primary-launch.pid" \
    --timeout "$TIMEOUT" --until-file "$PRIMARY/state/.session-start-complete" --until-regex 'PRIMARYREADY' -- \
    "$PRIMARY/bin/fm-kiro-primary.sh" --effort low ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    'Do not run any tools. Reply with the word PRIMARY immediately followed by the word READY, written as one word.' \
  || diagnose_fail "$LAB/primary-launch.log" "the launched primary never finished its first turn"
first_owner=$(head -n 1 "$PRIMARY/state/.lock")
[ "$first_owner" = "$(cat "$LAB/primary-launch.pid")" ] || fail "the launched primary's SessionStart did not take the lock"
! kill -0 "$first_owner" 2>/dev/null || fail "the launched primary is still running after /quit"
SID_P=$(only_session_id "$PRIMARY")
[ -n "$SID_P" ] || fail "Kiro did not list exactly one primary session"

rm -f "$LAB/primary-probe"
env -i "${BASE_ENV[@]}" KIRO_HOME="$FOREIGN_HOME" FM_KIRO_HOOK_PROBE_FILE="$LAB/primary-probe" \
  python3 "$PTY" --cwd "$PRIMARY" --log "$LAB/primary-resume.log" --pid-file "$LAB/primary-resume.pid" \
    --timeout "$TIMEOUT" --until-regex 'PRIMARYBACK' --settle 10 -- \
    "$KIRO_BIN" chat --v3 -a --resume-id "$SID_P" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    'Do not run any tools. Reply with the word PRIMARY immediately followed by the word BACK, written as one word.' \
  || diagnose_fail "$LAB/primary-resume.log" "the resumed primary never finished its turn"
[ "$(head -n 1 "$PRIMARY/state/.lock")" = "$(cat "$LAB/primary-resume.pid")" ] \
  || fail "the resumed primary did not retake the lock from its dead owner $first_owner"
[ "$(cat "$PRIMARY/state/.session-start-complete")" = "$(cat "$LAB/primary-resume.pid")" ] \
  || fail "the resumed primary did not complete a session start"
[ "$(grep -c '^at=' "$LAB/primary-probe")" -ge 2 ] \
  || fail "the resumed primary's UserPromptSubmit and Stop hooks did not both arrive"
pass "live primary: a resumed primary retakes its dead owner's lock on the first prompt ($KIRO_VERSION)"

printf '%s\n' "ok - Kiro resume continuity passed on $KIRO_VERSION"
