#!/usr/bin/env bash
# Own task-scoped chrome-devtools-axi lifecycle and resource detection.
#
# Usage:
#   fm-browser-session.sh name <firstmate-home> <task-id>
#   fm-browser-session.sh cleanup <firstmate-home> <task-meta>
#   fm-browser-session.sh sweep <firstmate-home> <state-dir>
#   fm-browser-session.sh count
#
# `name` derives the one chrome-devtools-axi named session assigned to a ship or
# scout from its resolved Firstmate home and task id. The opaque hash keeps the
# tool's 64-byte session-name limit while preventing equal task ids in separate
# homes from sharing a browser. bin/fm-spawn.sh records that value as
# `browser_session=` and exports it into the worker before launch. A worker must
# preserve the assignment and run `chrome-devtools-axi stop` when browser work
# ends; a later browser command starts a fresh process tree for the same task.
#
# `cleanup` accepts only the exact derived session recorded once in a regular
# task meta file. It reads that named session's own bridge.pid, refuses a live
# PID whose process is not chrome-devtools-axi's bridge, requires the bridge's
# health endpoint to report the exact session identity, invokes the tool's
# public `stop` command, and verifies that exact bridge is gone. The tool owns
# graceful MCP/Chrome closure and its bounded whole-tree escalation. Missing
# `browser_session=` is a compatibility no-op for tasks launched before this
# safeguard. No command enumerates and kills arbitrary Chrome processes.
#
# `sweep` is the watcher's bounded backstop. A new `done:` or `failed:` event
# closes that task's session once. A session whose own state has not changed for
# FM_BROWSER_IDLE_TIMEOUT_SECS (default 1800) is closed when the recorded worker
# is authoritatively dead or missing; every other stale owner is warned once per
# activity epoch and left untouched. The recovery-grade backend classifier can
# prove dead/missing only on its verified backends, so unverified backends take
# the warning path rather than risking an active browser. Markers under the
# owning home suppress repeated terminal and idle handling and are retired with
# the task.
#
# The same sweep counts chrome-devtools-axi-owned headless browser roots and
# their descendant helper processes from one process-table snapshot. At
# FM_BROWSER_ROOT_WARN roots (default 4) or FM_BROWSER_HELPER_WARN helpers
# (default 30), it emits one machine-wide warning and leaves every process
# untouched. The warning rearms after usage falls below both ceilings. Counting
# is deliberately broader than task metadata so sessions created manually by a
# worker still contribute to pressure, while cleanup remains narrower and can
# touch only a task's recorded exact session.
#
# FM_BROWSER_IDLE_TIMEOUT_SECS, FM_BROWSER_ROOT_WARN, and
# FM_BROWSER_HELPER_WARN accept positive integers; invalid values use defaults.
# Mechanics and state-file validation live here. docs/configuration.md owns the
# operator-facing behavior and bin/fm-watch.sh owns the audit cadence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

positive_integer_or_default() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*|0) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

browser_session_name() {  # <firstmate-home> <task-id>
  local home=$1 id=$2 digest
  [ -n "$home" ] || {
    echo "error: browser session name requires a Firstmate home" >&2
    return 1
  }
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || {
    echo "error: browser session home cannot be resolved: $home" >&2
    return 1
  }
  fm_task_id_creation_valid "$id" || {
    echo "error: invalid browser-session task id '$id'" >&2
    return 1
  }
  digest=$(printf 'firstmate-browser-v1\0%s\0%s' "$home" "$id" | git hash-object --stdin 2>/dev/null) || {
    echo "error: could not derive browser session identity for task $id" >&2
    return 1
  }
  case "$digest" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]* ) ;;
    *)
      echo "error: browser session identity for task $id is malformed" >&2
      return 1
      ;;
  esac
  printf 'fm-%s\n' "$digest"
}

browser_session_valid() {  # <session>
  local digest
  case "$1" in fm-*) digest=${1#fm-} ;; *) return 1 ;; esac
  [ "${#digest}" -eq 40 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; *) return 0 ;; esac
}

