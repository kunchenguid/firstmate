#!/usr/bin/env bash
# Opt-in live check of the Antigravity CLI (agy) guarded global hook.
#
# The guard is harness-dependent: its verdict comes from the payload agy itself
# emits, so a stub can only confirm the assumption already written into the stub.
# This runs the REAL binary against the REAL installed global hook - once from a
# workspace holding a registered Firstmate pointer, once from a workspace
# holding none - and asserts the turn-end marker and the semantic busy record
# move only for the registered one. That pair is the whole safety claim for
# sharing one hook entry with the captain's own agy sessions. It also proves
# --add-dir's two load-bearing effects: it populates the payload's
# workspacePaths, and it suppresses the folder-trust dialog.
#
# It is also the only proof of the busy half of the `agy-hook` source. agy has
# no second busy source by design, so if `PreInvocation` ever stopped carrying a
# workspace the record would sit at idle for every turn a crewmate works, and
# nothing else in the tree would notice.
#
# The hook itself must live in agy's real config directory: agy resolves that
# root from $HOME alone and honours no override, and moving $HOME would take its
# credentials with it. So this installs into the shared config through the same
# idempotent installer fm-spawn uses, and afterwards removes ONLY what it added -
# its own registry token always, its own tmux server always, and the shared hook
# only when this run is what created it. Everything else (state, workspaces,
# marker) is scratch.
#
# The last case drives the INTERACTIVE `-i` launch the adapter actually ships,
# in a real pane on a dedicated tmux socket. Headless `-p` and interactive `-i`
# are separately verified behaviours on agy, so a guard built only from `-p`
# would sit still through a release that changed Stop/fullyIdle or
# workspacePaths for the one mode a crewmate ever runs in.
set -u

if [ "${FM_AGY_SIGNALS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AGY_SIGNALS_LIVE_E2E=1 to run the live agy signal check"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGY_BIN=$(command -v agy) || fail "agy not found on PATH"
command -v jq >/dev/null 2>&1 || fail "jq not found"
REAL_TMUX=$(command -v tmux) || fail "tmux is required to drive agy's interactive launch mode"
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"
AGY_VERSION=$("$AGY_BIN" --version 2>&1 | head -1)
CONFIG_DIR="$HOME/.gemini/config"
[ -d "$CONFIG_DIR" ] || fail "agy config directory is absent at $CONFIG_DIR"
# Resolved, not raw: on macOS $TMPDIR ends in a slash, so fm_test_tmproot
# hands back a path carrying a redundant `//`, and agy's folder-trust check
# does not match such a path against the session it just opened - the dialog
# renders even with --add-dir. bin/fm-spawn.sh always passes a resolved
# worktree (tmux's pane_current_path), so a raw lab path would fail this file
# on a shape production never produces.
LAB=$(cd "$(fm_test_tmproot fm-agy-signals)" && pwd -P) \
  || fail "could not resolve the scratch lab directory"
STATE="$LAB/state"
mkdir -p "$STATE" "$LAB/registered" "$LAB/outsider"

HOOK_PREEXISTING=no
if [ -f "$CONFIG_DIR/hooks.json" ] \
   && jq -e 'has("firstmate-turn-end")' "$CONFIG_DIR/hooks.json" >/dev/null 2>&1; then
  HOOK_PREEXISTING=yes
fi
TOKEN=

cleanup_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$TOKEN" ] || rm -f "$CONFIG_DIR/fm-agy-turn-end.d/$TOKEN"
  if [ "$HOOK_PREEXISTING" = no ]; then
    "$ROOT/bin/fm-agy-config.sh" remove "$LAB/absent-skills" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_live EXIT

run_agy() {  # <workspace> [--add-dir]
  local workspace=$1
  shift
  ( cd "$workspace" && "$AGY_BIN" -p 'Reply with exactly: LIVE-OK' \
      --dangerously-skip-permissions "$@" \
      >"$LAB/agy.out" 2>"$LAB/agy.err" )
}

AGY_TRUST_PROMPT='Do you trust the contents of this project'

# The interactive launch fm-spawn actually ships, in a real pane, in a workspace
# agy has never been trusted for. No dialog is answered here: `--add-dir`
# suppresses it, and proving that is one of the things this file exists for.
run_agy_interactive() {  # <workspace> [extra-args...]
  local workspace=$1
  shift
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$workspace" \
    || fail "could not start the isolated tmux server ($AGY_VERSION)"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n agy -c "$workspace" -- \
    "$AGY_BIN" --dangerously-skip-permissions "$@" \
    -i 'Reply with exactly: LIVE-OK' \
    || fail "could not launch agy interactively ($AGY_VERSION)"
}

agy_pane_holds_trust_prompt() {  # <polls>
  local pane i=0
  while [ "$i" -lt "$1" ]; do
    pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -120 2>/dev/null || true)
    case "$pane" in *"$AGY_TRUST_PROMPT"*) return 0 ;; esac
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

