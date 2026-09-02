#!/usr/bin/env bash
# fm-ctx-statusline.sh — MEASURE component of the firstmate context watchdog.
#
# The `tmux_target` field keeps its name for compatibility with every sentinel
# already on disk and every reader of them; it holds a herdr PANE ID for a
# crewmate spawned onto herdr, and a tmux pane for one still draining.
#
# A Claude Code statusLine script: on every render Claude pipes a JSON blob on
# stdin. We read context_window.used_percentage, context_window.current_usage's
# token fields, exceeds_200k_tokens, transcript_path, and session_id, then write a
# compact sentinel — {window, tmux_target, role, total_tokens, used_pct,
# exceeds_200k, ts} — to state/ctx-<window>.json. The watch daemon polls those
# sentinels. We also print one short human status line to stdout (the statusLine
# itself), so this doubles as a real, useful status line.
#
# Idle-safe: it does nothing but read stdin + write one small file per render, so
# it relies entirely on the harness statusLine refreshInterval for cadence (no
# loop, no daemon). current_usage is null right after /compact until the next API
# call — handled: a null/absent total writes total_tokens=0, which the daemon's
# numeric threshold never fires on (fail-safe: never restart on an unknown size).
#
# Composition: if FM_CTX_WRAP_STATUSLINE is set to another statusLine command, its
# stdout is appended after ours so an existing status line is preserved, not
# clobbered. (At install time there is no other statusLine configured — see the
# arming notes — so this is a forward-compat hook.)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE" 2>/dev/null || true

# shellcheck source=bin/fm-ctx-lib.sh
. "$SCRIPT_DIR/fm-ctx-lib.sh"

INPUT="$(cat)"

# Resolve the stable window key + role + tmux target up front (bash side, so the
# key logic stays in one place — fm-ctx-lib). Pass them to python via env.
CWD_FROM_JSON="$(printf '%s' "$INPUT" | FM_PY_FIELD=cwd python3 -c 'import sys,json,os
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get(os.environ["FM_PY_FIELD"],"") or "")' 2>/dev/null || true)"
CWD="${CWD_FROM_JSON:-$PWD}"
KEY="$(fm_ctx_window_key "")"
if [ "$KEY" = unknown ]; then
  # Fall back to the session id from the JSON so we still have a stable filename.
  SID="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("session_id","") or "")' 2>/dev/null || true)"
  KEY="$(fm_ctx_window_key "${SID:-unknown}")"
fi
ROLE="$(fm_ctx_role "$CWD")"

# Managed-scope: this GLOBAL statusLine runs in EVERY Claude session, but only
# firstmate-owned panes may ever be steered. Stamp managed:true ONLY for those —
# ad-hoc/personal panes get managed:false and the daemon will skip them. Opt-in
# by construction, on whichever surface the pane lives on; the rule and the
# target it yields have one owner in fm-ctx-lib.sh.
MANAGED=false
TARGET="$(fm_ctx_managed_target)" && MANAGED=true

# Parse the measurement + write the sentinel atomically. Python (already a
# firstmate dependency — see fm-captain-bootstrap.sh) so we need no jq.
OUT="$STATE/ctx-$KEY.json"
printf '%s' "$INPUT" | FM_KEY="$KEY" FM_ROLE="$ROLE" FM_TARGET="$TARGET" FM_MANAGED="$MANAGED" FM_OUT="$OUT" python3 -c '
import sys, json, os, time, tempfile
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cw = d.get("context_window") or {}
cu = cw.get("current_usage")  # null right after /compact until the next API call
total = 0
if isinstance(cu, dict):
    for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
        v = cu.get(k)
        if isinstance(v, (int, float)):
            total += int(v)
pct = cw.get("used_percentage")
try:
    pct = int(round(float(pct)))
except Exception:
    pct = 0
exceeds = bool(cw.get("exceeds_200k_tokens") or d.get("exceeds_200k_tokens"))
rec = {
    "window": os.environ["FM_KEY"],
    "tmux_target": os.environ.get("FM_TARGET", ""),
    "role": os.environ["FM_ROLE"],
    "managed": os.environ.get("FM_MANAGED", "") == "true",
    "total_tokens": total,
    "used_pct": pct,
    "exceeds_200k": exceeds,
    "ts": int(time.time()),
}
out = os.environ["FM_OUT"]
d_ = os.path.dirname(out)
fd, tmp = tempfile.mkstemp(dir=d_, prefix=".ctx-", suffix=".tmp")
with os.fdopen(fd, "w") as fh:
    json.dump(rec, fh)
os.replace(tmp, out)
# Stdout = the actual status line shown to the human.
mark = " !200k" if exceeds else ""
role = os.environ["FM_ROLE"]
print("ctx %dk (%d%%) [%s]%s" % (total // 1000, pct, role, mark))
' 2>/dev/null || printf 'ctx ?'

# Optional composition with a pre-existing statusLine command.
if [ -n "${FM_CTX_WRAP_STATUSLINE:-}" ]; then
  printf ' | '
  printf '%s' "$INPUT" | eval "$FM_CTX_WRAP_STATUSLINE" 2>/dev/null || true
fi
