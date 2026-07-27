#!/usr/bin/env bash
# Manage Firstmate's local, project-scoped Graphify context generations.
#
# Graphify is deliberately installed into $FM_HOME/data/graphify/venv, never
# taken from PATH. Every graph lives below $FM_HOME/data/graphify/projects/<name>
# and is built from a validated registered clone, never from a caller path. The
# build copies only allowlisted regular source files into a private generation,
# uses Graphify's local AST API (no semantic backend), validates the result, and
# atomically publishes it only when the source fingerprint still agrees.
#
# Usage: fm-graphify.sh status <project>
#        fm-graphify.sh rebuild <project>
#        fm-graphify.sh query <project> <question>
#        fm-graphify.sh intake <project> <question>
#        fm-graphify.sh mark-stale <project> <reason>
#        fm-graphify.sh cleanup <project>
#        fm-graphify.sh install
#        fm-graphify.sh available
#
# status returns one JSON object with state missing|building|fresh|stale|failed.
# query and intake refuse stale graphs; intake is a bounded, provenance-rich
# worker-context rendering and returns success without output when unavailable.
# Limits and the private state format are owned here. Operators should use the
# configuration reference for setup and architecture for lifecycle integration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
GRAPHIFY_VERSION=0.9.28
GRAPHIFY_DIST="graphifyy==$GRAPHIFY_VERSION"
GRAPH_HOME="$DATA/graphify"
VENV="$GRAPH_HOME/venv"
PYTHON="$VENV/bin/python"
MAX_FILES=${FM_GRAPHIFY_MAX_FILES:-10000}
MAX_FILE_BYTES=${FM_GRAPHIFY_MAX_FILE_BYTES:-5242880}
MAX_TOTAL_BYTES=${FM_GRAPHIFY_MAX_TOTAL_BYTES:-104857600}
MAX_GRAPH_BYTES=${FM_GRAPHIFY_MAX_GRAPH_BYTES:-52428800}
BUILD_TIMEOUT=${FM_GRAPHIFY_BUILD_TIMEOUT:-120}
QUERY_TIMEOUT=${FM_GRAPHIFY_QUERY_TIMEOUT:-20}
QUERY_TOKENS=${FM_GRAPHIFY_QUERY_TOKENS:-600}
QUERY_BYTES=${FM_GRAPHIFY_QUERY_BYTES:-12000}
CONFIG_VERSION="v1;files=$MAX_FILES;file_bytes=$MAX_FILE_BYTES;total_bytes=$MAX_TOTAL_BYTES;graph_bytes=$MAX_GRAPH_BYTES;semantic=disabled"

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; }
die() { printf 'fm-graphify: %s\n' "$*" >&2; exit 1; }
json_error() { printf '{"state":"%s","diagnostic":"%s"}\n' "$1" "${2//\"/\\\"}"; }

bounded_run() {  # <whole-seconds> <command> [args...]
  local seconds=$1 pid elapsed=0 rc
  shift
  case "$seconds" in ''|*[!0-9]*|0) return 2 ;; esac
  "$@" <&0 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$seconds" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"; rc=$?
  return "$rc"
}

valid_project() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [ -f "$DATA/projects.md" ] || return 1
  awk -v n="$1" '$1=="-" && $2==n { found=1 } END { exit !found }' "$DATA/projects.md"
}

