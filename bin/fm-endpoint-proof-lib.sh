#!/usr/bin/env bash
# fm-endpoint-proof-lib.sh - the ONE owner of how firstmate identifies a tmux
# task endpoint beyond its window label, and of the evidence that a recorded
# tmux endpoint is GONE rather than merely unreachable from this seat.
#
# Sourced, never executed; sourcing has no side effects. The consumers are
# bin/fm-control-lib.sh (fm_control_endpoint_absence_verdict, the control
# plane's single absence proof), bin/fm-spawn.sh (which records the identity at
# every spawn and relaunch and re-proves absence before it rebinds), and
# bin/fm-endpoint-proof.sh (the read-only evidence report and the identity
# backfill).
#
# Why this exists. A tmux task record names its endpoint only as
# `window=<session>:fm-<id>`. That label means nothing once the tmux server it
# lived on is gone: `list-windows` describes only the server THIS process
# addresses, so a server that was killed (a crash, a WSL or machine restart
# that wipes /tmp), a server on another socket, and a window that was renamed
# all read the same - `missing`. Acting on `missing` is how a duplicate agent
# lands on a live worktree, so the control plane refused every tmux `missing`
# and a task whose terminal was lost with its server could never be recovered.
#
# What a record now carries (written by bin/fm-spawn.sh for every tmux task):
#   tmux_socket        the server's socket path (tmux's #{socket_path})
#   tmux_server_pid    the server's pid (#{pid})
#   tmux_server_start  the server's start time (#{start_time}); with the pid it
#                      names one server INSTANCE, which a reused pid or a
#                      reused socket path cannot impersonate
#   tmux_window_id     the window's stable id (#{window_id}); unlike the label
#                      it survives a rename or a move between sessions
#   endpoint_host      a hash of this host's machine identity
#   endpoint_boot      the kernel boot id, when the platform exposes one
# A record with none of these is LEGACY (spawned before they existed), one with
# some of them or an invalid one is MALFORMED, and both can never be proven
# absent from the record alone.
#
# The proof, for a complete record (fm_endpoint_tmux_proof). It prints
# "<verdict>\t<detail>" and the verdict is one of:
#   gone      the endpoint is PROVEN absent: no tmux server instance that could
#             hold the window exists, and no non-shell process is running in
#             the task's worktree. The detail names the basis.
#   unproven  anything else - the detail is the refusal sentence.
# Absence is established only by one of:
#   - the host rebooted since the record was written (same host identity,
#     different boot id): every process of the earlier boot, the tmux server
#     and the agent included, is gone;
#   - the recorded server instance is gone: its socket refuses or no longer
#     exists AND no tmux process holds the recorded pid, or the socket is now
#     served by a different instance (other pid or start time);
#   - the recorded server instance is alive and no longer has the recorded
#     window id (the server is authoritative about its own windows).
# Never an absence proof: a failed or timed-out read, a permission error, a
# record from another host, a server that is alive but unresponsive, a pid
# that is still a tmux process, and a window that is still there under another
# name or session. Each of those is `unproven`, which keeps every refusal the
# control plane already had. A global window inventory is never consulted as
# proof.
# After any absence basis the worktree is still checked for LIVE processes (a
# same-user non-shell process whose cwd is inside it, or whose environment
# carries FM_TASK_ID=<id>): a surviving agent that outlived its server vetoes
# the proof. A scan that cannot be completed vetoes it too.
#
# The legacy path (fm_endpoint_legacy_evidence, fm_endpoint_legacy_check). A
# legacy record carries nothing a proof can start from, so nothing is claimed.
# Instead the operator gets the evidence that can be read - host and boot
# identity, whether the record predates this boot, the ambient tmux server,
# every reachable tmux server of this user and whether any holds a window for
# the task, and the worktree's live processes - and a digest of exactly that
# evidence. Passing the digest back (--legacy-endpoint-consent) is the
# explicit, specific consent: it only verifies while the evidence is
# byte-identical, so it cannot be replayed once anything changed, it refuses
# outright while a live window or process for the task is visible, and it is
# recorded durably (fm_endpoint_consent_record). Consent never applies to a
# complete record: an unreachable or alive server is never overridden.
#
# Portability. Linux reads /proc; macOS reads sysctl and lsof. A signal a
# platform cannot provide is reported as unavailable and is never invented.
# Written for bash 3.2.

