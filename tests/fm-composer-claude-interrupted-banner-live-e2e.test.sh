#!/usr/bin/env bash
# tests/fm-composer-claude-interrupted-banner-live-e2e.test.sh - the live
# stale-Interrupted-banner guard (live-harness-optin family; task
# fix-interrupted-banner-composer-classifier).
#
# Real claude 2.x leaves a `⎿  Interrupted · What should Claude do instead?`
# line in its transcript, directly above its next composer redraw, when
# `fm-control.sh interrupt` (a single Escape) cancels a running Bash tool
# call. That banner is vendor-rendered text, so per
# .agents/skills/firstmate-coding-guidelines the byte fixture in
# tests/fm-composer-lib.test.sh is not enough on its own: this guard launches
# INSTALLED claude for real in an isolated tmux server, runs and interrupts a
# short Bash tool call to produce the banner for real, and requires the
# shared classifier (bin/fm-composer-lib.sh) to still read the settled,
# genuinely idle composer as `empty` - both through the cursor-anchored tmux
# read and the cursorless styled read that Herdr, the backend this bug was
# reported on, actually uses. It fails naming claude and `claude --version`.
#
# Unlike tests/fm-composer-matrix-live-e2e.test.sh, this guard DOES submit a
# short prompt (so a real tool call exists to interrupt) and so stays
# opt-in rather than default-on: run explicitly with
# FM_COMPOSER_CLAUDE_INTERRUPT_LIVE=1. An absent claude or tmux then fails
# instead of skipping. Refresh docs/verification/runtime-backends.md
# ("Composer classification matrix") from this guard's output after any
# claude upgrade.
#
# Folder trust: claude is launched with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unreadable-composer state and correctly fails the check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_COMPOSER_CLAUDE_INTERRUPT_LIVE claude tmux

SOCKET="fm-cib-live-$$"
SESSION="cibclaude"
WIN="claude"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
}
trap cleanup EXIT

VERSION=$(claude --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet, matching
# tests/fm-composer-matrix-live-e2e.test.sh's own isolation shim.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cib-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WIN" -c "$ROOT" -- claude \
  || fail "claude ($VERSION): could not launch in the isolated tmux server"

# --- 1. Reach a real idle composer, dismissing a startup modal at most once -
budget=${FM_COMPOSER_CLAUDE_INTERRUPT_LIVE_POLLS:-45}
i=0
dismissed=0
verdict=''
while [ "$i" -lt "$budget" ]; do
  verdict=$(fm_tmux_composer_state "$SESSION:$WIN")
  [ "$verdict" = empty ] && break
  i=$((i + 1))
  if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
    startup_screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$WIN" 2>/dev/null || true)
    if ! printf '%s\n' "$startup_screen" | grep -qi 'trust'; then
      tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Escape 2>/dev/null || true
    fi
    dismissed=1
  fi
  sleep 1
done
[ "$verdict" = empty ] || fail "claude ($VERSION): idle composer never classified empty before the interrupt probe"
pass "claude ($VERSION): real idle composer classifies empty before the interrupt probe"

# --- 2. Run a short Bash tool call, then interrupt it mid-flight -----------
# Literal text, then a settled separate Enter (fm_tmux_submit_core's own
# shape): a combined send-keys "<text> Enter" call races tmux's bracketed
# paste and the Enter can land inside the paste instead of submitting it.
# The probe sleeps long enough (15s) that a short fixed wait below is always
# inside the run, so the interrupt lands on a genuinely active tool call
# rather than racing a footer string that varies with claude's spinner verb.
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" -l \
  'Using your Bash tool, run exactly: sleep 15 && echo composer-interrupt-probe-done' \
  || fail "claude ($VERSION): could not type the interrupt-probe prompt"
sleep 1
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Enter \
  || fail "claude ($VERSION): could not submit the interrupt-probe prompt"
sleep 5

tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Escape \
  || fail "claude ($VERSION): could not deliver the interrupt key"

i=0
banner_seen=0
while [ "$i" -lt 30 ]; do
  screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$WIN" 2>/dev/null || true)
  case "$screen" in
    *'Interrupted'*) banner_seen=1; break ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$banner_seen" -eq 1 ] \
  || fail "claude ($VERSION): the interrupt never left the expected Interrupted banner in the transcript, so this guard proved nothing about the reported shape"

# --- 3. The settled, genuinely idle composer must still read empty ---------
i=0
verdict=''
while [ "$i" -lt "$budget" ]; do
  verdict=$(fm_tmux_composer_state "$SESSION:$WIN")
  [ "$verdict" = empty ] && break
  i=$((i + 1))
  sleep 1
done
if [ "$verdict" != empty ]; then
  printf '# claude (%s) pane tail after interrupt:\n' "$VERSION" >&2
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$WIN" 2>/dev/null \
    | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  fail "claude ($VERSION): a genuinely idle composer under a stale Interrupted banner classified '$verdict', not empty"
fi
pass "claude ($VERSION): idle composer under a stale Interrupted banner classifies empty (cursor-anchored)"

# The cursorless styled read is the one Herdr (this bug's own reported
# backend), zellij, cmux, and orca all actually perform - no #{cursor_y} to
# anchor the shape, so the bottom-most shape on the screen wins.
pane=$(fm_tmux_composer_capture "$SESSION:$WIN") \
  || fail "claude ($VERSION): cursorless re-read could not capture the settled pane"
caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=0')
cursorless=$(fm_composer_classify_screen "$caps" "$pane")
if [ "$cursorless" = need-identity ]; then
  if ! identity=$(fm_tmux_composer_identity "$SESSION:$WIN") || [ -z "$identity" ]; then
    identity='probe-absent'
  fi
  cursorless=$(fm_composer_classify_screen "$caps" "$pane" '' "$identity")
  [ "$cursorless" != need-identity ] || cursorless=unknown
fi
[ "$cursorless" = empty ] \
  || fail "claude ($VERSION): the Herdr-equivalent cursorless read classified '$cursorless' under a stale Interrupted banner, not empty"
pass "claude ($VERSION): idle composer under a stale Interrupted banner classifies empty (cursorless, Herdr-equivalent)"
