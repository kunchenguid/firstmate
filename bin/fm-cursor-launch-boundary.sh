#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-process-identity-lib.sh
. "$SCRIPT_DIR/fm-process-identity-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

TOKEN=$1
MARKER=$2
PROOF=$MARKER.proof
COMMAND=$3
LAUNCH_PID_FILE=$PROOF.launch
HANDOFF=$PROOF.handoff.$$
HANDOFF_CLOSED=$PROOF.handoff.closed.$$
HANDOFF_COMPLETE=$PROOF.handoff.complete
WORKER_FILE=$PROOF.worker
TOKEN_ABSENT_FILE=$PROOF.token.absent
TREE_COMPLETE_FILE=$PROOF.tree.complete
HANDOFF_READER_PID=
LAUNCH_PID=
WORKER_PID=
OBSERVER_PID=
OBSERVER_STOP=$PROOF.observe.stop.$$
scan_token_process() {
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} environ
  ARGS=
  environ="$proc_root/$pid/environ"
  if [ -r "$environ" ]; then
    tr '\0' '\n' < "$environ" 2>/dev/null \
      | grep -Fqx "FM_CURSOR_LAUNCH_TOKEN=$TOKEN" || return 1
    ARGS=$(tr '\0' ' ' < "$proc_root/$pid/cmdline" 2>/dev/null || true)
    return 0
  fi
  ARGS=$(LC_ALL=C ps eww -p "$pid" -o command= 2>/dev/null || true)
  case "$ARGS" in
    *"FM_CURSOR_LAUNCH_TOKEN=$TOKEN"*) return 0 ;;
  esac
  return 1
}
cleanup() {
  if [ -n "$OBSERVER_PID" ]; then
    : > "$OBSERVER_STOP"
    kill "$OBSERVER_PID" 2>/dev/null || true
    wait "$OBSERVER_PID" 2>/dev/null || true
  fi
  exec 9>&- 2>/dev/null || true
  if [ -n "$HANDOFF_READER_PID" ]; then
    kill "$HANDOFF_READER_PID" 2>/dev/null || true
    wait "$HANDOFF_READER_PID" 2>/dev/null || true
  fi
  rm -f -- "$HANDOFF" "$HANDOFF_CLOSED" "$OBSERVER_STOP"
}
trap cleanup EXIT
rm -f -- "$LAUNCH_PID_FILE" "$WORKER_FILE" "$TOKEN_ABSENT_FILE" "$TREE_COMPLETE_FILE"
rm -f -- "$HANDOFF" "$HANDOFF_CLOSED" "$HANDOFF_COMPLETE" "$OBSERVER_STOP"
if ! mkfifo "$HANDOFF" 2>/dev/null; then
  exit 1
fi
(
  cat "$HANDOFF" >/dev/null || exit 1
  TMP="$HANDOFF_CLOSED.tmp.$$"
  echo complete > "$TMP" && mv -f -- "$TMP" "$HANDOFF_CLOSED" || exit 1
  TMP="$HANDOFF_COMPLETE.tmp.$$"
  echo complete > "$TMP" && mv -f -- "$TMP" "$HANDOFF_COMPLETE"
) &
HANDOFF_READER_PID=$!
if ! exec 9>"$HANDOFF"; then
  exit 1
fi

