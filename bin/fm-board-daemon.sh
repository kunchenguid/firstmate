#!/usr/bin/env bash
# Board-driven automation daemon: watch the "Hadrien FirstMate" Azure board and
# auto-launch the right agent when the captain drags a card between columns.
# Design + rationale: docs/board-automation/README.md (and the source spec the
# captain approved). This is a POLL loop, not a webhook - no public tunnel.
#
# CPU-safety is a hard requirement (this must never slow the captain's Mac):
#   - one WIQL board query + one (chunked) batch detail fetch per cycle, nothing
#     else on an idle board; then sleep FM_BOARD_POLL_SECS (default 120s), no busy-wait.
#   - the process re-nices itself to +19 and, where available (Linux), lowers
#     its IO priority with ionice. Idle cost is effectively zero.
#   - a portable singleton lock (state/.board-daemon.lock, the same primitive the
#     watcher uses) so only one instance runs per home.
#
# Transitions acted on (column change vs the cached value, never first-sight):
#   -> "Ready to plan"                        spawn a PLANNING scout
#   -> "In Progress" (from Planned/Proposed)  spawn an IMPLEMENTATION ship crew
#   everything else (Proposed/Planned/PR/Done) is observed, not spawned.
#
# Guardrails: seed markers without spawning on first sight (no mass-spawn on
# start/restart); dedupe one agent per card+stage; concurrency cap
# (FM_BOARD_MAX_INFLIGHT); hourly runaway cap (FM_BOARD_MAX_PER_HOUR); repo
# resolution that flags-and-leaves rather than guessing; every decision logged.
#
# Kill switch / config:
#   state/.board-daemon.off present -> the loop idles (polls nothing, spawns
#     nothing) until the file is removed. This is the safe "stop" state.
#   FM_BOARD_AUTOSPAWN=0 (or off/false/no) -> poll + detect + log, but SUPPRESS
#     spawns and do not consume the transition, so re-enabling acts on it.
#   FM_BOARD_DRY_RUN=1 -> never spawn or write to Azure; log "[DRY] would ..."
#     and advance markers so the loop's decisions can be exercised offline.
#   FM_BOARD_FIXTURE=<file> -> read cards from a batch-workitems JSON fixture
#     instead of querying Azure (for tests). Implies read-only board access.
#
# Modes:
#   fm-board-daemon.sh            run the poll loop (default; usually via fm-board-arm.sh)
#   fm-board-daemon.sh --once     run exactly one cycle, then exit
#   fm-board-daemon.sh --seed     seed seen-markers for all current cards, no spawn, exit
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-board-lib.sh
. "$SCRIPT_DIR/fm-board-lib.sh"

DAEMON_PATH="$SCRIPT_DIR/fm-board-daemon.sh"
SPAWN="$SCRIPT_DIR/fm-spawn.sh"
LOCK="$STATE/.board-daemon.lock"
BEAT="$STATE/.board-daemon-beat"
LOG="$STATE/.board-daemon.log"
KILL_SWITCH="$STATE/.board-daemon.off"
SPAWN_LOG="$STATE/.board-spawn-log"       # one epoch per spawn, for the hourly cap

POLL_SECS="${FM_BOARD_POLL_SECS:-120}"
MAX_INFLIGHT="${FM_BOARD_MAX_INFLIGHT:-4}"
MAX_PER_HOUR="${FM_BOARD_MAX_PER_HOUR:-12}"
LOG_MAX_BYTES="${FM_BOARD_LOG_MAX_BYTES:-1048576}"

# Trigger columns and the milestone columns agents move cards to.
COL_READY="${FM_BOARD_COL_READY:-Ready to plan}"
COL_PLANNED="${FM_BOARD_COL_PLANNED:-Planned}"
COL_INPROGRESS="${FM_BOARD_COL_INPROGRESS:-In Progress}"
COL_PROPOSED="${FM_BOARD_COL_PROPOSED:-Proposed}"
COL_PR="${FM_BOARD_COL_PR:-PR}"

# Templates: tracked canonical copies ship under docs/board-automation/; a local
# data/_templates/ copy (gitignored) overrides them when the captain customizes.
TPL_DIR_TRACKED="$FM_ROOT/docs/board-automation"
TPL_DIR_LOCAL="$DATA/_templates"

is_falsey() { case "$1" in 0|off|OFF|no|NO|false|FALSE|"") return 0 ;; *) return 1 ;; esac; }

