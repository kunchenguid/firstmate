#!/usr/bin/env bash
# fm-agent-loop-baseline.sh - reproducible Firstmate agent-loop overhead baseline.
#
# Measures Firstmate-controlled always-loaded surfaces and deterministic render
# contracts. It does not call model APIs and does not invent provider-side
# inference claims. Provider cache/usage telemetry, WebSocket transport, and
# server-side compaction remain outside Firstmate control. Package and config
# fields below are local inventory only, not proof of runtime activation.
#
# Output schema (stdout, key=value unless --json):
#   schema=fm-agent-loop-baseline.v1
#   measured_at=<UTC ISO8601 or FM_BASELINE_NOW>
#   agents_md_bytes / agents_md_approx_tokens
#   skill_description_bytes / skill_description_count
#   skill_body_bytes (full SKILL.md bodies; loaded on demand, not always-on)
#   pi_extension_tool_description_bytes / pi_extension_tool_count
#   supervision_<harness>_bytes for each docs/supervision-protocols/*.md
#   supervision_render_<harness>_bytes for fm-supervision-instructions.sh output
#   session_start_fixture_bytes (optional; requires --with-session-fixture)
#   openai_server_compaction=<present|absent> (global config-file inventory)
#   openai_compact_threshold=<configured int or empty>
#   openai_use_previous_response_id=<configured true|false|unknown>
#   pi_cache_retention_env=<ambient value or unset>
#   openai_codex_models=<local model-store comma list when discoverable>
#   luna_available=<true|false|unknown> (local model-store inventory)
#   code_mode_embedded_runtime=<absent> (declared boundary, not runtime detection)
#   notes=...
#
# Usage:
#   fm-agent-loop-baseline.sh [--json] [--with-session-fixture]
#   fm-agent-loop-baseline.sh --help
#
# --with-session-fixture builds an isolated fake home, runs fm-session-start.sh
# once under lock-held conditions with a quiet toolchain, and records digest
# bytes. It never touches the live fleet home.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-prompt-stable-lib.sh
. "$SCRIPT_DIR/fm-prompt-stable-lib.sh"

JSON=0
WITH_FIXTURE=0
MEASURED_AT=${FM_BASELINE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --with-session-fixture) WITH_FIXTURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'fm-agent-loop-baseline: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

approx_tokens() {
  # Rough 4-byte heuristic used only for relative baselines, not billing.
  local bytes=$1
  printf '%s\n' $(( (bytes + 3) / 4 ))
}

file_bytes() {
  local path=$1
  if [ -f "$path" ]; then
    wc -c < "$path" | tr -d ' '
  else
    printf '0\n'
  fi
}

# Skill frontmatter description bytes (always-discoverable cost).
skill_description_stats() {
  local total=0 count=0 path desc
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    desc=$(python3 - "$path" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(r"^---\n(.*?)\n---", text, re.S)
if not m:
    print(0)
    raise SystemExit
block = m.group(1)
dm = re.search(r"(?m)^description:\s*(?:[|>][+-]?\s*)?(.*?)(?=\n[A-Za-z0-9_-]+:|\Z)", block, re.S)
if not dm:
    print(0)
    raise SystemExit
print(len(dm.group(1).strip().encode("utf-8")))
PY
)
    total=$((total + desc))
    count=$((count + 1))
  done < <(find "$FM_ROOT/.agents/skills" "$FM_ROOT/skills" -type f -name 'SKILL.md' 2>/dev/null | LC_ALL=C sort)
  printf '%s %s\n' "$total" "$count"
}

skill_body_bytes() {
  local total=0 path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    total=$((total + $(file_bytes "$path")))
  done < <(find "$FM_ROOT/.agents/skills" "$FM_ROOT/skills" -type f -name 'SKILL.md' 2>/dev/null | LC_ALL=C sort)
  printf '%s\n' "$total"
}

# Firstmate-owned Pi tool description / prompt metadata bytes.
pi_tool_stats() {
  python3 - "$FM_ROOT" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1]) / ".pi" / "extensions"
total = 0
count = 0
tool_call = re.compile(
    r"(?ms)^(?P<indent>[ \t]*)[^\n]*\bregisterTool(?:\?\.)?\(\s*\{"
    r"(?P<body>.*?)^(?P=indent)\}\);\s*$"
)
def byte_len(s: str) -> int:
    try:
        return len(bytes(s, "utf-8").decode("unicode_escape").encode("utf-8"))
    except Exception:
        return len(s.encode("utf-8"))

