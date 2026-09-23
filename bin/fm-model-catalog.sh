#!/usr/bin/env bash
# fm-model-catalog.sh - normalize native model listings for dispatch.
#
# Usage:
#   fm-model-catalog.sh <harness> [<harness> ...]
#
# Prints JSON Lines.
# Successful model rows carry:
#   {"status":"ok","harness":"<h>","model":"<id>","provider":"<provider>","provenance":{...}}
# Failed harness rows carry:
#   {"status":"error","harness":"<h>","reason":"<reason>","provenance":{...}}
#
# The helper is deliberately narrow: it calls each harness's own model-listing
# surface with a bounded timeout, normalizes identity and provenance, and never
# ranks, spawns, warms an agent, or calls a model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CATALOG_TIMEOUT=${FM_MODEL_CATALOG_TIMEOUT:-8}
case "$CATALOG_TIMEOUT" in ''|0|*[!0-9]*) CATALOG_TIMEOUT=8 ;; esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

json_emit_error() {  # <harness> <reason> <method>
  jq -cn --arg harness "$1" --arg reason "$2" --arg method "$3" \
    '{status:"error", harness:$harness, reason:$reason, provenance:{method:$method}}'
}

normalize_fixture() {  # <harness> <file>
  local harness=$1 file=$2
  jq -c --arg harness "$harness" '
    def reasoning_capabilities:
      [(.reasoningCapabilities // .reasoning_classes // .supportedReasoningEfforts // .capabilities.reasoning // [])[]?
       | if type == "object" then (.reasoningEffort // .reasoning_effort // .level // .name // empty) else . end
       | select(type == "string") | ascii_downcase] | unique;
    def task_types:
      [(.taskTypes // .task_types // .capabilities.taskTypes // .capabilities.task_types // [])[]?
       | select(type == "string") | ascii_downcase] | unique;
    select(type == "object") |
    if (.status // "ok") == "ok" then
      select((.harness? // $harness) == $harness) |
      (reasoning_capabilities) as $reasoning |
      (task_types) as $tasks |
      {status:"ok", harness:$harness, model:(.model // .id), provider:.provider,
       reasoningCapabilities:$reasoning, taskTypes:$tasks,
       provenance: ((.provenance // {}) + {method:"fixture"})}
      | select((.model | type) == "string" and (.model | length) > 0 and (.provider | type) == "string" and (.provider | length) > 0)
    else
      {status:"error", harness:$harness, reason:(.reason // "fixture error"), provenance: ((.provenance // {}) + {method:"fixture"})}
    end
  ' "$file"
}

with_fixture_if_present() {  # <harness>
  local harness=$1 file
  [ -n "${FM_MODEL_CATALOG_FIXTURE_DIR:-}" ] || return 1
  file="$FM_MODEL_CATALOG_FIXTURE_DIR/$harness.jsonl"
  if [ ! -r "$file" ]; then
    json_emit_error "$harness" "fixture missing for $harness" "fixture"
    return 0
  fi
  normalize_fixture "$harness" "$file"
  return 0
}

run_capture() {  # <harness> <method> <outfile> <command...>
  local harness=$1 method=$2 outfile=$3 rc
  shift 3
  if ! command -v "$1" >/dev/null 2>&1; then
    json_emit_error "$harness" "$1 not installed" "$method"
    return 1
  fi
  fm_run_timed "$CATALOG_TIMEOUT" "$@" > "$outfile" 2>"$outfile.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if fm_timed_out "$rc"; then
    json_emit_error "$harness" "catalog command timed out after ${CATALOG_TIMEOUT}s" "$method"
  else
    json_emit_error "$harness" "catalog command failed with exit $rc" "$method"
  fi
  return 1
}

catalog_opencode() {
  local harness=opencode tmp
  with_fixture_if_present "$harness" && return 0
  tmp=$(mktemp) || return 1
  if run_capture "$harness" "opencode --pure models --verbose" "$tmp" opencode --pure models --verbose; then
    python3 - "$tmp" <<'PY'
import json, sys
path = sys.argv[1]
seen = set()
with open(path, encoding='utf-8', errors='replace') as fh:
    for line in fh:
        s = line.strip()
        if not s.startswith('{'):
            continue
        try:
            obj = json.loads(s)
        except Exception:
            continue
        model = obj.get('id') or obj.get('model') or obj.get('name')
        provider = obj.get('providerID') or obj.get('provider')
        if not isinstance(model, str) or not model or not isinstance(provider, str) or not provider:
            continue
        key = (model, provider)
        if key in seen:
            continue
        seen.add(key)
        print(json.dumps({
            'status': 'ok', 'harness': 'opencode', 'model': model, 'provider': provider,
            'provenance': {'method': 'opencode --pure models --verbose', 'rawProvider': provider}
        }, separators=(',', ':')))
PY
  fi
  rm -f "$tmp" "$tmp.err"
}

catalog_pi() {  # <harness>
  local harness=$1 tmp
  with_fixture_if_present "$harness" && return 0
  tmp=$(mktemp) || return 1
  if run_capture "$harness" "pi --list-models" "$tmp" pi -ne -ns -np -nc --no-themes --no-approve --list-models; then
    python3 - "$tmp" "$harness" <<'PY'
import json, re, sys
path, harness = sys.argv[1], sys.argv[2]
seen = set()
with open(path, encoding='utf-8', errors='replace') as fh:
    for line in fh:
        s = line.strip()
        if not s or s.startswith(('-', '#')):
            continue
        cols = re.split(r'\s+', s)
        if len(cols) < 2:
            continue
        if cols[0].lower() in {'provider', 'providers'}:
            continue
        provider, model = cols[0], cols[1]
        if '/' in provider and '/' not in model:
            continue
        if not re.match(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$', provider):
            continue
        key = (model, provider)
        if key in seen:
            continue
        seen.add(key)
        print(json.dumps({
            'status': 'ok', 'harness': harness, 'model': f'{provider}/{model}', 'provider': provider,
            'provenance': {'method': 'pi --list-models', 'rawProvider': provider}
        }, separators=(',', ':')))
PY
  fi
  rm -f "$tmp" "$tmp.err"
}

catalog_claude() {
  local harness=claude rc
  with_fixture_if_present "$harness" && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    json_emit_error "$harness" "python3 not installed" "claude stream-json initialize"
    return 1
  fi
  if ! command -v claude >/dev/null 2>&1; then
    json_emit_error "$harness" "claude not installed" "claude stream-json initialize"
    return 1
  fi
  fm_run_timed "$CATALOG_TIMEOUT" python3 - <<'PY'
import json, subprocess, sys, time
cmd = [
  'claude', '--safe-mode', '--no-session-persistence', '--no-chrome',
  '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--tools', '',
  '--setting-sources', '', '--output-format', 'stream-json', '--input-format', 'stream-json',
  '--verbose', '--print'
]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
request = {'type':'control_request','request_id':'catalog-only','request':{'subtype':'initialize','hooks':{},'sdkMcpServers':[]}}
proc.stdin.write(json.dumps(request) + '\n')
proc.stdin.flush()
seen = set()
deadline = time.time() + 7
while time.time() < deadline:
    line = proc.stdout.readline()
    if not line:
        break
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get('type') != 'control_response':
        continue
    response = obj.get('response') or {}
    if response.get('request_id') != 'catalog-only':
        continue
    for model in ((response.get('response') or {}).get('models') or []):
        mid = model.get('value') or model.get('resolvedModel')
        if not isinstance(mid, str) or not mid or mid in seen:
            continue
        seen.add(mid)
        print(json.dumps({'status':'ok','harness':'claude','model':mid,'provider':'claude','provenance':{'method':'claude stream-json initialize','resolvedModel':model.get('resolvedModel')}}, separators=(',', ':')))
    proc.terminate()
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        proc.kill()
    sys.exit(0)
proc.kill()
sys.exit(1)
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      json_emit_error "$harness" "catalog command timed out after ${CATALOG_TIMEOUT}s" "claude stream-json initialize"
    else
      json_emit_error "$harness" "catalog command failed with exit $rc" "claude stream-json initialize"
    fi
    return 1
  fi
}

catalog_codex() {
  local harness=codex rc
  with_fixture_if_present "$harness" && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    json_emit_error "$harness" "python3 not installed" "codex app-server model/list"
    return 1
  fi
  if ! command -v codex >/dev/null 2>&1; then
    json_emit_error "$harness" "codex not installed" "codex app-server model/list"
    return 1
  fi
  fm_run_timed "$CATALOG_TIMEOUT" python3 - <<'PY'
import json, subprocess, sys, time
cmd = ['codex', 'app-server', '--listen', 'stdio://', '-c', 'analytics.enabled=false']
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def send(obj):
    proc.stdin.write(json.dumps(obj) + '\n')
    proc.stdin.flush()
send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'clientInfo':{'name':'firstmate_catalog','version':'1.0'},'capabilities':{'experimentalApi':False}}})
deadline = time.time() + 7
initialized = False
while time.time() < deadline:
    line = proc.stdout.readline()
    if not line:
        break
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get('id') == 1 and 'result' in obj:
        initialized = True
        break
if not initialized:
    proc.kill(); sys.exit(1)
send({'jsonrpc':'2.0','method':'initialized','params':{}})
seen = set(); cursor = None; req_id = 2
while True:
    params = {'includeHidden':False,'limit':100}
    if cursor:
        params['cursor'] = cursor
    send({'jsonrpc':'2.0','id':req_id,'method':'model/list','params':params})
    got = None
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get('id') == req_id:
            got = obj.get('result') or {}
            break
    if got is None:
        proc.kill(); sys.exit(1)
    data = got.get('data') or got.get('models') or []
    for model in data:
        mid = model.get('id') or model.get('model')
        if not isinstance(mid, str) or not mid or mid in seen:
            continue
        seen.add(mid)
        raw_efforts = model.get('supportedReasoningEfforts') or model.get('supported_reasoning_efforts') or []
        efforts = []
        for effort in raw_efforts:
            if isinstance(effort, dict):
                effort = effort.get('reasoningEffort') or effort.get('reasoning_effort') or effort.get('level') or effort.get('name')
            if isinstance(effort, str) and effort:
                efforts.append(effort.lower())
        print(json.dumps({'status':'ok','harness':'codex','model':mid,'provider':'codex','reasoningCapabilities':sorted(set(efforts)),'provenance':{'method':'codex app-server model/list','displayName':model.get('displayName'),'catalogProvider':model.get('provider')}}, separators=(',', ':')))
    cursor = got.get('nextCursor')
    if not cursor:
        break
    req_id += 1
proc.terminate()
try:
    proc.wait(timeout=1)
except subprocess.TimeoutExpired:
    proc.kill()
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      json_emit_error "$harness" "catalog command timed out after ${CATALOG_TIMEOUT}s" "codex app-server model/list"
    else
      json_emit_error "$harness" "catalog command failed with exit $rc" "codex app-server model/list"
    fi
    return 1
  fi
}

[ $# -gt 0 ] || { usage >&2; exit 2; }
status=0
for harness in "$@"; do
  case "$harness" in
    claude) catalog_claude || status=1 ;;
    codex) catalog_codex || status=1 ;;
    opencode) catalog_opencode || status=1 ;;
    pi|pi-signed) catalog_pi "$harness" || status=1 ;;
    *) json_emit_error "$harness" "no verified model catalog method for harness $harness" "unsupported"; status=1 ;;
  esac
done
exit "$status"
