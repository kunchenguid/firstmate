#!/usr/bin/env bash
# One-command overnight start for Cerberus FirstMate Phase 2.
# Usage: scripts/fm-overnight-start.sh [--programme overnight-gallery]
set -euo pipefail
FM_HOME="${FM_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
export FM_HOME
export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"
cd "$FM_HOME"

PROGRAMME=overnight-gallery
while [ $# -gt 0 ]; do
  case "$1" in
    --programme) PROGRAMME="${2:?}"; shift 2 ;;
    *) shift ;;
  esac
done
export FM_PHASE2_PROGRAMME="$PROGRAMME"

echo "=== FirstMate overnight start ==="
echo "home=$FM_HOME programme=$PROGRAMME"

# Ensure programme + tasks exist
if [ -x "$FM_HOME/scripts/fm-phase2-load-programme.sh" ]; then
  "$FM_HOME/scripts/fm-phase2-load-programme.sh" "$PROGRAMME"
fi

"$FM_HOME/bin/fm-phase2-registry.sh" init >/dev/null
"$FM_HOME/scripts/firstmate-resume.sh" --programme "$PROGRAMME" | head -40

# User systemd overnight daemon
mkdir -p "$HOME/.config/systemd/user"
cp -a "$FM_HOME/phase2/systemd/firstmate-phase2-overnight.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now firstmate-phase2-eventd.service 2>/dev/null || true
systemctl --user enable --now firstmate-phase2-watchdog.timer 2>/dev/null || true
systemctl --user enable --now firstmate-phase2-overnight.service

# Kick first continue only if overnight service is not already running a cycle
# (service ExecStart will call continue; avoid double spawn race on start)
if ! systemctl --user is-active --quiet firstmate-phase2-overnight.service 2>/dev/null; then
  "$FM_HOME/bin/fm-phase2-continue.sh" --programme "$PROGRAMME"
else
  echo "overnight service already active — skipping duplicate continue kick"
  sleep 50
  "$FM_HOME/bin/fm-phase2-continue.sh" --programme "$PROGRAMME" || true
fi

# Best-effort linger so user services survive logout
loginctl enable-linger "$USER" 2>/dev/null || echo "(linger not enabled — may need: sudo loginctl enable-linger $USER)"

echo
echo "Overnight controller: active"
systemctl --user is-active firstmate-phase2-overnight.service || true
echo "Logs: $FM_HOME/state/.phase2-overnight.log"
echo "Stop:  systemctl --user stop firstmate-phase2-overnight.service"
echo "       OR touch $FM_HOME/state/.phase2-overnight.stop"
echo
echo "Primary OpenCode: stay orchestration-only. Prefer AFK:"
echo "  (in OpenCode) run the /afk skill OR: bin/fm-afk-start.sh via tracked background"
echo "Done. You can sleep — Phase 2 overnight will schedule/spawn Cursor crewmates."
