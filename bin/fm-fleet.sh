#!/usr/bin/env bash
# fm-fleet.sh - thin fleet control plane for concurrently active FirstMate managers.
#
# Usage: fm-fleet.sh [--fleet-root <dir>] <command> [args...]
#
# Commands:
#   init                                  create an empty fleet registry
#   register --id <id> --home <abs> --scope <scope> [--secondmates a,b]
#            [--projects p,q] [--domains d,e]
#                                         add or update one manager shard
#   validate                              refuse duplicate ids, homes, secondmates,
#                                         projects, or domains before anything mutates
#   start [--managers a,b]                validate, then launch one manager process
#                                         per shard with an isolated FM_HOME
#   stop <id> | --all                     terminate manager processes; shards stay known
#   restart <id>                          stop then start one manager in its own home
#   status [--json]                       compact manager-level view for all shards
#   attach <id>                           print how to reach one manager's session
#   route [--secondmate <sm>] [--project <p>] [--domain <d>]
#                                         resolve new work to exactly one manager
#   progress <id> [--note <t>] [--active <n>]
#                                         record meaningful progress for one manager
#   set-wait <id> --on | --off            mark or clear a model/provider wait
#   set-blocked <id> --on [--reason <t>] | --off
#                                         mark or clear a blocked shard
#   dep add --owner <fm> --from <task> --needs <fm2> --task <task2>
#                                         record a durable cross-shard dependency
#   dep list | dep done --owner <fm> --from <task>
#                                         inspect or close cross-shard dependencies
#
# The fleet root holds fleet.json plus no reasoning of its own: detailed issue
# decomposition, worker supervision, retries, landing, and completion checks
# stay inside the owning manager shard. Fleet status never reports completion;
# completion is owned by each shard's Definition-of-Done and landing evidence.
# Single-manager usage is the degenerate case: a fleet with one registered
# manager behaves like today's single FirstMate home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANAGER_BIN="$SCRIPT_DIR/fm-fleet-manager.sh"

FLEET_ROOT="${FM_FLEET_ROOT:-}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fleet-root) FLEET_ROOT="${2:-}"; shift 2 ;;
    --fleet-root=*) FLEET_ROOT="${1#--fleet-root=}"; shift ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ "${#ARGS[@]}" -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

usage() {
  sed -n '2,/^#$/p' "$SCRIPT_DIR/fm-fleet.sh" | sed 's/^# \{0,1\}//'
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
[ -n "$FLEET_ROOT" ] || { echo "fm-fleet: --fleet-root <dir> or FM_FLEET_ROOT is required; refusing to guess" >&2; exit 2; }
REG="$FLEET_ROOT/fleet.json"
CMD=$1; shift

need_registry() {
  [ -f "$REG" ] || { echo "fm-fleet: no registry at $REG; run init first" >&2; exit 1; }
}

with_lock() {
  local lockdir="$FLEET_ROOT/.fleet.lock.d" waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || { echo "fm-fleet: registry is locked by another fleet command" >&2; exit 1; }
    sleep 0.1 2>/dev/null || sleep 1
  done
  trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT INT TERM HUP
  "$@"
  local rc=$?
  rmdir "$lockdir" 2>/dev/null || true
  trap - EXIT INT TERM HUP
  return $rc
}


fleet_backend() {
  if [ -n "${FM_FLEET_BACKEND:-}" ]; then
    printf '%s' "$FM_FLEET_BACKEND"
  elif command -v tmux >/dev/null 2>&1; then
    printf 'tmux'
  else
    printf 'nohup'
  fi
}

fleet_backend_check() {
  case "$1" in
    tmux|nohup) return 0 ;;
    herdr)
      command -v herdr >/dev/null 2>&1 || { echo "fm-fleet: herdr backend needs the herdr CLI" >&2; return 1; }
      command -v jq >/dev/null 2>&1 || { echo "fm-fleet: herdr backend needs jq" >&2; return 1; }
      return 0
      ;;
    *) echo "fm-fleet: unsupported backend $1 (want tmux, nohup, or herdr)" >&2; return 1 ;;
  esac
}

