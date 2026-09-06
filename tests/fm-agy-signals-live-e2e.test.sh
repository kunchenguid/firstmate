#!/usr/bin/env bash
# Opt-in real-process guard for every agy signal firstmate's adapter reads from
# the vendor rather than from its own code.
#
# The portable suite (tests/fm-agy-harness.test.sh) pins the LOGIC with no
# harness. This guard pins the ASSUMPTIONS that logic rests on, because a stub
# can only confirm the assumption already written into the stub:
#   - the workspace-trust dialog appears in a folder agy has never seen, and
#     --dangerously-skip-permissions does NOT suppress it
#   - registering the worktree suppresses it
#   - the two status bars are still `? for shortcuts` and `esc to cancel`
#   - the launch command shape still starts an interactive session on the brief
#   - the Stop hook still fires, and still reports fullyIdle
# Every failure names the harness and its version, because agy self-updates.
#
# Run after an agy upgrade and before trusting refreshed per-harness evidence:
#   FM_AGY_SIGNALS_LIVE_E2E=1 bin/fm-test-run.sh --family live-harness-optin
set -u

if [ "${FM_AGY_SIGNALS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AGY_SIGNALS_LIVE_E2E=1 to run the live agy signal guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
TRUST_ADDED=
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"
VERSION=
STORE="$HOME/.gemini/antigravity-cli/settings.json"
REGISTRY="$HOME/.gemini/antigravity-cli/fm-turn-end.d"
TOKEN=
HOOK_INSTALLED=

# Every mutation of the operator's REAL agy home is unwound here rather than on
# the success path, because a failed assertion exits through this trap: an
# orphan task token left in the registry makes every later `remove` refuse, and
# a deleted worktree left in trustedWorkspaces is invisible until it misroutes.
#
# Each mutation is unwound by REVERSING it, never by restoring a snapshot over
# the store. This guard runs for minutes against the operator's live agy home,
# and a `cp` of bytes read at the start would silently discard whatever their own
# agy session wrote meanwhile - exactly the loss bin/fm-agy-trust.sh fingerprints
# its reads to refuse. Withdrawing the spellings this run added leaves every
# other entry, and every other key, as the vendor last wrote them.
cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$TOKEN" ] || rm -f -- "$REGISTRY/$TOKEN"
  [ -z "$HOOK_INSTALLED" ] || "$ROOT/bin/fm-agy-turnend-hook.sh" remove >/dev/null 2>&1 || true
  while IFS= read -r cleanup_path; do
    [ -n "$cleanup_path" ] || continue
    "$ROOT/bin/fm-agy-trust.sh" --remove "$cleanup_path" >/dev/null 2>&1 || true
  done <<EOF
$TRUST_ADDED
EOF
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}
trap cleanup EXIT

fail() { printf 'not ok - agy %s: %s\n' "${VERSION:-unknown}" "$1" >&2; exit 1; }
pass() { printf 'ok - agy %s: %s\n' "$VERSION" "$1"; }

# An absent harness is reported explicitly. This guard is opt-in, so reaching it
# with no binary means the operator asked for a check that cannot run, and
# passing over it silently would report evidence that was never gathered.
[ -n "$AGY_BIN" ] || fail "agy was requested for the live guard but is not on PATH"
[ -n "$REAL_TMUX" ] || fail "tmux not found"
VERSION=$("$AGY_BIN" --version 2>&1 | head -1)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX")
HOME_LAB="$LAB/home"
PROJ="$LAB/project"
WT="$LAB/wt"
mkdir -p "$HOME_LAB"
git init -q "$PROJ"
git -C "$PROJ" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
git -C "$PROJ" worktree add -q -b wt-agy-signals "$WT"

# The real agy store, so trust and hooks are read from the operator's own
# credentialed home; only the worktree under test is added and it is removed
# again below. A separate HOME would land on an unauthenticated agy and every
# assertion would degrade into a login prompt.
[ -f "$STORE" ] || fail "no agy settings store at $STORE; sign in to agy before running this guard"

capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -t "$TARGET" -p; }
start_pane() {  # <command>
  "$REAL_TMUX" -L "$SOCKET" kill-session -t "$SESSION" >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n agy -x 200 -y 50 -c "$WT"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" "$1" Enter
}
wait_for() {  # <regex> <seconds> <what>
  local deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    capture | grep -qE "$1" && return 0
    sleep 2
  done
  printf '%s\n' "--- pane ---" >&2
  capture >&2
  fail "$3 (waited $2s for /$1/)"
}