autospawn_on() { ! is_falsey "${FM_BOARD_AUTOSPAWN:-1}"; }
dry_run() { [ "${FM_BOARD_DRY_RUN:-0}" = 1 ]; }

now() { date +%s; }

log() {
  local msg=$1 sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$msg" >> "$LOG" 2>/dev/null || true
  # Echo to stderr in foreground modes (--once/--seed) so a manual run is visible.
  [ "${FM_BOARD_FOREGROUND:-0}" = 1 ] && printf '%s\n' "$msg" >&2
  sz=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$LOG_MAX_BYTES" ]; then
    tail -n 4000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
    rm -f "$LOG.tmp" 2>/dev/null || true
  fi
}

# Lower our scheduling + IO priority so a poll can never contend with the
# captain's foreground work. renice to +19 (allowed unprivileged, since it only
# lowers priority); ionice only exists on Linux.
self_deprioritize() {
  renice 19 "$$" >/dev/null 2>&1 || true
  command -v ionice >/dev/null 2>&1 && ionice -c 3 -p "$$" >/dev/null 2>&1 || true
}

# --- marker helpers -------------------------------------------------------

seen_file()      { printf '%s/.board-seen-%s' "$STATE" "$1"; }
spawned_marker() { printf '%s/.board-spawned-%s-%s' "$STATE" "$1" "$2"; }   # <wid> <stage>
unresolved_marker() { printf '%s/.board-unresolved-%s-%s' "$STATE" "$1" "$2"; }

task_id() { printf 'board-%s-%s' "$1" "$2"; }   # <wid> <stage>

# In-flight board tasks = board-*.meta files (fm-spawn writes meta, teardown
# removes it). Used for the concurrency cap and, per-task, for dedupe.
inflight_count() {
  local n=0 m
  for m in "$STATE"/board-*.meta; do [ -e "$m" ] && n=$((n + 1)); done
  echo "$n"
}

# Spawns in the trailing hour, from the append-only spawn log.
spawns_last_hour() {
  [ -f "$SPAWN_LOG" ] || { echo 0; return; }
  local cutoff n=0 ts
  cutoff=$(( $(now) - 3600 ))
  while IFS= read -r ts; do
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    [ "$ts" -ge "$cutoff" ] && n=$((n + 1))
  done < "$SPAWN_LOG"
  echo "$n"
}

record_spawn_ts() { printf '%s\n' "$(now)" >> "$SPAWN_LOG" 2>/dev/null || true; }

# --- repo resolution ------------------------------------------------------
# An explicit `repo:<name>` tag/title token wins; else the card's lane maps to a
# fleet project via config/board-lane-map (KEY = project, one "Lane = project"
# per line, '#' comments) merged over a small built-in default. A resolved name
# must correspond to an actual clone under projects/ or it is treated as
# unresolvable - the daemon never guesses.

lane_map_lookup() {   # <lane>  -> project name on stdout, or nothing
  local lane=$1 file="$CONFIG/board-lane-map" k v
  # Built-in defaults for the lanes we can map with confidence.
  case "$lane" in
    "AI Knowledge Base") v="ai-knowledge-base" ;;
    "Greenhouse / IT Screener") v="greenhouse-auto" ;;
    *) v="" ;;
  esac
  # A config file entry overrides / extends the defaults.
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      k=${line%%=*}; k=$(printf '%s' "$k" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
      [ "$k" = "$lane" ] || continue
      v=${line#*=}; v=$(printf '%s' "$v" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
      break
    done < "$file"
  fi
  [ -n "$v" ] && printf '%s' "$v"
}

resolve_repo() {   # <lane> <tags> <title>  -> project name on stdout, or return 1
  local lane=$1 tags=$2 title=$3 cand=""
  # Explicit repo: tag anywhere in tags or title, e.g. "repo:ai-knowledge-base".
  cand=$(printf '%s %s' "$tags" "$title" \
    | grep -oiE 'repo:[A-Za-z0-9._-]+' | head -1 | cut -d: -f2 || true)
  [ -n "$cand" ] || cand=$(lane_map_lookup "$lane")
  [ -n "$cand" ] || return 1
  [ -d "$PROJECTS/$cand" ] || return 1
  printf '%s' "$cand"
}

# --- brief templating -----------------------------------------------------

template_path() {   # <stage>  -> plan|impl template, local override first
  local stage=$1 base
  case "$stage" in
    plan) base="board-plan-brief.md" ;;
    impl) base="board-impl-brief.md" ;;
    *) return 1 ;;
  esac
  if [ -f "$TPL_DIR_LOCAL/$base" ]; then printf '%s' "$TPL_DIR_LOCAL/$base"
  elif [ -f "$TPL_DIR_TRACKED/$base" ]; then printf '%s' "$TPL_DIR_TRACKED/$base"
  else return 1; fi
}

