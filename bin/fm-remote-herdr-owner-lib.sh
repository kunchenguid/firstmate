#!/usr/bin/env bash
# Who owns a Herdr session socket, and was that process born in the Aqua
# login session?
#
# Source this file; it defines functions only. It is the single owner of the
# socket-owner discovery and birth classification shared by
# bin/fm-remote-herdr-guard.sh (the launch agent's exec target) and
# bin/fm-remote-doctor.sh (the readiness check for that session).
#
# Why birth matters: a herdr server, and every pane and agent it later spawns,
# keeps the macOS audit session of whatever started it. Only the Aqua login
# session (the gui/<uid> launchd domain) can read the login keychain without a
# UI prompt. A server started over SSH - herdr's own remote attach does this
# when it finds no server, and it wins the socket at boot because sshd accepts
# connections before the login session exists - runs in sshd's audit session,
# where `security find-generic-password -w` exits 36 (interaction not allowed)
# and every claude pane silently falls back to a stale plaintext credentials
# file and reports "Login expired". docs/verification/runtime-backends.md
# ("fm-remote server birth and login-keychain access") holds the dated
# evidence for every marker read here.
#
# Functions:
#   fm_remote_herdr_socket_owner <socket-path>
#     Prints the pid of the herdr process that holds <socket-path>, or nothing
#     when no herdr process does. Reads `lsof -U -a -c herdr -F pn`; on macOS
#     `pgrep -f` cannot see the herdr server's argv, so lsof is the owner
#     source. When several herdr processes list the path, the one whose argv
#     runs `server` wins. Returns 2, printing nothing, when lsof does not
#     resolve; the caller decides what an unprovable owner means.
#   fm_remote_herdr_process_env <pid>
#     Prints the process environment as NAME=VALUE lines: `ps -Eww` on darwin
#     (own-uid processes only, and macOS hides the environment of Apple
#     platform binaries such as /bin/sleep even from the same user; a herdr
#     server is never one), /proc/<pid>/environ elsewhere.
#   fm_remote_herdr_process_ancestry <pid>
#     Prints "<pid> <command>" for <pid> and each ancestor up to pid 1.
#   fm_remote_herdr_owner_birth <pid>
#     Prints exactly one word, the strongest marker present:
#       ssh      SSH_CONNECTION, SSH_CLIENT, or SSH_TTY in the environment, or
#                an ancestor that is sshd or herdr's remote-client-bridge
#                (matched on argv[0] and whole arguments only)
#       launchd  XPC_SERVICE_NAME=<label>, with launchctl proving that job is
#                the owner in gui/<uid> or is loaded only in that domain
#       worker   FM_REMOTE_JOB_ACTIVE=1, with launchctl proving that
#                dev.firstmate.remote-job is loaded only in gui/<uid>
#       unknown  none of the above; XPC_SERVICE_NAME alone, including value 0,
#                does not prove an Aqua birth
#   fm_remote_herdr_birth_is_aqua <birth>
#     Succeeds only for launchd and worker. `unknown` is deliberately not
#     Aqua: a server that cannot prove its birth is treated like a foreign one,
#     because leaving it in place silently reproduces the keychain failure.

fm_remote_herdr_socket_owner() { # <socket-path>
  local socket=$1 real pid='' line candidates='' candidate cmd
  [ -n "$socket" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 2
  real=$(CDPATH='' cd -- "$(dirname "$socket")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$socket")") || real=$socket
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        [ -n "$pid" ] || continue
        case "${line#n}" in
          "$socket"|"$real") candidates="${candidates}${pid}"$'\n' ;;
        esac
        ;;
    esac
  done < <(lsof -U -a -c herdr -F pn 2>/dev/null)
  [ -n "$candidates" ] || return 0
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    cmd=$(ps -o command= -p "$candidate" 2>/dev/null || true)
    case " $cmd " in *' server '*) printf '%s\n' "$candidate"; return 0 ;; esac
  done <<EOF2
