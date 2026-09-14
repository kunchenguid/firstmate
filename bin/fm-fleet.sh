#!/usr/bin/env bash
# fm-fleet.sh - schema-v2 control plane for interchangeable FirstMate managers.
#
# Usage: fm-fleet.sh [--fleet-root <dir>] <command> [args...]
#
# Commands:
#   init | migrate | validate
#   manager register --id <manager-1..4> --home <absolute-home>
#   owner register --secondmate <id> --home <absolute-home>
#                  [--projects a,b] [--domains c,d]
#   start [--managers a,b] | stop <id>|--all | restart <id>
#   status [--json] | attach <id> | ask <id|--all> <text...>
#   route [--secondmate <id>] [--project <name>] [--domain <name>]
#         [--issue <key>]
#   assign --secondmate <id> [--reason <text>]
#   recover --secondmate <id> [--reason <text>]   (failover transfer to a live peer)
#   transfer begin --secondmate <id> --to <manager> [--source-home <home>]
#   transfer recover|rollback --transaction <id>
#   progress <manager> [--note <text>] [--active <count>]
#   set-wait <manager> --on|--off
#   set-blocked <manager> --on|--off [--reason <text>]
#   dep add --owner <secondmate> --from <task> --needs <secondmate> --task <task>
#   dep list | dep done --owner <secondmate> --from <task>
#
# fleet.json owns operational manager rows, exclusive semantic owners, sticky
# assignments, unassigned intake, and SecondMate-keyed dependencies. Assignment
# state is deliberately completion-free. Registry writes hold a kernel flock on
# .fleet.lock, which a crashed holder releases on exit, and publish through a temporary file plus rename.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REGISTRY_BIN="$SCRIPT_DIR/fm-fleet-registry.py"
TRANSFER_BIN="$SCRIPT_DIR/fm-fleet-transfer.py"
MANAGER_BIN="$SCRIPT_DIR/fm-fleet-manager.sh"

FLEET_ROOT="${FM_FLEET_ROOT:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fleet-root) FLEET_ROOT="${2:-}"; shift 2 ;;
    --fleet-root=*) FLEET_ROOT=${1#--fleet-root=}; shift ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ "${#ARGS[@]}" -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

usage() { sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "fm-fleet: $*" >&2; exit 1; }
[ $# -ge 1 ] || { usage >&2; exit 2; }
[ -n "$FLEET_ROOT" ] || { echo "fm-fleet: --fleet-root or FM_FLEET_ROOT is required" >&2; exit 2; }
REG="$FLEET_ROOT/fleet.json"
CMD=$1; shift

need_registry() { [ -f "$REG" ] || die "no registry at $REG; run init first"; }

with_lock() {
  local rc
  exec 9>>"$FLEET_ROOT/.fleet.lock" || die "cannot open $FLEET_ROOT/.fleet.lock"
  python3 -c '
import fcntl, sys, time
for _ in range(50):
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        time.sleep(0.1)
sys.exit(1)' || { exec 9>&-; die "registry is locked by another fleet command"; }
  "$@"; rc=$?
  exec 9>&-
  return "$rc"
}

manager_json() { python3 "$REGISTRY_BIN" "$REG" get manager "$1"; }
manager_home() { manager_json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["home"])'; }

fleet_backend() {
  if [ -n "${FM_FLEET_BACKEND:-}" ]; then printf '%s' "$FM_FLEET_BACKEND"
  elif command -v tmux >/dev/null 2>&1; then printf tmux
  else printf nohup
  fi
}

fleet_backend_check() {
  case "$1" in
    tmux|nohup) return 0 ;;
    herdr)
      [ -z "${FM_FLEET_HERDR_LAUNCH_HOOK:-}" ] || return 0
      command -v herdr >/dev/null 2>&1 || { echo "fm-fleet: herdr CLI is required" >&2; return 1; }
      command -v jq >/dev/null 2>&1 || { echo "fm-fleet: jq is required for Herdr" >&2; return 1; }
      ;;
    *) echo "fm-fleet: unsupported backend $1" >&2; return 1 ;;
  esac
}

fleet_tmux_session() {
  printf 'fm-fleet-%s-%s' "$(printf '%s' "$FLEET_ROOT" | cksum | cut -d' ' -f1)" "$1"
}
fleet_tmux_alive() { tmux has-session -t "$(fleet_tmux_session "$1")" 2>/dev/null; }
fleet_pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
fleet_pid_is_daemon() {
  fleet_pid_alive "${1:-}" || return 1
  ps -o command= -p "$1" 2>/dev/null | grep -q 'fm-fleet-manager\.sh'
}