write_brief() {   # <task-id> <wid> <stage> <repo>
  local tid=$1 wid=$2 stage=$3 repo=$4 tpl dest
  tpl=$(template_path "$stage") || return 1
  dest="$DATA/$tid/brief.md"
  mkdir -p "$DATA/$tid"
  FM_T_WID="$wid" FM_T_TASK_ID="$tid" FM_T_REPO="$repo" FM_T_STAGE="$stage" \
  FM_T_ORG_URL="$FM_BOARD_ORG_URL" FM_T_API="$FM_BOARD_API_VERSION" \
  FM_T_COLFIELD="$FM_BOARD_COLUMN_FIELD" FM_T_AREA="$FM_BOARD_AREA_PATH" \
  FM_T_PLANNED="$COL_PLANNED" FM_T_PR="$COL_PR" \
  python3 - "$tpl" "$dest" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
repl = {
    "{{WID}}": os.environ["FM_T_WID"],
    "{{TASK_ID}}": os.environ["FM_T_TASK_ID"],
    "{{REPO}}": os.environ["FM_T_REPO"],
    "{{STAGE}}": os.environ["FM_T_STAGE"],
    "{{ORG_URL}}": os.environ["FM_T_ORG_URL"],
    "{{API_VERSION}}": os.environ["FM_T_API"],
    "{{COLUMN_FIELD}}": os.environ["FM_T_COLFIELD"],
    "{{AREA_PATH}}": os.environ["FM_T_AREA"],
    "{{PLANNED_COLUMN}}": os.environ["FM_T_PLANNED"],
    "{{PR_COLUMN}}": os.environ["FM_T_PR"],
}
with open(src) as fh:
    text = fh.read()
for k, v in repl.items():
    text = text.replace(k, v)
with open(dst, "w") as fh:
    fh.write(text)
PY
}

# --- backlog recording ----------------------------------------------------
# Best-effort: prefer tasks-axi when the default backend is active and
# compatible, else append a bullet under "## In flight" in data/backlog.md.
# Never fatal - a bookkeeping hiccup must not break the loop.
record_backlog() {   # <task-id> <desc> <kind> <repo>
  local tid=$1 desc=$2 kind=$3 repo=$4 backend
  backend=$(cat "$CONFIG/backlog-backend" 2>/dev/null || true)
  if [ "$backend" != manual ] && command -v tasks-axi >/dev/null 2>&1; then
    ( cd "$FM_HOME" && tasks-axi add "$tid" "$desc" --kind "$kind" --repo "$repo" --start ) >/dev/null 2>&1 && return 0
  fi
  local bl="$DATA/backlog.md"
  [ -f "$bl" ] || return 0
  FM_BL_LINE="- [ ] $tid - $desc (repo: $repo, since $(date +%Y-%m-%d))" \
  python3 - "$bl" <<'PY'
import os, sys
path = sys.argv[1]
line = os.environ["FM_BL_LINE"]
with open(path) as fh:
    lines = fh.read().splitlines()
out, done = [], False
for l in lines:
    out.append(l)
    if not done and l.strip().lower().startswith("## in flight"):
        out.append(line)
        done = True
if not done:
    out.append("")
    out.append("## In flight")
    out.append(line)
with open(path, "w") as fh:
    fh.write("\n".join(out) + "\n")
PY
}

