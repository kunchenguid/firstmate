#!/usr/bin/env bash
# Authed usage reader for the `copilot` surface -> prints ONE integer 0-100 (headroom) or
# NOTHING (blind). Safe to reference from config/quota-overrides.json (.copilot).
#
# Why this exists: quota-axi ships a native `copilot` provider, but it probes only
# ~/.config/github-copilot/apps.json (the OLD IDE-plugin credential location). The
# standalone GitHub Copilot CLI (>=1.0.x) stores its OAuth token in ~/.copilot/config.json
# under .copilotTokens, so the native provider reports auth_required forever. This reader
# uses the CLI's OWN token — no browser cookie, no separate login:
#   GET https://api.github.com/copilot_internal/user   (Authorization: token <gho_...>)
# Response .quota_snapshots.<bucket>.percent_remaining is the routable number.
#
# Bucket choice: `premium_interactions` is the only metered bucket on a subscriber plan
# (chat/completions report unlimited=true, percent_remaining=100). We report the minimum
# percent_remaining across all metered (unlimited=false) buckets, so a future plan that
# meters more than one bucket is bounded by its tightest limit rather than silently
# reporting the roomiest one.
#
# Token is passed via a 0600 header file (never argv, never stdout). Any failure -> exit 0
# with no output, which the fleet treats as blind / fail-open.
set -uo pipefail

cfg="$HOME/.copilot/config.json"
command -v curl    >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ -f "$cfg" ] || exit 0

# ~/.copilot/config.json is JSON-with-//-comments; strip comment lines before parsing.
tok=$(python3 - "$cfg" <<'PY' 2>/dev/null
import json, re, sys
try:
    raw = re.sub(r'^\s*//.*$', '', open(sys.argv[1]).read(), flags=re.M)
    toks = json.loads(raw).get("copilotTokens") or {}
    print(next(iter(toks.values())) if toks else "")
except Exception:
    print("")
PY
)
[ -n "$tok" ] || exit 0

hdr=$(mktemp); chmod 600 "$hdr"
out=$(mktemp); chmod 600 "$out"
trap 'rm -f "$hdr" "$out"' EXIT
{ printf 'Authorization: token %s\n' "$tok"
  printf 'Accept: application/json\n'
  printf 'User-Agent: GitHubCopilotCLI\n'; } > "$hdr"

code=$(curl -sS -m 15 -o "$out" -w '%{http_code}' -H @"$hdr" \
  "https://api.github.com/copilot_internal/user" 2>/dev/null) || exit 0
[ "$code" = "200" ] || exit 0   # 401/403/5xx -> blind

python3 - "$out" <<'PY' 2>/dev/null
import json, sys
try:
    snaps = (json.load(open(sys.argv[1])).get("quota_snapshots") or {})
except Exception:
    sys.exit(0)
metered = [q.get("percent_remaining") for q in snaps.values()
           if isinstance(q, dict) and not q.get("unlimited")
           and isinstance(q.get("percent_remaining"), (int, float))]
if not metered:
    # every bucket unlimited -> full headroom (only when we actually saw buckets)
    if snaps:
        print(100)
    sys.exit(0)
h = min(metered)
print(int(max(0, min(100, h)) + 0.5))
PY
