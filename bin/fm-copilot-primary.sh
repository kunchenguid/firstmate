#!/usr/bin/env bash
# Start a GitHub Copilot CLI primary so its typed wake has a pane to type into.
# Usage: bin/fm-copilot-primary.sh [copilot args...]
#
# The typed wake (bin/fm-copilot-wake.sh) works by typing into the primary's own
# tmux or Herdr pane and refuses to start without one, so a Copilot opened from a
# plain or editor terminal has no supervision. Inside tmux or Herdr this just runs
# `copilot` here; otherwise it opens Copilot in a tmux session named for this home
# (`-A` re-attaches a running one, so a second start never makes a second Copilot).
# Pass the launch recipe's flags through, e.g. --no-auto-update --allow-all
# (docs/supervision-protocols/copilot.md). Native Windows is not supported; use WSL2.
# The launch adds `-i '<one line>'` unless the arguments already choose a prompt or only
# print help or a version: Copilot fires no hook at a plain open, so the session-start
# digest otherwise waits for a human's first prompt, while `-i` submits one itself
# (held behind the folder-trust dialog until it is answered) and the hook adds the
# digest to it. It also works after --resume=<id>.
# It also adds --no-auto-update unless the caller passes it or sets COPILOT_AUTO_UPDATE,
# because Copilot applies a downloaded release at the next plain launch, outside the
# verified range (docs/sessionstart-nudge.md "GitHub Copilot CLI").
# FM_COPILOT_BIN names the executable; FM_COPILOT_PRIMARY_DETACH=1 starts the tmux
# session detached (for tests).
set -u

ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
COPILOT=${FM_COPILOT_BIN:-copilot}
want_prompt=1
auto_update=1
[ -z "${COPILOT_AUTO_UPDATE:-}" ] || auto_update=0
for a in "$@"; do
  case "$a" in --no-auto-update) auto_update=0 ;; esac
  case "$a" in -i|--interactive|--interactive=*|-p|--prompt|--prompt=*|-h|--help|-v|--version) want_prompt=0 ;; esac
done
[ "$auto_update" = 0 ] || set -- --no-auto-update "$@"
[ "$want_prompt" = 0 ] || set -- "$@" -i 'Start the firstmate session.'
if [ -n "${TMUX_PANE:-}" ] || { [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; }; then
  cd "$ROOT" && exec "$COPILOT" "$@"
fi
command -v tmux >/dev/null 2>&1 || {
  echo 'error: a Copilot primary needs tmux or Herdr; install tmux (brew install tmux / apt install tmux) or open it inside Herdr' >&2
  exit 1
}
name=fm-copilot-$(printf '%s' "$ROOT" | cksum | cut -d ' ' -f 1)
exec tmux new-session ${FM_COPILOT_PRIMARY_DETACH:+-d} -A -s "$name" -c "$ROOT" "$COPILOT" "$@"
