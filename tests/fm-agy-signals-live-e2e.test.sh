#!/usr/bin/env bash
# Opt-in live guard for the Antigravity CLI (agy) signals firstmate depends on.
#
# tests/fm-agy-harness.test.sh pins the LOGIC portably, with real processes and
# real SQLite databases but no agy. That regression cannot notice the half of
# this adapter that only the vendor controls, because a fixture can only confirm
# the assumption already written into it. This guard exercises the real installed
# binary and fails naming the harness and its version, so a release that renames
# the process, stops logging `Created conversation`, changes the step-status
# vocabulary, or starts resolving trust differently is caught here rather than by
# a fleet of silently unsupervisable workers.
#
# Run it after every agy upgrade, and before trusting refreshed per-harness
# evidence in docs/verification/runtime-backends.md:
#   FM_AGY_SIGNALS_LIVE=1 tests/fm-agy-signals-live-e2e.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SQLITE_BIN=$(command -v sqlite3 2>/dev/null || true)
LAB=
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"
SETTINGS=
SETTINGS_BACKUP=

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # Restore the operator's own settings file byte for byte. This guard writes a
  # real trust grant into it, so leaving one behind would silently widen what a
  # later agy session is allowed to read.
  if [ -n "$SETTINGS" ] && [ -n "$SETTINGS_BACKUP" ] && [ -f "$SETTINGS_BACKUP" ]; then
    cp "$SETTINGS_BACKUP" "$SETTINGS" 2>/dev/null || true
  fi
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s (agy %s)\n' "$1" "${AGY_VERSION:-unknown}" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if [ "${FM_AGY_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AGY_SIGNALS_LIVE=1 to run the real agy signal drift guard"
  exit 0
fi

# An absent harness is reported explicitly rather than passed over: a guard that
# checked nothing must never look like a guard that checked something.
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "FM_AGY_SIGNALS_LIVE=1 but no real agy executable is installed on PATH"
[ -n "$REAL_TMUX" ] && [ -x "$REAL_TMUX" ] \
  || fail "FM_AGY_SIGNALS_LIVE=1 but tmux is not installed"
[ -n "$SQLITE_BIN" ] && [ -x "$SQLITE_BIN" ] \
  || fail "FM_AGY_SIGNALS_LIVE=1 but sqlite3 is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is required to write agy's trust grant"

AGY_VERSION=$("$AGY_BIN" --version 2>/dev/null | head -1)
[ -n "$AGY_VERSION" ] || fail "the installed agy reported no version"
printf '# agy %s at %s\n' "$AGY_VERSION" "$AGY_BIN"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" "$LAB/state"
WORKSPACE="$LAB/workspace"
CONVERSATIONS="${HOME:-}/.gemini/antigravity-cli/conversations"
SETTINGS="${HOME:-}/.gemini/antigravity-cli/settings.json"
SETTINGS_BACKUP="$LAB/settings.json.bak"
[ -f "$SETTINGS" ] || fail "no agy settings file at $SETTINGS; run agy once before this guard"
cp "$SETTINGS" "$SETTINGS_BACKUP" || fail "could not back up the agy settings file"

# --- trust: the grant firstmate writes must actually suppress the dialog ------
jq --arg p "$WORKSPACE" '.trustedWorkspaces = ((.trustedWorkspaces // []) + [$p] | unique)' \
  "$SETTINGS" > "$LAB/settings.new" || fail "could not compute an agy trust grant"
cp "$LAB/settings.new" "$SETTINGS" || fail "could not install the agy trust grant"

AGY_LOG="$LAB/state/live.agy-log"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n agy -c "$WORKSPACE" -- \
  "$AGY_BIN" --dangerously-skip-permissions --log-file "$AGY_LOG" \
  || fail "could not launch agy"

PANE=
for _ in $(seq 1 150); do
  PANE=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$PANE" in *'? for shortcuts'*) break ;; esac
  sleep 0.2
done
case "$PANE" in
  *'trust'*|*'Trust'*)
    fail "a pre-written trustedWorkspaces grant no longer suppresses agy's workspace-trust dialog"
    ;;
esac
case "$PANE" in
  *'? for shortcuts'*) : ;;
  *) fail "agy never reached its idle composer; the launch flags or startup shape changed" ;;
esac
pass "agy's trust grant still suppresses the workspace dialog for an exact path"

# --- detection: the live process is still named agy --------------------------
TTY=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_tty}' 2>/dev/null)
[ -n "$TTY" ] || fail "could not read the agy pane tty"
FOUND=0
while read -r _ pgid tpgid comm; do
  [ -n "$comm" ] || continue
  [ "$pgid" = "$tpgid" ] || continue
  case "${comm##*/}" in agy) FOUND=1 ;; esac