lock_status() { FM_HOME="$1" "$FM_ROOT/bin/fm-lock.sh" status 2>/dev/null || true; }
reasoning_live() { case "$(lock_status "$1")" in "lock: held by live"*) return 0 ;; *) return 1 ;; esac; }
wait_lock_live() {
  local home=$1 waited=0 limit=${FM_FLEET_START_WAIT_TICKS:-300}
  while [ "$waited" -lt "$limit" ]; do
    reasoning_live "$home" && return 0
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  return 1
}
wait_lock_free() {
  local home=$1 waited=0 limit=${FM_FLEET_STOP_WAIT_TICKS:-150}
  while [ "$waited" -lt "$limit" ]; do
    reasoning_live "$home" || return 0
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  return 1
}

manager_ids() {
  python3 - "$REG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(" ".join(sorted(row["id"] for row in json.load(handle)["managers"])))
PY
}

health_json() {
  local output=$1 mid home lock pid hb marker state authority detail active progress wait blocked
  printf '[]\n' > "$output"
  for mid in $(manager_ids); do
    home=$(manager_home "$mid") || return 1
    lock=$(lock_status "$home")
    pid=""; [ -f "$home/state/.fleet-manager.pid" ] && pid=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
    hb="$home/state/.fleet-heartbeat.json"
    active=0; progress=""; detail=""; wait=false; blocked=false
    [ -f "$home/state/.fleet-wait" ] && wait=true
    [ -f "$home/state/.fleet-blocked" ] && blocked=true
    marker="$home/state/.fleet-progress.json"
    if [ -f "$marker" ]; then
      active=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("active_tasks",0)))' "$marker" 2>/dev/null || echo 0)
      progress=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("last_progress", ""))' "$marker" 2>/dev/null || true)
    fi
    case "$lock" in
      "lock: held by live"*)
        authority=reasoning
        if [ "$wait" = true ]; then state=model-wait
        elif [ "$blocked" = true ]; then state=blocked
        elif [ "$active" -gt 0 ]; then state=running
        else state=idle
        fi
        detail=agent
        ;;
      *)
        authority=none
        if fleet_pid_is_daemon "$pid" && [ -f "$hb" ]; then
          authority=daemon; state=capacity-ready; detail=daemon
        elif [ -f "$hb" ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state_hint", ""))' "$hb" 2>/dev/null || true)" = stopped ]; then
          state=stopped
        elif [ -f "$hb" ] || [ -n "$pid" ]; then state=dead
        else state=ready
        fi
        ;;
    esac
    python3 - "$output" "$mid" "$home" "$state" "$authority" "$active" "$progress" "$detail" <<'PY'
import json, os, sys
path, mid, home, state, authority, active, progress, detail = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    rows = json.load(handle)
rows.append({"manager": mid, "home": home, "state": state, "authority": authority,
             "active": int(active), "last_progress": progress or None, "detail": detail})
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(rows, handle)
os.replace(tmp, path)
PY
  done
}

choose_manager() {
  local health=$1 secondmate=$2 exclude=${3:-}
  python3 - "$REG" "$health" "$secondmate" "$exclude" <<'PY'
import json, sys
with open(sys.argv[1]) as handle: reg=json.load(handle)
with open(sys.argv[2]) as handle: health=json.load(handle)
sm, exclude=sys.argv[3], sys.argv[4]
active={row["secondmate"]:row for row in reg["assignments"] if row.get("state")=="active"}
sticky=active.get(sm)
healthy={row["manager"] for row in health if row["authority"]=="reasoning" and row["state"] in ("idle","running","model-wait")}
if sticky and sticky["manager"] in healthy and sticky["manager"] != exclude:
    print(sticky["manager"]); raise SystemExit
loads={mid:0 for mid in healthy if mid != exclude}
for row in active.values():
    if row["manager"] in loads: loads[row["manager"]]+=1
if loads: print(min(loads, key=lambda mid:(loads[mid],mid)))
PY
}

assignment_current() { python3 "$REGISTRY_BIN" "$REG" get assignment "$1" 2>/dev/null || true; }
assignment_manager() { assignment_current "$1" | python3 -c 'import json,sys; data=sys.stdin.read(); print(json.loads(data).get("manager", "") if data else "")' 2>/dev/null || true; }

