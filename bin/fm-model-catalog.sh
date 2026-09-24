#!/usr/bin/env bash
# fm-model-catalog.sh - normalize native model listings for dispatch.
#
# Usage:
#   fm-model-catalog.sh <harness> [<harness> ...]
#   fm-model-catalog.sh --list-harnesses
#
# Prints JSON Lines.
# Successful model rows carry:
#   {"status":"ok","harness":"<h>","model":"<id>","provider":"<provider>","reasoningCapabilities":[...],"taskTypes":[...],"provenance":{...}}
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

supported_harnesses() {
  printf '%s\n' claude codex opencode pi pi-signed
}

json_emit_error() {  # <harness> <reason> <method>
  jq -cn --arg harness "$1" --arg reason "$2" --arg method "$3" \
    '{status:"error", harness:$harness, reason:$reason, provenance:{method:$method}}'
}

normalize_fixture() {  # <harness> <file>
  local harness=$1 file=$2
  jq -c --arg harness "$harness" '
    def reasoning_capabilities:
      [(.reasoningCapabilities // .reasoning_classes // .supportedReasoningEfforts // .reasoning // .capabilities.reasoning // [])[]?
       | if type == "object" then (.reasoningEffort // .reasoning_effort // .level // .name // empty) else . end
       | select(type == "string") | ascii_downcase] | unique;
    def task_types:
      [(.taskTypes // .task_types // .capabilities.taskTypes // .capabilities.task_types // .capabilities.tasks // .tasks // [])[]?
       | select(type == "string") | ascii_downcase] | unique;
    def pi_harness: $harness == "pi" or $harness == "pi-signed";
    def normalized_provider($provider):
      if pi_harness and (($provider == "openai-codex") or ($provider | startswith("openai-codex-"))) then "codex"
      elif pi_harness and $provider == "anthropic" then "claude"
      else $provider end;
    def launch_model($model; $raw_provider; $provider):
      if ($model | type) != "string" then $model
      elif (pi_harness | not) or ($model | contains("/")) then $model
      elif $raw_provider != $provider then ($raw_provider + "/" + $model)
      else $model end;
    select(type == "object") |
    if (.status // "ok") == "ok" then
      select((.harness? // $harness) == $harness) |
      (.provider) as $raw_provider |
      normalized_provider($raw_provider) as $provider |
      (.model // .id) as $raw_model |
      (reasoning_capabilities) as $reasoning |
      (task_types) as $tasks |
      {status:"ok", harness:$harness, model:launch_model($raw_model; $raw_provider; $provider), provider:$provider,
       reasoningCapabilities:$reasoning, taskTypes:$tasks,
       provenance: ((.provenance // {}) + {method:"fixture", rawProvider:$raw_provider})}
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
  if ! command -v python3 >/dev/null 2>&1; then
    json_emit_error "$harness" "python3 not installed" "opencode models"
    return 1
  fi
  tmp=$(mktemp) || return 1
  if run_capture "$harness" "opencode models" "$tmp" opencode models; then
    python3 - "$tmp" <<'PY'
import json, re, sys
path = sys.argv[1]
seen = set()

def values(obj, keys, item_keys):
    raw = None
    for key in keys:
        if obj.get(key) is not None:
            raw = obj.get(key)
            break
    if raw is None:
        capabilities = obj.get('capabilities') or {}
        for key in keys:
            if capabilities.get(key) is not None:
                raw = capabilities.get(key)
                break
    if not isinstance(raw, list):
        return []
    result = []
    for value in raw:
        if isinstance(value, dict):
            value = next((value.get(key) for key in item_keys if value.get(key)), None)
        if isinstance(value, str) and value:
            result.append(value.lower())
    return sorted(set(result))

def emit(model, provider, obj=None):
    obj = obj or {}
    key = (model, provider)
    if key in seen:
        return
    seen.add(key)
    print(json.dumps({
        'status': 'ok', 'harness': 'opencode', 'model': model, 'provider': provider,
        'reasoningCapabilities': values(obj, ['reasoningCapabilities', 'supportedReasoningEfforts', 'reasoningEfforts', 'reasoning', 'thinkingLevels', 'effortLevels'], ['reasoningEffort', 'reasoning_effort', 'level', 'name']),
        'taskTypes': values(obj, ['taskTypes', 'task_types', 'useCases', 'tasks'], ['taskType', 'task_type', 'type', 'name']),
        'provenance': {'method': 'opencode models', 'rawProvider': provider}
    }, separators=(',', ':')))

with open(path, encoding='utf-8', errors='replace') as fh:
    for line in fh:
        s = re.sub(r'\x1b\[[0-9;]*m', '', line.strip()).strip(' |*-')
        if not s:
            continue
        try:
            obj = json.loads(s)
        except Exception:
            obj = None
        if isinstance(obj, dict):
            model = obj.get('id') or obj.get('model') or obj.get('name')
            provider = obj.get('providerID') or obj.get('provider')
            if isinstance(model, str) and model and isinstance(provider, str) and provider:
                emit(model, provider, obj)
                continue
        cols = re.split(r'\s+', s)
        candidate = cols[0]
        if '/' in candidate:
            provider, model = candidate.split('/', 1)
        elif len(cols) >= 2:
            provider, model = cols[0], cols[1]
        else:
            continue
        if not re.match(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$', provider) or not model or model.lower() in {'model', 'models'}:
            continue
        emit(candidate if '/' in candidate else model, provider)
PY
  fi
  rm -f "$tmp" "$tmp.err"
}

catalog_pi() {  # <harness>
  local harness=$1 tmp executable
  with_fixture_if_present "$harness" && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    json_emit_error "$harness" "python3 not installed" "$harness --list-models"
    return 1
  fi
  executable=pi
  [ "$harness" = pi-signed ] && executable=pi-signed
  tmp=$(mktemp) || return 1
  if run_capture "$harness" "$executable --list-models" "$tmp" "$executable" -ne -ns -np -nc --no-themes --no-approve --list-models; then
    python3 - "$tmp" "$harness" <<'PY'
import json, re, sys
path, harness = sys.argv[1], sys.argv[2]
seen = set()

def values(obj, keys, item_keys):
    raw = None
    for key in keys:
        if obj.get(key) is not None:
            raw = obj.get(key)
            break
    if raw is None:
        capabilities = obj.get('capabilities') or {}
        for key in keys:
            if capabilities.get(key) is not None:
                raw = capabilities.get(key)
                break
    if not isinstance(raw, list):
        return []
    result = []
    for value in raw:
        if isinstance(value, dict):
            value = next((value.get(key) for key in item_keys if value.get(key)), None)
        if isinstance(value, str) and value:
            result.append(value.lower())
    return sorted(set(result))

def normalized_provider(provider):
    if provider == 'openai-codex' or provider.startswith('openai-codex-'):
        return 'codex'
    if provider == 'anthropic':
        return 'claude'
    return provider

def launch_model(model, raw_provider):
    if '/' in model:
        return model
    return raw_provider + '/' + model

with open(path, encoding='utf-8', errors='replace') as fh:
    for line in fh:
        s = line.strip()
        if not s or s.startswith(('-', '#')):
            continue
        try:
            obj = json.loads(s)
        except Exception:
            obj = None
        if isinstance(obj, dict):
            provider = obj.get('provider') or obj.get('providerID')
            model = obj.get('model') or obj.get('id') or obj.get('name')
            if isinstance(provider, str) and isinstance(model, str) and provider and model:
                raw_provider = provider
                normalized = normalized_provider(raw_provider)
                model = launch_model(model, raw_provider)
                key = (model, normalized)
                if key not in seen:
                    seen.add(key)
                    print(json.dumps({
                        'status': 'ok', 'harness': harness, 'model': model, 'provider': normalized,
                        'reasoningCapabilities': values(obj, ['reasoningCapabilities', 'supportedReasoningEfforts', 'reasoningEfforts', 'reasoning', 'thinkingLevels', 'effortLevels'], ['reasoningEffort', 'reasoning_effort', 'level', 'name']),
                        'taskTypes': values(obj, ['taskTypes', 'task_types', 'useCases', 'tasks'], ['taskType', 'task_type', 'type', 'name']),
                        'provenance': {'method': harness + ' --list-models', 'rawProvider': raw_provider}
                    }, separators=(',', ':')))
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
        raw_provider = provider
        normalized = normalized_provider(raw_provider)
        model = f'{raw_provider}/{model}'
        key = (model, normalized)
        if key in seen:
            continue
        seen.add(key)
        print(json.dumps({
            'status': 'ok', 'harness': harness, 'model': model, 'provider': normalized,
            'reasoningCapabilities': [], 'taskTypes': [],
            'provenance': {'method': harness + ' --list-models', 'rawProvider': raw_provider}
        }, separators=(',', ':')))
PY
  fi
  rm -f "$tmp" "$tmp.err"
}

catalog_claude() {
  local harness=claude rc script
  with_fixture_if_present "$harness" && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    json_emit_error "$harness" "python3 not installed" "claude stream-json initialize"
    return 1
  fi
  if ! command -v claude >/dev/null 2>&1; then
    json_emit_error "$harness" "claude not installed" "claude stream-json initialize"
    return 1
  fi
  script=$(mktemp) || return 1
  cat > "$script" <<'PY'
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
    def values(obj, keys, item_keys):
        raw = None
        for key in keys:
            if obj.get(key) is not None:
                raw = obj.get(key)
                break
        if raw is None:
            capabilities = obj.get('capabilities') or {}
            for key in keys:
                if capabilities.get(key) is not None:
                    raw = capabilities.get(key)
                    break
        if not isinstance(raw, list):
            return []
        result = []
        for value in raw:
            if isinstance(value, dict):
                value = next((value.get(key) for key in item_keys if value.get(key)), None)
            if isinstance(value, str) and value:
                result.append(value.lower())
        return sorted(set(result))
    for model in ((response.get('response') or {}).get('models') or []):
        mid = model.get('value') or model.get('resolvedModel') or model.get('id') or model.get('model')
        if not isinstance(mid, str) or not mid or mid in seen:
            continue
        seen.add(mid)
        print(json.dumps({'status':'ok','harness':'claude','model':mid,'provider':'claude',
                          'reasoningCapabilities':values(model, ['reasoningCapabilities', 'supportedReasoningEfforts', 'reasoningEfforts', 'reasoning', 'thinkingLevels', 'effortLevels'], ['reasoningEffort', 'reasoning_effort', 'level', 'name']),
                          'taskTypes':values(model, ['taskTypes', 'task_types', 'useCases', 'tasks'], ['taskType', 'task_type', 'type', 'name']),
                          'provenance':{'method':'claude stream-json initialize','resolvedModel':model.get('resolvedModel')}}, separators=(',', ':')))
    proc.terminate()
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        proc.kill()
    sys.exit(0)
proc.kill()
sys.exit(1)
PY
  fm_run_timed "$CATALOG_TIMEOUT" python3 "$script"
  rc=$?
  rm -f "$script"
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
  local harness=codex rc script
  with_fixture_if_present "$harness" && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    json_emit_error "$harness" "python3 not installed" "codex app-server model/list"
    return 1
  fi
  if ! command -v codex >/dev/null 2>&1; then
    json_emit_error "$harness" "codex not installed" "codex app-server model/list"
    return 1
  fi
  script=$(mktemp) || return 1
  cat > "$script" <<'PY'
import json, subprocess, sys, time
cmd = ['codex', 'app-server', '--stdio', '-c', 'analytics.enabled=false']
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
        def values(keys, item_keys):
            raw = None
            for key in keys:
                if model.get(key) is not None:
                    raw = model.get(key)
                    break
            if raw is None:
                capabilities = model.get('capabilities') or {}
                for key in keys:
                    if capabilities.get(key) is not None:
                        raw = capabilities.get(key)
                        break
            if not isinstance(raw, list):
                return []
            result = []
            for value in raw:
                if isinstance(value, dict):
                    value = next((value.get(key) for key in item_keys if value.get(key)), None)
                if isinstance(value, str) and value:
                    result.append(value.lower())
            return sorted(set(result))
        print(json.dumps({'status':'ok','harness':'codex','model':mid,'provider':'codex',
                          'reasoningCapabilities':values(['reasoningCapabilities', 'supportedReasoningEfforts', 'supported_reasoning_efforts', 'reasoningEfforts', 'reasoning'], ['reasoningEffort', 'reasoning_effort', 'level', 'name']),
                          'taskTypes':values(['taskTypes', 'task_types', 'useCases', 'tasks'], ['taskType', 'task_type', 'type', 'name']),
                          'provenance':{'method':'codex app-server model/list','displayName':model.get('displayName'),'catalogProvider':model.get('provider')}}, separators=(',', ':')))
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
  fm_run_timed "$CATALOG_TIMEOUT" python3 "$script"
  rc=$?
  rm -f "$script"
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      json_emit_error "$harness" "catalog command timed out after ${CATALOG_TIMEOUT}s" "codex app-server model/list"
    else
      json_emit_error "$harness" "catalog command failed with exit $rc" "codex app-server model/list"
    fi
    return 1
  fi
}

if [ "${1:-}" = --list-harnesses ]; then
  supported_harnesses
  exit 0
fi
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