resolve_project() {
  local name=$1 projects_real candidate root git_root
  valid_project "$name" || die "project '$name' is not registered"
  [ -d "$PROJECTS" ] && [ ! -L "$PROJECTS" ] || die "project registry root is unavailable"
  projects_real=$(cd "$PROJECTS" && pwd -P) || die "cannot resolve projects root"
  candidate="$PROJECTS/$name"
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || die "registered project '$name' clone is unavailable"
  root=$(cd "$candidate" && pwd -P) || die "cannot resolve registered project '$name'"
  case "$root" in "$projects_real"/*) ;; *) die "registered project '$name' escapes projects root" ;; esac
  [ "${root#"$projects_real"/}" = "$name" ] || die "registered project '$name' is not a direct clone child"
  git_root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || die "registered project '$name' is not a git clone"
  [ "$(cd "$git_root" && pwd -P)" = "$root" ] || die "registered project '$name' root is not its clone root"
  PROJECT_ROOT=$root
  GRAPH_DIR="$GRAPH_HOME/projects/$name"
  GRAPH_FILE="$GRAPH_DIR/graph.json"
  STATE_FILE="$GRAPH_DIR/state.json"
}

graphify_available() {
  [ -x "$PYTHON" ] || return 1
  "$PYTHON" - "$GRAPHIFY_VERSION" <<'PY' >/dev/null 2>&1
import sys
from importlib.metadata import version
sys.exit(0 if version("graphifyy") == sys.argv[1] else 1)
PY
}

install() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required to install Graphify"
  mkdir -p "$GRAPH_HOME"
  if [ ! -x "$PYTHON" ]; then python3 -m venv "$VENV"; fi
  "$PYTHON" -m pip install --disable-pip-version-check --upgrade "$GRAPHIFY_DIST"
  graphify_available || die "installed Graphify did not satisfy $GRAPHIFY_DIST"
  printf 'Graphify %s installed at %s\n' "$GRAPHIFY_VERSION" "$VENV"
}

write_state() {
  local state=$1 diagnostic=${2:-} fingerprint=${3:-}
  mkdir -p "$GRAPH_DIR"
  "$PYTHON" - "$STATE_FILE" "$state" "$diagnostic" "$fingerprint" "$GRAPHIFY_VERSION" "$CONFIG_VERSION" <<'PY'
import json, os, sys, tempfile, time
p, state, diagnostic, fingerprint, version, config = sys.argv[1:]
value={"schema":1,"state":state,"diagnostic":diagnostic,"fingerprint":fingerprint,"graphify_version":version,"config":config,"updated_at":int(time.time())}
fd,tmp=tempfile.mkstemp(prefix='.state.', dir=os.path.dirname(p))
with os.fdopen(fd,'w',encoding='utf-8') as f:
    json.dump(value,f,sort_keys=True,separators=(',',':')); f.flush(); os.fsync(f.fileno())
os.replace(tmp,p)
PY
}

fingerprint() {
  "$PYTHON" - "$PROJECT_ROOT" "$GRAPHIFY_VERSION" "$CONFIG_VERSION" "$MAX_FILES" "$MAX_FILE_BYTES" "$MAX_TOTAL_BYTES" <<'PY'
import hashlib, json, os, subprocess, sys
root, version, config, max_files, max_file, max_total = sys.argv[1:]
max_files, max_file, max_total = map(int,(max_files,max_file,max_total))
skip_dirs={'.git','.hg','.svn','node_modules','vendor','vendors','deps','dependency','dependencies','dist','build','out','target','coverage','graphify-out','.graphify','.venv','venv','__pycache__'}
extensions={'.py','.pyi','.js','.mjs','.cjs','.ts','.tsx','.jsx','.go','.rs','.java','.kt','.c','.h','.cc','.cpp','.hpp','.cs','.rb','.php','.swift','.scala','.sh','.bash','.zsh','.sql','.yaml','.yml','.json','.toml','.md','.mdx','.rst'}
secret_names={'id_rsa','id_ed25519','.netrc','credentials','credentials.json'}
def allowed(rel, full):
    parts=rel.split(os.sep)
    if any(part in skip_dirs for part in parts[:-1]): return False
    name=parts[-1].lower()
    if name.startswith('.env') or name in secret_names or 'secret' in name or name.endswith('.pem') or name.endswith('.key'): return False
    if os.path.islink(full) or not os.path.isfile(full): return False
    return os.path.splitext(name)[1] in extensions
items=[]; total=0
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    dirs[:]=[d for d in dirs if d not in skip_dirs and not os.path.islink(os.path.join(base,d))]
    for name in sorted(files):
        full=os.path.join(base,name); rel=os.path.relpath(full,root)
        if not allowed(rel,full): continue
        size=os.path.getsize(full)
        if size > max_file: continue
        total += size
        if total > max_total: raise SystemExit('source bytes exceed graph limit')
        items.append((rel.replace(os.sep,'/'),size))
        if len(items)>max_files: raise SystemExit('source file count exceeds graph limit')
head=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'], text=True).strip()
h=hashlib.sha256(); h.update(('graphifyy='+version+'\0'+config+'\0'+head+'\0').encode())
for rel,size in items:
    h.update(rel.encode()); h.update(b'\0'); h.update(str(size).encode()); h.update(b'\0')
    with open(os.path.join(root,*rel.split('/')),'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
print(json.dumps({'fingerprint':h.hexdigest(),'revision':head,'files':[x[0] for x in items]},separators=(',',':')))
PY
}

status() {
  local lock=0 fp=''
  [ -d "$GRAPH_DIR/.build.lock" ] && lock=1
  if ! graphify_available; then json_error missing "Graphify $GRAPHIFY_DIST is not installed in this Firstmate home"; return 0; fi
  if ! fp=$(fingerprint 2>&1); then json_error failed "$fp"; return 0; fi
  "$PYTHON" - "$STATE_FILE" "$GRAPH_FILE" "$fp" "$lock" <<'PY'
import hashlib,json,os,sys
state_file,graph_file,current,lock=sys.argv[1:]; current=json.loads(current)
if lock=='1': print(json.dumps({'state':'building','diagnostic':'a rebuild holds the project lock'})); raise SystemExit
if not os.path.isfile(graph_file) or os.path.islink(graph_file): print(json.dumps({'state':'missing','diagnostic':'no published graph'})); raise SystemExit
try: state=json.load(open(state_file,encoding='utf-8'))
except Exception: state={}
if state.get('state')=='failed': print(json.dumps({'state':'failed','diagnostic':state.get('diagnostic','last rebuild failed')})); raise SystemExit
if state.get('state')=='stale': print(json.dumps({'state':'stale','diagnostic':state.get('diagnostic','graph was explicitly invalidated'),'revision':current['revision']})); raise SystemExit
if state.get('fingerprint') != current['fingerprint']:
 print(json.dumps({'state':'stale','diagnostic':'project revision or graph configuration changed','revision':current['revision']})); raise SystemExit
print(json.dumps({'state':'fresh','revision':current['revision'],'files':len(current['files']),'graph_sha256':hashlib.sha256(open(graph_file,'rb').read()).hexdigest()}))
PY
}

rebuild() {
  graphify_available || die "Graphify $GRAPHIFY_DIST is unavailable; request bootstrap install consent"
  mkdir -p "$GRAPH_DIR"
  if ! mkdir "$GRAPH_DIR/.build.lock" 2>/dev/null; then json_error building "a rebuild is already running"; return 0; fi
  local stage fp out
  trap 'rm -rf -- "${stage:-}"; rmdir -- "$GRAPH_DIR/.build.lock" 2>/dev/null || true' EXIT
  fp=$(fingerprint) || { write_state failed "cannot enumerate source scope"; die "cannot enumerate source scope"; }
  write_state building "generation is building" "$(printf '%s' "$fp" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"
  stage=$(mktemp -d "$GRAPH_DIR/.generation.XXXXXX")
  if ! out=$(bounded_run "$BUILD_TIMEOUT" "$PYTHON" - "$PROJECT_ROOT" "$stage" "$fp" "$MAX_GRAPH_BYTES" <<'PY' 2>&1
import hashlib,json,os,shutil,sys
from pathlib import Path
import graphify
root, stage, fp_text, max_graph = sys.argv[1:]; fp=json.loads(fp_text); stage=Path(stage); source=stage/'source'; source.mkdir()
for rel in fp['files']:
    inp=Path(root,*rel.split('/')); dst=source.joinpath(*rel.split('/')); dst.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(inp,dst)
sources=[source.joinpath(*p.split('/')) for p in fp['files']]
if not sources: raise RuntimeError('no supported local source files are available')
data=graphify.extract(sources,cache_root=stage/'cache',root=source,parallel=False)
graph=graphify.build_from_json(data,directed=True,root=source)
if graph.number_of_nodes() <= 0: raise RuntimeError('Graphify generated no structural nodes')
out=stage/'graph.json'
if not graphify.to_json(graph,{},str(out),force=True): raise RuntimeError('Graphify refused to write the generation')
raw=json.loads(out.read_text(encoding='utf-8'))
if not isinstance(raw,dict): raise RuntimeError('Graphify output is not a JSON object')
for n in raw.get('nodes',[]):
    if not isinstance(n,dict): raise RuntimeError('Graphify output has malformed nodes')
    p=n.get('source_file')
    if p and (not isinstance(p,str) or p.startswith('/') or '..' in Path(p).parts or p.replace('\\','/') not in fp['files']): raise RuntimeError('Graphify output cites an out-of-scope source')
raw.setdefault('graph',{}).setdefault('firstmate',{}).update({'schema':1,'graphify_version':'0.9.28','semantic_backend':'disabled','fingerprint':fp['fingerprint'],'revision':fp['revision'],'source_files':len(fp['files'])})
payload=json.dumps(raw,sort_keys=True,separators=(',',':')).encode()
if not payload or len(payload)>int(max_graph): raise RuntimeError('Graphify output exceeds graph byte limit')
out.write_bytes(payload)
print(json.dumps({'nodes':graph.number_of_nodes(),'edges':graph.number_of_edges(),'sha256':hashlib.sha256(payload).hexdigest()}))
PY
); then
    write_state failed "${out:0:1000}" "$(printf '%s' "$fp" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"
    die "rebuild failed: ${out:0:1000}"
  fi
  local after
  after=$(fingerprint) || { write_state failed "cannot re-enumerate source scope after generation"; die "source scope changed during generation"; }
  [ "$(printf '%s' "$after" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')" = "$(printf '%s' "$fp" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')" ] || {
    write_state stale "source scope changed during generation" "$(printf '%s' "$after" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"
    die "source scope changed during generation; prior graph was preserved"
  }
  "$PYTHON" - "$stage/graph.json" "$GRAPH_FILE" "$fp" "$out" <<'PY'
import json,os,sys
stage,canonical,fp_text,out=sys.argv[1:]; fp=json.loads(fp_text); result=json.loads(out)
if not os.path.isfile(stage) or os.path.islink(stage): raise SystemExit('generation did not produce a regular graph')
current=json.loads(sys.stdin.read() or '{}') if False else fp
os.replace(stage,canonical)
print(json.dumps({'state':'fresh','revision':fp['revision'],'fingerprint':fp['fingerprint'],**result},separators=(',',':')))
PY
  write_state fresh "" "$(printf '%s' "$fp" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')"
}

mark_stale() {
  local reason=$1 current=''
  [ -d "$GRAPH_DIR" ] || return 0
  current=$(fingerprint 2>/dev/null | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])' 2>/dev/null || true)
  write_state stale "${reason:0:1000}" "$current"
  printf '{"state":"stale","diagnostic":"%s"}\n' "${reason//\"/\\\"}"
}

query() {
  local question=$1 st out
  st=$(status)
  if [ "$(printf '%s' "$st" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["state"])')" != fresh ]; then return 2; fi
  out=$(cd "$GRAPH_DIR" && HOME="$GRAPH_DIR/home" XDG_CACHE_HOME="$GRAPH_DIR/cache" bounded_run "$QUERY_TIMEOUT" "$VENV/bin/graphify" query "$question" --graph "$GRAPH_FILE" --budget "$QUERY_TOKENS" 2>&1) || return 1
  printf '%s' "$out" | head -c "$QUERY_BYTES"
  printf '\n'
}

intake() {
  local question=$1 st context provenance
  st=$(status)
  [ "$(printf '%s' "$st" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["state"])')" = fresh ] || return 0
  context=$(query "$question") || return 0
  provenance=$("$PYTHON" - "$GRAPH_FILE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8')); seen=[]
for n in d.get('nodes',[]):
 p=n.get('source_file') if isinstance(n,dict) else None
 if p and p not in seen: seen.append(p)
print(', '.join(seen[:8]))
PY
)
  [ -n "$context" ] || return 0
  printf '\n## Bounded Graphify context\n%s\n\nProvenance: revision %s; cited source files: %s\n' "$context" "$(printf '%s' "$st" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("revision","unknown"))')" "$provenance"
}

cleanup() {
  [ -d "$GRAPH_DIR" ] || return 0
  [ ! -L "$GRAPH_DIR" ] || die "refusing symlinked graph state"
  rm -rf "$GRAPH_DIR"
  printf '{"state":"missing","diagnostic":"derived graph state removed"}\n'
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
cmd=$1; shift
case "$cmd" in
  available) [ $# -eq 0 ] || die 'available takes no arguments'; graphify_available ;;
  install) [ $# -eq 0 ] || die 'install takes no arguments'; install ;;
  status|rebuild|mark-stale|cleanup|query|intake)
    [ $# -ge 1 ] || die "$cmd requires a registered project name"; resolve_project "$1"; shift
    case "$cmd" in
      status) [ $# -eq 0 ] || die 'status takes no extra arguments'; status ;;
      rebuild) [ $# -eq 0 ] || die 'rebuild takes no extra arguments'; rebuild ;;
      mark-stale) [ $# -eq 1 ] || die 'mark-stale requires one reason'; mark_stale "$1" ;;
      cleanup) [ $# -eq 0 ] || die 'cleanup takes no extra arguments'; cleanup ;;
      query|intake) [ $# -eq 1 ] || die "$cmd requires one bounded question"; [ ${#1} -le 1000 ] || die 'question exceeds 1000 characters'; "$cmd" "$1" ;;
    esac
    ;;
  -h|--help) usage ;;
  *) die "unknown command '$cmd'" ;;
esac