fleet_tmux_session() {
  printf 'fm-fleet-%s-%s' "$(printf '%s' "$FLEET_ROOT" | cksum | cut -d' ' -f1)" "$1"
}

fleet_tmux_alive() {
  tmux has-session -t "$(fleet_tmux_session "$1")" 2>/dev/null
}



fleet_pid_is_manager() {
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  ps -o command= -p "$1" 2>/dev/null | grep -q "fm-fleet-manager\.sh" || return 1
}

case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  init)
    if [ -f "$REG" ]; then
      echo "fm-fleet: registry already exists at $REG; refusing to overwrite" >&2
      exit 1
    fi
    mkdir -p "$FLEET_ROOT" || { echo "fm-fleet: cannot create $FLEET_ROOT" >&2; exit 1; }
    printf '{"version": 1, "managers": [], "dependencies": []}\n' > "$REG" || exit 1
    echo "fleet initialized at $REG"
    ;;

  register)
    need_registry
    id="" home="" scope="" sms="" projs="" doms=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --id) id="${2:-}"; shift 2 ;;
        --home) home="${2:-}"; shift 2 ;;
        --scope) scope="${2:-}"; shift 2 ;;
        --secondmates) sms="${2:-}"; shift 2 ;;
        --projects) projs="${2:-}"; shift 2 ;;
        --domains) doms="${2:-}"; shift 2 ;;
        *) echo "fm-fleet: unknown register flag $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$id" ] && [ -n "$home" ] && [ -n "$scope" ] || { echo "fm-fleet: register needs --id, --home, and --scope" >&2; exit 2; }
    backup="$REG.register-backup.$$"
    cp "$REG" "$backup" || { echo "fm-fleet: cannot back up registry" >&2; exit 1; }
    with_lock python3 - "$REG" "$id" "$home" "$scope" "$sms" "$projs" "$doms" <<'PY'
import json, sys
path, mid, home, scope, sms, projs, doms = sys.argv[1:8]
def lst(s):
    return [p for p in (s.split(",") if s else []) if p]
with open(path) as fh:
    reg = json.load(fh)
mgrs = [m for m in reg.get("managers", []) if m.get("id") != mid]
mgrs.append({"id": mid, "home": home, "scope": scope,
             "secondmates": lst(sms), "projects": lst(projs), "domains": lst(doms)})
reg["managers"] = sorted(mgrs, key=lambda m: m["id"])
with open(path, "w") as fh:
    json.dump(reg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    "$SCRIPT_DIR/fm-fleet.sh" --fleet-root "$FLEET_ROOT" validate || {
      echo "fm-fleet: registration of $id failed validation; review the errors above" >&2
      mv "$backup" "$REG"
      exit 1
    }
    rm -f "$backup" 2>/dev/null || true
    echo "registered $id (home $home, scope $scope)"
    ;;

  validate)
    need_registry
    python3 - "$REG" <<'PY'
import json, os, sys
path = sys.argv[1]
errors = []
with open(path) as fh:
    reg = json.load(fh)
if reg.get("version") != 1:
    errors.append("unsupported registry version: %r" % (reg.get("version"),))
