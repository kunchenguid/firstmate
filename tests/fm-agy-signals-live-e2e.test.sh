#!/usr/bin/env bash
# Live guard for the real, installed Antigravity CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping, isolated on a private
# tmux socket so it never touches the host's own sessions.
#
# It proves the harness-dependent facts bin/fm-spawn.sh and bin/fm-control-lib.sh
# encode for agy, each of which is a rendered or executed behavior that only the
# real binary can answer:
# The delivery-only busy matcher must also recognize its running footer with
# and without a recorded agy harness, while rejecting its idle footer.
#
#   1. The production launch shape reaches a usable composer with NO
#      workspace-trust dialog, and without appending anything to the operator's
#      global trustedWorkspaces list. Both follow from granting a resolved path:
#      an unresolved grant makes agy prompt for trust and, once accepted, records
#      that path globally, so every spawn would grow the operator's own config.
#   2. --mode accept-edits really does auto-approve a file edit inside the
#      granted worktree - the autonomy half of the approval decision.
#   3. A shell command under that SAME mode still requests approval - the half
#      that makes agy block more than claude or codex. This is the load-bearing
#      one: if a release ever widened accept-edits to cover commands, the
#      adapter's documented operating characteristic would be wrong, and if it
#      ever narrowed to deny silently, an agy worker would stop being
#      supervisable. The check requires a VISIBLE approval request, not merely
#      an absent side effect.
#   4. A single Escape cancels a running turn and leaves an empty composer, so
#      no clear key is needed after it.
#   5. /exit exits on one Enter.
#   6. A workspace-local .agents/hooks.json never fires, which is why agy
#      carries no turn-end signal and is refused for secondmate work. Only the
#      worktree-local hook path is exercised: this guard never writes agy's
#      global ~/.gemini configuration.
#
# --add-dir is not re-proven here because the portable suite pins that the flag
# is emitted; what this guard adds is that the flag's mode and prompts behave as
# recorded. Every failure names agy and its version, because that is the fact a
# release can invalidate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
LAB=
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"
AGY_VERSION=

cleanup() {
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s (agy %s)\n' "$1" "${AGY_VERSION:-unknown}" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_AGY_SIGNALS_LIVE tmux

REAL_TMUX=$(command -v tmux)
# An absent harness is reported, never passed over: the family exists to catch
# adapter drift, and a silent skip on the one host that has agy installed would
# hide exactly that.
[ -x "${AGY_BIN:-}" ] \
  || fail "FM_AGY_SIGNALS_LIVE=1 but no real agy executable is installed"
AGY_VERSION=$("$AGY_BIN" --version 2>/dev/null | tr -d '\n')
[ -n "$AGY_VERSION" ] || fail "the installed agy did not report a version"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-live.XXXXXX")
# Resolved deliberately, exactly as bin/fm-spawn.sh resolves each agy grant:
# agy resolves a path before testing it against the granted workspace, so an
# unresolved grant (the /var -> /private/var case mktemp -d produces here) makes
# it treat a write inside the granted directory as non-workspace access.
LAB=$(cd "$LAB" && pwd -P)
WORKSPACE="$LAB/workspace"
mkdir -p "$WORKSPACE/.agents"
# The worktree-local hook path agy's own release notes document. It must never
# fire; see fact 6 above.
cat > "$WORKSPACE/.agents/hooks.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch $WORKSPACE/STOP_FIRED"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"touch $WORKSPACE/PRETOOL_FIRED"}]}]}}
EOF

# The operator's global settings file, read ONLY to prove this launch does not
# change it. Nothing here ever writes to it.
AGY_SETTINGS="${XDG_CONFIG_HOME:-$HOME}/.gemini/antigravity-cli/settings.json"
[ -f "$AGY_SETTINGS" ] || AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"

agy_trusted_count() {
  [ -f "$AGY_SETTINGS" ] || { printf ''; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf ''; return 0; }
  python3 - "$AGY_SETTINGS" <<'PYCOUNT' 2>/dev/null || printf ''
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(len(json.load(fh).get("trustedWorkspaces", [])))
except Exception:
    print("")
PYCOUNT
}