# The two libraries this one leans on are loaded the first time a function that
# needs them runs, never at source time: sourcing this file stays free, adds no
# startup dependency to the scripts that source it (a missing sibling must still
# be named by the owner that checks for it), and does not switch on the strict
# options fm-timeout-lib.sh sets.
FM_ENDPOINT_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$FM_ENDPOINT_LIB_DIR" != "${BASH_SOURCE[0]}" ] || FM_ENDPOINT_LIB_DIR=.

# fm_endpoint_need <function> <library>: source <library> unless <function>
# is already defined.
fm_endpoint_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  . "${FM_ENDPOINT_LIB_DIR:-/}/$2"
}

# A boundary on every read of a tmux server this seat does not own. A server
# that accepts the connection but never answers (stopped, wedged) must read as
# `unresponsive`, never block a recovery forever.
FM_ENDPOINT_PROBE_TIMEOUT=${FM_ENDPOINT_PROBE_TIMEOUT:-5}
# The record predates a boot only when it is older than boot time by more than
# this, so ordinary clock slop between a spawn and a boot never claims it.
FM_ENDPOINT_BOOT_MARGIN=${FM_ENDPOINT_BOOT_MARGIN:-300}

FM_ENDPOINT_TAB=$(printf '\t')

fm_endpoint_sha256() {  # stdin -> hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    return 1
  fi
}

# --- host and boot identity -------------------------------------------------

# A stable per-machine identity, hashed so the raw machine id never lands in a
# task record. Linux machine-id, macOS IOPlatformUUID, then the hostname.
fm_endpoint_host_id() {
  local raw=''
  if [ -r /etc/machine-id ]; then
    raw=$(head -c 64 /etc/machine-id 2>/dev/null) || raw=
  fi
  if [ -z "$raw" ] && [ -r /var/lib/dbus/machine-id ]; then
    raw=$(head -c 64 /var/lib/dbus/machine-id 2>/dev/null) || raw=
  fi
  if [ -z "$raw" ] && [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v ioreg >/dev/null 2>&1; then
    raw=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ {print $4; exit}') || raw=
  fi
  if [ -z "$raw" ]; then
    raw=$(hostname 2>/dev/null) || raw=
  fi
  [ -n "$raw" ] || return 1
  printf 'fm-endpoint-host:%s' "$raw" | fm_endpoint_sha256 | cut -c1-24
}

# The kernel's per-boot identity, or nothing where the platform has none.
fm_endpoint_boot_id() {
  local raw=''
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    raw=$(tr -d '[:space:]' </proc/sys/kernel/random/boot_id 2>/dev/null) || raw=
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    raw=$(sysctl -n kern.bootsessionuuid 2>/dev/null | tr -d '[:space:]') || raw=
  fi
  case "$raw" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  printf '%s' "$raw"
}

# The boot time as epoch seconds. Derived from the wall clock, so it is
# evidence for a human to read and is never part of a proof.
fm_endpoint_boot_epoch() {
  local raw=''
  if [ -r /proc/stat ]; then
    raw=$(awk '/^btime / {print $2; exit}' /proc/stat 2>/dev/null) || raw=
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    raw=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p') || raw=
  fi
  case "$raw" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$raw"
}

# --- record fields ----------------------------------------------------------

# fm_endpoint_meta_field <meta> <key>: the value when the key appears exactly
# once. 1 when absent, 2 when it appears more than once or is empty.
fm_endpoint_meta_field() {
  local out rc=0
  out=$(LC_ALL=C awk -v key="$2" '
    index($0, key "=") == 1 { count++; value = substr($0, length(key) + 2) }
    END { if (count == 0) exit 1; if (count > 1 || value == "") exit 2; print value }
  ' "$1" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out"
}

fm_endpoint_valid_socket() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[[:space:][:cntrl:]]*) return 1 ;;
  esac
}
fm_endpoint_valid_digits() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
fm_endpoint_valid_window_id() {
  case "$1" in
    @[0-9]*) ;;
    *) return 1 ;;
  esac
  case "${1#@}" in
    *[!0-9]*) return 1 ;;
  esac
}
fm_endpoint_valid_token() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

# fm_endpoint_field_ok <meta> <key> <validator>: the key appears exactly once
# and its value passes <validator>.
fm_endpoint_field_ok() {
  local value
  value=$(fm_endpoint_meta_field "$1" "$2") || return 1
  "$3" "$value"
}