mgrs = reg.get("managers", [])
seen_ids, seen_homes, seen_sm, seen_proj, seen_dom = {}, {}, {}, {}, {}
homes = []
for m in mgrs:
    mid = m.get("id", "")
    if not mid or not all(c.isalnum() or c in "-_" for c in mid):
        errors.append("manager id must be non-empty [a-z0-9-_]: %r" % (mid,))
    if mid in seen_ids:
        errors.append("duplicate manager id: %s" % mid)
    seen_ids[mid] = True
    home = m.get("home", "")
    if not os.path.isabs(home):
        errors.append("manager %s home must be absolute: %r" % (mid, home))
    else:
        norm = os.path.normpath(home)
        if norm in seen_homes:
            errors.append("duplicate manager home: %s (used by %s and %s)" % (home, seen_homes[norm], mid))
        seen_homes[norm] = mid
        homes.append((mid, norm))
    if not m.get("scope"):
        errors.append("manager %s needs a scope" % (mid,))
    for sm in m.get("secondmates", []):
        if sm in seen_sm:
            errors.append("duplicate SecondMate assignment: %s is owned by both %s and %s" % (sm, seen_sm[sm], mid))
        seen_sm[sm] = mid
    for p in m.get("projects", []):
        if p in seen_proj:
            errors.append("project %s is routed to both %s and %s; routing must resolve to exactly one manager" % (p, seen_proj[p], mid))
        seen_proj[p] = mid
    for d in m.get("domains", []):
        if d in seen_dom:
            errors.append("domain %s is routed to both %s and %s; routing must resolve to exactly one manager" % (d, seen_dom[d], mid))
        seen_dom[d] = mid
for i in range(len(homes)):
    for j in range(i + 1, len(homes)):
        a, b = homes[i][1], homes[j][1]
        if a == b or a.startswith(b + "/") or b.startswith(a + "/"):
            errors.append("overlapping manager homes: %s (%s) and %s (%s)" % (homes[i][0], a, homes[j][0], b))
known = set(seen_ids)
for d in reg.get("dependencies", []):
    if d.get("owner") not in known:
        errors.append("dependency %s names unknown owner %s" % (d.get("from_task"), d.get("owner")))
    if d.get("needs_manager") not in known:
        errors.append("dependency %s names unknown needs_manager %s" % (d.get("from_task"), d.get("needs_manager")))
    if d.get("owner") == d.get("needs_manager"):
        errors.append("dependency %s is not cross-shard (owner and needs_manager are both %s)" % (d.get("from_task"), d.get("owner")))
    if d.get("status") not in ("open", "done"):
        errors.append("dependency %s has invalid status %r" % (d.get("from_task"), d.get("status")))
if errors:
    print("fleet validation FAILED:")
    for e in errors:
        print("  - %s" % e)
    sys.exit(1)
print("fleet validation ok: %d manager(s), %d secondmate(s), %d open dep(s)" % (
    len(mgrs), len(seen_sm),
    sum(1 for d in reg.get("dependencies", []) if d.get("status") == "open")))
