#!/usr/bin/env bash
# Live opt-in drift guard for the Cline CLI adapter.
#
# Every fact this exercises is harness-dependent: cline's start mode, its
# session-record lifecycle, its interrupt key, and its exit key all come from
# what the vendor emits, so a stub could only confirm the assumption already
# written into the stub. This runs the REAL installed binary and fails naming
# the harness and version.
#
# It deliberately uses the operator's own cline data directory, because that is
# where the credentials and provider configuration live and because the whole
# act-mode mechanism is a redirect of ONE file out of that directory. It never
# writes anything under it: the only files this creates are the lab's own
# settings copies and workspace.
#
# Refresh docs/verification/cline-adapter.md from this guard after every cline
# upgrade.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLINE_BIN=$(command -v cline 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-cline-signals-$$"
SESSION=cline-signals
TARGET="$SESSION:cline"
VERSION=

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - cline %s: %s\n' "${VERSION:-unknown-version}" "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - cline %s: %s\n' "$VERSION" "$1"
}

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true
}

pane_command() {
  "$REAL_TMUX" -L "$SOCKET" display -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true
}

# wait_for_pane <seconds> <grep-pattern>: poll the rendered pane for a pattern.
wait_for_pane() {
  local budget=$1 pattern=$2 i=0
  while [ "$i" -lt "$((budget * 5))" ]; do
    capture | grep -qE "$pattern" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

launch_cline() {  # <settings-path>
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" \
    "CLINE_GLOBAL_SETTINGS_PATH='$1' '$CLINE_BIN' -i --tui --auto-approve true" Enter \
    || fail "could not launch cline in the lab pane"
}

exit_cline() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c || fail "could not send cline's exit key"
}

if [ "${FM_CLINE_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CLINE_SIGNALS_LIVE=1 to run the real cline signal drift guard"
  exit 0
fi

[ -x "$CLINE_BIN" ] || fail "FM_CLINE_SIGNALS_LIVE=1 but no real cline executable is installed on PATH"
[ -x "$REAL_TMUX" ] || fail "FM_CLINE_SIGNALS_LIVE=1 but tmux is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is required to read cline's own session records"

VERSION=$("$CLINE_BIN" --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || fail "the installed cline did not report a version"

CLINE_DATA_ROOT="${CLINE_DATA_DIR:-$HOME/.cline/data}"
CLINE_SESSIONS_ROOT="$CLINE_DATA_ROOT/sessions"
OPERATOR_SETTINGS="$CLINE_DATA_ROOT/settings/global-settings.json"
[ -d "$CLINE_SESSIONS_ROOT" ] || fail "cline has no sessions directory at $CLINE_SESSIONS_ROOT; run cline once before this guard"

# The operator's own settings must come out byte-identical. This is the whole
# safety claim of the act-mode mechanism, so it is measured, not asserted in
# prose.
OPERATOR_BEFORE=
[ ! -f "$OPERATOR_SETTINGS" ] || OPERATOR_BEFORE=$(cksum < "$OPERATOR_SETTINGS")

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cline-signals.XXXXXX") || fail "could not create the isolated cline lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" "$LAB/bin"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated cline workspace"

# Route firstmate's own plain `tmux` calls at the isolated lab server, so the
# liveness read below inspects this pane rather than the operator's session.
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated cline workspace"

printf '{"planActMode": "plan"}\n' > "$LAB/plan-settings.json"
printf '{"planActMode": "act"}\n' > "$LAB/act-settings.json"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" -x 200 -y 50 \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n cline -c "$WORKSPACE" \
  || fail "could not create the isolated cline window"

# --- the gap itself: a persisted plan mode wins over the documented default ---
#
# If this stops reproducing, cline changed its start-mode precedence and the
# act-mode forcing below may no longer be load-bearing - which is a fact worth
# failing on rather than silently carrying a redundant mechanism.
launch_cline "$LAB/plan-settings.json"
wait_for_pane 40 '● Plan ○ Act' \
  || fail "a persisted planActMode=plan no longer starts the TUI in plan mode; re-verify the act-mode mechanism"
pass "a persisted plan mode still governs the TUI start mode (the gap reproduces)"

# --- exit key: cline has no composer exit command ---------------------------
[ "$(fm_control_exit_key cline)" = C-c ] || fail "the control plane no longer records cline's exit key"
exit_cline
CLEARED=0
for _ in $(seq 1 50); do
  case "$(pane_command)" in
    ''|node) sleep 0.2 ;;
    *) CLEARED=1; break ;;
  esac
done
[ "$CLEARED" = 1 ] || fail "cline's recorded exit key did not return the pane to its shell"
pass "cline's recorded exit key exits the real TUI cleanly"

# --- act mode is forced, rendered AND structurally --------------------------
BEFORE_SESSIONS="$LAB/sessions.before"
fm_busy_cline_matching_sessions "$CLINE_SESSIONS_ROOT" "$WORKSPACE" > "$BEFORE_SESSIONS" 2>/dev/null || true

launch_cline "$LAB/act-settings.json"
wait_for_pane 40 '○ Plan ● Act' \
  || fail "the firstmate act-mode settings redirect did not start the real TUI in act mode"
pass "the act-mode settings redirect starts the real TUI in act mode"