# legacy | complete | malformed. See the header: legacy carries no identity
# key at all, complete carries every required one validly, anything else is
# malformed and is never treated as legacy, so a half-written record cannot
# unlock the consent path.
fm_endpoint_identity_state() {  # <meta>
  local meta=$1 key present=0 value rc
  for key in tmux_socket tmux_server_pid tmux_server_start tmux_window_id endpoint_host endpoint_boot; do
    if value=$(fm_endpoint_meta_field "$meta" "$key"); then
      present=$((present + 1))
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        printf 'malformed'
        return 0
      fi
    fi
  done
  if [ "$present" -eq 0 ]; then
    printf 'legacy'
    return 0
  fi
  fm_endpoint_field_ok "$meta" tmux_socket fm_endpoint_valid_socket || { printf 'malformed'; return 0; }
  fm_endpoint_field_ok "$meta" tmux_server_pid fm_endpoint_valid_digits || { printf 'malformed'; return 0; }
  fm_endpoint_field_ok "$meta" tmux_server_start fm_endpoint_valid_digits || { printf 'malformed'; return 0; }
  fm_endpoint_field_ok "$meta" tmux_window_id fm_endpoint_valid_window_id || { printf 'malformed'; return 0; }
  fm_endpoint_field_ok "$meta" endpoint_host fm_endpoint_valid_token || { printf 'malformed'; return 0; }
  if fm_endpoint_meta_field "$meta" endpoint_boot >/dev/null; then
    fm_endpoint_field_ok "$meta" endpoint_boot fm_endpoint_valid_token || { printf 'malformed'; return 0; }
  fi
  printf 'complete'
}

# --- recording identity -----------------------------------------------------

# fm_endpoint_tmux_identity_lines <tmux-target> <session:window-label>: the
# record lines for the window <tmux-target> on the AMBIENT tmux server, or
# nothing (status 1) when any of them cannot be read. The label read back from
# tmux must equal the one the caller expects, so a target that silently
# resolved to some other window records nothing rather than the wrong
# identity. Every value is validated before it is printed.
fm_endpoint_tmux_identity_lines() {
  local target=$1 expect=$2 facts sock label pid start wid host boot
  # Three single-purpose reads, never one tab-joined line: tmux rewrites a tab
  # in its own output to `_` outside a UTF-8 locale, and a session name may hold
  # a space.
  facts=$(fm_endpoint_tmux_capture display-message -p -t "$target" '#{pid} #{start_time} #{window_id}') || return 1
  sock=$(fm_endpoint_tmux_capture display-message -p -t "$target" '#{socket_path}') || return 1
  label=$(fm_endpoint_tmux_capture display-message -p -t "$target" '#{session_name}:#{window_name}') || return 1
  read -r pid start wid <<EOF
$facts
EOF
  fm_endpoint_valid_socket "$sock" || return 1
  fm_endpoint_valid_digits "$pid" || return 1
  fm_endpoint_valid_digits "$start" || return 1
  fm_endpoint_valid_window_id "$wid" || return 1
  [ "$label" = "$expect" ] || return 1
  host=$(fm_endpoint_host_id) || return 1
  fm_endpoint_valid_token "$host" || return 1
  printf 'tmux_socket=%s\n' "$sock"
  printf 'tmux_server_pid=%s\n' "$pid"
  printf 'tmux_server_start=%s\n' "$start"
  printf 'tmux_window_id=%s\n' "$wid"
  printf 'endpoint_host=%s\n' "$host"
  if boot=$(fm_endpoint_boot_id); then
    printf 'endpoint_boot=%s\n' "$boot"
  fi
}

# The keys fm_endpoint_tmux_identity_lines writes, so a writer that replaces
# the identity can drop the previous one first.
fm_endpoint_identity_keys() {
  printf '%s\n' tmux_socket tmux_server_pid tmux_server_start tmux_window_id endpoint_host endpoint_boot
}

# --- reading one tmux server -------------------------------------------------

# fm_endpoint_tmux_capture <tmux args...>: one bounded tmux call. Prints the
# combined output; status is the command's own, or 124 when the bound fired.
#
# The output is captured through a FILE, never a pipe. A tmux client hands its
# stdin and stdout to the server it talks to, so while a stopped or wedged
# server still holds them, a command substitution that captured the client
# through a pipe keeps waiting for EOF long after the bound killed the client
# (verified against tmux 3.6: a SIGSTOPped server held a $(tmux ...) capture
# until it was resumed). A file has no reader to wait.
fm_endpoint_tmux_capture() {
  local file rc=0
  fm_endpoint_need fm_run_timed fm-timeout-lib.sh
  file=$(mktemp "${TMPDIR:-/tmp}/fm-endpoint-tmux.XXXXXX") || return 125
  fm_run_timed "$FM_ENDPOINT_PROBE_TIMEOUT" env LC_ALL=C tmux "$@" >"$file" 2>&1 </dev/null || rc=$?
  cat "$file" 2>/dev/null || true
  rm -f "$file"
  return "$rc"
}

