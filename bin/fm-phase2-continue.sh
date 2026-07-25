#!/usr/bin/env bash
# Advance Phase 2 after a crewmate finishes: ledger → schedule → spawn next.
# Usage:
#   fm-phase2-continue.sh [--programme <id>] [--dry-run] [--once]
#   fm-phase2-continue.sh --task <id>   # process one done task then schedule
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${PATH}"

# Single-flight: overnight daemon + manual continue must not race spawns.
mkdir -p "$FM_HOME/state"
exec 9>"$FM_HOME/state/.phase2-continue.lock"
if ! flock -n 9; then
  echo "continue: another continue is running; exiting"
  exit 0
fi

REG="$FM_HOME/bin/fm-phase2-registry.sh"
CFG="$FM_HOME/phase2/config/concurrency.json"
PROG_CFG_DIR="$FM_HOME/phase2/config/programmes"
SEEN_DIR="$FM_HOME/state/phase2-continue-seen"
mkdir -p "$SEEN_DIR"

PROGRAMME=""
DRY=0
ONCE=0
ONLY_TASK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --programme) PROGRAMME="${2:?}"; shift 2 ;;
    --task) ONLY_TASK="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --once) ONCE=1; shift ;;
    -h|--help)
      sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROGRAMME" ]; then
  PROGRAMME=$("$REG" snapshot 2>/dev/null | python3 -c "import json,sys; p=json.load(sys.stdin).get('programme') or {}; print(p.get('id') or '')" || true)
fi

resolve_project() {
  local tid=$1
  local prog=${2:-}
  python3 - "$FM_HOME" "$tid" "$prog" <<'PY'
import json, sys
from pathlib import Path
fm, tid, prog = sys.argv[1:4]
# 1) meta project=
meta = Path(fm) / "state" / f"{tid}.meta"
if meta.exists():
    for line in meta.read_text().splitlines():
        if line.startswith("project="):
            print(line.split("=", 1)[1].strip())
            raise SystemExit(0)
# 2) programme config
cfg_dir = Path(fm) / "phase2" / "config" / "programmes"
candidates = []
if prog:
    candidates.append(cfg_dir / f"{prog}.json")
candidates.extend(sorted(cfg_dir.glob("*.json")))
for path in candidates:
    if not path.exists():
        continue
    data = json.loads(path.read_text())
    default = data.get("project") or data.get("project_dir") or ""
    for t in data.get("tasks") or []:
        if t.get("id") == tid:
            print(t.get("project") or default)
            raise SystemExit(0)
    if default and (not prog or data.get("id") == prog):
        print(default)
        raise SystemExit(0)
print("")
PY
}

mark_done_processed() {
  local tid=$1 line_hash=$2
  printf '%s\n' "$line_hash" > "$SEEN_DIR/$tid.done"
}

already_processed() {
  local tid=$1 line_hash=$2
  [ -f "$SEEN_DIR/$tid.done" ] && [ "$(cat "$SEEN_DIR/$tid.done")" = "$line_hash" ]
}

process_done_status() {
  local tid=$1
  local status_file="$FM_HOME/state/$tid.status"
  [ -f "$status_file" ] || return 0
  local line
  line=$(grep '^done:' "$status_file" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 0
  local h
  h=$(printf '%s' "$line" | sha256sum | awk '{print $1}')
  if already_processed "$tid" "$h"; then
    return 0
  fi
  echo "continue: processing done for $tid"

  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would advance $tid and schedule"
    return 0
  fi

  # Best-effort advance through validation states when RESULT exists
  local pkt="$FM_HOME/data/$tid/packet"
  if [ -f "$pkt/RESULT.md" ] && grep -qiE 'Status:\s*(DONE|COMPLETE|PASS)' "$pkt/RESULT.md"; then
    "$REG" transition "$tid" awaiting_tests --reason "done_signal" 2>/dev/null || true
    "$REG" transition "$tid" awaiting_review --reason "done_signal" 2>/dev/null || true
    if [ -f "$pkt/REVIEW.md" ] && grep -q '| AC-' "$pkt/REVIEW.md" && ! grep -q 'NOT TESTED\|FAIL' "$pkt/REVIEW.md"; then
      "$REG" transition "$tid" awaiting_ci --reason "review_present" 2>/dev/null || true
    fi
  fi

  # Record commit from worktree if possible
  local wt
  wt=$(awk -F= '/^worktree=/{print $2; exit}' "$FM_HOME/state/$tid.meta" 2>/dev/null || true)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    local sha
    sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
    [ -n "$sha" ] && "$REG" set "$tid" --field "commit_sha=$sha" 2>/dev/null || true
  fi

  "$FM_HOME/bin/fm-phase2-event.sh" worker_finished --task "$tid" --dedupe "done-$h" \
    --payload "{\"line\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$line")}" >/dev/null || true

  mark_done_processed "$tid" "$h"
}