PY
    ;;

  start)
    need_registry
    only=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --managers) only="${2:-}"; shift 2 ;;
        *) echo "fm-fleet: unknown start flag $1" >&2; exit 2 ;;
      esac
    done
    "$SCRIPT_DIR/fm-fleet.sh" --fleet-root "$FLEET_ROOT" validate || exit 1
    managers=$(python3 -c 'import json,sys; print(" ".join(m["id"] for m in json.load(open(sys.argv[1]))["managers"]))' "$REG")
    if [ -n "$only" ]; then
      managers=$(printf '%s' "$only" | tr ',' ' ')
    fi
    [ -n "$managers" ] || { echo "fm-fleet: no managers registered" >&2; exit 1; }
    known=$(python3 -c 'import json,sys; print(" ".join(m["id"] for m in json.load(open(sys.argv[1]))["managers"]))' "$REG")
    # shellcheck disable=SC2086
    for mid in $managers; do
      case " $known " in
        *" $mid "*) ;;
        *) echo "fm-fleet: unknown manager $mid" >&2; exit 1 ;;
      esac
    done
    # shellcheck disable=SC2086
    for mid in $managers; do
      home=$(python3 -c 'import json,sys; print([m["home"] for m in json.load(open(sys.argv[1]))["managers"] if m["id"]==sys.argv[2]][0])' "$REG" "$mid")
      mkdir -p "$home/state" "$home/data" "$home/config" || { echo "fm-fleet: cannot create home $home" >&2; exit 1; }
      if [ -f "$home/state/.fleet-manager.pid" ]; then
        old=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
        if fleet_pid_is_manager "$old"; then
          echo "fm-fleet: duplicate live authority for $mid (pid $old in $home); refusing to start" >&2
          exit 1
        fi
        rm -f "$home/state/.fleet-manager.pid" 2>/dev/null || true
      fi
      lockinfo=$(FM_HOME="$home" "$FM_ROOT/bin/fm-lock.sh" status 2>/dev/null || true)
      case "$lockinfo" in
        "lock: held by live"*)
          echo "fm-fleet: $home session lock is $lockinfo; refusing to start $mid" >&2
          exit 1
          ;;
      esac
    done
    # shellcheck disable=SC2086
    backend=$(fleet_backend)
    fleet_backend_check "$backend" || exit 2
    if [ "$backend" = "tmux" ]; then
      # shellcheck disable=SC2086
      for mid in $managers; do
        if fleet_tmux_alive "$mid"; then
          echo "fm-fleet: duplicate live tmux session for $mid; refusing to start" >&2
          exit 1
        fi
      done
    fi
    # shellcheck disable=SC2086
    for mid in $managers; do
      home=$(python3 -c 'import json,sys; print([m["home"] for m in json.load(open(sys.argv[1]))["managers"] if m["id"]==sys.argv[2]][0])' "$REG" "$mid")
      log="$home/state/.fleet-manager.log"
      epoch=$(date +%s)
      if [ "$backend" = "tmux" ]; then
        if fleet_tmux_alive "$mid"; then
          tmux kill-session -t "$(fleet_tmux_session "$mid")" 2>/dev/null || true
        fi
        tmux new-session -d -s "$(fleet_tmux_session "$mid")" -x 200 -y 50 "$MANAGER_BIN" "$FLEET_ROOT" "$mid" >> "$log" 2>&1 || {
          echo "fm-fleet: tmux failed to launch $mid; see $log" >&2
          exit 1
        }
      elif [ "$backend" = "herdr" ]; then
        FM_FLEET_POLL="${FM_FLEET_POLL:-2}" "$SCRIPT_DIR/fm-fleet-herdr.sh" launch "$FLEET_ROOT" "$mid" "$home" "$MANAGER_BIN" >> "$log" 2>&1 || {
          echo "fm-fleet: herdr failed to launch $mid; see $log" >&2
          exit 1
        }
      else
        nohup "$MANAGER_BIN" "$FLEET_ROOT" "$mid" >> "$log" 2>&1 < /dev/null &
        disown 2>/dev/null || true
      fi
      waited=0
      while [ "$waited" -lt 150 ]; do
        if [ -f "$home/state/.fleet-manager.pid" ] && [ -f "$home/state/.fleet-heartbeat.json" ]; then
          pidnow=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
          hbpid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid") or "")' "$home/state/.fleet-heartbeat.json" 2>/dev/null || true)
          hbmtime=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$home/state/.fleet-heartbeat.json" 2>/dev/null || echo 0)
          if [ -n "$pidnow" ] && [ "$pidnow" = "$hbpid" ] && [ "$hbmtime" -ge "$epoch" ] && kill -0 "$pidnow" 2>/dev/null; then
            break
          fi
        fi
        sleep 0.1 2>/dev/null || sleep 1
        waited=$((waited + 1))
      done
      if [ -f "$home/state/.fleet-manager.pid" ]; then
        pidnow=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
        if [ -n "$pidnow" ] && kill -0 "$pidnow" 2>/dev/null; then
          echo "started $mid (home $home, pid $pidnow, backend $backend)"
        else
          echo "fm-fleet: $mid published no live heartbeat; see $log" >&2
          exit 1
        fi
      else
        echo "fm-fleet: $mid failed to publish a heartbeat; see $log" >&2
        exit 1
      fi
    done
    ;;

  stop)
    need_registry
    all=0 ids=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) all=1; shift ;;
        *) ids="$ids $1"; shift ;;
      esac
    done
    if [ "$all" -eq 1 ]; then
      ids=$(python3 -c 'import json,sys; print(" ".join(m["id"] for m in json.load(open(sys.argv[1]))["managers"]))' "$REG")
    fi
    [ -n "$ids" ] || { echo "fm-fleet: stop needs an id or --all" >&2; exit 2; }
    # shellcheck disable=SC2086
    for mid in $ids; do
      home=$(python3 -c 'import json,sys; ms=[m["home"] for m in json.load(open(sys.argv[1]))["managers"] if m["id"]==sys.argv[2]]; print(ms[0] if ms else "")' "$REG" "$mid")
      [ -n "$home" ] || { echo "fm-fleet: unknown manager $mid" >&2; exit 1; }
      pid=""
      [ -f "$home/state/.fleet-manager.pid" ] && pid=$(cat "$home/state/.fleet-manager.pid" 2>/dev/null || true)
      if [ -z "$pid" ] || ! fleet_pid_is_manager "$pid"; then
        echo "stopped $mid (no live manager process; shard remains registered)"
        rm -f "$home/state/.fleet-manager.pid" 2>/dev/null || true
        if [ -f "$home/state/.fleet-heartbeat.json" ]; then
          python3 - "$home/state/.fleet-heartbeat.json" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        hb = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