# fm_endpoint_tmux_run_on <socket> <tmux args...>: the same against an explicit
# socket, which is how a server this seat does not own is read.
fm_endpoint_tmux_run_on() {
  local sock=$1
  shift
  fm_endpoint_tmux_capture -S "$sock" "$@"
}

# fm_endpoint_tmux_server_read <socket>: classify what answers at <socket>.
# Prints one of
#   answer\t<pid>\t<start>     a tmux server answered
#   no-server                  the socket is absent or refuses connections
#   unresponsive               it did not answer within the bound
#   unreadable\t<first line>   any other failure (a permission error included)
fm_endpoint_tmux_server_read() {
  local sock=$1 out rc pid start
  fm_endpoint_need fm_timed_out fm-timeout-lib.sh
  if out=$(fm_endpoint_tmux_run_on "$sock" display-message -p "#{pid} #{start_time}"); then
    rc=0
  else
    rc=$?
  fi
  if fm_timed_out "$rc"; then
    printf 'unresponsive'
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    read -r pid start <<EOF
$out
EOF
    if fm_endpoint_valid_digits "$pid" && fm_endpoint_valid_digits "$start"; then
      printf 'answer\t%s\t%s' "$pid" "$start"
    else
      printf 'unreadable\tunexpected answer from the tmux server'
    fi
    return 0
  fi
  case "$out" in
    *"no server running on "*|*"error connecting to "*"(No such file or directory)"*|*"error connecting to "*"(Connection refused)"*)
      printf 'no-server'
      ;;
    *)
      printf 'unreadable\t%s' "${out%%$'\n'*}"
      ;;
  esac
}

# fm_endpoint_pid_is_tmux <pid>: yes | no | unknown. Whether a process with
# that pid exists right now and is a tmux process.
fm_endpoint_pid_is_tmux() {
  local pid=$1 comm
  if [ -d /proc/self ]; then
    if [ ! -d "/proc/$pid" ]; then
      printf 'no'
      return 0
    fi
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || {
      [ -d "/proc/$pid" ] || { printf 'no'; return 0; }
      printf 'unknown'
      return 0
    }
  elif command -v ps >/dev/null 2>&1; then
    comm=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null) || comm=
    [ -n "$comm" ] || { printf 'no'; return 0; }
  else
    printf 'unknown'
    return 0
  fi
  case "${comm##*/}" in
    tmux*) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

# fm_endpoint_tmux_probe_recorded <meta>: prints "<kind>\t<detail>" about the
# server instance a complete record names. Kinds:
#   other-host        the record was written on another machine
#   boot-changed      same machine, different boot
#   same-present      the recorded instance is alive and still has the window
#                     (detail: its current session:name)
#   same-absent       the recorded instance is alive and the window is gone
#   replaced          the socket is now served by a different instance
#   server-gone       no instance answers and no tmux process holds the pid
#   pid-alive         no answer, but a tmux process still holds the pid
#   unresponsive / unreadable   nothing can be concluded
fm_endpoint_tmux_probe_recorded() {
  local meta=$1 sock pid start wid host boot cur_host cur_boot kind a b out rc row_id row_name
  sock=$(fm_endpoint_meta_field "$meta" tmux_socket) || { printf 'unreadable\tthe record has no readable tmux_socket'; return 0; }
  pid=$(fm_endpoint_meta_field "$meta" tmux_server_pid) || { printf 'unreadable\tthe record has no readable tmux_server_pid'; return 0; }
  start=$(fm_endpoint_meta_field "$meta" tmux_server_start) || { printf 'unreadable\tthe record has no readable tmux_server_start'; return 0; }
  wid=$(fm_endpoint_meta_field "$meta" tmux_window_id) || { printf 'unreadable\tthe record has no readable tmux_window_id'; return 0; }
  host=$(fm_endpoint_meta_field "$meta" endpoint_host) || { printf 'unreadable\tthe record has no readable endpoint_host'; return 0; }
  boot=$(fm_endpoint_meta_field "$meta" endpoint_boot) || boot=
  cur_host=$(fm_endpoint_host_id) || cur_host=
  if [ -z "$cur_host" ]; then
    printf 'unreadable\tthis host has no readable identity to compare the record with'
    return 0
  fi
  if [ "$host" != "$cur_host" ]; then
    printf 'other-host\tthe record was written on another machine, whose processes this host cannot see'
    return 0
  fi
  if [ -n "$boot" ]; then
    cur_boot=$(fm_endpoint_boot_id) || cur_boot=
    if [ -z "$cur_boot" ]; then
      printf 'unreadable\tthis host cannot read its boot id to compare it with the recorded one'
      return 0
    fi
    if [ "$boot" != "$cur_boot" ]; then
      printf 'boot-changed\tthe host rebooted since the endpoint was recorded (boot %s, now %s)' "${boot%%-*}" "${cur_boot%%-*}"
      return 0
    fi
  fi
  out=$(fm_endpoint_tmux_server_read "$sock")
  IFS=$FM_ENDPOINT_TAB read -r kind a b <<EOF
$out
EOF
  case "$kind" in
    answer)
      if [ "$a" = "$pid" ] && [ "$b" = "$start" ]; then
        if out=$(fm_endpoint_tmux_run_on "$sock" list-windows -a -F '#{window_id} #{session_name}:#{window_name}'); then
          rc=0
        else
          rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
          printf 'unreadable\tthe recorded tmux server answered but its window list could not be read'
          return 0
        fi
        while read -r row_id row_name; do
          if [ "$row_id" = "$wid" ]; then
            printf 'same-present\t%s' "$row_name"
            return 0
          fi
        done <<EOF