assignment_locked() {
  local selected home
  selected=$(choose_manager "$ASSIGN_HEALTH" "$ASSIGN_SECONDMATE")
  [ -n "$selected" ] || { echo "fm-fleet: no healthy reasoning manager remains assignable" >&2; return 1; }
  home=$(manager_home "$selected") || return 1
  reasoning_live "$home" || { echo "fm-fleet: selected manager $selected lost its live reasoning lock" >&2; return 1; }
  python3 "$REGISTRY_BIN" "$REG" assign --secondmate "$ASSIGN_SECONDMATE" --manager "$selected" --reason "$ASSIGN_REASON"
}

do_assign() {
  local secondmate=$1 reason=$2 health selected current current_manager rc
  health=$(mktemp "$FLEET_ROOT/.health.XXXXXX") || return 1
  health_json "$health" || { rm -f "$health"; return 1; }
  current=$(assignment_current "$secondmate")
  if [ -n "$current" ]; then
    current_manager=$(assignment_manager "$secondmate")
    selected=$(choose_manager "$health" "$secondmate")
    rm -f "$health"
    if [ "$selected" = "$current_manager" ]; then printf '%s\n' "$current"; return 0; fi
    echo "fm-fleet: $secondmate remains assigned to unhealthy $current_manager; use recover" >&2
    return 1
  fi
  selected=$(choose_manager "$health" "$secondmate")
  [ -n "$selected" ] || { rm -f "$health"; echo "fm-fleet: no healthy reasoning manager is assignable" >&2; return 1; }
  ASSIGN_SECONDMATE=$secondmate; ASSIGN_REASON=$reason; ASSIGN_HEALTH=$health
  with_lock assignment_locked
  rc=$?
  rm -f "$health"
  return "$rc"
}

start_managers() {
  local ids=$1 backend mid home log epoch pid waited hbpid hbmtime
  backend=$(fleet_backend); fleet_backend_check "$backend" || return 1
  for mid in $ids; do
    home=$(manager_home "$mid") || { echo "fm-fleet: unknown manager $mid" >&2; return 1; }
    mkdir -p "$home/state" "$home/data" "$home/config" || return 1
    if reasoning_live "$home"; then echo "fm-fleet: $mid already has a live reasoning session" >&2; return 1; fi
    pid=""; [ -f "$home/state/.fleet-manager.pid" ] && pid=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
    fleet_pid_is_daemon "$pid" && { echo "fm-fleet: duplicate live authority for $mid" >&2; return 1; }
  done
  for mid in $ids; do
    home=$(manager_home "$mid"); log="$home/state/.fleet-manager.log"; epoch=$(date +%s)
    if [ "$backend" = herdr ]; then
      "$SCRIPT_DIR/fm-fleet-herdr.sh" launch "$FLEET_ROOT" "$mid" "$home" "${FM_FLEET_MANAGER_HARNESS:-codex}" >> "$log" 2>&1 || return 1
      wait_lock_live "$home" || { echo "fm-fleet: $mid did not acquire its reasoning-session lock; see $log" >&2; return 1; }
      echo "started $mid (home $home, interactive Herdr reasoning session)"
      continue
    fi
    if [ "$backend" = tmux ]; then
      fleet_tmux_alive "$mid" && { echo "fm-fleet: duplicate tmux session for $mid" >&2; return 1; }
      tmux new-session -d -s "$(fleet_tmux_session "$mid")" -x 200 -y 50 "$MANAGER_BIN" "$FLEET_ROOT" "$mid" >> "$log" 2>&1 || return 1
    else
      nohup "$MANAGER_BIN" "$FLEET_ROOT" "$mid" >> "$log" 2>&1 < /dev/null &
      disown 2>/dev/null || true
    fi
    waited=0
    while [ "$waited" -lt 150 ]; do
      pid=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
      hbpid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid", ""))' "$home/state/.fleet-heartbeat.json" 2>/dev/null || true)
      hbmtime=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$home/state/.fleet-heartbeat.json" 2>/dev/null || echo 0)
      [ -n "$pid" ] && [ "$pid" = "$hbpid" ] && [ "$hbmtime" -ge "$epoch" ] && fleet_pid_alive "$pid" && break
      sleep 0.1 2>/dev/null || sleep 1; waited=$((waited + 1))
    done
    fleet_pid_is_daemon "$pid" || { echo "fm-fleet: $mid published no live heartbeat" >&2; return 1; }
    echo "started $mid (home $home, capacity daemon $pid)"
  done
}

