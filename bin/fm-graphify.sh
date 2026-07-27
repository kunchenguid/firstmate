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
#        fm-graphify.sh schedule <project> <reason> [invalidate]
#        fm-graphify.sh refresh <project> <reason> [invalidate]
#        fm-graphify.sh query <project> <question>
#        fm-graphify.sh intake <project> <question>
#        fm-graphify.sh mark-stale <project> <reason>
#        fm-graphify.sh cleanup <project>
#        fm-graphify.sh install
#        fm-graphify.sh available
#
# status returns one JSON object with state missing|building|fresh|stale|failed.
# A published graph is reported fresh only after a generation completed and was
# recorded; an interrupted or unrecorded generation reports stale, never fresh.
# schedule is the single lifecycle owner every guarded fleet sync and merge
# calls. It returns immediately, so a rebuild's delay or failure can never hide
# or change the lifecycle operation's own outcome, coalesces repeated events for
# one project into the in-flight refresh, and bounds the whole home to
# FM_GRAPHIFY_MAX_CONCURRENT_REBUILDS generations at once. The optional
# invalidate token additionally records the graph stale even when nothing moved,
# which is what a remote merge needs while the local clone still lags.
# refresh applies that policy once and synchronously: it builds a missing graph,
# rebuilds only when the revision or graph configuration actually changed, is a
# cheap no-op for a fresh unchanged project, never installs Graphify, never fails
# its caller, and keeps the last valid graph byte-for-byte on failure.
# Every lock and scheduling marker records its holder, and one whose holder
# process is gone is recovered by an atomic rename, so a hard kill or reboot can
# neither wedge a project nor let two holders run at once.
# query and intake refuse stale graphs; intake is a bounded, provenance-rich
# worker-context rendering and returns success without output when unavailable.
# Limits and the private state format are owned here. Operators should use the
# configuration reference for setup and architecture for lifecycle integration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
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
MAX_CONCURRENT_REBUILDS=${FM_GRAPHIFY_MAX_CONCURRENT_REBUILDS:-10}
SCHEDULE_WAIT=${FM_GRAPHIFY_SCHEDULE_WAIT:-900}
case "$MAX_CONCURRENT_REBUILDS" in ''|*[!0-9]*|0) MAX_CONCURRENT_REBUILDS=10 ;; esac
case "$SCHEDULE_WAIT" in ''|*[!0-9]*) SCHEDULE_WAIT=900 ;; esac
SCHEDULER_DIR="$GRAPH_HOME/scheduler"
CONFIG_VERSION="v1;files=$MAX_FILES;file_bytes=$MAX_FILE_BYTES;total_bytes=$MAX_TOTAL_BYTES;graph_bytes=$MAX_GRAPH_BYTES;semantic=disabled"

PROJECT_NAME=''
PROJECT_ROOT=''
GRAPH_DIR=''
GRAPH_FILE=''
STATE_FILE=''
STAGE_DIR=''
HELD_MARKERS=()
# Derived from the process id rather than mktemp, so a helper that runs inside a
# command substitution resolves the same directory as its parent shell instead
# of creating one in a fork that no exit handler would ever clean up.
SCRATCH_DIR="$GRAPH_HOME/tmp.$$"

usage() { sed -n '2,42p' "$0" | sed 's/^# \?//'; }
die() { printf 'fm-graphify: %s\n' "$*" >&2; exit 1; }

