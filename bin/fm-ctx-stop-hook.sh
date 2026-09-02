#!/usr/bin/env bash
# fm-ctx-stop-hook.sh — belt-and-suspenders MEASURE for panes WITHOUT a statusLine.
#
# A Claude Code Stop hook. Some panes (crew harnesses, or any session before the
# statusLine has rendered) have no statusLine writing ctx-<window>.json. On every
# Stop this hook parses the transcript's LAST assistant message `usage` block and
# writes the SAME sentinel the statusLine would:
#   total context = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# So the watch daemon sees a fresh measurement after each turn regardless of
# statusLine availability. current_usage being null right after /compact is a
# statusLine concern, not here — the transcript usage is the authoritative count.
#
# Never blocks Stop: it always exits 0 and emits nothing on stdout (a Stop hook
# that prints could interfere), writing only the sentinel file as a side effect.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE" 2>/dev/null || true

# shellcheck source=bin/fm-ctx-lib.sh
. "$SCRIPT_DIR/fm-ctx-lib.sh"

INPUT="$(cat)"
CWD_FROM_JSON="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("cwd","") or "")' 2>/dev/null || true)"
CWD="${CWD_FROM_JSON:-$PWD}"
KEY="$(fm_ctx_window_key "")"
if [ "$KEY" = unknown ]; then
  SID="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("session_id","") or "")' 2>/dev/null || true)"
  KEY="$(fm_ctx_window_key "${SID:-unknown}")"
fi
ROLE="$(fm_ctx_role "$CWD")"
OUT="$STATE/ctx-$KEY.json"

# Managed-scope (see fm-ctx-statusline.sh): only firstmate-owned panes may be
# steered; ad-hoc panes get managed:false and the daemon skips them. The belt
# and the suspenders must agree, so both ask fm_ctx_managed_target rather than
# each re-deciding what ownership means on each surface.
MANAGED=false
TARGET="$(fm_ctx_managed_target)" && MANAGED=true

printf '%s' "$INPUT" | FM_KEY="$KEY" FM_ROLE="$ROLE" FM_TARGET="$TARGET" FM_MANAGED="$MANAGED" FM_OUT="$OUT" python3 -c '
import sys, json, os, time, tempfile
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
tp = d.get("transcript_path") or ""
total = 0
# Walk the JSONL transcript from the end; first assistant line with a usage block wins.
if tp and os.path.exists(tp):
    try:
        with open(tp) as fh:
            lines = fh.readlines()
    except Exception:
        lines = []
    for ln in reversed(lines):
        ln = ln.strip()
        if not ln:
            continue
        try:
            ev = json.loads(ln)
        except Exception:
            continue
        msg = ev.get("message") or {}
        usage = msg.get("usage") or ev.get("usage") or {}
        if not usage:
            continue
        t = 0
        for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
            v = usage.get(k)
            if isinstance(v, (int, float)):
                t += int(v)
        if t > 0:
            total = t
            break
if total <= 0:
    sys.exit(0)  # no usable measurement — leave any existing sentinel untouched
pct = int(round(total * 100.0 / 200000))
rec = {
    "window": os.environ["FM_KEY"],
    "tmux_target": os.environ.get("FM_TARGET", ""),
    "role": os.environ["FM_ROLE"],
    "managed": os.environ.get("FM_MANAGED", "") == "true",
    "total_tokens": total,
    "used_pct": pct,
    "exceeds_200k": total >= 200000,
    "ts": int(time.time()),
}
out = os.environ["FM_OUT"]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".ctx-", suffix=".tmp")
with os.fdopen(fd, "w") as fh:
    json.dump(rec, fh)
os.replace(tmp, out)
' 2>/dev/null || true

exit 0