# 1. The dialog appears with the permission flag set. This is the whole reason
# bin/fm-agy-trust.sh exists; if agy ever starts honouring the flag for
# workspace trust, this failing is the signal to simplify, not a regression.
# The worktree is a fresh mktemp path agy has never seen, so nothing has to be
# reset to reach the unregistered starting state this asserts.
start_pane "$AGY_BIN --dangerously-skip-permissions"
wait_for 'Do you trust the contents of this project' 60 \
  "the workspace-trust dialog did not appear in a fresh worktree with --dangerously-skip-permissions; re-check whether the trust pre-seed is still needed"
pass "--dangerously-skip-permissions does not suppress the workspace-trust dialog"

# 2. Registering the worktree suppresses it, and the pane reaches the idle bar.
"$REAL_TMUX" -L "$SOCKET" kill-session -t "$SESSION" >/dev/null 2>&1 || true
# A worktree named through a symlinked TMPDIR - macOS's /var -> /private/var -
# registers under BOTH spellings, and removal withdraws exactly the spelling it
# is named, so the guard unwinds by the same record its callers keep: one
# withdrawal per reported `added:` line.
TRUST_REPORT=$("$ROOT/bin/fm-agy-trust.sh" "$WT" "$PROJ") \
  || fail "the trust registration refused a legitimate task worktree"
TRUST_ADDED=$(printf '%s\n' "$TRUST_REPORT" | sed -n 's/^added: //p')
start_pane "$AGY_BIN --dangerously-skip-permissions"
wait_for '\? for shortcuts' 60 "a registered worktree did not reach the idle status bar"
capture | grep -q 'Do you trust the contents' \
  && fail "the trust dialog still appeared after registration"
pass "registering the worktree suppresses the dialog and reaches the idle status bar"

# 3. The two status bars still separate accepting from not-accepting, and the
# turn-end hook still fires with fullyIdle. Both are checked on one real turn.
"$ROOT/bin/fm-agy-turnend-hook.sh" install >/dev/null || fail "the turn-end hook could not be installed"
HOOK_INSTALLED=1
MARKER="$LAB/task.turn-ended"
TOKEN=$(basename "$(mktemp "$REGISTRY/fm.XXXXXXXXXXXX")")
printf '%s\n' "$MARKER" > "$REGISTRY/$TOKEN"
printf 'token=%s\n' "$TOKEN" > "$WT/.fm-agy-turnend"
retire_token() { rm -f "$REGISTRY/$TOKEN"; TOKEN=; }

# Restart so the pane loads the hook that was just installed.
"$REAL_TMUX" -L "$SOCKET" kill-session -t "$SESSION" >/dev/null 2>&1 || true
start_pane "$AGY_BIN --dangerously-skip-permissions"
wait_for '\? for shortcuts' 60 "the pane did not reach the idle status bar before the turn"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" "Reply with exactly: LIVEOK"
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
wait_for 'esc to cancel' 30 "a submitted turn did not render the busy status bar"
pass "a running turn renders the busy status bar"

wait_for 'LIVEOK' 120 "the submitted prompt was accepted but never answered"
wait_for '\? for shortcuts' 60 "the finished turn did not return to the idle status bar"
pass "typing plus a separate Enter submits and the agent acts on it"

deadline=$((SECONDS + 30))
while [ "$SECONDS" -lt "$deadline" ] && [ ! -e "$MARKER" ]; do sleep 2; done
[ -e "$MARKER" ] || fail "the Stop hook did not signal the finished turn; agy's hooks facility is undocumented in --help and has changed before"
pass "the Stop hook signals a finished turn through the task token"

retire_token
"$ROOT/bin/fm-agy-turnend-hook.sh" remove >/dev/null || fail "the turn-end hook could not be removed"
HOOK_INSTALLED=
# The same withdrawal teardown performs, against the operator's real store.
while IFS= read -r trust_path; do
  [ -n "$trust_path" ] || continue
  "$ROOT/bin/fm-agy-trust.sh" --remove "$trust_path" >/dev/null \
    || fail "the trust registration could not be withdrawn"
done <<EOF
$TRUST_ADDED
EOF
grep -Fq "$WT" "$STORE" && fail "the guard left its worktree in the operator's trusted workspaces"
pass "the guard leaves the operator's store and hooks exactly as it found them"