stop_manager() {
  local mid=$1 home pid target waited=0
  home=$(manager_home "$mid") || { echo "fm-fleet: unknown manager $mid" >&2; return 1; }
  target=$(cat "$home/state/.fleet-herdr-target" 2>/dev/null || true)
  if reasoning_live "$home"; then
    [ -n "$target" ] || { echo "fm-fleet: $mid has a live reasoning session without a fleet Herdr target; refusing" >&2; return 1; }
    "$SCRIPT_DIR/fm-fleet-herdr.sh" close "$FLEET_ROOT" "$mid" "$home" >/dev/null 2>&1 || return 1
    wait_lock_free "$home" || { echo "fm-fleet: $mid reasoning session did not stop" >&2; return 1; }
  fi
  pid=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
  if fleet_pid_is_daemon "$pid"; then
    kill "$pid" 2>/dev/null || true
    while fleet_pid_alive "$pid" && [ "$waited" -lt 50 ]; do sleep 0.1 2>/dev/null || sleep 1; waited=$((waited + 1)); done
    fleet_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$home/state/.fleet-manager.pid" 2>/dev/null || true
  if command -v tmux >/dev/null 2>&1 && fleet_tmux_alive "$mid"; then tmux kill-session -t "$(fleet_tmux_session "$mid")" 2>/dev/null || true; fi
  [ -z "$target" ] || "$SCRIPT_DIR/fm-fleet-herdr.sh" close "$FLEET_ROOT" "$mid" "$home" >/dev/null 2>&1 || true
  if [ -f "$home/state/.fleet-heartbeat.json" ]; then
    python3 - "$home/state/.fleet-heartbeat.json" <<'PY'
import json, os, sys
path=sys.argv[1]
with open(path) as handle: value=json.load(handle)
value["state_hint"]="stopped"
tmp=path+".tmp"
with open(tmp,"w") as handle: json.dump(value,handle)
os.replace(tmp,path)
PY
  fi
  echo "stopped $mid"
}

transfer_hook() {
  local hook_name=$1 home=$2 identity=$3 action=$4 hook
  eval "hook=\${$hook_name:-}"
  if [ -n "$hook" ]; then "$hook" "$home" "$identity" "$action"; return; fi
  case "$action" in
    stop-secondmate) FM_HOME="$home" "$FM_ROOT/bin/fm-control.sh" "$identity" exit ;;
    start-manager) FM_FLEET_BACKEND=herdr "$0" --fleet-root "$FLEET_ROOT" start --managers "$identity" ;;
    start-secondmate) FM_HOME="$home" "$FM_ROOT/bin/fm-spawn.sh" "$identity" --secondmate ;;
  esac
}

destination_ready() {  # <home> <failover>
  if [ "$2" = 1 ]; then reasoning_live "$1"; else ! reasoning_live "$1"; fi
}

transfer_endpoints_check() {  # <source-home> <destination-home> <failover> <tx> [when]
  reasoning_live "$1" && die "source parent home became live${5:-}; recover or rollback $4"
  destination_ready "$2" "$3" || die "destination manager changed session state${5:-}; recover or rollback $4"
}

transfer_activate() {  # <secondmate> <manager> <destination-home> <failover> <tx> <journal>
  if [ "$4" != 1 ]; then
    transfer_hook FM_FLEET_TRANSFER_MANAGER_START_HOOK "$3" "$2" start-manager || die "assignment published; destination manager relaunch failed; recover $5"
  fi
  transfer_hook FM_FLEET_TRANSFER_SECONDMATE_START_HOOK "$3" "$1" start-secondmate || die "assignment published; SecondMate relaunch failed; recover $5"
  with_lock python3 "$REGISTRY_BIN" "$REG" transfer-state --secondmate "$1" --transaction "$5" --state active >/dev/null
  python3 "$TRANSFER_BIN" state --journal "$6" --set active >/dev/null
}