for path in sorted(root.rglob("*.ts")):
    text = path.read_text(encoding="utf-8", errors="replace")
    for tool in tool_call.finditer(text):
        body = tool.group("body")
        if not re.search(r"(?m)^\s*name\s*:", body):
            continue
        count += 1
        for key in ("description", "promptSnippet"):
            for m in re.finditer(rf"{key}:\s*\"((?:\\.|[^\"\\])*)\"", body):
                total += byte_len(m.group(1))
        for m in re.finditer(r"promptGuidelines:\s*\[(.*?)\]", body, re.S):
            for sm in re.finditer(r"\"((?:\\.|[^\"\\])*)\"", m.group(1)):
                total += byte_len(sm.group(1))
print(f"{total} {count}")
PY
}

supervision_doc_bytes() {
  local harness=$1
  file_bytes "$FM_ROOT/docs/supervision-protocols/${harness}.md"
}

supervision_render_bytes() {
  local harness=$1
  local out bytes
  out=$(mktemp "${TMPDIR:-/tmp}/fm-supervision-render.XXXXXX") || return 1
  if ! "$SCRIPT_DIR/fm-supervision-instructions.sh" \
    --harness "$harness" --read-only 0 --afk 0 --x-mode 0 > "$out"; then
    rm -f "$out"
    return 1
  fi
  bytes=$(file_bytes "$out")
  rm -f "$out"
  printf '%s\n' "$bytes"
}

discover_openai_compaction() {
  local cfg="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/openai-server-compaction.json"
  if [ -f "$cfg" ]; then
    python3 - "$cfg" <<'PY'
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("present")
print(cfg.get("compactThreshold", ""))
print("true" if cfg.get("usePreviousResponseId") else "false")
PY
  else
    printf 'absent\n\nunknown\n'
  fi
}

discover_codex_models() {
  local store="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models-store.json"
  if [ ! -f "$store" ]; then
    printf 'unknown\nfalse\n'
    return 0
  fi
  python3 - "$store" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
models = []
for m in data.get("openai-codex", {}).get("models", []):
    mid = m.get("id") or ""
    if mid:
        models.append(mid)
print(",".join(models) if models else "none")
print("true" if any(x == "gpt-5.6-luna" for x in models) else "false")
PY
}

run_session_fixture() {
  local tmp home fakebin out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-loop-baseline.XXXXXX")
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  # Quiet toolchain stubs.
  for cmd in tmux node gh gh-axi chrome-devtools-axi lavish-axi treehouse no-mistakes; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$cmd"
    chmod +x "$fakebin/$cmd"
  done
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'alpha\n' > "$home/data/captain.md"
  # Two tasks in reverse create order; listing must still be alpha-sorted.
  cat > "$home/state/zulu.meta" <<'EOF'
window=tmux:zulu
harness=pi
kind=ship
mode=no-mistakes
yolo=off
EOF
  cat > "$home/state/alpha.meta" <<'EOF'
window=tmux:alpha
harness=pi
kind=ship
mode=no-mistakes
yolo=off
EOF
  printf 'working: start\n' > "$home/state/zulu.status"
  printf 'working: start\n' > "$home/state/alpha.status"
  # Fresh beacon keeps the session-start watcher banner from alternating between
  # first-sighting and same-episode wording across two fixture runs.
  : > "$home/state/.last-watcher-beat"
  # Hold the session lock as this process so the digest is lock-held.
  printf '%s\n' "$$" > "$home/state/.lock"
  out="$tmp/digest.txt"
  if ! env PATH="$fakebin:/usr/bin:/bin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$SCRIPT_DIR/fm-session-start.sh" > "$out" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  printf '%s\n' "$(file_bytes "$out")"
  # Determinism: second run must match excluding lock/bootstrap noise if any.
  local out2="$tmp/digest2.txt"
  if ! env PATH="$fakebin:/usr/bin:/bin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$SCRIPT_DIR/fm-session-start.sh" > "$out2" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  if cmp -s "$out" "$out2"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  # Meta section order must list alpha before zulu.
  if awk '
    /Work under way/ {inmeta=1}
    inmeta && /^--- alpha ---$/ {a=1}
    inmeta && /^--- zulu ---$/ {z=1; if(a) ok=1}
    END { exit ok ? 0 : 1 }
  ' "$out"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  rm -rf "$tmp"
}

AGENTS_BYTES=$(file_bytes "$FM_ROOT/AGENTS.md")
AGENTS_TOKENS=$(approx_tokens "$AGENTS_BYTES")
read -r SKILL_DESC_BYTES SKILL_DESC_COUNT < <(skill_description_stats)
SKILL_BODY_BYTES=$(skill_body_bytes)
read -r PI_TOOL_BYTES PI_TOOL_COUNT < <(pi_tool_stats)