$out
EOF
        printf 'same-absent\t'
      else
        printf 'replaced\tsocket %s is now served by another tmux server (pid %s, started %s)' "$sock" "$a" "$b"
      fi
      ;;
    no-server)
      case "$(fm_endpoint_pid_is_tmux "$pid")" in
        no) printf 'server-gone\tsocket %s refuses connections and no tmux process holds the recorded pid %s' "$sock" "$pid" ;;
        yes) printf 'pid-alive\ta tmux process still holds the recorded server pid %s although socket %s does not answer' "$pid" "$sock" ;;
        *) printf 'unreadable\tit could not be determined whether the recorded tmux server pid %s still exists' "$pid" ;;
      esac
      ;;
    unresponsive)
      printf 'unresponsive\tthe recorded tmux server did not answer within %ss' "$FM_ENDPOINT_PROBE_TIMEOUT"
      ;;
    *)
      printf 'unreadable\t%s' "${a:-the recorded tmux server could not be read}"
      ;;
  esac
}

# --- the worktree's live processes ------------------------------------------

# Whether <pid> is this shell or one of its descendants, so the probe never
# counts its own helpers (a `sleep` in a wait loop) as a live agent when the
# operator runs it from inside the worktree.
fm_endpoint_pid_is_own_descendant() {  # <pid>
  local pid=$1 depth=0 ppid
  while [ "$depth" -lt 64 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
    [ "$pid" != "$$" ] || return 0
    ppid=$(awk '{ sub(/^[0-9]+ \(.*\) /, ""); print $2 }' "/proc/$pid/stat" 2>/dev/null) || return 1
    pid=$ppid
    depth=$((depth + 1))
  done
  return 1
}

# fm_endpoint_worktree_processes <worktree> <task-id>: prints one
# "<pid>\t<comm>\t<why>" line per same-user, non-shell, non-tmux process that
# is working in <worktree> (its cwd is inside it) or carries FM_TASK_ID=<id> in
# its environment. Status 0 when the scan completed (no output means none),
# 2 when this host offers no way to scan, which a caller must read as "could
# not rule a live agent out". Shells are ignored because a shell is never the
# agent and an idle interactive shell in the directory is not a duplicate.
fm_endpoint_worktree_processes() {
  local wt=$1 id=$2 wt_real p pid cwd why comm argv0 cls out cur
  fm_endpoint_need fm_agent_process_classify fm-agent-process-lib.sh
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  if [ -d /proc/self ]; then
    for p in /proc/[0-9]*; do
      pid=${p#/proc/}
      [ "$pid" != "$$" ] || continue
      [ -O "$p" ] || continue
      cwd=$(readlink "$p/cwd" 2>/dev/null) || cwd=
      why=
      case "$cwd" in
        "$wt_real"|"$wt_real"/*) why=cwd ;;
      esac
      if [ -z "$why" ] && [ -r "$p/environ" ] && grep -aqzxF -- "FM_TASK_ID=$id" "$p/environ" 2>/dev/null; then
        why=task-env
      fi
      [ -n "$why" ] || continue
      comm=$(cat "$p/comm" 2>/dev/null) || continue
      case "$comm" in tmux*) continue ;; esac
      fm_endpoint_pid_is_own_descendant "$pid" && continue
      argv0=$(tr '\0' '\n' <"$p/cmdline" 2>/dev/null | head -n 1) || argv0=
      cls=$(fm_agent_process_classify "$comm" "$argv0" "" "$pid")
      [ "$cls" != shell ] || continue
      printf '%s\t%s\t%s\n' "$pid" "$comm" "$why"
    done
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    cur=$(id -u)
    out=$(lsof -a -u "$cur" -d cwd -Fpcn 2>/dev/null) || return 2
    printf '%s\n' "$out" | awk -v wt="$wt_real" -v self="$$" '
      /^p/ { pid = substr($0, 2); comm = ""; next }
      /^c/ { comm = substr($0, 2); next }
      /^n/ {
        path = substr($0, 2)
        if (pid != self && (path == wt || index(path, wt "/") == 1)) {
          if (comm !~ /^(tmux|zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish)$/) printf "%s\t%s\tcwd\n", pid, comm
        }
      }
    '
    return 0
  fi
  return 2
}

# --- the proof for a complete record ----------------------------------------

# fm_endpoint_tmux_proof <meta>: "<verdict>\t<detail>" (see the header).
fm_endpoint_tmux_proof() {
  local meta=$1 id wt probe kind detail basis procs scan_rc nproc
  id=$(fm_endpoint_meta_field "$meta" endpoint_task_id) || id=$(basename "$meta" .meta)
  wt=$(fm_endpoint_meta_field "$meta" worktree) || wt=
  probe=$(fm_endpoint_tmux_probe_recorded "$meta")
  kind=${probe%%"$FM_ENDPOINT_TAB"*}
  detail=${probe#*"$FM_ENDPOINT_TAB"}
  case "$kind" in
    boot-changed|replaced|server-gone) basis=$detail ;;
    same-absent) basis='its recorded tmux server is running and no longer has the recorded window' ;;
    same-present)
      printf 'unproven\tthe recorded tmux window %s is still alive on its recorded server (it is now %s); that endpoint is not gone, so recover it from a seat attached to that server instead of rebinding it' \
        "$(fm_endpoint_meta_field "$meta" tmux_window_id)" "$detail"
      return 0
      ;;
    *)
      printf 'unproven\t%s' "$detail"
      return 0
      ;;
  esac
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'unproven\tthe recorded worktree is unavailable, so no live agent can be ruled out there'
    return 0
  fi
  if procs=$(fm_endpoint_worktree_processes "$wt" "$id"); then
    scan_rc=0
  else
    scan_rc=$?
  fi
  if [ "$scan_rc" -ne 0 ]; then
    printf 'unproven\tthis host offers no way to list the processes running in the task worktree, so a surviving agent cannot be ruled out'
    return 0
  fi
  if [ -n "$procs" ]; then
    nproc=$(printf '%s\n' "$procs" | awk 'END {print NR}')
    printf 'unproven\t%s process(es) are still running in the task worktree, so an agent may still hold it (first: pid %s, %s)' \
      "$nproc" "$(printf '%s\n' "$procs" | awk -F'\t' 'NR == 1 {print $1}')" "$(printf '%s\n' "$procs" | awk -F'\t' 'NR == 1 {print $2}')"
    return 0
  fi
  printf 'gone\t%s' "$basis"
}

# --- the legacy path: evidence, digest, consent ------------------------------

# fm_endpoint_tmux_socket_dirs: the directories tmux keeps this user's sockets
# in, deduplicated, one per line.
fm_endpoint_tmux_socket_dirs() {
  local uid ambient
  uid=$(id -u)
  {
    printf '%s\n' "${TMUX_TMPDIR:-/tmp}/tmux-$uid"
    printf '%s\n' "/tmp/tmux-$uid"
    printf '%s\n' "/private/tmp/tmux-$uid"
    ambient=$(fm_endpoint_tmux_capture display-message -p '#{socket_path}') || ambient=
    case "$ambient" in
      /*) printf '%s\n' "${ambient%/*}" ;;
    esac
  } | awk 'NF && !seen[$0]++'
}

# fm_endpoint_scan_tmux_servers <window-label-name>: one line per tmux socket
# of this user, sorted: "server <socket> pid=<p> start=<s> has-window=<yes|no>",
# "stale <socket>" (nothing answers), or "unreachable <socket>" (it exists and
# could not be read). Reads only; a server is never started.
fm_endpoint_scan_tmux_servers() {
  local name=$1 dir sock out kind pid start wins has
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for sock in "$dir"/*; do
      [ -S "$sock" ] || continue
      out=$(fm_endpoint_tmux_server_read "$sock")
      IFS=$FM_ENDPOINT_TAB read -r kind pid start <<EOF
$out
EOF
      case "$kind" in
        answer)
          has=no
          if wins=$(fm_endpoint_tmux_run_on "$sock" list-windows -a -F '#{window_name}'); then
            printf '%s\n' "$wins" | grep -qxF -- "$name" && has=yes
          else
            has=unreadable
          fi
          printf 'server %s pid=%s start=%s has-window=%s\n' "$sock" "$pid" "$start" "$has"
          ;;
        no-server) printf 'stale %s\n' "$sock" ;;
        *) printf 'unreachable %s\n' "$sock" ;;
      esac
    done
  done <<EOF
$(fm_endpoint_tmux_socket_dirs)
EOF
}

# The count of live tmux SERVER processes of this user that none of the scanned
# sockets accounts for, or `unknown` where processes cannot be listed by name.
fm_endpoint_unmapped_tmux_servers() {  # <scan-output>
  local scan=$1 p pid comm known unmapped=0
  [ -d /proc/self ] || { printf 'unknown'; return 0; }
  known=$(printf '%s\n' "$scan" | sed -n 's/^server .* pid=\([0-9][0-9]*\) .*/\1/p')
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -O "$p" ] || continue
    comm=$(cat "$p/comm" 2>/dev/null) || continue
    [ "$comm" = "tmux: server" ] || continue
    printf '%s\n' "$known" | grep -qx -- "$pid" || unmapped=$((unmapped + 1))
  done
  printf '%s' "$unmapped"
}

fm_endpoint_iso_utc() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'epoch:%s' "$1"
}