# Diagnostics carry third-party output (tracebacks, quotes, backslashes,
# newlines), so every JSON string this script emits without Python goes through
# one escaper; the documented "one JSON object" contract must hold on failures.
json_escape() {
  local LC_ALL=C s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  s=${s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']/}
  printf '%s' "$s"
}
json_error() { printf '{"state":"%s","diagnostic":"%s"}\n' "$1" "$(json_escape "${2:-}")"; }

release_marker() {  # <marker-dir>
  rm -f -- "$1/pid"
  rmdir -- "$1" 2>/dev/null || true
}

on_exit() {
  local marker
  [ -z "$STAGE_DIR" ] || rm -rf -- "$STAGE_DIR"
  for marker in "${HELD_MARKERS[@]+"${HELD_MARKERS[@]}"}"; do
    release_marker "$marker"
  done
  rm -rf -- "$SCRATCH_DIR"
  return 0
}
trap on_exit EXIT

ensure_scratch_dir() { mkdir -p "$SCRATCH_DIR"; }

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
  PROJECT_NAME=$name
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

# The fingerprint enumerates every selected source path, so it is handed to the
# next stage as a file. A single argv string is capped at MAX_ARG_STRLEN (128KiB
# on Linux), far below the documented MAX_FILES bound.
fingerprint_to() {  # <destination-file>
  "$PYTHON" - "$1" "$PROJECT_ROOT" "$GRAPHIFY_VERSION" "$CONFIG_VERSION" "$MAX_FILES" "$MAX_FILE_BYTES" "$MAX_TOTAL_BYTES" <<'PY'
import hashlib, json, os, subprocess, sys
dest, root, version, config, max_files, max_file, max_total = sys.argv[1:]
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
with open(dest,'w',encoding='utf-8') as f:
    json.dump({'fingerprint':h.hexdigest(),'revision':head,'files':[x[0] for x in items]},f,separators=(',',':'))
PY
}

json_file_field() {  # <json-file> <key>
  "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get(sys.argv[2],""))' "$1" "$2"
}

json_text_field() {  # <json-text> <key>
  printf '%s' "$1" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"
}

marker_holder_pid() {  # <marker-dir>; fails when no numeric holder was recorded
  local holder
  holder=$(head -n 1 "$1/pid" 2>/dev/null || true)
  case "$holder" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$holder"
}

dir_age_seconds() {  # <path>
  "$PYTHON" -c 'import os,sys,time; print(max(0,int(time.time()-os.path.getmtime(sys.argv[1]))))' "$1" 2>/dev/null || printf '0'
}

# free | live | abandoned. A marker is abandoned when its recorded holder is
# gone, so a SIGKILL, OOM kill, or reboot cannot wedge the project forever. A
# marker with no readable holder is only abandoned once it outlived a whole build
# window, which keeps the mkdir-then-record window safe.
marker_state() {  # <marker-dir>
  local marker=$1 holder
  [ -d "$marker" ] || { printf 'free\n'; return 0; }
  if holder=$(marker_holder_pid "$marker"); then
    if kill -0 "$holder" 2>/dev/null; then printf 'live\n'; else printf 'abandoned\n'; fi
    return 0
  fi
  if [ "$(dir_age_seconds "$marker")" -ge "$BUILD_TIMEOUT" ]; then printf 'abandoned\n'; else printf 'live\n'; fi
}

# Recovery renames the abandoned marker to a private name first, so only the
# renaming process can proceed, and the claim is confirmed by reading back the
# recorded holder: a racing recovery that moved this marker aside is detected
# instead of producing two holders that both believe they own it.
claim_marker() {  # <marker-dir>
  local marker=$1 aside
  if ! mkdir "$marker" 2>/dev/null; then
    [ "$(marker_state "$marker")" = abandoned ] || return 1
    aside="$marker.abandoned.$$"
    mv -- "$marker" "$aside" 2>/dev/null || return 1
    rm -rf -- "$aside"
    mkdir "$marker" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$marker/pid"
  [ "$(head -n 1 "$marker/pid" 2>/dev/null || true)" = "$$" ] || return 1
  HELD_MARKERS+=("$marker")
}

build_lock_state() { marker_state "$GRAPH_DIR/.build.lock"; }

acquire_build_lock() { claim_marker "$GRAPH_DIR/.build.lock"; }

# One home-wide pool bounds how many project generations run at once, so a fleet
# sync that advances many projects cannot turn into an unbounded rebuild storm.
acquire_rebuild_slot() {
  local waited=0 n
  mkdir -p "$SCHEDULER_DIR"
  while :; do
    n=1
    while [ "$n" -le "$MAX_CONCURRENT_REBUILDS" ]; do
      if claim_marker "$SCHEDULER_DIR/slot.$n"; then return 0; fi
      n=$((n + 1))
    done
    [ "$waited" -lt "$SCHEDULE_WAIT" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

status_json() {  # <include-graph-digest 0|1>
  local digest=$1 lock fpf err
  if ! graphify_available; then json_error missing "Graphify $GRAPHIFY_DIST is not installed in this Firstmate home"; return 0; fi
  lock=$(build_lock_state)
  if [ "$lock" = live ]; then json_error building "a rebuild holds the project lock"; return 0; fi
  ensure_scratch_dir
  fpf="$SCRATCH_DIR/fingerprint.json"
  if ! err=$(fingerprint_to "$fpf" 2>&1); then json_error failed "$err"; return 0; fi
  "$PYTHON" - "$STATE_FILE" "$GRAPH_FILE" "$fpf" "$digest" <<'PY'
import hashlib,json,os,sys
state_file,graph_file,fp_file,digest=sys.argv[1:]
current=json.load(open(fp_file,encoding='utf-8'))
def emit(d):
    print(json.dumps(d)); raise SystemExit
if not os.path.isfile(graph_file) or os.path.islink(graph_file):
    emit({'state':'missing','diagnostic':'no published graph','fingerprint':current['fingerprint'],'state_fingerprint':'','revision':current['revision']})
try: state=json.load(open(state_file,encoding='utf-8'))
except Exception: state={}
common={'fingerprint':current['fingerprint'],'state_fingerprint':state.get('fingerprint',''),'revision':current['revision']}
if state.get('state')=='failed':
    emit({'state':'failed','diagnostic':state.get('diagnostic','last rebuild failed'),**common})
if state.get('state')=='stale':
    emit({'state':'stale','diagnostic':state.get('diagnostic','graph was explicitly invalidated'),**common})
# Recorded as building with no live lock: the generation was interrupted before
# it was published and recorded, so the published graph may predate this
# fingerprint. Only an explicitly recorded fresh generation may be compared, so
# no unrecorded or partial outcome can ever be reported fresh.
if state.get('state')=='building':
    emit({'state':'stale','diagnostic':'a rebuild was interrupted before it published a generation',**common})
if state.get('state')!='fresh':
    emit({'state':'stale','diagnostic':'no recorded published generation',**common})
if state.get('fingerprint') != current['fingerprint']:
    emit({'state':'stale','diagnostic':'project revision or graph configuration changed',**common})
fresh={'state':'fresh','files':len(current['files']),**common}
if digest=='1': fresh['graph_sha256']=hashlib.sha256(open(graph_file,'rb').read()).hexdigest()
emit(fresh)
PY
}

status() { status_json 1; }

rebuild() {
  graphify_available || die "Graphify $GRAPHIFY_DIST is unavailable; request bootstrap install consent"
  mkdir -p "$GRAPH_DIR"
  acquire_build_lock || { json_error building "a rebuild is already running"; return 0; }
  local fpf afterf fp out published
  ensure_scratch_dir
  fpf="$SCRATCH_DIR/fingerprint.json"
  fingerprint_to "$fpf" || { write_state failed "cannot enumerate source scope"; die "cannot enumerate source scope"; }
  fp=$(json_file_field "$fpf" fingerprint)
  write_state building "generation is building" "$fp"
  STAGE_DIR=$(mktemp -d "$GRAPH_DIR/.generation.XXXXXX")
  if ! out=$(bounded_run "$BUILD_TIMEOUT" "$PYTHON" - "$PROJECT_ROOT" "$STAGE_DIR" "$fpf" "$MAX_GRAPH_BYTES" "$GRAPHIFY_VERSION" <<'PY' 2>&1
import hashlib,json,os,shutil,sys
from pathlib import Path
import graphify
root, stage, fp_file, max_graph, version = sys.argv[1:]
fp=json.load(open(fp_file,encoding='utf-8')); stage=Path(stage); source=stage/'source'; source.mkdir()
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
raw.setdefault('graph',{}).setdefault('firstmate',{}).update({'schema':1,'graphify_version':version,'semantic_backend':'disabled','fingerprint':fp['fingerprint'],'revision':fp['revision'],'source_files':len(fp['files'])})
payload=json.dumps(raw,sort_keys=True,separators=(',',':')).encode()
if not payload or len(payload)>int(max_graph): raise RuntimeError('Graphify output exceeds graph byte limit')
out.write_bytes(payload)
# The measured result goes to a file, never to stdout: the caller captures
# stdout and stderr together, so any third-party warning would corrupt it.
(stage/'result.json').write_text(json.dumps({'nodes':graph.number_of_nodes(),'edges':graph.number_of_edges(),'sha256':hashlib.sha256(payload).hexdigest()},separators=(',',':')),encoding='utf-8')
PY
); then
    write_state failed "${out:0:1000}" "$fp"
    die "rebuild failed: ${out:0:1000}"
  fi
  afterf="$SCRATCH_DIR/fingerprint.after.json"
  fingerprint_to "$afterf" || { write_state failed "cannot re-enumerate source scope after generation"; die "source scope changed during generation"; }
  [ "$(json_file_field "$afterf" fingerprint)" = "$fp" ] || {
    write_state stale "source scope changed during generation" "$(json_file_field "$afterf" fingerprint)"
    die "source scope changed during generation; prior graph was preserved"
  }
  # Publication is the last step that can fail, so it records a failed outcome
  # too; state must never stay at building while status can still be consulted.
  if ! published=$("$PYTHON" - "$STAGE_DIR/graph.json" "$GRAPH_FILE" "$fpf" "$STAGE_DIR/result.json" <<'PY' 2>&1
import json,os,sys
stage,canonical,fp_file,result_file=sys.argv[1:]
fp=json.load(open(fp_file,encoding='utf-8')); result=json.load(open(result_file,encoding='utf-8'))
if not os.path.isfile(stage) or os.path.islink(stage): raise SystemExit('generation did not produce a regular graph')
os.replace(stage,canonical)
print(json.dumps({'state':'fresh','revision':fp['revision'],'fingerprint':fp['fingerprint'],**result},separators=(',',':')))
PY
  ); then
    write_state failed "publication failed: ${published:0:1000}" "$fp"
    die "publication failed: ${published:0:1000}"
  fi
  write_state fresh "" "$fp"
  printf '%s\n' "$published"
}

mark_stale() {  # <reason> [already-measured fingerprint]
  local reason=$1 current=${2:-} fpf
  [ -d "$GRAPH_DIR" ] || return 0
  graphify_available || return 0
  if [ -z "$current" ]; then
    ensure_scratch_dir
    fpf="$SCRATCH_DIR/fingerprint.stale.json"
    if fingerprint_to "$fpf" 2>/dev/null; then
      current=$(json_file_field "$fpf" fingerprint 2>/dev/null || true)
    fi
  fi
  write_state stale "${reason:0:1000}" "$current"
  printf '{"state":"stale","diagnostic":"%s"}\n' "$(json_escape "${reason:0:1000}")"
}

# One application of the lifecycle policy: never install, build a graph that is
# missing, rebuild only when the fingerprint actually moved, and leave the last
# valid graph untouched (and never reported fresh) when a rebuild cannot run or
# fails. With the invalidate token an unchanged graph is additionally recorded
# stale, which is what a remote merge needs while the local clone still lags.
refresh() {
  local reason=$1 invalidate=${2:-0} st state current persisted
  graphify_available || return 0
  if [ "$(build_lock_state)" = live ]; then return 0; fi
  st=$(status_json 0) || return 0
  state=$(json_text_field "$st" state) || return 0
  current=$(json_text_field "$st" fingerprint)
  persisted=$(json_text_field "$st" state_fingerprint)
  case "$state" in
    building) return 0 ;;
    missing) ;;
    failed)
      # The same input already failed; retry only once its fingerprint moves.
      [ -n "$current" ] && [ "$current" != "$persisted" ] || return 0
      ;;
    *)
      if [ -n "$current" ] && [ "$current" = "$persisted" ]; then
        # Nothing the graph depends on changed, so an identical rebuild would be
        # waste. The fingerprint status just measured is reused rather than
        # hashing the whole tree a second time.
        if [ "$invalidate" = 1 ]; then mark_stale "$reason" "$current" >/dev/null 2>&1 || true; fi
        return 0
      fi
      ;;
  esac
  # A separate process so the rebuild owns its own lock, stage, and exit trap
  # and can never abort the lifecycle operation that asked for the refresh.
  "$SELF" rebuild "$PROJECT_NAME" >/dev/null 2>&1 || true
  return 0
}