SUP_HARNESSES="claude codex grok kimi opencode pi unknown"
SUP_DOC_JSON=""
SUP_RENDER_JSON=""
for h in $SUP_HARNESSES; do
  db=$(supervision_doc_bytes "$h")
  rb=$(supervision_render_bytes "$h")
  eval "SUP_DOC_${h}=$db"
  eval "SUP_RENDER_${h}=$rb"
  SUP_DOC_JSON="${SUP_DOC_JSON}\"${h}\":${db},"
  SUP_RENDER_JSON="${SUP_RENDER_JSON}\"${h}\":${rb},"
done
SUP_DOC_JSON="{${SUP_DOC_JSON%,}}"
SUP_RENDER_JSON="{${SUP_RENDER_JSON%,}}"

COMPACTION_RAW=$(discover_openai_compaction)
COMPACTION_STATE=$(printf '%s
' "$COMPACTION_RAW" | sed -n '1p')
COMPACT_THRESHOLD=$(printf '%s
' "$COMPACTION_RAW" | sed -n '2p')
USE_PREV_RESP=$(printf '%s
' "$COMPACTION_RAW" | sed -n '3p')
CODEX_RAW=$(discover_codex_models)
CODEX_MODELS=$(printf '%s
' "$CODEX_RAW" | sed -n '1p')
LUNA_AVAILABLE=$(printf '%s
' "$CODEX_RAW" | sed -n '2p')

if [ -z "${PI_CACHE_RETENTION+x}" ]; then
  PI_CACHE_RETENTION_ENV="unset"
else
  PI_CACHE_RETENTION_ENV=$PI_CACHE_RETENTION
fi

SESSION_FIXTURE_BYTES=0
SESSION_FIXTURE_DETERMINISTIC=unknown
SESSION_FIXTURE_SORTED=unknown
if [ "$WITH_FIXTURE" -eq 1 ]; then
  fixture_out=$(run_session_fixture)
  SESSION_FIXTURE_BYTES=$(printf '%s\n' "$fixture_out" | sed -n '1p')
  SESSION_FIXTURE_DETERMINISTIC=$(printf '%s\n' "$fixture_out" | sed -n '2p')
  SESSION_FIXTURE_SORTED=$(printf '%s\n' "$fixture_out" | sed -n '3p')
fi

NOTES='Firstmate controls AGENTS.md, skill descriptions, supervision renders, session-start digests, and tracked Pi extension tools. Provider WebSocket/delta tokenization and GPU inference are outside Firstmate. Code Mode was not added: existing shell aggregates (fm-fleet-snapshot, fm-bearings-snapshot, fm-session-start) already batch fleet inspection. Sol/Terra/Luna dispatch is unchanged without measured same-task evidence. Single OpenAI compaction path remains operator-installed pi-openai-server-compaction at compactThreshold when present.'

if [ "$JSON" -eq 1 ]; then
  FM_BASELINE_JSON_MEASURED_AT=$MEASURED_AT \
  FM_BASELINE_JSON_AGENTS_BYTES=$AGENTS_BYTES \
  FM_BASELINE_JSON_AGENTS_TOKENS=$AGENTS_TOKENS \
  FM_BASELINE_JSON_SKILL_DESC_BYTES=$SKILL_DESC_BYTES \
  FM_BASELINE_JSON_SKILL_DESC_COUNT=$SKILL_DESC_COUNT \
  FM_BASELINE_JSON_SKILL_BODY_BYTES=$SKILL_BODY_BYTES \
  FM_BASELINE_JSON_PI_TOOL_BYTES=$PI_TOOL_BYTES \
  FM_BASELINE_JSON_PI_TOOL_COUNT=$PI_TOOL_COUNT \
  FM_BASELINE_JSON_SUP_DOC=$SUP_DOC_JSON \
  FM_BASELINE_JSON_SUP_RENDER=$SUP_RENDER_JSON \
  FM_BASELINE_JSON_SESSION_BYTES=$SESSION_FIXTURE_BYTES \
  FM_BASELINE_JSON_SESSION_DETERMINISTIC=$SESSION_FIXTURE_DETERMINISTIC \
  FM_BASELINE_JSON_SESSION_SORTED=$SESSION_FIXTURE_SORTED \
  FM_BASELINE_JSON_COMPACTION_STATE=$COMPACTION_STATE \
  FM_BASELINE_JSON_COMPACT_THRESHOLD=$COMPACT_THRESHOLD \
  FM_BASELINE_JSON_USE_PREV_RESP=$USE_PREV_RESP \
  FM_BASELINE_JSON_PI_CACHE_RETENTION=$PI_CACHE_RETENTION_ENV \
  FM_BASELINE_JSON_CODEX_MODELS=$CODEX_MODELS \
  FM_BASELINE_JSON_LUNA_AVAILABLE=$LUNA_AVAILABLE \
  FM_BASELINE_JSON_NOTES=$NOTES \
  python3 - <<'PY'
import json
import os
value = os.environ.__getitem__
print(json.dumps({
  "schema": "fm-agent-loop-baseline.v1",
  "measured_at": value("FM_BASELINE_JSON_MEASURED_AT"),
  "agents_md_bytes": int(value("FM_BASELINE_JSON_AGENTS_BYTES")),
  "agents_md_approx_tokens": int(value("FM_BASELINE_JSON_AGENTS_TOKENS")),
  "skill_description_bytes": int(value("FM_BASELINE_JSON_SKILL_DESC_BYTES")),
  "skill_description_count": int(value("FM_BASELINE_JSON_SKILL_DESC_COUNT")),
  "skill_body_bytes": int(value("FM_BASELINE_JSON_SKILL_BODY_BYTES")),
  "pi_extension_tool_description_bytes": int(value("FM_BASELINE_JSON_PI_TOOL_BYTES")),
  "pi_extension_tool_count": int(value("FM_BASELINE_JSON_PI_TOOL_COUNT")),
  "supervision_doc_bytes": json.loads(value("FM_BASELINE_JSON_SUP_DOC")),
  "supervision_render_bytes": json.loads(value("FM_BASELINE_JSON_SUP_RENDER")),
  "session_start_fixture_bytes": int(value("FM_BASELINE_JSON_SESSION_BYTES")),
  "session_start_fixture_deterministic": value("FM_BASELINE_JSON_SESSION_DETERMINISTIC"),
  "session_start_fixture_sorted_ids": value("FM_BASELINE_JSON_SESSION_SORTED"),
  "openai_server_compaction": value("FM_BASELINE_JSON_COMPACTION_STATE"),
  "openai_compact_threshold": value("FM_BASELINE_JSON_COMPACT_THRESHOLD"),
  "openai_use_previous_response_id": value("FM_BASELINE_JSON_USE_PREV_RESP"),
  "pi_cache_retention_env": value("FM_BASELINE_JSON_PI_CACHE_RETENTION"),
  "openai_codex_models": value("FM_BASELINE_JSON_CODEX_MODELS"),
  "luna_available": value("FM_BASELINE_JSON_LUNA_AVAILABLE"),
  "code_mode_embedded_runtime": "absent",
  "notes": value("FM_BASELINE_JSON_NOTES"),
}, indent=2, sort_keys=True))
PY
  exit 0
fi

cat <<EOF
schema=fm-agent-loop-baseline.v1
measured_at=$MEASURED_AT
agents_md_bytes=$AGENTS_BYTES
agents_md_approx_tokens=$AGENTS_TOKENS
skill_description_bytes=$SKILL_DESC_BYTES
skill_description_count=$SKILL_DESC_COUNT
skill_body_bytes=$SKILL_BODY_BYTES
pi_extension_tool_description_bytes=$PI_TOOL_BYTES
pi_extension_tool_count=$PI_TOOL_COUNT
EOF

for h in $SUP_HARNESSES; do
  eval "db=\$SUP_DOC_${h}"
  eval "rb=\$SUP_RENDER_${h}"
  printf 'supervision_%s_doc_bytes=%s\n' "$h" "$db"
  printf 'supervision_%s_render_bytes=%s\n' "$h" "$rb"
done

cat <<EOF
session_start_fixture_bytes=$SESSION_FIXTURE_BYTES
session_start_fixture_deterministic=$SESSION_FIXTURE_DETERMINISTIC
session_start_fixture_sorted_ids=$SESSION_FIXTURE_SORTED
openai_server_compaction=$COMPACTION_STATE
openai_compact_threshold=$COMPACT_THRESHOLD
openai_use_previous_response_id=$USE_PREV_RESP
pi_cache_retention_env=$PI_CACHE_RETENTION_ENV
openai_codex_models=$CODEX_MODELS
luna_available=$LUNA_AVAILABLE
code_mode_embedded_runtime=absent
notes=$NOTES
EOF