$candidates
EOF2
  printf '%s\n' "${candidates%%$'\n'*}"
}

fm_remote_herdr_process_env() { # <pid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ"
    return 0
  fi
  ps -Eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true
}

fm_remote_herdr_process_ancestry() { # <pid>
  local pid=$1 depth=0 line ppid
  while [ "$depth" -lt 64 ]; do
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 0 ] || return 0
    line=$(ps -o ppid=,command= -p "$pid" 2>/dev/null) || return 0
    [ -n "$line" ] || return 0
    ppid=$(printf '%s' "$line" | awk '{print $1}')
    printf '%s %s\n' "$pid" "$(printf '%s' "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')"
    [ "$pid" -ne 1 ] || return 0
    pid=$ppid
    depth=$((depth + 1))
  done
}

fm_remote_herdr_gui_job_proves_owner() { # <uid> <label> <pid>
  local uid=$1 label=$2 pid=$3 job
  [ -n "$label" ] && [ "$label" != 0 ] || return 1
  job=$(launchctl print "gui/$uid/$label" 2>/dev/null) || return 1
  if printf '%s\n' "$job" | awk -v expected="$pid" '
    $1 == "pid" && $2 == "=" && $3 == expected { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    return 0
  fi
  ! launchctl print "user/$uid/$label" >/dev/null 2>&1
}

fm_remote_herdr_gui_job_is_exclusive() { # <uid> <label>
  local uid=$1 label=$2
  launchctl print "gui/$uid/$label" >/dev/null 2>&1 \
    && ! launchctl print "user/$uid/$label" >/dev/null 2>&1
}

fm_remote_herdr_owner_birth() { # <pid>
  local pid=$1 env uid xpc_line label
  env=$(fm_remote_herdr_process_env "$pid") || { printf 'unknown\n'; return 0; }
  if printf '%s\n' "$env" | grep -q -E '^SSH_(CONNECTION|CLIENT|TTY)='; then
    printf 'ssh\n'
    return 0
  fi
  uid=$(id -u 2>/dev/null) || uid=
  xpc_line=$(printf '%s\n' "$env" | grep -E '^XPC_SERVICE_NAME=' | head -1 || true)
  label=${xpc_line#XPC_SERVICE_NAME=}
  if [ -n "$uid" ] && [ -n "$xpc_line" ] \
    && fm_remote_herdr_gui_job_proves_owner "$uid" "$label" "$pid"; then
    printf 'launchd\n'
    return 0
  fi
  if printf '%s\n' "$env" | grep -q -E '^FM_REMOTE_JOB_ACTIVE=1$' \
    && [ -n "$uid" ] \
    && fm_remote_herdr_gui_job_is_exclusive "$uid" dev.firstmate.remote-job; then
    printf 'worker\n'
    return 0
  fi
  if fm_remote_herdr_process_ancestry "$pid" | fm_remote_herdr_ancestry_has_ssh_origin; then
    printf 'ssh\n'
    return 0
  fi
  printf 'unknown\n'
}

# Reads "<pid> <command>" ancestry lines on stdin and succeeds when one of
# them IS sshd (argv[0] sshd or sshd-session, including the "sshd-session:
# user@notty" process title) or IS herdr's SSH remote attach (argv[0] herdr
# with the whole-word argument remote-client-bridge). Only argv[0] and whole
# arguments are matched: an ancestor whose free-text arguments merely mention
# those words, such as an agent carrying a brief, must not count.
fm_remote_herdr_ancestry_has_ssh_origin() {
  awk '
    {
      argv0 = $2
      sub(/.*\//, "", argv0)
      sub(/:$/, "", argv0)
      if (argv0 == "sshd" || argv0 == "sshd-session") { found = 1; exit }
      if (argv0 == "herdr") {
        for (i = 3; i <= NF; i++) if ($i == "remote-client-bridge") { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

fm_remote_herdr_birth_is_aqua() { # <birth>
  case "$1" in launchd|worker) return 0 ;; esac
  return 1
}