hb["state_hint"] = "stopped"
with open(path, "w") as fh:
    json.dump(hb, fh)
PY
        fi
        if command -v tmux >/dev/null 2>&1 && fleet_tmux_alive "$mid"; then
          tmux kill-session -t "$(fleet_tmux_session "$mid")" 2>/dev/null || true
        fi
        "$SCRIPT_DIR/fm-fleet-herdr.sh" close "$FLEET_ROOT" "$mid" "$home" >/dev/null 2>&1 || true
        continue
      fi
      kill "$pid" 2>/dev/null || true
      waited=0
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        echo "stopped $mid (forced; shard remains registered)"
      else
        echo "stopped $mid (clean; shard remains registered)"
      fi
      rm -f "$home/state/.fleet-manager.pid" 2>/dev/null || true
      if command -v tmux >/dev/null 2>&1 && fleet_tmux_alive "$mid"; then
        tmux kill-session -t "$(fleet_tmux_session "$mid")" 2>/dev/null || true
      fi
      "$SCRIPT_DIR/fm-fleet-herdr.sh" close "$FLEET_ROOT" "$mid" "$home" >/dev/null 2>&1 || true
    done
    ;;

  restart)
    [ $# -eq 1 ] || { echo "fm-fleet: restart needs exactly one manager id" >&2; exit 2; }
    "$SCRIPT_DIR/fm-fleet.sh" --fleet-root "$FLEET_ROOT" stop "$1" || exit 1
    "$SCRIPT_DIR/fm-fleet.sh" --fleet-root "$FLEET_ROOT" start --managers "$1" || exit 1
    ;;

  status)
    need_registry
    json=0
    [ "${1:-}" = "--json" ] && json=1
    STALL_SECS="${FM_FLEET_STALL_SECS:-300}"
    python3 - "$REG" "$json" "$STALL_SECS" <<'PY'