browser_session_from_meta() {  # <firstmate-home> <task-meta>; prints empty for legacy
  local home=$1 meta=$2 id count session expected
  if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
    echo "error: browser cleanup requires a readable regular task record: $meta" >&2
    return 1
  fi
  id=$(basename "$meta" .meta)
  fm_task_id_creation_valid "$id" || {
    echo "error: browser cleanup cannot derive a task id from $meta" >&2
    return 1
  }
  count=$(grep -c '^browser_session=' "$meta" 2>/dev/null || true)
  case "$count" in
    0) return 0 ;;
    1) ;;
    *)
      echo "error: task $id records browser_session more than once; refusing browser cleanup" >&2
      return 1
      ;;
  esac
  session=$(grep '^browser_session=' "$meta" | cut -d= -f2-)
  browser_session_valid "$session" || {
    echo "error: task $id records an invalid browser_session; refusing browser cleanup" >&2
    return 1
  }
  expected=$(browser_session_name "$home" "$id") || return 1
  [ "$session" = "$expected" ] || {
    echo "error: task $id's browser_session does not match its home-scoped identity; refusing browser cleanup" >&2
    return 1
  }
  printf '%s\n' "$session"
}

browser_state_root() {
  [ -n "${HOME:-}" ] || {
    echo "error: HOME is unset; browser session state cannot be resolved" >&2
    return 1
  }
  printf '%s/.chrome-devtools-axi\n' "$HOME"
}

browser_session_dir() {  # <session>
  local root
  root=$(browser_state_root) || return 1
  printf '%s/sessions/%s\n' "$root" "$1"
}

BROWSER_PID=
BROWSER_PORT=
browser_session_pid() {  # <session>; 0=read, 1=absent, 2=unsafe/malformed
  local session=$1 dir pid_file record pid port
  BROWSER_PID=
  BROWSER_PORT=
  dir=$(browser_session_dir "$session") || return 2
  pid_file="$dir/bridge.pid"
  if [ ! -e "$pid_file" ] && [ ! -L "$pid_file" ]; then
    return 1
  fi
  if [ ! -f "$pid_file" ] || [ -L "$pid_file" ] || [ ! -r "$pid_file" ]; then
    echo "error: browser session $session has an unsafe bridge.pid" >&2
    return 2
  fi
  record=$(jq -er '
    if (.pid | type) == "number" and (.pid | floor) == .pid and .pid > 1 and
       (.port | type) == "number" and (.port | floor) == .port and .port > 0 and .port <= 65535
    then "\(.pid) \(.port)"
    else error("invalid bridge identity")
    end
  ' "$pid_file" 2>/dev/null) || {
    echo "error: browser session $session has a malformed bridge.pid" >&2
    return 2
  }
  read -r pid port <<EOF
$record
EOF
  case "$pid:$port" in
    *[!0-9:]*|:*|*:)
      echo "error: browser session $session has a malformed bridge identity" >&2
      return 2
      ;;
  esac
  BROWSER_PID=$pid
  BROWSER_PORT=$port
  return 0
}

browser_pid_alive() {  # <pid>
  kill -0 "$1" 2>/dev/null
}

browser_pid_is_bridge() {  # <pid>
  local command
  command=$(LC_ALL=C ps -p "$1" -o command= 2>/dev/null) || return 1
  case "$command" in
    *'/chrome-devtools-axi-bridge.js'*|*'/chrome-devtools-axi-bridge.ts'*) return 0 ;;
    *) return 1 ;;
  esac
}

browser_health_matches_session() {  # <port> <session>
  node -e '
    const http = require("node:http");
    const port = Number(process.argv[1]);
    const expected = process.argv[2];
    const req = http.get({hostname: "127.0.0.1", port, path: "/health", timeout: 2000}, response => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", chunk => { body += chunk; });
      response.on("end", () => {
        try {
          const health = JSON.parse(body);
          process.exitCode = response.statusCode === 200 && health.status === "ok" && health.session === expected ? 0 : 1;
        } catch {
          process.exitCode = 1;
        }
      });
    });
    req.on("timeout", () => req.destroy());
    req.on("error", () => { process.exitCode = 1; });
  ' "$1" "$2" >/dev/null 2>&1
}

