#!/usr/bin/env bash
# tests/fm-composer-codex-idle-live-e2e.test.sh - the live codex idle-screen
# guard (live-harness-optin family; task fm-composer-codex-idle-furniture).
#
# codex-cli 0.154.0 draws animation furniture around its idle composer: a
# braille "starfield" on the rows around the bare `›` prompt (and behind its
# dim `Ask Codex to do anything` placeholder), with a bright model/path/title
# status footer beneath it. The shared classifier (bin/fm-composer-lib.sh)
# must read those rows as furniture, not typed input, or every steering
# doorbell into an idle codex pane is deferred as "pending text". Those rows
# are vendor-rendered, so per .agents/skills/firstmate-coding-guidelines the
# byte fixture in tests/fm-composer-lib.test.sh is not enough on its own: this
# guard launches the INSTALLED codex idle in an isolated tmux server, captures
# its screen with styling preserved, and requires the classifier to reach
# `empty` through BOTH capability profiles that read it in production - the
# cursor-anchored tmux read (fm_tmux_composer_state) and the cursorless styled
# read that Herdr and Zellij use, which is the profile that failed live. It
# fails naming codex and `codex --version`.
#
# Reading an idle screen submits no prompt, so no model tokens are spent and
# the gate is default-on wherever codex and tmux are installed (fm_live_gate):
# FM_COMPOSER_CODEX_IDLE_LIVE=1 forces it (an absent codex then fails instead
# of skipping) and =0 disables it. A run that verified nothing fails rather
# than passing vacuously. Whether the starfield was actually drawn during the
# read is reported as a note, because codex need not animate it under every
# model or mode; the `empty` verdict is required either way.
# Refresh docs/verification/runtime-backends.md ("Composer classification
# matrix") from this guard's output after any codex upgrade.
#
# Folder trust: codex is launched with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unreadable-composer state and correctly fails the check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_COMPOSER_CODEX_IDLE_LIVE codex tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOCKET="fm-codex-idle-$$"
SESSION="codexidle"
WIN="codex"
CHECKED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
}
trap cleanup EXIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-idle-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

VERSION=$(codex --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 45 -c "$ROOT"
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WIN" -c "$ROOT" -- codex \
  || fail "codex ($VERSION): could not launch in the isolated tmux server"

# The cursorless styled read exactly as bin/backends/herdr.sh describes its
# ANSI capture: a bounded styled tail plus the shared capability facts, with
# the lazy identity pass answered `probe-absent` because no identity probe is
# needed for a bare composer.
CAPS_CURSORLESS=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
classify_cursorless() {  # <styled-screen>
  local verdict
  verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1")
  if [ "$verdict" = need-identity ]; then
    verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1" '' probe-absent)
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

budget=${FM_COMPOSER_CODEX_IDLE_LIVE_POLLS:-45}
i=0
tmux_verdict=''
cursorless_verdict=''
styled=''
dismissed=0
while [ "$i" -lt "$budget" ]; do
  tmux_verdict=$(fm_tmux_composer_state "$SESSION:$WIN")
  styled=$(tmux capture-pane -e -p -t "$SESSION:$WIN" 2>/dev/null | tail -n "$FM_COMPOSER_CAPTURE_LINES")
  cursorless_verdict=$(classify_cursorless "$styled")
  if [ "$tmux_verdict" = empty ] && [ "$cursorless_verdict" = empty ]; then
    break
  fi
  i=$((i + 1))
  # A fresh codex may park on a vendor update-available modal (observed live
  # on codex 0.146.0), which the strict classifier correctly refuses to call a
  # composer. Dismiss it once, mid-budget, with a single Escape - the one key
  # that submits nothing. Never Enter: on codex's dialog Enter would RUN the
  # upgrade. A trust prompt also accepts Escape, but there it exits codex and
  # erases the actionable failure surface, so it is left alone.
  if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
    if ! tmux capture-pane -p -t "$SESSION:$WIN" 2>/dev/null | grep -qi 'trust'; then
      tmux send-keys -t "$SESSION:$WIN" Escape 2>/dev/null || true
    fi
    dismissed=1
  fi
  sleep 1
done

# Report what codex actually drew, so a refreshed verification record can say
# whether the starfield was exercised rather than assuming it.
plain=$(printf '%s\n' "$styled" | fm_composer_strip_ansi)
starfield=no
while IFS= read -r row; do
  if _fm_composer_row_is_braille_furniture "$row"; then starfield=yes; break; fi
done <<PLAIN
$plain
PLAIN
placeholder=no
case "$plain" in *'Ask Codex to do anything'*) placeholder=yes ;; esac
note "codex ($VERSION): starfield furniture observed=$starfield placeholder observed=$placeholder"

if [ "$tmux_verdict" = empty ] && [ "$cursorless_verdict" = empty ]; then
  CHECKED=$((CHECKED + 1))
  pass "codex ($VERSION): real idle screen classifies empty on the cursor-anchored tmux read and the cursorless styled read"
else
  printf '# codex pane tail at failure:\n' >&2
  printf '%s\n' "$plain" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "codex ($VERSION): idle screen never classified empty (tmux read: ${tmux_verdict:-unreadable}, cursorless styled read: ${cursorless_verdict:-unreadable})"
fi

[ "$CHECKED" -gt 0 ] || fail "live codex idle-screen guard verified nothing; refusing a vacuous pass"
pass "live codex idle-screen guard verified $CHECKED live surface(s)"