# The single scheduling owner. Every guarded lifecycle caller hands its event
# here and gets an immediate return, so a rebuild can never delay, hide, or
# change the outcome of the merge or sync that triggered it.
schedule() {
  local reason=$1 invalidate=${2:-0}
  graphify_available || return 0
  mkdir -p "$GRAPH_DIR"
  : > "$GRAPH_DIR/.refresh.request"
  ( "$SELF" refresh-worker "$PROJECT_NAME" "$reason" "$invalidate" >/dev/null 2>&1 & ) || true
  return 0
}

# Exactly one worker per project runs at a time; a repeated event for a project
# whose worker is still pending is coalesced into it, because the worker re-reads
# the request marker after each pass and re-measures the project from scratch.
refresh_worker() {
  local reason=$1 invalidate=${2:-0}
  graphify_available || return 0
  mkdir -p "$GRAPH_DIR"
  claim_marker "$GRAPH_DIR/.refresh.worker" || return 0
  # The request is deliberately left in place when no slot frees up in time, so
  # the next lifecycle event still finds outstanding work rather than losing it.
  acquire_rebuild_slot || return 0
  while [ -f "$GRAPH_DIR/.refresh.request" ]; do
    rm -f -- "$GRAPH_DIR/.refresh.request"
    refresh "$reason" "$invalidate"
  done
  return 0
}