cleanup_browser_session() {  # <firstmate-home> <task-meta>
  local home=$1 meta=$2 session pid port rc attempt
  session=$(browser_session_from_meta "$home" "$meta") || return 1
  [ -n "$session" ] || return 0
  rc=0
  browser_session_pid "$session" || rc=$?
  case "$rc" in
    0) pid=$BROWSER_PID; port=$BROWSER_PORT ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  browser_pid_alive "$pid" || return 0
  browser_pid_is_bridge "$pid" || {
    echo "error: browser session $session records live PID $pid, but that PID is not chrome-devtools-axi's bridge; refusing to signal it" >&2
    return 1
  }
  browser_health_matches_session "$port" "$session" || {
    echo "error: browser session $session records bridge PID $pid, but its health endpoint does not report that exact session; refusing to signal it" >&2
    return 1
  }
  rc=0
  browser_session_pid "$session" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$BROWSER_PID" != "$pid" ] || [ "$BROWSER_PORT" != "$port" ]; then
    echo "error: browser session $session changed bridge identity during cleanup; refusing to signal it" >&2
    return 1
  fi
  command -v chrome-devtools-axi >/dev/null 2>&1 || {
    echo "error: browser session $session is live but chrome-devtools-axi is unavailable; refusing to orphan it" >&2
    return 1
  }
  if ! CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi stop >/dev/null; then
    echo "error: chrome-devtools-axi could not stop task browser session $session" >&2
    return 1
  fi
  attempt=0
  while [ "$attempt" -lt 20 ] && browser_pid_is_bridge "$pid"; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if browser_pid_is_bridge "$pid"; then
    echo "error: task browser session $session still owns bridge PID $pid after stop" >&2
    return 1
  fi
}

browser_stat_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

browser_session_activity_mtime() {  # <session>
  local session=$1 dir entry stamp latest=0
  dir=$(browser_session_dir "$session") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for entry in "$dir"/*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    stamp=$(browser_stat_mtime "$entry" || true)
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    [ "$stamp" -le "$latest" ] || latest=$stamp
  done
  [ "$latest" -gt 0 ] || return 1
  printf '%s\n' "$latest"
}

browser_process_counts() {
  LC_ALL=C ps -axo pid=,ppid=,command= 2>/dev/null | awk '
    function reaches_bridge(pid, p, n) {
      p=pid
      for (n=0; n<4096 && p>0; n++) {
        if (p in bridge) return 1
        if (!(p in parent) || parent[p] == p) return 0
        p=parent[p]
      }
      return 0
    }
    function reaches_browser(pid, p, n) {
      p=pid
      for (n=0; n<4096 && p>0; n++) {
        if (p in browser) return 1
        if (!(p in parent) || parent[p] == p) return 0
        p=parent[p]
      }
      return 0
    }
    function browser_root_command(value, lower) {
      lower=tolower(value)
      if (lower !~ /--headless(=new)?([[:space:]]|$)/ || lower ~ /--type=/) return 0
      return lower ~ /google chrome( for testing)?([[:space:]]|$)/ || \
        lower ~ /\/(google-chrome(-stable)?|chromium(-browser)?|chrome|chrome-headless-shell)([[:space:]]|$)/
    }
    {
      pid=$1; ppid=$2
      line=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]*/, "", line)
      parent[pid]=ppid
      command[pid]=line
      if (line ~ /chrome-devtools-axi-bridge\.(js|ts)([[:space:]]|$)/) bridge[pid]=1
    }
    END {
      roots=0
      helpers=0
      for (pid in command) {
        if (!(pid in bridge) && reaches_bridge(pid) && browser_root_command(command[pid])) {
          browser[pid]=1
          roots++
        }
      }
      for (pid in command) {
        if (!(pid in browser) && reaches_browser(pid)) helpers++
      }
      printf "%d %d\n", roots, helpers
    }
  '
}

WARNINGS=()
warning_add() { WARNINGS+=("$1"); }

marker_read() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] && cat "$1" 2>/dev/null
}

marker_write() {  # <path> <content>
  local path=$1 content=$2 tmp
  tmp="$path.tmp.${BASHPID:-$$}"
  (umask 077; printf '%s\n' "$content" > "$tmp") && mv -f "$tmp" "$path"
}