# fm_endpoint_legacy_evidence <meta>: the evidence lines for a legacy record,
# one `key=value` per line, stable for identical evidence. A line starting
# `veto=` is positive evidence that a live endpoint or agent exists; status 3
# then, 0 otherwise. The digest (fm_endpoint_legacy_digest) is computed over
# exactly these lines.
fm_endpoint_legacy_evidence() {
  local meta=$1 id window wt branch spawn_gen spawn_epoch host boot boot_epoch rel ambient scan unreadable unmapped procs scan_rc veto=0 line
  id=$(fm_endpoint_meta_field "$meta" endpoint_task_id) || id=$(basename "$meta" .meta)
  window=$(fm_endpoint_meta_field "$meta" window) || window=
  wt=$(fm_endpoint_meta_field "$meta" worktree) || wt=
  branch=$(fm_endpoint_meta_field "$meta" branch) || branch=
  spawn_gen=$(fm_endpoint_meta_field "$meta" spawn_gen) || spawn_gen=
  spawn_epoch=
  case "$spawn_gen" in
    s[0-9]*.*) spawn_epoch=${spawn_gen#s}; spawn_epoch=${spawn_epoch%%.*} ;;
  esac
  fm_endpoint_valid_digits "$spawn_epoch" || spawn_epoch=
  host=$(fm_endpoint_host_id) || host=unavailable
  boot=$(fm_endpoint_boot_id) || boot=unavailable
  boot_epoch=$(fm_endpoint_boot_epoch) || boot_epoch=
  rel=unknown
  if [ -n "$spawn_epoch" ] && [ -n "$boot_epoch" ]; then
    if [ $((spawn_epoch + FM_ENDPOINT_BOOT_MARGIN)) -lt "$boot_epoch" ]; then
      rel=predates-this-boot
    else
      rel=not-before-this-boot
    fi
  fi
  ambient=$(fm_endpoint_tmux_capture display-message -p '#{socket_path} pid=#{pid} start=#{start_time}') || ambient=
  [ -n "$ambient" ] || ambient=none
  scan=$(fm_endpoint_scan_tmux_servers "fm-$id" | LC_ALL=C sort)
  unmapped=$(fm_endpoint_unmapped_tmux_servers "$scan")
  printf 'evidence=v1\n'
  printf 'task=%s\n' "$id"
  printf 'window=%s\n' "$window"
  printf 'worktree=%s\n' "$wt"
  printf 'branch=%s\n' "$branch"
  printf 'spawn_gen=%s\n' "$spawn_gen"
  printf 'host=%s\n' "$host"
  printf 'boot=%s\n' "$boot"
  printf 'record_vs_boot=%s\n' "$rel"
  printf 'ambient_server=%s\n' "$ambient"
  # What the digest binds is what could change the decision: where a
  # replacement would open (the ambient server above), whether any reachable
  # server holds a window for the task (a veto), and how many servers could not
  # be read at all. The rest of the server list is shown to the operator as
  # `info.` lines and left out of the digest, because another server starting or
  # dying can only add or remove a place an unrelated session lives: a stale
  # socket is left behind by every tmux server that exits, and a server that
  # appears cannot be holding an agent that was already gone.
  unreadable=$(printf '%s\n' "$scan" | grep -c '^unreachable ' || true)
  printf 'tmux_servers_unreadable=%s\n' "$unreadable"
  printf '%s\n' "$scan" | sed -n 's/^server /info.tmux_server: /p'
  printf '%s\n' "$scan" | sed -n 's/^stale /info.tmux_stale_socket: /p'
  printf '%s\n' "$scan" | sed -n 's/^unreachable /info.tmux_unreachable_socket: /p'
  printf 'info.unmapped_tmux_servers=%s\n' "$unmapped"
  printf 'tmux_windows_named_fm-%s=%s\n' "$id" "$(printf '%s\n' "$scan" | grep -c 'has-window=yes' || true)"
  while IFS= read -r line; do
    case "$line" in
      *"has-window=yes"*)
        printf 'veto=a live tmux window named fm-%s exists on %s\n' "$id" "$(printf '%s' "$line" | awk '{print $2}')"
        veto=1
        ;;
    esac
  done <<EOF
