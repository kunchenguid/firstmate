#!/usr/bin/env bash
# Rollout embargo: a separate control that forbids resuming parked GLX
# initiatives during the Firstmate results-first cutover.
# Usage:
#   fm-rollout-embargo.sh set-generation <generation-id>
#   fm-rollout-embargo.sh permit <task-id>
#   fm-rollout-embargo.sh forbid <task-id>
#   fm-rollout-embargo.sh status
#
# The generation record is write-once within a generation. Permits/forbids are
# appended to the active generation. The default cutover policy permits only the
# Firstmate primary, its linked Dotfiles support, and one later prequalified
# canary.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
EMBARGO_DIR="$FM_HOME/state/.rollout-embargo"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
CMD=$1
shift

mkdir -p "$EMBARGO_DIR"
chmod 700 "$EMBARGO_DIR"

active_generation_file() { printf '%s/active-generation\n' "$EMBARGO_DIR"; }
embargo_file() { printf '%s/%s.json\n' "$EMBARGO_DIR" "${1:-active}"; }

atomic_write() {
  local dst=$1 content=$2
  local tmp
  tmp=$(mktemp "$dst.tmp.XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dst"
}

generation_id() {
  local f
  f=$(active_generation_file)
  [ -f "$f" ] || return 1
  cat "$f"
}

current_embargo_file() {
  local gen
  gen=$(generation_id) || { echo "error: no active generation" >&2; return 1; }
  embargo_file "$gen"
}

read_embargo() {
  local f
  f=$(current_embargo_file) || return 1
  [ -f "$f" ] || { printf '{}\n'; return 0; }
  cat "$f"
}

do_set_generation() {
  local gen=$1
  [ -n "$gen" ] || { echo "error: generation id required" >&2; exit 2; }
  local f
  f=$(active_generation_file)
  if [ -f "$f" ]; then
    local current
    current=$(cat "$f")
    [ "$current" = "$gen" ] || { echo "error: generation already set to $current" >&2; exit 1; }
    echo "generation already $gen"
    return 0
  fi
  printf '%s\n' "$gen" > "$f"
  chmod 600 "$f"
  # Initialize an empty embargo record for the generation.
  atomic_write "$(embargo_file "$gen")" '{"schemaVersion":"firstmate.rollout-embargo.v1","generation":"'"$gen"'","permitted":[],"forbidden":[]}'
  echo "set generation $gen"
}

do_permit() {
  local id=$1
  [ -n "$id" ] || { echo "error: task id required" >&2; exit 2; }
  local f content
  f=$(current_embargo_file) || return 1
  content=$(python3 - "$id" "$f" <<'PYEOF'
import json, sys
id, path = sys.argv[1:3]
with open(path) as fh:
    doc = json.load(fh)
if id not in doc.get("permitted", []):
    doc.setdefault("permitted", []).append(id)
print(json.dumps(doc))
PYEOF
)
  atomic_write "$f" "$content"
  echo "permitted $id"
}

do_forbid() {
  local id=$1
  [ -n "$id" ] || { echo "error: task id required" >&2; exit 2; }
  local f content
  f=$(current_embargo_file) || return 1
  content=$(python3 - "$id" "$f" <<'PYEOF'
import json, sys
id, path = sys.argv[1:3]
with open(path) as fh:
    doc = json.load(fh)
if id not in doc.get("forbidden", []):
    doc.setdefault("forbidden", []).append(id)
print(json.dumps(doc))
PYEOF
)
  atomic_write "$f" "$content"
  echo "forbid $id"
}

do_status() {
  local f
  f=$(current_embargo_file) || return 1
  python3 - "$f" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    doc = json.load(fh)
print(f"generation: {doc.get('generation', '')}")
print(f"permitted: {', '.join(doc.get('permitted', []))}")
print(f"forbidden: {', '.join(doc.get('forbidden', []))}")
PYEOF
}

check_permitted() {
  local id=$1
  local f
  f=$(current_embargo_file) || return 2
  python3 - "$id" "$f" <<'PYEOF'
import json, sys
id, path = sys.argv[1:3]
with open(path) as fh:
    doc = json.load(fh)
if id in doc.get("permitted", []):
    sys.exit(0)
print(f"error: {id} is not permitted by generation {doc.get('generation','')}", file=sys.stderr)
sys.exit(1)
PYEOF
}

case "$CMD" in
  set-generation)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    do_set_generation "$1"
    ;;
  permit)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    do_permit "$1"
    ;;
  forbid)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    do_forbid "$1"
    ;;
  status)
    do_status
    ;;
  check)
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    check_permitted "$1"
    ;;
  *)
    echo "error: unknown command $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