query() {  # <question> [already-computed status JSON]
  local question=$1 st=${2:-} out
  graphify_available || return 2
  [ -n "$st" ] || st=$(status_json 0)
  [ "$(json_text_field "$st" state)" = fresh ] || return 2
  out=$(cd "$GRAPH_DIR" && HOME="$GRAPH_DIR/home" XDG_CACHE_HOME="$GRAPH_DIR/cache" bounded_run "$QUERY_TIMEOUT" "$VENV/bin/graphify" query "$question" --graph "$GRAPH_FILE" --budget "$QUERY_TOKENS" 2>&1) || return 1
  # head closes the pipe at the cap, which raises SIGPIPE under pipefail; the
  # captured bytes are already complete, so the truncation is not a failure.
  out=$(printf '%s' "$out" | head -c "$QUERY_BYTES") || true
  printf '%s\n' "$out"
}

intake() {
  local question=$1 st context provenance revision
  graphify_available || return 0
  st=$(status_json 0)
  [ "$(json_text_field "$st" state)" = fresh ] || return 0
  context=$(query "$question" "$st") || return 0
  [ -n "$context" ] || return 0
  revision=$(json_text_field "$st" revision)
  [ -n "$revision" ] || revision=unknown
  provenance=$("$PYTHON" - "$GRAPH_FILE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8')); seen=[]
for n in d.get('nodes',[]):
 p=n.get('source_file') if isinstance(n,dict) else None
 if p and p not in seen: seen.append(p)
print(', '.join(seen[:8]))
PY
)
  printf '\n## Bounded Graphify context\n%s\n\nProvenance: revision %s; cited source files: %s\n' "$context" "$revision" "$provenance"
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
  status|rebuild|schedule|refresh|refresh-worker|mark-stale|cleanup|query|intake)
    [ $# -ge 1 ] || die "$cmd requires a registered project name"; resolve_project "$1"; shift
    case "$cmd" in
      status) [ $# -eq 0 ] || die 'status takes no extra arguments'; status ;;
      rebuild) [ $# -eq 0 ] || die 'rebuild takes no extra arguments'; rebuild ;;
      schedule|refresh|refresh-worker)
        [ $# -ge 1 ] && [ $# -le 2 ] || die "$cmd requires one reason and an optional invalidate token"
        invalidate=0
        case "${2:-0}" in invalidate|1) invalidate=1 ;; ''|0) invalidate=0 ;; *) die "$cmd accepts only 'invalidate' as its optional token" ;; esac
        case "$cmd" in
          schedule) schedule "$1" "$invalidate" ;;
          refresh) refresh "$1" "$invalidate" ;;
          refresh-worker) refresh_worker "$1" "$invalidate" ;;
        esac
        ;;
      mark-stale) [ $# -eq 1 ] || die 'mark-stale requires one reason'; mark_stale "$1" ;;
      cleanup) [ $# -eq 0 ] || die 'cleanup takes no extra arguments'; cleanup ;;
      query|intake) [ $# -eq 1 ] || die "$cmd requires one bounded question"; [ ${#1} -le 1000 ] || die 'question exceeds 1000 characters'; "$cmd" "$1" ;;
    esac
    ;;
  -h|--help) usage ;;
  *) die "unknown command '$cmd'" ;;
esac
