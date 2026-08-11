#!/usr/bin/env bash
# Authed usage reader for the `cursor` surface -> prints ONE integer 0-100 (headroom) or
# NOTHING (blind). Safe to reference from config/quota-overrides.json (.cursor).
#
# Uses Cursor's native Connect usage RPC with the CLI's OWN access token (the one cursor-
# agent already stores) — no browser cookie needed:
#   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
#   Content-Type: application/json  +  Connect-Protocol-Version: 1  +  Bearer <accessToken>
# Response .planUsage.totalPercentUsed is "percent of included total used"; headroom =
# 100 - that. Token via a 0600 header file (never argv); nothing secret is printed.
set -uo pipefail
auth="$HOME/.config/cursor/auth.json"
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
[ -f "$auth" ] || exit 0
tok=$(jq -r '.accessToken // empty' "$auth" 2>/dev/null)
[ -n "$tok" ] || exit 0
# NOTE: `cursor-agent about` emits ANSI SGR codes (e.g. ESC[22m) around the version. An
# unstripped code in the header value makes the RPC return 400 Bad Request, so strip CSI
# sequences and keep only version-safe characters before using it.
ver=$(cursor-agent about 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
      | awk -F'  +' '/CLI Version/{print $2}' \
      | tr -cd '0-9A-Za-z.\-')
: "${ver:=2026.07.23}"

# The trap is armed BEFORE the token is written: an interrupt in between would
# otherwise leave the bearer token behind in the temp file.
hdr=$(mktemp); chmod 600 "$hdr"
trap 'rm -f "$hdr"' EXIT
{ printf 'Authorization: Bearer %s\n' "$tok"
  printf 'Connect-Protocol-Version: 1\n'
  printf 'x-cursor-client-version: %s\n' "$ver"
  printf 'x-cursor-client-type: cli\n'; } > "$hdr"

resp=$(curl -sS -m 15 -X POST -H @"$hdr" -H 'Content-Type: application/json' --data '{}' \
  "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage" 2>/dev/null) || exit 0
used=$(printf '%s' "$resp" | jq -r '.planUsage.totalPercentUsed // empty' 2>/dev/null)
[ -n "$used" ] || exit 0   # non-200 / unexpected shape -> blind
awk -v u="$used" 'BEGIN{ h=100-u; if(h<0)h=0; if(h>100)h=100; printf "%d\n", int(h+0.5) }'