# A planned transfer needs a stopped destination that it relaunches. A failover
# (failover=1) moves supervision into an already-live reasoning manager.
transfer_begin() {  # <secondmate> <manager> <source-home or empty> <failover> <reason>
  local sm=$1 dest=$2 source=$3 failover=$4 reason=$5 dest_home tx journal info expected
  dest_home=$(manager_home "$dest") || die "unknown destination manager $dest"
  [ -n "$source" ] || source=$(manager_home "$(assignment_manager "$sm")" 2>/dev/null || true)
  [ -n "$source" ] || die "source home is unknown; pass --source-home"
  reasoning_live "$source" && die "source parent home still has a live session lock"
  destination_ready "$dest_home" "$failover" || die "destination manager $dest is not in the session state this transfer requires"
  tx="$(date -u +%Y%m%dT%H%M%SZ)-$sm-$$"; journal="$FLEET_ROOT/transactions/$tx.json"; mkdir -p "$FLEET_ROOT/transactions"
  info=$(with_lock python3 "$TRANSFER_BIN" prepare "$REG" --secondmate "$sm" --manager "$dest" --source-home "$source" --transaction "$tx" --journal "$journal" --failover "$failover") || exit 1
  transfer_endpoints_check "$source" "$dest_home" "$failover" "$tx"
  transfer_hook FM_FLEET_TRANSFER_STOP_HOOK "$source" "$sm" stop-secondmate || die "SecondMate stop hook failed; recover $tx"
  transfer_endpoints_check "$source" "$dest_home" "$failover" "$tx" " after endpoint stop"
  with_lock python3 "$TRANSFER_BIN" apply --journal "$journal" || die "owner-record move failed; recover or rollback $tx"
  expected=$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["expected_generation"])')
  with_lock python3 "$REGISTRY_BIN" "$REG" transfer-publish --secondmate "$sm" --manager "$dest" --expected-generation "$expected" --transaction "$tx" --reason "$reason" >/dev/null || { echo "fm-fleet: records moved but assignment publication failed; recover $tx" >&2; exit 1; }
  python3 "$TRANSFER_BIN" state --journal "$journal" --set published >/dev/null
  transfer_activate "$sm" "$dest" "$dest_home" "$failover" "$tx" "$journal"
  echo "transfer $tx active: $sm -> $dest"
}

transfer_rollback_locked() {
  python3 "$REGISTRY_BIN" "$REG" transfer-rollback-check --secondmate "$ROLLBACK_SM" --transaction "$ROLLBACK_TX" || return 1
  python3 "$TRANSFER_BIN" rollback --journal "$ROLLBACK_JOURNAL" || return 1
  python3 "$REGISTRY_BIN" "$REG" transfer-rollback --secondmate "$ROLLBACK_SM" --transaction "$ROLLBACK_TX" --prior-assignment "$ROLLBACK_PRIOR"
}