import json, os, sys, time
path, as_json, stall = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3])
def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False
def age(ts):
    try:
        s = int(time.time() - time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")))
    except Exception:
        return None
    if s < 0:
        s = 0
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm" % (s // 60)
    return "%dh" % (s // 3600)
with open(path) as fh:
    reg = json.load(fh)
open_deps = [d for d in reg.get("dependencies", []) if d.get("status") == "open"]
rows = []
for m in sorted(reg.get("managers", []), key=lambda x: x.get("id")):
    mid, home, scope = m.get("id"), m.get("home"), m.get("scope")
    state_dir = os.path.join(home, "state")
    pid, alive, hb, fresh = None, False, {}, False
    try:
        with open(os.path.join(state_dir, ".fleet-manager.pid")) as fh:
            pid = fh.read().strip() or None
    except OSError:
        pid = None
    if pid and pid_alive(pid):
        alive = True
    try:
        with open(os.path.join(state_dir, ".fleet-heartbeat.json")) as fh:
            hb = json.load(fh)
        fresh = (time.time() - os.path.getmtime(os.path.join(state_dir, ".fleet-heartbeat.json"))) <= 15
    except OSError:
        hb, fresh = {}, False
    wait = bool(hb.get("provider_wait")) or os.path.exists(os.path.join(state_dir, ".fleet-wait"))
    blocked = bool(hb.get("blocked")) or os.path.exists(os.path.join(state_dir, ".fleet-blocked"))
    reason = hb.get("blocked_reason") or ""
    if not reason and blocked:
        try:
            with open(os.path.join(state_dir, ".fleet-blocked")) as fh:
                reason = fh.readline().strip()
        except OSError:
            reason = ""
    dep_wait = [d for d in open_deps if d.get("owner") == mid]
    if alive and fresh:
        if wait:
            state = "model-wait"
        elif blocked or dep_wait:
            state = "blocked"
        else:
            lp = hb.get("last_progress")
            try:
                idle_for = time.time() - time.mktime(time.strptime(lp, "%Y-%m-%dT%H:%M:%SZ")) if lp else 10 ** 9
            except Exception:
                idle_for = 10 ** 9
            if idle_for > stall:
                state = "stalled"
            elif int(hb.get("active_tasks") or 0) > 0:
                state = "running"
            else:
                state = "idle"
    elif not alive and (hb.get("state_hint") == "stopped") and pid is None:
        state = "stopped"
    else:
        state = "dead"
    detail = reason or ("; ".join("needs %s:%s" % (d.get("needs_manager"), d.get("needs_task")) for d in dep_wait) if dep_wait else "")
    rows.append({"manager": mid, "scope": scope, "state": state,
                 "sms": len(m.get("secondmates", [])), "active": int(hb.get("active_tasks") or 0),
                 "blocked": 1 if (blocked or dep_wait) else 0,
                 "last_progress": age(hb.get("last_progress")) if hb.get("last_progress") else "-",
                 "secondmates": m.get("secondmates", []), "home": home,
                 "pid": pid if alive else None, "detail": detail})
if as_json:
    print(json.dumps({"managers": rows}, indent=2, sort_keys=True))
else:
    print("MANAGER   SCOPE        STATE       SMS   ACTIVE   BLOCKED   LAST-PROGRESS   DETAIL")
    for r in rows:
        print("%-9s %-12s %-11s %-5d %-8d %-9d %-15s %s" % (
            r["manager"], (r["scope"] or "-")[:12], r["state"],
            r["sms"], r["active"], r["blocked"], r["last_progress"], r["detail"] or "-"))
PY
    ;;

  attach)
    need_registry
    [ $# -eq 1 ] || { echo "fm-fleet: attach needs exactly one manager id" >&2; exit 2; }
    home=$(python3 -c 'import json,sys; ms=[m["home"] for m in json.load(open(sys.argv[1]))["managers"] if m["id"]==sys.argv[2]]; print(ms[0] if ms else "")' "$REG" "$1")
    [ -n "$home" ] || { echo "fm-fleet: unknown manager $1" >&2; exit 1; }
    cat <<EOF
manager $1 home: $home
inspect (read-only, safe while the manager runs):
  FM_HOME=$home $FM_ROOT/bin/fm-fleet-view.sh
  FM_HOME=$home $FM_ROOT/bin/fm-crew-state.sh <task-id>
take over authority (stops the supervised daemon first):
  $FM_ROOT/bin/fm-fleet.sh --fleet-root $FLEET_ROOT stop $1
  FM_HOME=$home \$SHELL
remote (MacBook control surface, Mac mini execution host):
  ssh <mini> "FM_HOME=$home \$SHELL -l"
EOF
    ;;

  route)
    need_registry
    sm="" proj="" dom=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --secondmate) sm="${2:-}"; shift 2 ;;
        --project) proj="${2:-}"; shift 2 ;;
        --domain) dom="${2:-}"; shift 2 ;;
        *) echo "fm-fleet: unknown route flag $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$sm$proj$dom" ] || { echo "fm-fleet: route needs at least one of --secondmate, --project, --domain" >&2; exit 2; }
    python3 - "$REG" "$sm" "$proj" "$dom" <<'PY'