sweep_browser_sessions() {  # <firstmate-home> <state-dir>
  local home=$1 state=$2 now idle_timeout root_warn helper_warn meta id session rc pid
  local status_line verb signature terminal_marker activity age idle_marker backend target owner
  local counts roots helpers capacity_marker capacity_created=0 root
  [ -d "$home" ] || {
    echo "error: browser sweep Firstmate home is missing: $home" >&2
    return 1
  }
  [ -d "$state" ] && [ ! -L "$state" ] || {
    echo "error: browser sweep state directory is unsafe or missing: $state" >&2
    return 1
  }
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"

  now=$(date +%s)
  idle_timeout=$(positive_integer_or_default "${FM_BROWSER_IDLE_TIMEOUT_SECS:-}" 1800)
  root_warn=$(positive_integer_or_default "${FM_BROWSER_ROOT_WARN:-}" 4)
  helper_warn=$(positive_integer_or_default "${FM_BROWSER_HELPER_WARN:-}" 30)

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    session=$(browser_session_from_meta "$home" "$meta" 2>/dev/null) || {
      warning_add "task=$id browser ownership record is invalid"
      continue
    }
    [ -n "$session" ] || continue
    rc=0
    browser_session_pid "$session" 2>/dev/null || rc=$?
    case "$rc" in
      0) pid=$BROWSER_PID ;;
      1) continue ;;
      *) warning_add "task=$id session=$session bridge identity is unreadable"; continue ;;
    esac
    browser_pid_alive "$pid" || continue
    if ! browser_pid_is_bridge "$pid"; then
      warning_add "task=$id session=$session bridge PID $pid belongs to another process"
      continue
    fi

    status_line=$(last_status_line "$state/$id.status")
    verb=$(status_line_verb "$status_line")
    case "$verb" in
      done|failed)
        # Include the live bridge incarnation so a same-task browser restarted
        # after an earlier terminal cleanup is recovered on the next sweep too.
        signature=$(printf '%s' "$status_line" | cksum | awk -v pid="$pid" '{print $1 ":" $2 ":" pid}')
        terminal_marker="$state/.$id.browser-terminal-cleaned"
        if [ "$(marker_read "$terminal_marker" || true)" != "$signature" ]; then
          if cleanup_browser_session "$home" "$meta"; then
            marker_write "$terminal_marker" "$signature" || warning_add "task=$id browser terminal-cleanup marker could not be written"
          else
            warning_add "task=$id session=$session terminal cleanup failed"
          fi
        fi
        continue
        ;;
    esac

    activity=$(browser_session_activity_mtime "$session" || true)
    [ -n "$activity" ] || continue
    age=$((now - activity))
    [ "$age" -ge 0 ] || age=0
    idle_marker="$state/.$id.browser-idle-warned"
    if [ "$age" -lt "$idle_timeout" ]; then
      rm -f "$idle_marker"
      continue
    fi

    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    owner=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf unreadable)
    case "$owner" in
      dead|missing)
        if cleanup_browser_session "$home" "$meta"; then
          rm -f "$idle_marker"
        else
          warning_add "task=$id session=$session orphan cleanup failed owner=$owner age=${age}s"
        fi
        ;;
      *)
        signature="$activity:$owner"
        if [ "$(marker_read "$idle_marker" || true)" != "$signature" ]; then
          warning_add "task=$id session=$session idle=${age}s owner=$owner"
          marker_write "$idle_marker" "$signature" || warning_add "task=$id browser idle-warning marker could not be written"
        fi
        ;;
    esac
  done

  counts=$(browser_process_counts) || counts='0 0'
  read -r roots helpers <<EOF
$counts
EOF
  case "$roots:$helpers" in
    *[!0-9:]*|:*) roots=0; helpers=0 ;;
  esac
  root=$(browser_state_root) || return 1
  capacity_marker="$root/.firstmate-capacity-warning"
  if [ "$roots" -ge "$root_warn" ] || [ "$helpers" -ge "$helper_warn" ]; then
    if [ ! -e "$capacity_marker" ] && [ ! -L "$capacity_marker" ]; then
      mkdir -p "$root" || return 1
      if (set -C; umask 077; printf 'roots=%s helpers=%s\n' "$roots" "$helpers" > "$capacity_marker") 2>/dev/null; then
        capacity_created=1
      fi
    fi
    [ "$capacity_created" -eq 0 ] || warning_add "browser capacity roots=$roots/$root_warn helpers=$helpers/$helper_warn"
  elif [ -f "$capacity_marker" ] && [ ! -L "$capacity_marker" ]; then
    rm -f "$capacity_marker"
  fi

  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '%s' "${WARNINGS[0]}"
    for ((rc=1; rc < ${#WARNINGS[@]}; rc++)); do
      printf '; %s' "${WARNINGS[$rc]}"
    done
    printf '\n'
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    ;;
  name)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    browser_session_name "$2" "$3"
    ;;
  cleanup)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    cleanup_browser_session "$2" "$3"
    ;;
  sweep)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    sweep_browser_sessions "$2" "$3"
    ;;
  count)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    browser_process_counts | awk '{printf "roots=%s helpers=%s\n", $1, $2}'
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