scan_token_ps_snapshot() {
  local discover_workers=$1 pid args identity tmp environ proc_root=/proc grep_z=0
  if [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ] && [ -d "$proc_root" ]; then
    grep -Fzl '' /dev/null >/dev/null 2>&1
    case "$?" in 0|1) grep_z=1 ;; esac
  fi
  if [ "$grep_z" -eq 1 ]; then
    FOUND=0
    while IFS= read -r -d '' environ; do
      pid=${environ%/environ}
      pid=${pid##*/}
      [ -n "$pid" ] || continue
      [ "$pid" != "$$" ] && [ "$pid" != "${BASHPID:-$$}" ] \
        && [ "$pid" != "$PPID" ] && [ "$pid" != "$OBSERVER_PID" ] \
        && [ "$pid" != "$HANDOFF_READER_PID" ] || continue
      if [ -n "$LAUNCH_PID" ] && [ "$pid" = "$LAUNCH_PID" ]; then
        continue
      fi
      if [ -n "$WORKER_PID" ] && [ "$pid" = "$WORKER_PID" ]; then
        continue
      fi
      if [ "$discover_workers" -eq 0 ]; then
        FOUND=1
        continue
      fi
      args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null || true)
      case "$args" in
        *'worker-server'*)
          if [ -z "$WORKER_PID" ]; then
            if identity=$(fm_process_identity "$pid" 2>/dev/null); then
              tmp="$WORKER_FILE.tmp.${BASHPID:-$$}"
              if printf '%s %s\n' "$pid" "$identity" > "$tmp" \
                 && mv -f -- "$tmp" "$WORKER_FILE"; then
                WORKER_PID=$pid
              else
                rm -f -- "$tmp"
                FOUND=1
              fi
            else
              FOUND=1
            fi
          fi
          ;;
      esac
    done < <(grep -Fzl -- "FM_CURSOR_LAUNCH_TOKEN=$TOKEN" \
      "$proc_root"/*/environ 2>/dev/null)
    return
  fi
  PIDS=$(LC_ALL=C ps eww -u "$(id -u)" -o pid= -o command= 2>/dev/null || true)
  FOUND=0
  while read -r pid args; do
    pid=${pid#"${pid%%[![:space:]]*}"}
    pid=${pid%"${pid##*[![:space:]]}"}
    [ -n "$pid" ] || continue
    [ "$pid" != "$$" ] && [ "$pid" != "${BASHPID:-$$}" ] \
      && [ "$pid" != "$PPID" ] && [ "$pid" != "$OBSERVER_PID" ] \
      && [ "$pid" != "$HANDOFF_READER_PID" ] || continue
    if [ -n "$LAUNCH_PID" ] && [ "$pid" = "$LAUNCH_PID" ]; then
      continue
    fi
    if [ -n "$WORKER_PID" ] && [ "$pid" = "$WORKER_PID" ]; then
      continue
    fi
    case "$args" in
      *"FM_CURSOR_LAUNCH_TOKEN=$TOKEN"*) ;;
      *) continue ;;
    esac
    if [ "$discover_workers" -eq 0 ]; then
      FOUND=1
      continue
    fi
    case "$args" in
      *'worker-server'*)
        if [ -z "$WORKER_PID" ]; then
          if identity=$(fm_process_identity "$pid" 2>/dev/null); then
            tmp="$WORKER_FILE.tmp.${BASHPID:-$$}"
            if printf '%s %s\n' "$pid" "$identity" > "$tmp" \
               && mv -f -- "$tmp" "$WORKER_FILE"; then
              WORKER_PID=$pid
            else
              rm -f -- "$tmp"
              FOUND=1
            fi
          else
            FOUND=1
          fi
        fi
        ;;
    esac
  done <<EOF
$PIDS
EOF
}

scan_token_workers() {
  local pid identity tmp
  if [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ]; then
    scan_token_ps_snapshot 1
    return
  fi
  PIDS=$(LC_ALL=C ps -u "$(id -u)" -o pid= 2>/dev/null || true)
  FOUND=0
  while IFS= read -r PID; do
    PID=${PID#"${PID%%[![:space:]]*}"}
    PID=${PID%"${PID##*[![:space:]]}"}
    [ -n "$PID" ] || continue
    [ "$PID" != "$$" ] && [ "$PID" != "${BASHPID:-$$}" ] \
      && [ "$PID" != "$PPID" ] && [ "$PID" != "$OBSERVER_PID" ] \
      && [ "$PID" != "$HANDOFF_READER_PID" ] || continue
    if [ -n "$LAUNCH_PID" ] && [ "$PID" = "$LAUNCH_PID" ]; then
      continue
    fi
    if scan_token_process "$PID" 2>/dev/null; then
        case "$ARGS" in
          *'worker-server'*)
            if [ -z "$WORKER_PID" ]; then
              if identity=$(fm_process_identity "$PID" 2>/dev/null); then
                tmp="$WORKER_FILE.tmp.${BASHPID:-$$}"
                if printf '%s %s\n' "$PID" "$identity" > "$tmp" \
                   && mv -f -- "$tmp" "$WORKER_FILE"; then
                  WORKER_PID=$PID
                else
                  rm -f -- "$tmp"
                  FOUND=1
                fi
              else
                FOUND=1
              fi
            fi
            ;;
        esac
    fi
  done <<EOF
$PIDS
EOF
  if [ "$FOUND" -eq 0 ]; then
    : > "$TOKEN_ABSENT_FILE"
  else
    rm -f -- "$TOKEN_ABSENT_FILE"
  fi
}

observe_token_workers() {
  exec 9>&-
  unset FM_CURSOR_LAUNCH_TOKEN FM_CURSOR_EXECUTABLE FM_CURSOR_IDENTITY_FILE \
    FM_CURSOR_BOUNDARY_LAUNCH_FILE
  while [ ! -f "$OBSERVER_STOP" ]; do
    if [ -z "$LAUNCH_PID" ]; then
      read -r LAUNCH_PID < "$LAUNCH_PID_FILE" 2>/dev/null || true
    fi
    scan_token_workers
    if [ -n "$LAUNCH_PID" ] && ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
      scan_launch_tree
      if [ "$FOUND" -eq 0 ]; then
        scan_launch_group
      fi
      if [ "$FOUND" -eq 0 ]; then
        scan_token_processes
        if [ "$FOUND" -eq 0 ]; then
          : > "$TREE_COMPLETE_FILE"
          break
        fi
      fi
    fi
    sleep 0.1
  done
}

scan_token_processes() {
  local pid
  if [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ]; then
    scan_token_ps_snapshot 0
    if [ "$FOUND" -eq 0 ]; then
      : > "$TOKEN_ABSENT_FILE"
    else
      rm -f -- "$TOKEN_ABSENT_FILE"
    fi
    return
  fi
  PIDS=$(LC_ALL=C ps -u "$(id -u)" -o pid= 2>/dev/null || true)
  FOUND=0
  while IFS= read -r PID; do
    PID=${PID#"${PID%%[![:space:]]*}"}
    PID=${PID%"${PID##*[![:space:]]}"}
    [ -n "$PID" ] || continue
    [ "$PID" != "$$" ] && [ "$PID" != "${BASHPID:-$$}" ] \
      && [ "$PID" != "$PPID" ] && [ "$PID" != "$OBSERVER_PID" ] \
      && [ "$PID" != "$HANDOFF_READER_PID" ] || continue
    if [ -n "$LAUNCH_PID" ] && [ "$PID" = "$LAUNCH_PID" ]; then
      continue
    fi
    if [ -n "$WORKER_PID" ] && [ "$PID" = "$WORKER_PID" ]; then
      continue
    fi
    scan_token_process "$PID" 2>/dev/null && FOUND=1
  done <<EOF
$PIDS
EOF
}

scan_launch_group() {
  local record_pid record_identity record_pgid own_pgid pid current_pgid record_sid own_sid current_sid saved_pgid
  IFS=$'\t' read -r record_pid record_identity record_pgid < "$LAUNCH_PID_FILE" 2>/dev/null || return 0
  case "$record_pgid" in ''|*[!0-9]*|0|1) return 0 ;; esac
  saved_pgid=$record_pgid
  IFS=$'\t' read -r record_pgid record_sid < <(sed -n '3p' "$LAUNCH_PID_FILE")
  [ -n "$record_pgid" ] || record_pgid=$saved_pgid
  own_pgid=$(LC_ALL=C ps -p "$$" -o pgid= 2>/dev/null || true)
  own_pgid=$(printf '%s' "$own_pgid" | tr -d '[:space:]')
  own_sid=$(LC_ALL=C ps -p "$$" -o sid= 2>/dev/null || true)
  own_sid=$(printf '%s' "$own_sid" | tr -d '[:space:]')
  [ "$record_pgid" != "$own_pgid" ] || [ "$record_sid" != "$own_sid" ] || return 0
  if [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ]; then
    PIDS=$(LC_ALL=C ps -u "$(id -u)" -o pid= -o pgid= -o sid= 2>/dev/null || true)
    FOUND=0
    while read -r pid current_pgid current_sid; do
      pid=${pid#"${pid%%[![:space:]]*}"}
      pid=${pid%"${pid##*[![:space:]]}"}
      [ -n "$pid" ] || continue
      [ "$pid" != "$$" ] && [ "$pid" != "${BASHPID:-$$}" ] \
        && [ "$pid" != "$PPID" ] && [ "$pid" != "$OBSERVER_PID" ] \
        && [ "$pid" != "$HANDOFF_READER_PID" ] || continue
      [ "$pid" != "$record_pid" ] || continue
      [ -n "$WORKER_PID" ] && [ "$pid" = "$WORKER_PID" ] && continue
      if [ "$current_pgid" = "$record_pgid" ] || \
         { [ -n "$record_sid" ] && [ "$current_sid" = "$record_sid" ]; }; then
        FOUND=1
        return
      fi
    done <<EOF
$PIDS
EOF
    return
  fi
  PIDS=$(LC_ALL=C ps -u "$(id -u)" -o pid= 2>/dev/null || true)
  FOUND=0
  while IFS= read -r PID; do
    PID=${PID#"${PID%%[![:space:]]*}"}
    PID=${PID%"${PID##*[![:space:]]}"}
    [ -n "$PID" ] || continue
    [ "$PID" != "$$" ] && [ "$PID" != "${BASHPID:-$$}" ] \
      && [ "$PID" != "$PPID" ] && [ "$PID" != "$OBSERVER_PID" ] \
      && [ "$PID" != "$HANDOFF_READER_PID" ] || continue
    [ "$PID" != "$record_pid" ] || continue
    [ -n "$WORKER_PID" ] && [ "$PID" = "$WORKER_PID" ] && continue
    current_pgid=$(LC_ALL=C ps -p "$PID" -o pgid= 2>/dev/null || true)
    current_pgid=$(printf '%s' "$current_pgid" | tr -d '[:space:]')
    current_sid=$(LC_ALL=C ps -p "$PID" -o sid= 2>/dev/null || true)
    current_sid=$(printf '%s' "$current_sid" | tr -d '[:space:]')
    if [ "$current_pgid" = "$record_pgid" ] || \
       { [ -n "$record_sid" ] && [ "$current_sid" = "$record_sid" ]; }; then
      FOUND=1
    fi
  done <<EOF
$PIDS
EOF
}

scan_launch_tree() {
  local pid current parent
  if [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ]; then
    PIDS=$(LC_ALL=C ps -u "$(id -u)" -o pid= -o ppid= 2>/dev/null || true)
    FOUND=0
    while read -r pid parent; do
      pid=${pid#"${pid%%[![:space:]]*}"}
      pid=${pid%"${pid##*[![:space:]]}"}
      [ -n "$pid" ] || continue
      [ "$pid" != "$$" ] && [ "$pid" != "${BASHPID:-$$}" ] \
        && [ "$pid" != "$PPID" ] && [ "$pid" != "$OBSERVER_PID" ] \
        && [ "$pid" != "$HANDOFF_READER_PID" ] || continue
      [ "$pid" != "$LAUNCH_PID" ] || continue
      [ -n "$WORKER_PID" ] && [ "$pid" = "$WORKER_PID" ] && continue
      current=$pid
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        parent=$(printf '%s\n' "$PIDS" | awk -v pid="$current" '$1 == pid { print $2; exit }')
        case "$parent" in
          "$LAUNCH_PID") FOUND=1; break 2 ;;
          ''|*[!0-9]*|0|1) break ;;
        esac
        current=$parent
      done
    done <<EOF
$PIDS
EOF
    return
  fi
  PIDS=$(LC_ALL=C ps -u "$(id -u)" -o pid= 2>/dev/null || true)
  FOUND=0
  while IFS= read -r PID; do
    PID=${PID#"${PID%%[![:space:]]*}"}
    PID=${PID%"${PID##*[![:space:]]}"}
    [ -n "$PID" ] || continue
    [ "$PID" != "$$" ] && [ "$PID" != "${BASHPID:-$$}" ] \
      && [ "$PID" != "$PPID" ] && [ "$PID" != "$OBSERVER_PID" ] \
      && [ "$PID" != "$HANDOFF_READER_PID" ] || continue
    [ "$PID" != "$LAUNCH_PID" ] || continue
    [ -n "$WORKER_PID" ] && [ "$PID" = "$WORKER_PID" ] && continue
    current=$PID
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      parent=$(fm_cursor_process_parent_pid "$current" 2>/dev/null || true)
      case "$parent" in
        "$LAUNCH_PID") FOUND=1; break ;;
        ''|*[!0-9]*|0|1) break ;;
      esac
      current=$parent
    done
  done <<EOF
$PIDS
EOF
}

observe_token_workers </dev/null >/dev/null 2>&1 &
OBSERVER_PID=$!
FM_CURSOR_BOUNDARY_PID_FILE="$LAUNCH_PID_FILE" bash -c '
  pid=$BASHPID
  identity=
  if [ -r "/proc/$pid/stat" ]; then
    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null || true)
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] && identity="starttime=${stat_fields[19]}"
  fi
  if [ -z "$identity" ]; then
    value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [ -n "$value" ] && identity="lstart=$value"
  fi
  pgid=$(LC_ALL=C ps -p "$pid" -o pgid= 2>/dev/null || true)
  pgid=$(printf '%s' "$pgid" | tr -d '[:space:]')
  sid=$(LC_ALL=C ps -p "$pid" -o sid= 2>/dev/null || true)
  sid=$(printf '%s' "$sid" | tr -d '[:space:]')
  printf "%s\t%s\t%s\n" "$pid" "$identity" "$pgid" > "$FM_CURSOR_BOUNDARY_PID_FILE"
  printf "%s\t%s\n" "${FM_CURSOR_LAUNCH_TOKEN:-}" "${FM_CURSOR_EXECUTABLE:-}" >> "$FM_CURSOR_BOUNDARY_PID_FILE"
  printf "%s\t%s\n" "$pgid" "$sid" >> "$FM_CURSOR_BOUNDARY_PID_FILE"
  eval "$1"
' _ "$COMMAND"
STATUS=$?
if [ -r "$WORKER_FILE" ]; then
  read -r WORKER_PID _ < "$WORKER_FILE" || true
fi
read -r LAUNCH_PID < "$LAUNCH_PID_FILE" 2>/dev/null || true
if [ -z "$LAUNCH_PID" ]; then
  : > "$OBSERVER_STOP"
  wait "$OBSERVER_PID" 2>/dev/null || true
  OBSERVER_PID=
  exit "${STATUS:-1}"
fi
exec 9>&-

while [ ! -f "$TREE_COMPLETE_FILE" ]; do
  kill -0 "$OBSERVER_PID" 2>/dev/null || break
  sleep 0.1
done
wait "$OBSERVER_PID" 2>/dev/null || true
OBSERVER_PID=
[ -f "$TREE_COMPLETE_FILE" ] || exit "${STATUS:-1}"

if [ -n "$WORKER_PID" ] && [ ! -f "$HANDOFF_CLOSED" ]; then
  kill "$HANDOFF_READER_PID" 2>/dev/null || true
  wait "$HANDOFF_READER_PID" 2>/dev/null || true
  TMP="$HANDOFF_COMPLETE.tmp.$$"
  echo complete > "$TMP" && mv -f -- "$TMP" "$HANDOFF_COMPLETE"
else
  wait "$HANDOFF_READER_PID" 2>/dev/null || true
fi
unset FM_CURSOR_LAUNCH_TOKEN

fm_cursor_launch_boundary_complete_file "$LAUNCH_PID_FILE" "$HANDOFF_COMPLETE" || exit "$STATUS"
TMP="$PROOF.tmp.$$"
echo complete > "$TMP" && mv -f -- "$TMP" "$PROOF" || exit "$STATUS"
TMP="$MARKER.tmp.$$"
echo complete > "$TMP" && mv -f -- "$TMP" "$MARKER" || exit "$STATUS"
exit "$STATUS"