trusted_before=$(agy_trusted_count)

tmux_capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true
}

assert_delivery_busy() {  # <busy|idle>
  local expected=$1 visible harness actual
  visible=$(tmux_capture | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || fail "delivery busy check captured no visible footer"
  for harness in agy ''; do
    actual=idle
    if printf '%s\n' "$visible" | bash -c \
      '. "$1/bin/fm-composer-lib.sh"; unset FM_BUSY_REGEX; fm_busy_lines_match "$2"' \
      _ "$ROOT" "$harness"; then
      actual=busy
    fi
    [ "$actual" = "$expected" ] \
      || fail "delivery matcher ${harness:-union} expected $expected, got $actual: $visible"
  done
  pass "agy $AGY_VERSION: explicit and harness-less delivery matchers read $expected"
}

# Turn completion, not a text sentinel. The pane echoes the request verbatim,
# so waiting for a token named in the prompt matches immediately and reads a
# still-running turn as finished. The footer is the one reliable boundary:
# `esc to cancel` while a turn runs, `? for shortcuts` when idle.
# A submitted turn does not become busy instantly, so waiting only for idle can
# return on the pre-submission footer and read the turn as already finished.
# Every turn wait therefore brackets: busy first, then idle.
wait_for_turn() {  # [samples]
  wait_for_text 'esc to cancel' 120 || return 1
  wait_for_idle "${1:-240}"
}

wait_for_idle() {  # [samples]
  local samples=${1:-240} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(tmux_capture)
    case "$out" in
      *'esc to cancel'*) ;;
      *'? for shortcuts'*) return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_text() {  # <text> [samples]
  local text=$1 samples=${2:-200} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(tmux_capture)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# The production approval posture for config/crew-permissions=auto, which is
# what makes facts 2 and 3 a test of the shipped decision rather than of an
# arbitrary flag combination.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n agy -c "$WORKSPACE" -x 200 -y 50 \
  || fail "could not create the private tmux session"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "$AGY_BIN --mode accept-edits --add-dir $WORKSPACE -i 'reply with exactly: LIVE_OK'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

# --- 1. no trust dialog, no global trust mutation ---------------------------

# Every task worktree is a path agy has never seen, so an unresolved grant would
# put its trust dialog on the critical path of every single spawn. A resolved
# grant is what keeps the launch unattended, and the composer placeholder is the
# proof that accept-edits was actually applied rather than silently ignored.
wait_for_text 'Accept-edits mode' \
  || fail "agy did not reach an accept-edits composer"
wait_for_turn || fail "agy did not complete its opening turn"
assert_delivery_busy idle
capture=$(tmux_capture)
case "$capture" in
  *'Do you trust the contents of this project?'*)
    fail "a resolved --add-dir grant must not raise agy's workspace-trust dialog: $capture" ;;
esac
# The dialog's real cost is durable: accepting it appends the path to the
# operator's own global settings, so a launch that raises it silently grows a
# file firstmate does not own.
if [ -n "${trusted_before:-}" ]; then
  trusted_after=$(agy_trusted_count)
  [ "$trusted_after" = "$trusted_before" ] \
    || fail "the launch changed the operator's global trustedWorkspaces ($trusted_before -> $trusted_after)"
fi
pass "agy: a resolved grant launches with no trust dialog and no global trust write"

# --- 2. accept-edits auto-approves a file edit ------------------------------

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  'Using your file writing tool, create edit-probe.txt containing EDIT_OK.'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
wait_for_turn || fail "agy did not finish the accept-edits file write turn"
[ -f "$WORKSPACE/edit-probe.txt" ] \
  || fail "--mode accept-edits did not auto-approve a file edit in the granted worktree"
pass "agy: --mode accept-edits auto-approves a file edit inside the granted worktree"

# --- 3. the same mode still prompts for a shell command --------------------