# --- the spawn decision ---------------------------------------------------
# Handles one detected trigger transition. Returns via the shared RESULT var:
#   spawned | deduped | capped | runaway | unresolved | suppressed | dry | error
# The caller advances the seen-marker only for terminal results (spawned, dry,
# deduped, suppressed-consume). "capped"/"runaway"/"unresolved" deliberately do
# NOT consume the transition so it is retried once conditions clear.
RESULT=""
handle_transition() {   # <wid> <stage> <lane> <tags> <title>
  local wid=$1 stage=$2 lane=$3 tags=$4 title=$5
  local tid repo kind
  tid=$(task_id "$wid" "$stage")
  [ "$stage" = plan ] && kind=scout || kind=ship

  # Dedupe: one agent per card+stage. Live meta OR a persisted spawned-marker.
  if [ -e "$STATE/$tid.meta" ] || [ -e "$(spawned_marker "$wid" "$stage")" ]; then
    log "deduped: #$wid $stage already spawned (task $tid)"
    RESULT=deduped; return 0
  fi

  # Suppressed by the autospawn flag: log, do NOT consume (re-enable acts on it).
  if ! autospawn_on; then
    log "suppressed: #$wid $stage (FM_BOARD_AUTOSPAWN off)"
    RESULT=suppressed; return 0
  fi

  # Repo resolution: flag-and-leave, never guess.
  if ! repo=$(resolve_repo "$lane" "$tags" "$title"); then
    if [ ! -e "$(unresolved_marker "$wid" "$stage")" ]; then
      log "UNRESOLVED: #$wid $stage - no fleet project for lane='$lane' (add a config/board-lane-map entry or a 'repo:<name>' tag). Leaving the card; will retry."
      : > "$(unresolved_marker "$wid" "$stage")" 2>/dev/null || true
    fi
    RESULT=unresolved; return 0
  fi

  # Concurrency cap: queue (retry next cycle) without consuming the transition.
  local inflight; inflight=$(inflight_count)
  if [ "$inflight" -ge "$MAX_INFLIGHT" ]; then
    log "at cap ($inflight/$MAX_INFLIGHT): queued #$wid $stage; will retry"
    RESULT=capped; return 0
  fi

  # Hourly runaway cap: refuse this cycle, do NOT consume; the window rolls off.
  local perhour; perhour=$(spawns_last_hour)
  if [ "$perhour" -ge "$MAX_PER_HOUR" ]; then
    log "RUNAWAY GUARD: $perhour spawns in the last hour >= $MAX_PER_HOUR; refusing #$wid $stage this cycle"
    RESULT=runaway; return 0
  fi

  # Build the brief.
  if ! write_brief "$tid" "$wid" "$stage" "$repo"; then
    log "ERROR: #$wid $stage - could not write brief from template; leaving card"
    RESULT=error; return 0
  fi

  if dry_run; then
    log "[DRY] would spawn $kind $tid for #$wid in projects/$repo"
    : > "$(spawned_marker "$wid" "$stage")" 2>/dev/null || true
    record_spawn_ts
    rm -f "$(unresolved_marker "$wid" "$stage")" 2>/dev/null || true
    RESULT=dry; return 0
  fi

  # Real spawn via the standard machinery.
  local spawn_args=("$tid" "projects/$repo")
  [ "$stage" = plan ] && spawn_args+=(--scout)
  [ -n "${FM_BOARD_HARNESS:-}" ] && spawn_args+=(--harness "$FM_BOARD_HARNESS")
  if ( cd "$FM_HOME" && "$SPAWN" "${spawn_args[@]}" ) >> "$LOG" 2>&1; then
    : > "$(spawned_marker "$wid" "$stage")" 2>/dev/null || true
    record_spawn_ts
    rm -f "$(unresolved_marker "$wid" "$stage")" 2>/dev/null || true
    record_backlog "$tid" "board #$wid $stage: $(printf '%s' "$title" | cut -c1-60)" "$kind" "$repo"
    fm_board_add_comment "$wid" \
      "firstmate auto-launched a $stage agent (task $tid) in $repo." 2>/dev/null || true
    log "SPAWNED $kind $tid for #$wid in projects/$repo"
    RESULT=spawned; return 0
  fi
  log "ERROR: spawn failed for #$wid $stage (task $tid); leaving card, will retry"
  RESULT=error; return 0
}

# Classify a column transition into a spawn stage, or empty for no spawn.
stage_for_transition() {   # <prev-col> <new-col>
  local prev=$1 cur=$2
  if [ "$cur" = "$COL_READY" ]; then echo plan; return; fi
  if [ "$cur" = "$COL_INPROGRESS" ] && { [ "$prev" = "$COL_PLANNED" ] || [ "$prev" = "$COL_PROPOSED" ]; }; then
    echo impl; return
  fi
  echo ""
}

