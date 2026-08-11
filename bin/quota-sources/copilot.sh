#!/usr/bin/env bash
# quota source: copilot surface. quota-axi HAS a native `copilot` provider, but it probes
# only ~/.config/github-copilot/apps.json (the old IDE-plugin credential path), so a
# standalone GitHub Copilot CLI login is invisible to it and the row sits at
# auth_required. This source supersedes that row using the CLI's own token store.
#
# Copilot usage is locally obtainable through bin/quota-copilot-usage.sh, but only
# when the operator explicitly wires that reader in config/quota-overrides.json .copilot.
# Without the override we still report accurate login state, with headroom blind/fail-open.
# Read-only; no secret to stdout.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; root="$(cd "$here/../.." && pwd)"
ov="$root/config/quota-overrides.json"; hr=null

override() { # surface -> echoes int 0-100 or nothing
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$ov" ] || return 0
  local cmd; cmd=$(jq -r --arg s "$1" '.[$s] // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] || return 0
  local out; out=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$out" ] || return 0
  [ "$out" -ge 0 ] 2>/dev/null && [ "$out" -le 100 ] 2>/dev/null && printf '%s' "$out"
}

# Login state = a stored token in the CLI's own config (presence only; value never read out).
copilot_logged_in() {
  local cfg="$HOME/.copilot/config.json"
  [ -f "$cfg" ] || return 1
  python3 - "$cfg" <<'PY' 2>/dev/null
import json, re, sys
try:
    raw = re.sub(r'^\s*//.*$', '', open(sys.argv[1]).read(), flags=re.M)
    d = json.loads(raw)
except Exception:
    sys.exit(1)
sys.exit(0 if (d.get("copilotTokens") or d.get("loggedInUsers")) else 1)
PY
}

if command -v copilot >/dev/null 2>&1; then
  o=$(override copilot); [ -n "$o" ] && hr=$o
  if copilot_logged_in; then status=logged_in; else status=auth_required; fi
else
  status=unavailable
fi

if [ "$hr" != null ]; then
  note="live headroom via authed usage reader (copilot_internal/user quota_snapshots)"
elif [ "$status" = "logged_in" ]; then
  note="blind: set config/quota-overrides.json .copilot to bin/quota-copilot-usage.sh for a live number"
else
  note="GitHub Copilot CLI sign-in required (run: copilot login)"
fi
printf '{"surface":"copilot","status":"%s","headroom":%s,"unit":"premium interactions","models":["claude","gpt"],"note":"%s"}\n' "$status" "$hr" "$note"