case "$CMD" in
  -h|--help|help) usage ;;
  init)
    mkdir -p "$FLEET_ROOT" || exit 1
    with_lock python3 "$REGISTRY_BIN" "$REG" init || exit 1
    echo "fleet initialized at $REG"
    ;;
  migrate) need_registry; with_lock python3 "$REGISTRY_BIN" "$REG" migrate ;;
  validate) need_registry; python3 "$REGISTRY_BIN" "$REG" validate ;;
  manager)
    need_registry; [ "${1:-}" = register ] || { echo "fm-fleet: manager needs register" >&2; exit 2; }; shift
    id=""; home=""
    while [ $# -gt 0 ]; do case "$1" in --id) id=${2:-}; shift 2;; --home) home=${2:-}; shift 2;; *) echo "fm-fleet: unknown manager flag $1" >&2; exit 2;; esac; done
    [ -n "$id" ] && [ -n "$home" ] || { echo "fm-fleet: manager register needs --id and --home" >&2; exit 2; }
    with_lock python3 "$REGISTRY_BIN" "$REG" manager-register --id "$id" --home "$home" || exit 1
    echo "registered operational manager $id"
    ;;
  register) echo "fm-fleet: register moved to 'manager register'; manager rows no longer accept scope or ownership" >&2; exit 2 ;;
  owner)
    need_registry; [ "${1:-}" = register ] || { echo "fm-fleet: owner needs register" >&2; exit 2; }; shift
    sm=""; home=""; projects=""; domains=""
    while [ $# -gt 0 ]; do case "$1" in --secondmate) sm=${2:-}; shift 2;; --home) home=${2:-}; shift 2;; --projects) projects=${2:-}; shift 2;; --domains) domains=${2:-}; shift 2;; *) echo "fm-fleet: unknown owner flag $1" >&2; exit 2;; esac; done
    [ -n "$sm" ] && [ -n "$home" ] || { echo "fm-fleet: owner register needs --secondmate and --home" >&2; exit 2; }
    with_lock python3 "$REGISTRY_BIN" "$REG" owner-register --secondmate "$sm" --home "$home" --projects "$projects" --domains "$domains" || exit 1
    echo "registered semantic owner $sm"
    ;;
  start)
    need_registry; only=""
    while [ $# -gt 0 ]; do case "$1" in --managers) only=${2:-}; shift 2;; *) echo "fm-fleet: unknown start flag $1" >&2; exit 2;; esac; done
    "$0" --fleet-root "$FLEET_ROOT" validate >/dev/null || exit 1
    ids=$(manager_ids); [ -z "$only" ] || ids=$(printf '%s' "$only" | tr ',' ' ')
    [ -n "$ids" ] || die "no managers registered"
    start_managers "$ids"
    ;;
  stop)
    need_registry; ids=""; all=0
    while [ $# -gt 0 ]; do case "$1" in --all) all=1; shift;; *) ids="$ids $1"; shift;; esac; done
    [ "$all" -eq 0 ] || ids=$(manager_ids)
    [ -n "$ids" ] || { echo "fm-fleet: stop needs an id or --all" >&2; exit 2; }
    rc=0; for mid in $ids; do stop_manager "$mid" || rc=1; done; exit "$rc"
    ;;
  restart) [ $# -eq 1 ] || { echo "fm-fleet: restart needs one manager id" >&2; exit 2; }; stop_manager "$1" && start_managers "$1" ;;
  assign|recover)
    need_registry; sm=""
    if [ "$CMD" = assign ]; then reason="initial assignment"; else reason="manager recovery"; fi
    while [ $# -gt 0 ]; do case "$1" in --secondmate) sm=${2:-}; shift 2;; --reason) reason=${2:-}; shift 2;; *) echo "fm-fleet: unknown $CMD flag $1" >&2; exit 2;; esac; done
    [ -n "$sm" ] || { echo "fm-fleet: $CMD needs --secondmate" >&2; exit 2; }
    [ "$CMD" = recover ] || { do_assign "$sm" "$reason"; exit; }
    current=$(assignment_manager "$sm"); [ -n "$current" ] || die "$sm has no assignment to recover"
    old_home=$(manager_home "$current") || die "unknown manager $current"
    reasoning_live "$old_home" && die "current manager $current can still be alive"
    health=$(mktemp "$FLEET_ROOT/.health.XXXXXX") || exit 1
    health_json "$health" || { rm -f "$health"; exit 1; }
    dest=$(choose_manager "$health" "$sm" "$current"); rm -f "$health"
    [ -n "$dest" ] || die "no healthy reasoning manager remains assignable"
    transfer_begin "$sm" "$dest" "$old_home" 1 "$reason"
    ;;
  route)
    need_registry; flags=()
    while [ $# -gt 0 ]; do case "$1" in --secondmate|--project|--domain|--issue) flags+=("$1" "${2:-}"); shift 2;; *) echo "fm-fleet: unknown route flag $1" >&2; exit 2;; esac; done
    [ "${#flags[@]}" -gt 0 ] || { echo "fm-fleet: route needs a semantic key" >&2; exit 2; }
    routed=$(with_lock python3 "$REGISTRY_BIN" "$REG" route "${flags[@]}"); rc=$?
    if [ "$rc" -ne 0 ]; then [ -z "$routed" ] || printf '%s\n' "$routed"; exit "$rc"; fi
    state=$(printf '%s' "$routed" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
    sm=$(printf '%s' "$routed" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secondmate"])')
    if [ "$state" = needs-assignment ]; then do_assign "$sm" "intake assignment" >/dev/null || exit 1; routed=$(with_lock python3 "$REGISTRY_BIN" "$REG" route "${flags[@]}") || exit 1; fi
    manager=$(printf '%s' "$routed" | python3 -c 'import json,sys; print(json.load(sys.stdin)["manager"])')
    generation=$(printf '%s' "$routed" | python3 -c 'import json,sys; print(json.load(sys.stdin)["generation"])')
    echo "${flags[*]} -> $sm -> $manager (generation $generation)"
    ;;
  status)
    need_registry; as_json=0; [ "${1:-}" = --json ] && as_json=1
    health=$(mktemp "$FLEET_ROOT/.status-health.XXXXXX") || exit 1; health_json "$health" || { rm -f "$health"; exit 1; }
    python3 - "$REG" "$health" "$as_json" <<'PY'
import json, sys
with open(sys.argv[1]) as h: reg=json.load(h)
with open(sys.argv[2]) as h: health=json.load(h)
assignments={row["secondmate"]:row for row in reg["assignments"] if row.get("state")=="active"}
deps=[row for row in reg["dependencies"] if row.get("status")=="open"]
for row in health:
    sms=sorted(sm for sm,a in assignments.items() if a["manager"]==row["manager"])
    row["assigned_secondmates"]=sms; row["assignment_count"]=len(sms)
    waiting=[d for d in deps if d["owner_secondmate"] in sms]
    if waiting and row["state"] not in ("dead","stopped","ready"):
        row["state"]="blocked"; row["detail"]="; ".join("%s needs %s:%s"%(d["owner_secondmate"],d["needs_secondmate"],d["needs_task"]) for d in waiting)
owners=sorted(reg["owners"],key=lambda r:r["secondmate"]); triage=sorted(reg["unassigned"],key=lambda r:r["key"])
if sys.argv[3]=="1": print(json.dumps({"managers":health,"owners":owners,"unassigned":triage},indent=2,sort_keys=True))
else:
 print("MANAGER   STATE          SMS   ASSIGNED                 LAST-PROGRESS        DETAIL")
 for row in health: print("%-9s %-14s %-5d %-24s %-20s %s"%(row["manager"],row["state"],row["assignment_count"],",".join(row["assigned_secondmates"]) or "-",row["last_progress"] or "-",row["detail"] or "-"))
 print("\nSEMANTIC OWNERS")
 for row in owners: print("%s projects=%s domains=%s"%(row["secondmate"],",".join(row["projects"]) or "-",",".join(row["domains"]) or "-"))
 print("\nUNASSIGNED TRIAGE")
 for row in triage: print("%s attempts=%s reason=%s"%(row["key"],row["attempts"],row["reason"]))
PY
    rm -f "$health"
    ;;
  attach) need_registry; [ $# -eq 1 ] || exit 2; home=$(manager_home "$1") || die "unknown manager $1"; target=$(cat "$home/state/.fleet-herdr-target" 2>/dev/null || true); printf 'manager %s home: %s\n' "$1" "$home"; [ -z "$target" ] || printf 'herdr target: %s\n' "$target" ;;
  ask)
    need_registry; [ $# -ge 2 ] || exit 2; who=$1; shift; [ "$who" != --all ] || who=$(manager_ids); rc=0
    for mid in $who; do home=$(manager_home "$mid") || { rc=1; continue; }; target=$(cat "$home/state/.fleet-herdr-target" 2>/dev/null || true); [ -n "$target" ] || { echo "fm-fleet: no Herdr target for $mid" >&2; rc=1; continue; }; TARGET="$target" TEXT="$*" FM_HOME="$home" FM_ROOT="$FM_ROOT" bash -c '. "$FM_ROOT/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit "$TARGET" "$TEXT" 3 1 0.5' _ >/dev/null || rc=1; done; exit "$rc"
    ;;
  progress|set-wait|set-blocked)
    need_registry; [ $# -ge 1 ] || exit 2; mid=$1; shift; home=$(manager_home "$mid") || die "unknown manager $mid"; mkdir -p "$home/state"
    if [ "$CMD" = progress ]; then note=""; active=""; while [ $# -gt 0 ]; do case "$1" in --note) note=${2:-}; shift 2;; --active) active=${2:-}; shift 2;; *) exit 2;; esac; done; python3 - "$home/state/.fleet-progress.json" "$note" "$active" <<'PY'
import datetime,json,os,sys
p,n,a=sys.argv[1:]; d={}
try:
 with open(p) as h:d=json.load(h)
except (OSError,ValueError):pass
d["last_progress"]=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if n:d["last_note"]=n
if a:d["active_tasks"]=int(a)
t=p+".tmp"; open(t,"w").write(json.dumps(d)); os.replace(t,p)
PY
    else on=0; reason=""; while [ $# -gt 0 ]; do case "$1" in --on) on=1; shift;; --off) on=0; shift;; --reason) reason=${2:-}; shift 2;; *) exit 2;; esac; done; [ "$CMD" = set-wait ] && marker="$home/state/.fleet-wait" || marker="$home/state/.fleet-blocked"; if [ "$on" -eq 1 ]; then printf '%s\n' "$reason" > "$marker"; else rm -f "$marker"; fi; fi
    ;;
  dep)
    need_registry; [ $# -ge 1 ] || exit 2; sub=$1; shift; flags=(); while [ $# -gt 0 ]; do flags+=("$1"); shift; done
    if [ "$sub" = list ]; then python3 "$REGISTRY_BIN" "$REG" dep list; else with_lock python3 "$REGISTRY_BIN" "$REG" dep "$sub" "${flags[@]}"; fi
    ;;
  transfer)
    need_registry; [ $# -ge 1 ] || exit 2; sub=$1; shift
    if [ "$sub" = begin ]; then
      sm=""; dest=""; source=""; while [ $# -gt 0 ]; do case "$1" in --secondmate) sm=${2:-}; shift 2;; --to) dest=${2:-}; shift 2;; --source-home) source=${2:-}; shift 2;; *) exit 2;; esac; done
      [ -n "$sm" ] && [ -n "$dest" ] || exit 2
      transfer_begin "$sm" "$dest" "$source" 0 "supervision transfer"
    elif [ "$sub" = recover ]; then
      [ "${1:-}" = --transaction ] && [ -n "${2:-}" ] || exit 2; tx=$2; journal="$FLEET_ROOT/transactions/$tx.json"; data=$(python3 "$TRANSFER_BIN" state --journal "$journal") || exit 1
      sm=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secondmate"])'); dest=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["destination_manager"])'); source=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["source_home"])'); dest_home=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["destination_home"])')
      failover=$(printf '%s' "$data" | python3 -c 'import json,sys; print(1 if json.load(sys.stdin).get("failover") else 0)')
      reasoning_live "$source" && die "source home has a live lock; recovery refused"; destination_ready "$dest_home" "$failover" || die "destination home session state blocks recovery"; state=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
      if [ "$state" = preparing ]; then transfer_hook FM_FLEET_TRANSFER_STOP_HOOK "$source" "$sm" stop-secondmate || die "SecondMate stop hook failed"; with_lock python3 "$TRANSFER_BIN" apply --journal "$journal" || exit 1; state=records-ready; fi
      if [ "$state" = records-ready ]; then expected=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["expected_generation"])'); with_lock python3 "$REGISTRY_BIN" "$REG" transfer-publish --secondmate "$sm" --manager "$dest" --expected-generation "$expected" --transaction "$tx" --reason "recovered supervision transfer" >/dev/null || exit 1; python3 "$TRANSFER_BIN" state --journal "$journal" --set published >/dev/null || exit 1; fi
      transfer_activate "$sm" "$dest" "$dest_home" "$failover" "$tx" "$journal"; echo "transfer $tx recovered"
    elif [ "$sub" = rollback ]; then
      [ "${1:-}" = --transaction ] && [ -n "${2:-}" ] || exit 2; tx=$2; journal="$FLEET_ROOT/transactions/$tx.json"; data=$(python3 "$TRANSFER_BIN" state --journal "$journal") || exit 1; source=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["source_home"])'); dest_home=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["destination_home"])'); sm=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secondmate"])')
      state=$(printf '%s' "$data" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'); prior=$(printf '%s' "$data" | python3 -c 'import json,sys; value=json.load(sys.stdin).get("prior_assignment"); print(json.dumps(value) if value else "")'); reasoning_live "$source" && die "source home has a live lock; rollback refused"; reasoning_live "$dest_home" && die "destination home has a live lock; rollback refused"; if [ "$state" = rolled-back ]; then echo "transfer $tx already rolled back"; exit 0; fi; if [ "$state" = preparing ]; then stop_home=$source; else stop_home=$dest_home; fi; transfer_hook FM_FLEET_TRANSFER_STOP_HOOK "$stop_home" "$sm" stop-secondmate || die "SecondMate stop hook failed; rollback refused"; ROLLBACK_SM=$sm; ROLLBACK_TX=$tx; ROLLBACK_JOURNAL=$journal; ROLLBACK_PRIOR=$prior; with_lock transfer_rollback_locked >/dev/null || exit 1; transfer_hook FM_FLEET_TRANSFER_ROLLBACK_START_HOOK "$source" "$sm" start-secondmate || die "records restored; source SecondMate relaunch failed"; echo "transfer $tx rolled back"
    else echo "fm-fleet: transfer needs begin, recover, or rollback" >&2; exit 2; fi
    ;;
  *) echo "fm-fleet: unknown command $CMD" >&2; usage >&2; exit 2 ;;
esac