# --- one poll cycle -------------------------------------------------------
# seed_only=1 seeds markers for all current cards without acting on transitions.
run_cycle() {
  local seed_only=${1:-0}
  local cards
  if [ -n "${FM_BOARD_FIXTURE:-}" ]; then
    [ -f "$FM_BOARD_FIXTURE" ] || { log "ERROR: FM_BOARD_FIXTURE not found: $FM_BOARD_FIXTURE"; return 1; }
    cards=$(fm_board_parse_cards < "$FM_BOARD_FIXTURE") || { log "ERROR: could not parse fixture"; return 1; }
  else
    if ! cards=$(fm_board_list_cards); then
      log "WARN: board query failed (transient); skipping cycle"
      return 1
    fi
  fi

  local id state col lane tags title prev stage
  while IFS=$(printf '\t') read -r id state col lane tags title; do
    [ -n "$id" ] || continue
    local sf; sf=$(seen_file "$id")
    # First sight of a card: seed the cache, never spawn (prevents mass-spawn on
    # first run / restart / a newly created card).
    if [ ! -e "$sf" ]; then
      printf '%s' "$col" > "$sf"
      [ "$seed_only" = 1 ] && log "seeded #$id at column '$col'"
      continue
    fi
    [ "$seed_only" = 1 ] && { printf '%s' "$col" > "$sf"; continue; }

    prev=$(cat "$sf" 2>/dev/null || true)
    [ "$col" = "$prev" ] && continue    # no change

    stage=$(stage_for_transition "$prev" "$col")
    if [ -z "$stage" ]; then
      printf '%s' "$col" > "$sf"        # consume non-trigger transition
      log "transition #$id '$prev' -> '$col' (no spawn)"
      continue
    fi

    log "transition #$id '$prev' -> '$col' => $stage"
    handle_transition "$id" "$stage" "$lane" "$tags" "$title"
    case "$RESULT" in
      spawned|dry|deduped)
        printf '%s' "$col" > "$sf" ;;    # transition handled: consume it
      *)
        : ;;                             # capped/runaway/unresolved/suppressed/error: retry later
    esac
  done <<EOF
$cards
EOF
  return 0
}

# --- entrypoints ----------------------------------------------------------

# Source the PAT for board access unless a fixture makes the board read moot.
load_pat() {
  if [ -z "${ADO_PAT_FULL_ACCESS:-}" ] && [ -f "$HOME/.env" ]; then
    set -a
    # shellcheck source=/dev/null disable=SC1091  # external runtime file, not in the repo
    . "$HOME/.env"
    set +a
  fi
}

# Loop mode: singleton lock, then poll forever.
run_loop() {
  if ! fm_lock_try_acquire "$LOCK"; then
    if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      echo "board-daemon: already running pid $FM_LOCK_HELD_PID" >&2
    else
      echo "board-daemon: already running" >&2
    fi
    exit 0
  fi
  trap 'fm_lock_release "$LOCK"' EXIT
  DAEMON_PID=${BASHPID:-$$}
  printf '%s\n' "$FM_HOME" > "$LOCK/fm-home" 2>/dev/null || true
  printf '%s\n' "$DAEMON_PATH" > "$LOCK/daemon-path" 2>/dev/null || true
  fm_pid_identity "$DAEMON_PID" > "$LOCK/pid-identity" 2>/dev/null || true

  load_pat
  self_deprioritize
  log "board-daemon started pid=$DAEMON_PID poll=${POLL_SECS}s cap=$MAX_INFLIGHT/hr$MAX_PER_HOUR autospawn=$(autospawn_on && echo on || echo off)$(dry_run && echo ' DRY' || true)"

  while :; do
    # Self-eviction if a second daemon took the singleton (mirrors the watcher).
    if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" != "$DAEMON_PID" ]; then
      exit 0
    fi
    touch "$BEAT"
    if [ -e "$KILL_SWITCH" ]; then
      log "idle: kill switch present"
    else
      run_cycle 0 || true
    fi
    sleep "$POLL_SECS"
  done
}

main() {
  case "${1:-}" in
    --seed)
      FM_BOARD_FOREGROUND=1
      load_pat
      log "seed: seeding seen-markers for all current cards (no spawn)"
      run_cycle 1
      exit 0
      ;;
    --once)
      FM_BOARD_FOREGROUND=1
      load_pat
      self_deprioritize
      if [ -e "$KILL_SWITCH" ]; then log "idle: kill switch present ($KILL_SWITCH)"; exit 0; fi
      touch "$BEAT"
      run_cycle 0
      exit 0
      ;;
    '') run_loop ;;
    *) echo "usage: $(basename "$0") [--once|--seed]" >&2; exit 2 ;;
  esac
}

# Run the entrypoint only on direct execution; a test can source this file to
# exercise the pure functions without launching the loop.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