import json, sys
path, sm, proj, dom = sys.argv[1:5]
with open(path) as fh:
    reg = json.load(fh)
mgrs = reg.get("managers", [])
def owners(key, val):
    return sorted(m["id"] for m in mgrs if val and val in (m.get(key) or []))
claims = {}
for key, val in (("secondmates", sm), ("projects", proj), ("domains", dom)):
    if not val:
        continue
    found = owners(key, val)
    if len(found) > 1:
        print("fm-fleet: %s %r resolves to multiple managers %s; fix the registry" % (key, val, found))
        sys.exit(1)
    if len(found) == 1:
        claims[key] = found[0]
if not claims:
    print("fm-fleet: no manager owns secondmate=%r project=%r domain=%r" % (sm, proj, dom))
    sys.exit(1)
if len(set(claims.values())) > 1:
    print("fm-fleet: routing dimensions disagree %r; refusing to guess" % (claims,))
    sys.exit(1)
by = sorted(claims)[0]
print("%s (by %s)" % (claims[by], by))
PY
    ;;

  progress)
    need_registry
    [ $# -ge 1 ] || { echo "fm-fleet: progress needs a manager id" >&2; exit 2; }
    mid=$1; shift
    note="" active=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --note) note="${2:-}"; shift 2 ;;
        --active) active="${2:-}"; shift 2 ;;
        *) echo "fm-fleet: unknown progress flag $1" >&2; exit 2 ;;
      esac
    done
    home=$(python3 -c 'import json,sys; ms=[m["home"] for m in json.load(open(sys.argv[1]))["managers"] if m["id"]==sys.argv[2]]; print(ms[0] if ms else "")' "$REG" "$mid")
    [ -n "$home" ] || { echo "fm-fleet: unknown manager $mid" >&2; exit 1; }
    mkdir -p "$home/state" || exit 1
    with_lock python3 - "$home/state/.fleet-progress.json" "$note" "$active" <<'PY'
import datetime, json, os, sys
path, note, active = sys.argv[1:4]
marked = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            marked = json.load(fh)
    except (OSError, ValueError):
        marked = {}
marked["last_progress"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if active != "":
    marked["active_tasks"] = int(active)
if note:
    marked["last_note"] = note
tmp = path + ".tmp.$$"
with open(tmp, "w") as fh:
    json.dump(marked, fh)
os.replace(tmp, path)
PY
    echo "progress recorded for $mid"
    ;;

  set-wait|set-blocked)
    need_registry
    mode=$CMD
    [ $# -ge 1 ] || { echo "fm-fleet: $mode needs a manager id" >&2; exit 2; }
    mid=$1; shift
    on=0 reason=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --on) on=1; shift ;;
        --off) on=0; shift ;;
        --reason) reason="${2:-}"; shift 2 ;;
        *) echo "fm-fleet: unknown $mode flag $1" >&2; exit 2 ;;
      esac
    done
    home=$(python3 -c 'import json,sys; ms=[m["home"] for m in json.load(open(sys.argv[1]))["managers"] if m["id"]==sys.argv[2]]; print(ms[0] if ms else "")' "$REG" "$mid")
    [ -n "$home" ] || { echo "fm-fleet: unknown manager $mid" >&2; exit 1; }
    if [ "$mode" = "set-wait" ]; then
      marker="$home/state/.fleet-wait"
    else
      marker="$home/state/.fleet-blocked"
    fi
    if [ "$on" -eq 1 ]; then
      mkdir -p "$home/state"
      printf '%s\n' "$reason" > "$marker" || exit 1
      echo "$mid marked ${mode#set-}: ${reason:-$mode active}"
    else
      rm -f "$marker" 2>/dev/null || true
      echo "$mid cleared ${mode#set-}"
    fi
    ;;

  dep)
    need_registry
    [ $# -ge 1 ] || { echo "fm-fleet: dep needs add, list, or done" >&2; exit 2; }
    sub=$1; shift
    case "$sub" in
      add)
        owner="" from="" needs="" task=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --owner) owner="${2:-}"; shift 2 ;;
            --from) from="${2:-}"; shift 2 ;;
            --needs) needs="${2:-}"; shift 2 ;;
            --task) task="${2:-}"; shift 2 ;;
            *) echo "fm-fleet: unknown dep add flag $1" >&2; exit 2 ;;
          esac
        done
        [ -n "$owner$from$needs$task" ] && [ -n "$owner" ] && [ -n "$from" ] && [ -n "$needs" ] && [ -n "$task" ] || { echo "fm-fleet: dep add needs --owner, --from, --needs, --task" >&2; exit 2; }
        with_lock python3 - "$REG" "$owner" "$from" "$needs" "$task" <<'PY'
