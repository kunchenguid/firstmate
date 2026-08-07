#!/usr/bin/env bash
# Multi-brain oracle query tool — query all registered brains, merge results with attribution.
# Phase 1: brain registry + oracle routing.
#
# Usage:
#   fm-oracle.sh query "<question>" [max-results]
#     Query all registered brains, return merged results with per-brain attribution.
#   fm-oracle.sh list
#     List all registered brains with their room schemas.
#   fm-oracle.sh health
#     Health-check all registered brains.
#
# Requires: CROF venv, projects/crof checkout, brain_registry.json
set -eu

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/brains/brain_registry.json"
CROF_VENV="/Users/walter/Dev/crof/.venv/bin/python"
CROF_PATH="$FM_ROOT/projects/crof"
ORACLE_SCRIPT="$DATA/brains/_oracle_query.py"

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'; exit 2; }

# Write the Python oracle query script once
ensure_oracle_script() {
  if [ -f "$ORACLE_SCRIPT" ]; then return 0; fi
  cat > "$ORACLE_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""Oracle multi-brain query — called by fm-oracle.sh.

Reads brain_registry.json and queries each registered brain, merges results.
Each brain is queried in its own subprocess to avoid cbgt namespace conflicts.
"""
from __future__ import annotations
import json, os, subprocess, sys, traceback
from pathlib import Path

CROF_VENV = "/Users/walter/Dev/crof/.venv/bin/python"
CROF_PATH = "/Users/walter/Dev/firstmate/projects/crof"
QUERY_HELPER = f"{CROF_PATH}/examples/read_only_brain_query.py"
# note: read_only_brain_query.py takes <brain_path> <query> [max_results]

def main() -> int:
    registry_path = Path(sys.argv[1])
    query = sys.argv[2] if len(sys.argv) > 2 else ""
    max_results = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    if not query:
        print(json.dumps({"error": "query text required"}))
        return 2
    if not registry_path.is_file():
        print(json.dumps({"error": f"registry not found: {registry_path}"}))
        return 1

    registry = json.loads(registry_path.read_text())
    answers = []
    errors = []

    for name, cfg in registry.get("brains", {}).items():
        brain_path = Path(cfg["path"])
        if not brain_path.is_file():
            errors.append({"brain": name, "status": "ABSENT", "path": str(brain_path)})
            continue
        try:
            result = subprocess.run(
                [CROF_VENV, QUERY_HELPER, str(brain_path), query, "--max-results", str(max_results)],
                capture_output=True, text=True, timeout=45,
                env={
                    **os.environ,
                    "HF_HUB_OFFLINE": "1",
                    "TRANSFORMERS_OFFLINE": "1",
                    "PYTHONNOUSERSITE": "1",
                    "PYTHONPATH": CROF_PATH,
                },
                cwd=CROF_PATH,
            )
            if result.returncode != 0:
                errors.append({"brain": name, "status": "FAIL",
                               "stderr": result.stderr[:200]})
                continue
            out = json.loads(result.stdout)
            hybrid = out.get("hybrid", {})
            brain_results = hybrid.get("results", [])
            vec_status = hybrid.get("vector_status", {})
            entry = {
                "brain": name,
                "path": str(brain_path),
                "vector_coverage": vec_status.get("coverage_pct", 0),
                "results_count": len(brain_results),
                "results": [{
                    "source_key": r.get("source_key", ""),
                    "summary": r.get("summary", ""),
                    "heading_path": r.get("heading_path", ""),
                    "status": r.get("status", ""),
                    "combined_score": r.get("combined_score", 0),
                    "chunk_text": (r.get("chunk_text") or "")[:300],
                } for r in brain_results[:max_results]],
            }
            answers.append(entry)
        except Exception as e:
            errors.append({"brain": name, "status": "ERROR",
                           "error": str(e)[:200],
                           "trace": traceback.format_exc()[:200]})

    output = {
        "query": query,
        "brains_answered": len(answers),
        "brains_errored": len(errors),
        "answers": answers,
    }
    if errors:
        output["errors"] = errors
    print(json.dumps(output, indent=2, default=str))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
  chmod 644 "$ORACLE_SCRIPT"
}

list_brains() {
  if [ ! -f "$REGISTRY" ]; then
    echo '{"error":"no brain registry found"}'
    return 1
  fi
  python3 -c "
import json
r=json.load(open('$REGISTRY'))
for name, cfg in r['brains'].items():
    print(f'{name}: {cfg[\"purpose\"]}')
    print(f'  path={cfg[\"path\"]} rooms={\", \".join(cfg[\"rooms\"])} stamp={cfg[\"stamp\"][\"model\"]}')
" 2>&1
}

health_check() {
  local err; err=$(mktemp "$FM_HOME/state/.oracle-h-XXXXXX") || return 1
  local rc=0
  python3 -c "
import json, sqlite3
from pathlib import Path
r=json.load(open('$REGISTRY'))
results={}
for name, cfg in r['brains'].items():
    p=cfg['path']
    if not __import__('os').path.exists(p):
        results[name]={'status':'ABSENT'}
        continue
    try:
        con=sqlite3.connect(Path(p).resolve().as_uri() + '?mode=ro', uri=True)
        con.execute('PRAGMA query_only=ON')
        check=con.execute('PRAGMA integrity_check').fetchone()[0]
        con.close()
        results[name]={'status':'ok','integrity':check[:20]}
    except Exception as e:
        results[name]={'status':'ERROR','error':str(e)[:100]}
print(json.dumps({'health':results},indent=2))
" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then cat "$err" >&2; rm -f "$err"; return 1; fi
  rm -f "$err"
}

oracle_query() {
  local query="${1:-}" max="${2:-3}"
  [ -z "$query" ] && { echo '{"error":"query text required"}'; return 2; }
  [ ! -f "$REGISTRY" ] && { echo '{"error":"no brain registry at '"$REGISTRY"'"}'; return 1; }
  ensure_oracle_script
  local err; err=$(mktemp "$FM_HOME/state/.oracle-q-XXXXXX") || return 1
  local rc=0
  # shellcheck disable=SC2097,SC2098 # CROF_PATH is re-exported for the child; both expansions read the shell's value.
  (cd "$CROF_PATH" && HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    CROF_PATH="$CROF_PATH" PYTHONNOUSERSITE=1 PYTHONPATH="$CROF_PATH" \
    /usr/bin/arch -arm64 "$CROF_VENV" "$ORACLE_SCRIPT" "$REGISTRY" "$query" "$max") 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$err" >&2
    rm -f "$err"
    echo '{"error":"oracle query failed"}'
    return 1
  fi
  rm -f "$err"
}

case "${1:-}" in
  query) shift; oracle_query "$@" ;;
  list) list_brains ;;
  health) health_check ;;
  *) usage ;;
esac
