#!/usr/bin/env bash
# Standalone message identities; loaded after fm-task-inbox-lib.sh.
# Registry: state/services/<name>.json, schema fm-service.v1, exact name, pid,
# physical home, UTC registration started_at and hashed native PID identity.
# No argv or credential values are persisted. Normal shutdown deregisters;
# after abrupt death the next registration may replace the stale record, never
# the inbox. Missing/dead/ambiguous identities refuse, never become supervisor.
# Registration/deregistration share the participant's metadata lock with sends.
# A CLI registration must name its direct parent PID; use requires a descendant
# of that same live process. This is a same-UID operational guard, not a sandbox.
# Usage: fm_service_manage <state> register|deregister <name> <parent-pid>

fm_service_path() {  # <state> <name>
  [[ "$2" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] && [ "$2" != supervisor ] || return 1
  [ ! -L "$1" ] && [ ! -L "$1/services" ] || return 1
  [ ! -e "$1/services" ] || [ -d "$1/services" ] || return 1
  printf '%s/services/%s.json' "$1" "$2"
}

fm_service_fingerprint() {
  local identity
  fm_pid_alive "$1" || return 1
  identity=$(fm_pid_identity "$1") || return 1
  printf '%s' "$identity" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'
}

fm_service_record() {  # <state> <name>, caller serializes mutations
  local file home
  file=$(fm_service_path "$1" "$2") || return 1
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(wc -c < "$file")" -le 8192 ] || return 1
  home=$(cd "$FM_HOME" && pwd -P) || return 1
  jq -cse --arg name "$2" --arg home "$home" '
    select(length==1) | .[0] | select(type=="object")
    | select(keys==["fingerprint","home","name","pid","schema","started_at"])
    | select(.schema=="fm-service.v1" and .name==$name and .home==$home)
    | select((.pid|type)=="number" and .pid>1 and .pid<=2147483647 and .pid==(.pid|floor))
    | select((.fingerprint|type)=="string" and (.fingerprint|test("^[a-f0-9]{64}$")))
    | select((.started_at|type)=="string" and (.started_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
  ' "$file"
}

fm_service_live() {  # <state> <name>
  local record fingerprint
  [ ! -e "$1/$2.meta" ] && [ ! -L "$1/$2.meta" ] || return 1
  record=$(fm_service_record "$1" "$2") || return 1
  fingerprint=$(fm_service_fingerprint "$(printf '%s' "$record" | jq -r .pid)") || return 1
  [ "$fingerprint" = "$(printf '%s' "$record" | jq -r .fingerprint)" ]
}

fm_service_descendant() {  # <registered-pid>, bounded native ancestry, never a label
  local pid=$PPID i
  for ((i=0; i<64; i++)); do
    [ "$pid" != "$1" ] || return 0
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
  done
  return 1
}

fm_service_sender() {  # <state> <name>
  local record
  fm_service_live "$1" "$2" || { echo 'error: service identity is absent, dead or ambiguous' >&2; return 1; }
  record=$(fm_service_record "$1" "$2") || return 1
  fm_service_descendant "$(printf '%s' "$record" | jq -r .pid)" || {
    echo 'error: service sender is not a descendant of its registered process' >&2; return 1;
  }
  printf '%s' "$2"
}

fm_service_unmarked_caller() {  # <state>; no registered service may fall back to another identity
  local file pid record name
  [ ! -L "$1/services" ] || return 1
  [ ! -e "$1/services" ] || [ -d "$1/services" ] || return 1
  for file in "$1/services/"*.json; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    name=${file##*/}; name=${name%.json}
    record=$(fm_service_record "$1" "$name") || return 1
    pid=$(printf '%s' "$record" | jq -r .pid) || return 1
    if fm_service_descendant "$pid"; then
      echo 'error: registered service requires its explicit FM_SERVICE_ID' >&2; return 1
    fi
  done
}

fm_service_manage() (
  set -eu
  local state=$1 operation=$2 name=$3 pid=$4 file lock='' tmp='' record fingerprint rc outcome
  local phase="service_$operation" sender='' request_id started_ms step_ms
  # shellcheck source=bin/fm-message-telemetry-lib.sh
  . "$SCRIPT_DIR/fm-message-telemetry-lib.sh"
  request_id="req-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  started_ms=$(fm_timing_now_ms); step_ms=$started_ms
  trap 'rc=$?; [ -z "$tmp" ] || rm -f "$tmp"; [ -z "$lock" ] || fm_lock_release "$lock";
    outcome=rejected; [ "$rc" -ne 0 ] || outcome=accepted;
    fm_message_log finished "$outcome" "$phase"' EXIT
  case "$operation" in register|deregister) ;; *) exit 1 ;; esac
  [ "$pid" = "$PPID" ] && [ "$pid" -gt 1 ] || { echo 'error: service must register or deregister its own parent process' >&2; exit 1; }
  [ "$(cd "$state" && pwd -P)" = "$(cd "$FM_HOME/state" && pwd -P)" ] || exit 1
  file=$(fm_service_path "$state" "$name") || exit 1
  [ ! -e "$state/$name.meta" ] && [ ! -L "$state/$name.meta" ] || { echo 'error: service name conflicts with a task' >&2; exit 1; }
  fingerprint=$(fm_service_fingerprint "$pid") || exit 1
  sender=$name; fm_message_log port.enter '' "$phase"
  lock=$(fm_meta_lock_path "$state/$name.meta")
  fm_task_inbox_lock_acquire "$lock" || { lock=''; exit 1; }
  [ ! -e "$state/$name.meta" ] && [ ! -L "$state/$name.meta" ] || exit 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    record=$(fm_service_record "$state" "$name") || { echo 'error: invalid service record' >&2; exit 1; }
    # A changed fingerprint is not proof the recorded process is gone.
    if [ "$operation" = deregister ] || fm_pid_alive "$(printf '%s' "$record" | jq -r .pid)"; then
      printf '%s' "$record" | jq -e --argjson pid "$pid" --arg fingerprint "$fingerprint" \
        '.pid==$pid and .fingerprint==$fingerprint' >/dev/null || { echo 'error: service name belongs to another process' >&2; exit 1; }
      if [ "$operation" = register ]; then printf '%s\n' "$record"; exit 0; fi
    fi
  elif [ "$operation" = deregister ]; then exit 0
  fi
  if [ "$operation" = deregister ]; then rm "$file"; exit 0; fi
  mkdir -p "$state/services"
  tmp=$(mktemp "$state/services/.registration.XXXXXX")
  jq -cn --arg name "$name" --argjson pid "$pid" --arg home "$(cd "$FM_HOME" && pwd -P)" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg fingerprint "$fingerprint" \
    '{schema:"fm-service.v1",name:$name,pid:$pid,home:$home,started_at:$started,fingerprint:$fingerprint}' > "$tmp"
  mv "$tmp" "$file"; tmp=''
  fm_service_record "$state" "$name"
)