import json, sys
path, owner, frm, needs, task = sys.argv[1:6]
with open(path) as fh:
    reg = json.load(fh)
known = {m["id"] for m in reg.get("managers", [])}
if owner not in known or needs not in known:
    print("fm-fleet: unknown manager in dependency", file=sys.stderr)
    sys.exit(1)
if owner == needs:
    print("fm-fleet: dependency is not cross-shard (owner and needs are both %s)" % owner, file=sys.stderr)
    sys.exit(1)
deps = [d for d in reg.get("dependencies", []) if not (d.get("owner") == owner and d.get("from_task") == frm)]
deps.append({"owner": owner, "from_task": frm, "needs_manager": needs, "needs_task": task, "status": "open"})
reg["dependencies"] = deps
with open(path, "w") as fh:
    json.dump(reg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
        "$SCRIPT_DIR/fm-fleet.sh" --fleet-root "$FLEET_ROOT" validate || exit 1
        echo "dependency recorded: $owner:$from waits on $needs:$task (ownership stays with $owner)"
        ;;
      list)
        python3 - "$REG" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    reg = json.load(fh)
deps = reg.get("dependencies", [])
if not deps:
    print("no cross-shard dependencies")
else:
    for d in deps:
        print("%s:%s -> %s:%s [%s]" % (d.get("owner"), d.get("from_task"), d.get("needs_manager"), d.get("needs_task"), d.get("status")))
PY
        ;;
      done)
        owner="" from=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --owner) owner="${2:-}"; shift 2 ;;
            --from) from="${2:-}"; shift 2 ;;
            *) echo "fm-fleet: unknown dep done flag $1" >&2; exit 2 ;;
          esac
        done
        [ -n "$owner" ] && [ -n "$from" ] || { echo "fm-fleet: dep done needs --owner and --from" >&2; exit 2; }
        with_lock python3 - "$REG" "$owner" "$from" <<'PY'
import json, sys
path, owner, frm = sys.argv[1:4]
with open(path) as fh:
    reg = json.load(fh)
found = False
for d in reg.get("dependencies", []):
    if d.get("owner") == owner and d.get("from_task") == frm and d.get("status") == "open":
        d["status"] = "done"
        found = True
if not found:
    print("fm-fleet: no open dependency %s:%s" % (owner, frm), file=sys.stderr)
    sys.exit(1)
with open(path, "w") as fh:
    json.dump(reg, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
        echo "dependency closed: $owner:$from"
        ;;
      *) echo "fm-fleet: unknown dep subcommand $sub" >&2; exit 2 ;;
    esac
    ;;

  *) echo "fm-fleet: unknown command $CMD" >&2; usage >&2; exit 2 ;;
esac