"$ROOT/bin/fm-agy-config.sh" install "$LAB/absent-skills" \
  || fail "agy global wiring install failed"

BUSY_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live) \
  || fail "could not arm a busy generation"
TOKEN=$(basename "$(mktemp "$CONFIG_DIR/fm-agy-turn-end.d/fm.XXXXXXXXXXXX")")
printf '%s\n%s\n%s\n%s\n%s\n' "$STATE/live.turn-ended" "$ROOT/bin/fm-busy-event.sh" \
  "$STATE" live "$BUSY_GEN" > "$CONFIG_DIR/fm-agy-turn-end.d/$TOKEN"
printf 'token=%s\n' "$TOKEN" > "$LAB/registered/.fm-agy-turnend"

# 1. An agy session in a workspace Firstmate never registered.
run_agy "$LAB/outsider" --add-dir "$LAB/outsider" \
  || fail "agy refused to run in the unregistered workspace: $(head -3 "$LAB/agy.err")"
[ ! -e "$STATE/live.turn-ended" ] \
  || fail "an unregistered agy session fired a Firstmate turn-end marker ($AGY_VERSION)"
grep -q 'source=agy-hook' "$STATE/live.busy-state" \
  && fail "an unregistered agy session wrote a Firstmate busy event ($AGY_VERSION)"
pass "the agy global hook is inert for a session Firstmate did not register ($AGY_VERSION)"

# 2. The same hook, same binary, in the registered workspace.
run_agy "$LAB/registered" --add-dir "$LAB/registered" \
  || fail "agy refused to run in the registered workspace: $(head -3 "$LAB/agy.err")"
[ -e "$STATE/live.turn-ended" ] \
  || fail "a registered agy session did not fire its turn-end marker ($AGY_VERSION)"
grep -q 'state=idle source=agy-hook' "$STATE/live.busy-state" \
  || fail "a registered agy session did not record a semantic idle event ($AGY_VERSION)"
pass "the agy global hook fires the turn-end marker and idle event for a registered task ($AGY_VERSION)"

# 3. agy still reports an EMPTY workspacePaths without --add-dir, which is the
# reason fm-spawn passes it; without that binding the guard can never match, so
# a release that starts populating it would make the flag redundant and this
# case is what would say so.
rm -f "$STATE/live.turn-ended"
run_agy "$LAB/registered" \
  || fail "agy refused to run without --add-dir: $(head -3 "$LAB/agy.err")"
[ ! -e "$STATE/live.turn-ended" ] \
  || fail "agy populated workspacePaths without --add-dir; fm-spawn's binding may be redundant now ($AGY_VERSION)"
pass "agy still reports no workspace without --add-dir, so fm-spawn's binding is still required ($AGY_VERSION)"

# 3b. --add-dir's SECOND load-bearing effect: it suppresses the folder-trust
# dialog, which --dangerously-skip-permissions does not and which agy has no
# --trust flag for. Both arms are interactive on purpose - headless `-p` renders
# no dialog either, so asserting suppression from a `-p` run would pass just as
# well with the flag removed. Two fresh never-trusted paths, one arm each, so
# the absence in the first arm is attributable to the flag and not to the path
# already being trusted.
mkdir -p "$LAB/trust-with" "$LAB/trust-without"
run_agy_interactive "$LAB/trust-without"
agy_pane_holds_trust_prompt 60 \
  || fail "a launch WITHOUT --add-dir showed no folder-trust dialog, so the suppression arm below proves nothing ($AGY_VERSION)"