$scan
EOF
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'veto=the recorded worktree is unavailable\n'
    printf 'worktree_processes=unavailable\n'
    return 3
  fi
  if procs=$(fm_endpoint_worktree_processes "$wt" "$id"); then
    scan_rc=0
  else
    scan_rc=$?
  fi
  if [ "$scan_rc" -ne 0 ]; then
    printf 'worktree_processes=unavailable\n'
    printf 'veto=this host offers no way to list the processes running in the task worktree\n'
    veto=1
  elif [ -n "$procs" ]; then
    printf 'worktree_processes=%s\n' "$(printf '%s\n' "$procs" | awk -F'\t' '{printf "%s%s(%s,%s)", sep, $2, $1, $3; sep=","}')"
    printf 'veto=a live process is working in the task worktree\n'
    veto=1
  else
    printf 'worktree_processes=none\n'
  fi
  [ "$veto" -eq 0 ] || return 3
  return 0
}

# The digest covers every evidence line except the informational `info.` ones.
fm_endpoint_legacy_digest() {  # stdin: the evidence lines
  grep -v '^info\.' | fm_endpoint_sha256
}

# fm_endpoint_legacy_check <meta> <digest>: 0 when <digest> is the digest of
# the evidence as it stands NOW and that evidence carries no veto. Otherwise
# prints the refusal on stdout and returns 1; the refusal carries the current
# digest when one can be offered.
fm_endpoint_legacy_check() {
  local meta=$1 digest=$2 state evidence rc=0 fresh
  state=$(fm_endpoint_identity_state "$meta")
  if [ "$state" != legacy ]; then
    printf 'consent applies only to a record that predates endpoint identity, and this record is %s' "$state"
    return 1
  fi
  evidence=$(fm_endpoint_legacy_evidence "$meta") || rc=$?
  fresh=$(printf '%s\n' "$evidence" | fm_endpoint_legacy_digest) || {
    printf 'no sha256 tool is available to digest the evidence'
    return 1
  }
  if [ "$rc" -ne 0 ]; then
    printf 'the evidence names a live endpoint or agent, which no consent can override: %s' \
      "$(printf '%s\n' "$evidence" | sed -n 's/^veto=//p' | awk 'NR == 1')"
    return 1
  fi
  if [ "$digest" != "$fresh" ]; then
    printf 'the consent digest does not match the evidence as it stands now (digest %s); review it again with bin/fm-endpoint-proof.sh and pass the current digest' "$fresh"
    return 1
  fi
  return 0
}

# fm_endpoint_consent_record <state-dir> <id> <meta> <digest>: append the
# durable, self-verifying consent record. The block repeats the evidence
# verbatim so anyone can re-digest it and compare.
fm_endpoint_consent_record() {
  local state=$1 id=$2 meta=$3 digest=$4 file evidence
  file="$state/$id.endpoint-consent"
  evidence=$(fm_endpoint_legacy_evidence "$meta") || true
  {
    printf 'consent=v1\n'
    printf 'task=%s\n' "$id"
    printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'user=%s\n' "$(id -un 2>/dev/null || echo unknown)"
    printf 'digest=%s\n' "$digest"
    printf '%s\n' "$evidence" | sed 's/^/ev./'
    printf 'end=consent\n'
  } >>"$file"
}
