#!/usr/bin/env bash
# quota source: cursor surface. Usage is server-side and headroom is blind by default.
# Supply an authed reader via config/quota-overrides.json (.cursor = a command printing
# one int 0-100) to get a real number. The shipped bin/quota-cursor-usage.sh reader uses
# Cursor's own CLI token against its usage RPC. Read-only; no secret to stdout.
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

if command -v cursor-agent >/dev/null 2>&1; then
  o=$(override cursor); [ -n "$o" ] && hr=$o
  status=$(cursor-agent status 2>/dev/null | grep -qi 'logged in' && echo logged_in || echo auth_required)
else
  status=unavailable
fi
if [ "$hr" != null ]; then
  note="live headroom via authed usage reader (Connect GetCurrentPeriodUsage)"
else
  note="blind: set config/quota-overrides.json .cursor to bin/quota-cursor-usage.sh for a live number"
fi
printf '{"surface":"cursor","status":"%s","headroom":%s,"unit":"requests","models":["grok","claude","gpt"],"note":"%s"}\n' "$status" "$hr" "$note"