# Leave that arm refused rather than trusted: answering it would write the path
# into agy's trustedWorkspaces and outlive the test.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Down Enter 2>/dev/null || true
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true

run_agy_interactive "$LAB/trust-with" --add-dir "$LAB/trust-with"
agy_pane_holds_trust_prompt 20 \
  && fail "--add-dir no longer suppresses the folder-trust dialog; every unattended spawn would park on it ($AGY_VERSION)"
jq -e --arg ws "$LAB/trust-with" '[.trustedWorkspaces[]? | strings] | index($ws) | not' \
  "$HOME/.gemini/antigravity-cli/settings.json" >/dev/null 2>&1 \
  || fail "a --add-dir launch wrote its workspace into agy's trustedWorkspaces; firstmate must write nothing there ($AGY_VERSION)"
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
pass "--add-dir suppresses agy's folder-trust dialog, which a launch without it still shows ($AGY_VERSION)"

# 4. The same guarded hook under the launch mode the adapter actually ships,
# and the only live proof of its BUSY half.
# `-i` keeps the session interactive, which is a different code path in agy than
# `-p`, and CORRECTION 2 in this adapter's brief exists because an earlier probe
# concluded the hook was headless-only. A pane is the only way to exercise it.
#
# Both records are cleared first: case 2 already wrote the idle line into
# live.busy-state, so an assertion made against the surviving copy would pass
# whether or not this session published anything. Clearing the record also
# resets the sequence, which is what turns it into evidence: bin/fm-busy-event.sh
# derives each seq from the record it replaces, so a run where only `Stop`
# published leaves seq=1, while a run where `PreInvocation` opened the turn
# first leaves seq=2. Both events resolve the task from the SAME
# payload.workspacePaths guard, so a second event under source=agy-hook is proof
# that agy populated that array for PreInvocation too, not only for Stop.
rm -f "$STATE/live.turn-ended" "$STATE/live.busy-state"
run_agy_interactive "$LAB/registered" --add-dir "$LAB/registered"
# Wait for the RECORD to settle, not for the marker. The installed hook touches
# the turn-end marker before it execs the busy applier, so the marker appearing
# proves nothing about the record yet and breaking on it would report a false
# regression against a healthy binary.
BUSY_SEEN=no
for _ in $(seq 1 240); do
  grep -q 'state=busy source=agy-hook' "$STATE/live.busy-state" 2>/dev/null && BUSY_SEEN=yes
  grep -q 'state=idle source=agy-hook' "$STATE/live.busy-state" 2>/dev/null && break
  sleep 0.5
done
grep -q 'state=idle source=agy-hook' "$STATE/live.busy-state" 2>/dev/null \
  || fail "an interactive agy session did not record a semantic idle event within 120s ($AGY_VERSION)"
[ -e "$STATE/live.turn-ended" ] \
  || fail "an interactive agy session did not fire its turn-end marker ($AGY_VERSION)"
# The sequence, not the mid-turn poll, is the gate: a fast turn can settle
# between two polls, but the seq it leaves behind cannot be missed.
BUSY_SEQ=$(sed -n 's/^v1 .* seq=\([0-9][0-9]*\) .*/\1/p' "$STATE/live.busy-state" 2>/dev/null)
[ "${BUSY_SEQ:-0}" -gt 1 ] \
  || fail "an interactive agy session published only one busy-state event (seq=${BUSY_SEQ:-none}); PreInvocation did not open the turn, so a steered agy crewmate would read idle while working ($AGY_VERSION)"
pass "the agy global hook fires for the interactive -i launch fm-spawn actually uses, both halves (seq=$BUSY_SEQ, busy observed mid-turn: $BUSY_SEEN) ($AGY_VERSION)"