# `date` is deliberately a command no allow-rule would plausibly already cover.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  'Run the shell command: date'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
wait_for_text 'Requesting permission for:' 240 \
  || fail "accept-edits must still REQUEST approval for a shell command; no prompt appeared"
capture=$(tmux_capture)
# The prompt has to be a real, answerable choice - a stall a supervisor can see
# and act on - not a silent denial.
case "$capture" in
  *'Run this command?'*) ;;
  *) fail "agy's command approval prompt did not render its question: $capture" ;;
esac
case "$capture" in
  *'Yes, run command'*) ;;
  *) fail "agy's command approval prompt offered no approve choice: $capture" ;;
esac
pass "agy: a shell command still requests approval under accept-edits"

# --- 4. Escape cancels and leaves an empty composer ------------------------

# Cancel the pending approval, then interrupt a real running turn: the recorded
# mechanic is a single Escape with no clear key after it.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape
sleep 2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  'Count slowly from 1 to 60, one number per line with a sentence about each.'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
wait_for_text 'esc to cancel' 120 \
  || fail "agy did not render its running-turn footer for a long turn"
assert_delivery_busy busy
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape
wait_for_text 'Interrupted' 120 \
  || fail "a single Escape did not cancel agy's running turn"
capture=$(tmux_capture)
# muse restores the cancelled prompt as real composer text and therefore needs
# Ctrl+U; agy is recorded as NOT doing that, so the cancelled instruction must
# not be sitting in the composer waiting to concatenate onto the next line.
case "$capture" in
  *'Count slowly from 1 to 60'*'> Count slowly'*)
    fail "agy repolluted its composer after Escape and would need a clear key" ;;
esac
pass "agy: a single Escape cancels the turn and leaves the composer empty"

# --- 5. /exit exits on one Enter -------------------------------------------

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l '/exit'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
i=0
exited=0
while [ "$i" -lt 60 ]; do
  cmd=$("$REAL_TMUX" -L "$SOCKET" list-panes -t "$TARGET" -F '#{pane_current_command}' 2>/dev/null || true)
  case "$cmd" in
    *agy*) ;;
    '') ;;
    *) exited=1; break ;;
  esac
  sleep 0.5
  i=$((i + 1))
done
[ "$exited" -eq 1 ] || fail "/exit did not exit agy on one Enter"
pass "agy: /exit exits the agent on one Enter"

# --- 6. no turn-end hook ---------------------------------------------------

# Several turns have now completed and a tool has actually run, so both hook
# events had their chance. Their absence is why agy has no turn-end signal.
[ ! -e "$WORKSPACE/STOP_FIRED" ] \
  || fail "a workspace-local Stop hook FIRED; agy may now have a usable turn-end signal and the adapter should be revisited"
[ ! -e "$WORKSPACE/PRETOOL_FIRED" ] \
  || fail "a workspace-local PreToolUse hook FIRED; agy's hook surface may now be usable and the adapter should be revisited"
pass "agy: workspace-local hooks never fire, so the adapter installs no turn-end hook"

# --- 7. the model-id / --effort conflict is real ---------------------------

# Headless, because it is a launch-argument verdict rather than a TUI behavior.
# This is what makes fm-spawn.sh suppress --effort for a suffixed model id.
if conflict=$("$AGY_BIN" --model gemini-3.8-flash-high --effort low -p 'reply OK' \
    --print-timeout 60s 2>&1); then
  case "$conflict" in
    *conflicts*) ;;
    *) fail "a suffixed model id with --effort no longer conflicts; fm-spawn.sh's suppression may be unnecessary: $conflict" ;;
  esac
else
  case "$conflict" in
    *conflicts*) ;;
    *) fail "a suffixed model id with --effort failed for an unexpected reason: $conflict" ;;
  esac
fi
pass "agy: a suffixed model id still conflicts with --effort"

printf '# all fm-agy-signals live checks passed (agy %s)\n' "$AGY_VERSION"