spawn_assigned() {
  local tid=$1
  local meta="$FM_HOME/state/$tid.meta"
  if [ -f "$meta" ] && grep -q '^window=' "$meta"; then
    echo "continue: $tid already has window"
    return 0
  fi
  local project harness model effort
  project=$(resolve_project "$tid" "$PROGRAMME")
  [ -n "$project" ] || project="projects/northscapes-gallery"
  harness=cursor
  model=auto
  effort=xhigh
  if [ -f "$PROG_CFG_DIR/${PROGRAMME}.json" ]; then
    eval "$(python3 - "$PROG_CFG_DIR/${PROGRAMME}.json" "$tid" <<'PY'
import json,sys,shlex
data=json.load(open(sys.argv[1]))
tid=sys.argv[2]
h=data.get("harness","cursor"); m=data.get("model","auto"); e=data.get("effort","xhigh")
for t in data.get("tasks") or []:
  if t.get("id")==tid:
    h=t.get("harness",h); m=t.get("model",m); e=t.get("effort",e)
    break
print(f"harness={shlex.quote(h)}")
print(f"model={shlex.quote(m)}")
print(f"effort={shlex.quote(e)}")
PY
)"
  fi

  if [ ! -f "$FM_HOME/data/$tid/brief.md" ]; then
    local repo_name
    repo_name=$(basename "$project")
    "$FM_HOME/bin/fm-brief.sh" "$tid" "$repo_name" || true
    # Inject packet objective into brief if still placeholder
    if [ -f "$FM_HOME/data/$tid/packet/TASK.md" ] && grep -q '{TASK}' "$FM_HOME/data/$tid/brief.md" 2>/dev/null; then
      python3 - "$FM_HOME/data/$tid/brief.md" "$FM_HOME/data/$tid/packet/TASK.md" <<'PY'
from pathlib import Path
import sys
brief, task = Path(sys.argv[1]), Path(sys.argv[2])
text = brief.read_text()
body = "# Task\n" + task.read_text().strip() + "\n\nCommit, fill packet/RESULT.md, append status done: when finished.\n"
if "{TASK}" in text:
    brief.write_text(text.replace("{TASK}", body))
PY
    fi
  fi

  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would spawn $tid -> $project harness=$harness model=$model"
    return 0
  fi

  echo "continue: spawning $tid ($project) harness=$harness model=$model"
  set +e
  "$FM_HOME/bin/fm-spawn.sh" "$tid" "$project" --harness "$harness" --model "$model" --effort "$effort"
  spawn_rc=$?
  set -e
  meta="$FM_HOME/state/$tid.meta"
  if [ -f "$meta" ] && grep -q '^window=' "$meta"; then
    "$REG" transition "$tid" implementing --reason "auto_spawned" 2>/dev/null || true
    # clear prior false spawn_failed
    "$REG" set "$tid" --field "blocker=" --field "next_action=" 2>/dev/null || true
    "$FM_HOME/bin/fm-phase2-heartbeat.sh" beat "$tid" >/dev/null 2>&1 || true
    local wt
    wt=$(awk -F= '/^worktree=/{print $2; exit}' "$meta" 2>/dev/null || true)
    [ -n "$wt" ] && "$REG" set "$tid" --field "worktree=$wt" 2>/dev/null || true
    echo "continue: spawn ok rc=$spawn_rc window=$(grep '^window=' "$meta")"
  else
    echo "continue: spawn failed for $tid rc=$spawn_rc" >&2
    "$REG" transition "$tid" blocked --reason "spawn_failed" --field "blocker=spawn_failed" 2>/dev/null || true
    return 1
  fi
}

# --- main ---
"$REG" init >/dev/null

if [ -n "$ONLY_TASK" ]; then
  process_done_status "$ONLY_TASK"
else
  # All known tasks + any status files
  mapfile -t STATUS_IDS < <(find "$FM_HOME/state" -maxdepth 1 -name '*.status' -printf '%f\n' 2>/dev/null | sed 's/\.status$//' || true)
  for tid in "${STATUS_IDS[@]}"; do
    process_done_status "$tid" || true
  done
fi

"$FM_HOME/scripts/firstmate-ledger-update.sh" >/dev/null 2>&1 || true

SCHED_ARGS=(--programme "$PROGRAMME")
[ -z "$PROGRAMME" ] && SCHED_ARGS=()
if [ "$DRY" -eq 1 ]; then
  "$FM_HOME/bin/fm-phase2-schedule.sh" "${SCHED_ARGS[@]}" --dry-run || true
else
  "$FM_HOME/bin/fm-phase2-schedule.sh" "${SCHED_ARGS[@]}" || true
fi

# Spawn newly assigned tasks
mapfile -t ASSIGNED < <("$REG" snapshot ${PROGRAMME:+--programme "$PROGRAMME"} | python3 -c "
import json,sys
s=json.load(sys.stdin)
for t in s.get('tasks') or []:
  if t.get('status')=='assigned':
    print(t['id'])
")

for tid in "${ASSIGNED[@]}"; do
  spawn_assigned "$tid" || true
  [ "$ONCE" -eq 1 ] && break
done

# Re-arm watcher (best effort; do not block forever)
if [ "$DRY" -eq 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 "$FM_HOME/bin/fm-watch-arm.sh" >/dev/null 2>&1 || true
  fi
fi

echo "continue: complete programme=${PROGRAMME:-any}"