done <<EOF
$(LC_ALL=C ps -t "${TTY#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
[ "$FOUND" = 1 ] \
  || fail "the live agy foreground process is no longer named 'agy'; bin/fm-harness.sh and bin/backends/tmux.sh anchor on that exact name"
pass "agy's live process name is still the exact string agy"

# --- composer: the real rendered shape still classifies ----------------------
STYLED=$("$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" -S 0 -E - 2>/dev/null)
CY=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{cursor_y}' 2>/dev/null)
CAPS=$(printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n')
VERDICT=$(fm_composer_classify_screen "$CAPS" "$STYLED" "$CY" "$(printf 'agy\tidle')")
[ "$VERDICT" = empty ] \
  || fail "a real idle agy composer classified '$VERDICT' rather than empty; its rendered shape changed"
pass "agy's real idle composer still classifies empty"

# --- busy: the real log binding and step-status fold -------------------------
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" \
  'Run the shell command: sleep 25 && echo slept. Then say done.' Enter \
  || fail "could not submit a turn to the live agy pane"

CONV=
for _ in $(seq 1 150); do
  CONV=$(LC_ALL=C sed -n \
    's/.*Created conversation \([0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}\).*/\1/p' \
    "$AGY_LOG" 2>/dev/null | tail -1)
  [ -z "$CONV" ] || break
  sleep 0.2
done
if [ -z "$CONV" ]; then
  # Distinguish "agy changed" from "this account could not start a turn". agy
  # answers an ineligible or throttled account in the pane without ever opening
  # a conversation, which would otherwise be reported here as a log-format
  # change and send a maintainer looking in the wrong place.
  PANE=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$PANE" in
    *'verifying your account'*|*'try again shortly'*|*'quota'*|*'rate limit'*|*'Rate limit'*)
      fail "agy accepted the turn but its account could not start one (pane says: $(printf '%s' "$PANE" | grep -iE 'verifying your account|try again shortly|quota|rate limit' | head -1 | sed 's/^[[:space:]]*//')). This is an account/quota condition, not adapter drift - retry when the account is available"
      ;;
  esac
  fail "the real agy log no longer carries a 'Created conversation <id>' line; the conversation binding in bin/fm-busy-lib.sh depends on it"
fi
pass "agy still names its conversation in the per-task log file"

DB="$CONVERSATIONS/$CONV.db"
for _ in $(seq 1 150); do
  [ -f "$DB" ] && break
  sleep 0.2
done
[ -f "$DB" ] || fail "agy created no conversation database at $DB"

# Bind the task exactly as fm-spawn does, then fold through the real classifier.
{
  printf 'conversations_root=%s\n' "$CONVERSATIONS"
  printf 'log_file=%s\n' "$AGY_LOG"
} > "$LAB/state/live.agy-session"

RUN_STATE=
for _ in $(seq 1 200); do
  RUN_STATE=$(fm_busy_agy_run_state "$DB" 2>/dev/null || true)
  [ "$RUN_STATE" = busy ] && break
  sleep 0.2
done
[ "$RUN_STATE" = busy ] \
  || fail "fm_busy_agy_run_state never observed the real turn in flight; agy's step-status vocabulary changed"
[ "$(fm_busy_classify tmux "$TARGET" agy live "$LAB/state")" = "busy agy-steps" ] \
  || fail "the classifier did not report busy agy-steps for a real in-flight agy turn"
pass "agy's real conversation database classifies busy in flight"

for _ in $(seq 1 400); do
  RUN_STATE=$(fm_busy_agy_run_state "$DB" 2>/dev/null || true)
  [ "$RUN_STATE" = settled ] && break
  sleep 0.2
done
[ "$RUN_STATE" = settled ] \
  || fail "fm_busy_agy_run_state never settled after the real turn finished; agy's step-status vocabulary changed"
[ "$(fm_busy_classify tmux "$TARGET" agy live "$LAB/state")" = "idle agy-steps" ] \
  || fail "the classifier did not report idle agy-steps after a real agy turn settled"
pass "agy's real conversation database settles to idle after the turn"

# --- interrupt: a cancelled step must still settle to the finished status ----
# The fold treats any status other than 3 as a turn in flight, so a step that
# settled to some OTHER terminal value after an interrupt would read busy
# forever. Interrupt is a first-class verb for agy, so that assumption is
# exercised here rather than assumed.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" \
  'Write an extremely long detailed essay, at least 4000 words, about the history of maritime navigation. Do not use any tools.' Enter \
  || fail "could not submit the interrupt-path turn to the live agy pane"

RUN_STATE=
for _ in $(seq 1 200); do
  RUN_STATE=$(fm_busy_agy_run_state "$DB" 2>/dev/null || true)
  [ "$RUN_STATE" = busy ] && break
  sleep 0.2
done
[ "$RUN_STATE" = busy ] \
  || fail "the interrupt-path turn never read busy, so the interrupt assertion below would be vacuous"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not deliver Escape to the live agy pane"

RUN_STATE=
for _ in $(seq 1 150); do
  RUN_STATE=$(fm_busy_agy_run_state "$DB" 2>/dev/null || true)
  [ "$RUN_STATE" = settled ] && break
  sleep 0.2
done
[ "$RUN_STATE" = settled ] \
  || fail "an INTERRUPTED agy step did not settle to the finished status; fm_busy_agy_run_state would read busy forever after every interrupt"
pass "an interrupted agy turn still settles the conversation database to idle"

# --- effort/model axes: the launch flags this adapter passes still parse ------
"$AGY_BIN" --dangerously-skip-permissions --model gemini-3.6-flash --effort low \
  -p 'Reply with exactly: ok' >/dev/null 2>"$LAB/effort.err" \
  || fail "a bare base model name plus --effort no longer launches: $(head -1 "$LAB/effort.err")"
pass "agy still accepts a bare base model name alongside --effort"

if "$AGY_BIN" --dangerously-skip-permissions --model gemini-3.6-flash --effort xhigh \
    -p 'ping' >/dev/null 2>&1; then
  fail "agy now accepts --effort xhigh; bin/fm-spawn.sh and bin/fm-bootstrap.sh cap it at high"
fi
pass "agy still caps --effort at high"

cleanup
trap - EXIT