# Every lifecycle verb refuses an endpoint it cannot positively attribute, and
# cline runs as a bundled Node script reporting a bare `node`. This is the
# second reason fm-control refused a live cline worker, separate from its
# missing mechanics, so assert it against the real process rather than a fixture.
AGENT_STATE=$(fm_backend_agent_state tmux "$TARGET" 2>/dev/null || true)
[ "$AGENT_STATE" = alive ] \
  || fail "a live cline pane reads agent state '$AGENT_STATE'; every lifecycle verb refuses anything but a positively classified endpoint"
pass "a live cline pane is positively attributed as a running agent"

# Bind the pane to its own session record exactly as fm-spawn does.
STATE="$LAB/state"
mkdir -p "$STATE"
{
  printf 'sessions_root=%s\n' "$CLINE_SESSIONS_ROOT"
  printf 'workspace_root=%s\n' "$WORKSPACE"
  while IFS= read -r prior; do
    [ -n "$prior" ] && printf 'prior_session=%s\n' "$prior"
  done < "$BEFORE_SESSIONS"
} > "$STATE/live.cline-session"

# A turn long enough to observe in flight and to interrupt.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" \
  "Count slowly from 1 to 60, writing one short line per number. Do not use tools." || fail "could not type the probe turn"
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit the probe turn"

# Observe the turn from the instant it is submitted. Everything that could be
# checked first - a quota refusal, the binding, the recorded mode - is checked
# INSIDE this loop rather than before it, because each pre-check would spend
# part of the only window in which the turn is observably in flight. That
# sequencing is what a first cut of this guard got wrong: it read the fold only
# after the turn had already finished, and reported the source broken when it
# was not.
#
# A quota refusal renders like a completed turn, which is exactly why it must be
# named rather than allowed to pass as one. Refuse a vacuous pass.
RECORD=
TURN_STATE=
for _ in $(seq 1 200); do
  if capture | grep -qE 'ClinePass limit reached|usage limit'; then
    fail "the provider refused the probe turn (ClinePass limit reached), so no live turn lifecycle was observed; re-run when the limit resets"
  fi
  if [ -z "$RECORD" ]; then
    RECORD=$(fm_busy_cline_session_record "$STATE" live 2>/dev/null || true)
  fi
  if [ -n "$RECORD" ]; then
    TURN_STATE=$(fm_busy_cline_session_state "$RECORD" 2>/dev/null || true)
    [ "$TURN_STATE" = busy ] && break
  fi
  sleep 0.2
done

[ -n "$RECORD" ] || fail "the real cline pane produced no uniquely bound workspace session record"
pass "the real cline pane binds to exactly one of its own session records"

# The structural proof of act mode: cline records the mode it actually ran in,
# so this does not depend on the footer glyphs above.
MODE=$(LC_ALL=C jq -r '.metadata.mode // empty' "$RECORD" 2>/dev/null || true)
[ "$MODE" = act ] \
  || fail "the real session record reports mode '$MODE', so the crewmate did not run in act mode"
pass "the real session record structurally confirms the crewmate ran in act mode"

[ "$TURN_STATE" = busy ] \
  || fail "fm_busy_cline_session_state never observed the real turn in flight (read '$TURN_STATE'); a turn that settled before it could be observed is not proof the source works"
pass "cline's real session record classifies busy in flight"

# --- interrupt key: Escape cancels the TURN and leaves the agent running ----
[ "$(fm_control_interrupt_key cline)" = Escape ] || fail "the control plane no longer records cline's interrupt key"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape || fail "could not send cline's interrupt key"
sleep 2
case "$(pane_command)" in
  node) ;;
  *) fail "cline's recorded interrupt key stopped the agent instead of its turn" ;;
esac
wait_for_pane 20 'Ask anything\.\.\.|What can I do for you\?' \
  || fail "cline's composer did not return to an idle placeholder after its interrupt key"
# The composer must not hold the cancelled prompt, or the next submitted line
# would concatenate onto it - the reason the clear-key table exists.
#
# Read the LAST prompt-glyph row only. The submitted prompt is also echoed into
# the conversation above the composer, so a whole-pane search finds it in the
# scrollback and reports a restored prompt that is not there.
COMPOSER_ROW=$(capture | grep -a '❯' | tail -1)
case "$COMPOSER_ROW" in
  *'Ask anything'*|*'What can I do for you'*) ;;
  *)
    fail "after its interrupt key cline's composer row reads '$COMPOSER_ROW' rather than an idle placeholder; if it now restores the cancelled prompt it needs a clear key the control plane does not record"
    ;;
esac
pass "cline's recorded interrupt key cancels the turn without polluting the composer"

for _ in $(seq 1 150); do
  TURN_STATE=$(fm_busy_cline_session_state "$RECORD" 2>/dev/null || true)
  case "$TURN_STATE" in busy) sleep 0.2 ;; *) break ;; esac
done
case "$TURN_STATE" in
  settled|stalled) ;;
  *) fail "the interrupted turn never left busy (read '$TURN_STATE')" ;;
esac
pass "cline's real session record leaves busy once the turn is cancelled"

exit_cline
sleep 2

# --- the operator's own configuration is untouched --------------------------
if [ -n "$OPERATOR_BEFORE" ]; then
  [ "$OPERATOR_BEFORE" = "$(cksum < "$OPERATOR_SETTINGS")" ] \
    || fail "the guard changed the operator's own cline global settings"
  pass "the operator's own cline settings are byte-identical after a forced-act run"
fi

cleanup
trap - EXIT
echo "ALL PASS: fm-cline-signals-live-e2e (cline $VERSION)"
