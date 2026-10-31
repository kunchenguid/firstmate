#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-nm-run-lib.sh"

# Print native server identity for recording at spawn or for comparison with
# independently supplied operator evidence. The format is metadata, not shell.
fm_backend_tmux_identity() {
  local row socket pid started host boot process namespace
  row=$(fm_tmux display-message -p '#{socket_path}|#{pid}|#{start_time}') || return 1
  IFS='|' read -r socket pid started <<< "$row"
  case "$socket" in /*) ;; *) return 1 ;; esac
  case "$socket" in *$'\n'*|*$'\r'*|*$'\t'*|*'|'*) return 1 ;; esac
  case "$pid:$started" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$pid" -gt 0 ] && [ "$started" -gt 0 ] || return 1
  printf '%s\n' "tmux_socket=$socket" "tmux_server_pid=$pid" "tmux_server_start=$started"
  if [ "$(uname -s)" = Linux ]; then
    host=$(fm_run_timed 5 cat /etc/machine-id) && boot=$(fm_run_timed 5 cat /proc/sys/kernel/random/boot_id) \
      && namespace=$(fm_run_timed 5 readlink /proc/self/ns/pid) && process=$(fm_tmux_pid_identity "$pid") || return 1
    case "$host:$boot:$process" in *$'\n'*|*$'\r'*|*$'\t'*|:*|*::*|*:) return 1 ;; esac
    printf '%s\n' "tmux_host_id=$host" "tmux_boot_id=$boot" "tmux_pid_namespace=$namespace" "tmux_process_identity=$process"
  fi
}

# Legacy records retain their ordinary live-endpoint behavior and missing
# endpoint refusal. A partial binding is an error, never a legacy fallback.
fm_backend_tmux_load_meta() {  # <meta>
  local meta=$1 count key value
  unset FM_TMUX_SOCKET FM_TMUX_SERVER_PID FM_TMUX_SERVER_START FM_TMUX_WINDOW_ID \
    FM_TMUX_HOST_ID FM_TMUX_BOOT_ID FM_TMUX_PID_NAMESPACE FM_TMUX_PROCESS_IDENTITY \
    FM_TMUX_REBOOT_BOOT_ID FM_TMUX_REBOOT_BOOT_EPOCH FM_TMUX_REBOOT_PID_NAMESPACE FM_TMUX_REBOOT_SPAWN_GEN
  FM_TMUX_SUCCESSOR=0
  FM_TMUX_META=$meta
  count=$(grep -c '^tmux_' "$meta" 2>/dev/null || true)
  [ "$count" != 0 ] || return 0
  if [ "$count" = 7 ]; then
    FM_TMUX_SOCKET=$(fm_backend_meta_exact_value "$meta" tmux_socket) || return 1
    FM_TMUX_SERVER_PID=$(fm_backend_meta_exact_value "$meta" tmux_server_pid) || return 1
    FM_TMUX_HOST_ID=$(fm_backend_meta_exact_value "$meta" tmux_host_id) || return 1
    FM_TMUX_REBOOT_BOOT_ID=$(fm_backend_meta_exact_value "$meta" tmux_reboot_boot_id) || return 1
    FM_TMUX_REBOOT_BOOT_EPOCH=$(fm_backend_meta_exact_value "$meta" tmux_reboot_boot_epoch) || return 1
    FM_TMUX_REBOOT_PID_NAMESPACE=$(fm_backend_meta_exact_value "$meta" tmux_reboot_pid_namespace) || return 1
    FM_TMUX_REBOOT_SPAWN_GEN=$(fm_backend_meta_exact_value "$meta" tmux_reboot_spawn_gen) || return 1
    return 0
  fi
  case "$count" in 4|8) ;; *) echo "error: incomplete or ambiguous tmux identity" >&2; return 1 ;; esac
  for key in socket server_pid server_start window_id; do
    value=$(fm_backend_meta_exact_value "$meta" "tmux_$key") || return 1
    case "$key" in
      socket) FM_TMUX_SOCKET=$value ;;
      server_pid) FM_TMUX_SERVER_PID=$value ;;
      server_start) FM_TMUX_SERVER_START=$value ;;
      window_id) FM_TMUX_WINDOW_ID=$value ;;
    esac
  done
  if [ "$count" = 8 ]; then
    FM_TMUX_HOST_ID=$(fm_backend_meta_exact_value "$meta" tmux_host_id) || return 1
    FM_TMUX_BOOT_ID=$(fm_backend_meta_exact_value "$meta" tmux_boot_id) || return 1
    FM_TMUX_PID_NAMESPACE=$(fm_backend_meta_exact_value "$meta" tmux_pid_namespace) || return 1
    FM_TMUX_PROCESS_IDENTITY=$(fm_backend_meta_exact_value "$meta" tmux_process_identity) || return 1
  fi
}

fm_backend_tmux_bind_meta() {  # <meta>
  fm_backend_tmux_load_meta "$1" || return 1
  [ -n "${FM_TMUX_SOCKET:-}" ] || return 0
  case "$(fm_backend_tmux_server_state)" in
    alive|gone) return 0 ;;
    successor) fm_backend_tmux_apply_successor "$1" && return 0 ;;
  esac
  echo "error: recorded tmux server is inaccessible, foreign, or its identity was reused; preserving task state" >&2
  return 1
}

# Scope recorded task operations to their native server without leaking one
# task's binding into the next watcher iteration or into a supervisor target.
fm_backend_tmux_for_target() (  # <operation> <target> [args...]
  local op=$1 target=$2 meta state=${STATE:-$FM_HOME/state} id
  shift
  meta=$(fm_backend_meta_for_window "$target" "$state" 2>/dev/null || true)
  if [ -n "$meta" ] && grep -q '^tmux_' "$meta"; then
    id=${meta##*/}; id=${id%.meta}
    if ! fm_backend_validate_task_endpoint "$meta" "$id" \
      || ! fm_backend_tmux_bind_meta "$meta"; then
      if [ "$op" = agent_state ]; then printf unreadable; return 0; fi
      return 1
    fi
    if fm_backend_tmux_target_exists "$target"; then
      [ "$FM_TMUX_SUCCESSOR" = 0 ] \
        && [ "$(fm_tmux display-message -p -t "$target" '#{window_id}')" = "$FM_TMUX_WINDOW_ID" ] || {
        if [ "$op" = agent_state ]; then printf unreadable; return 0; fi
        return 1
      }
    fi
  fi
  "fm_backend_tmux_$op" "$@"
)

# A native startup receipt belongs to one recorded task in this home. Its
# retained predecessor proves which dead server it replaced; its kernel/native
# successor identity permits other recorded siblings to use that exact server.
# No unrelated live socket is accepted, even when it has matching task labels.
fm_backend_tmux_successor() {  # <meta> [apply]
  local meta=$1 action=${2:-} home taskdir receipt prior key expected observed found='' identity=''
  local old_socket=$FM_TMUX_SOCKET old_pid=$FM_TMUX_SERVER_PID old_host=$FM_TMUX_HOST_ID
  local FM_TMUX_SOCKET FM_TMUX_SERVER_PID FM_TMUX_SERVER_START FM_TMUX_HOST_ID
  local FM_TMUX_BOOT_ID FM_TMUX_PID_NAMESPACE FM_TMUX_PROCESS_IDENTITY
  home=${meta%/state/*}
  [ "$home/state/${meta##*/}" = "$meta" ] || return 1
  for receipt in "$home"/data/*/tmux-start.*/identity; do
    [ -f "$receipt" ] && [ -O "$receipt" ] && [ ! -L "$receipt" ] || continue
    prior=${receipt%/*}/meta-prior
    taskdir=${receipt%/tmux-start.*/identity}
    [ -d "$taskdir" ] && [ -O "$taskdir" ] && [ ! -L "$taskdir" ] || continue
    [ -d "${receipt%/*}" ] && [ -O "${receipt%/*}" ] && [ ! -L "${receipt%/*}" ] || continue
    [ -f "$home/state/${taskdir##*/}.meta" ] && [ -f "$prior" ] && [ -O "$prior" ] && [ ! -L "$prior" ] || continue
    fm_backend_validate_task_endpoint "$prior" "${taskdir##*/}" >/dev/null 2>&1 || continue
    [ "$(fm_backend_meta_exact_value "$prior" tmux_socket)" = "$old_socket" ] \
      && [ "$(fm_backend_meta_exact_value "$prior" tmux_server_pid)" = "$old_pid" ] \
      && [ "$(fm_backend_meta_exact_value "$prior" tmux_host_id)" = "$old_host" ] || continue
    for key in tmux_server_start tmux_boot_id tmux_pid_namespace tmux_process_identity \
      tmux_reboot_boot_id tmux_reboot_boot_epoch tmux_reboot_pid_namespace; do
      expected=$(fm_meta_get "$meta" "$key")
      observed=$(fm_meta_get "$prior" "$key")
      [ "$expected" = "$observed" ] || break
    done
    [ "$expected" = "$observed" ] || continue
    [ "$(grep -c '^tmux_' "$receipt")" = 7 ] || continue
    FM_TMUX_SOCKET=$(fm_backend_meta_exact_value "$receipt" tmux_socket) || continue
    [ "$FM_TMUX_SOCKET" = "$old_socket" ] || continue
    FM_TMUX_SERVER_PID=$(fm_backend_meta_exact_value "$receipt" tmux_server_pid) || continue
    FM_TMUX_SERVER_START=$(fm_backend_meta_exact_value "$receipt" tmux_server_start) || continue
    FM_TMUX_HOST_ID=$(fm_backend_meta_exact_value "$receipt" tmux_host_id) || continue
    FM_TMUX_BOOT_ID=$(fm_backend_meta_exact_value "$receipt" tmux_boot_id) || continue
    FM_TMUX_PID_NAMESPACE=$(fm_backend_meta_exact_value "$receipt" tmux_pid_namespace) || continue
    FM_TMUX_PROCESS_IDENTITY=$(fm_backend_meta_exact_value "$receipt" tmux_process_identity) || continue
    observed=$(fm_backend_tmux_identity 2>/dev/null) || continue
    [ "$observed" = "$(cat "$receipt")" ] || continue
    [ -z "$found" ] || [ "$identity" = "$observed" ] || return 1
    found=$receipt identity=$observed
  done
  [ -n "$found" ] || return 1
  [ "$action" = apply ] || return 0
  # The caller applies these values after this function's local bindings leave.
  printf '%s\n' "$identity"
}

fm_backend_tmux_apply_successor() {
  local identity key value
  identity=$(fm_backend_tmux_successor "$1" apply) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      tmux_socket) FM_TMUX_SOCKET=$value ;;
      tmux_server_pid) FM_TMUX_SERVER_PID=$value ;;
      tmux_server_start) FM_TMUX_SERVER_START=$value ;;
      tmux_host_id) FM_TMUX_HOST_ID=$value ;;
      tmux_boot_id) FM_TMUX_BOOT_ID=$value ;;
      tmux_pid_namespace) FM_TMUX_PID_NAMESPACE=$value ;;
      tmux_process_identity) FM_TMUX_PROCESS_IDENTITY=$value ;;
    esac
  done <<< "$identity"
  unset FM_TMUX_REBOOT_BOOT_ID FM_TMUX_REBOOT_BOOT_EPOCH FM_TMUX_REBOOT_PID_NAMESPACE FM_TMUX_REBOOT_SPAWN_GEN
  FM_TMUX_SUCCESSOR=1
}

# SAFETY: a connection refusal alone cannot distinguish a dead server from an
# inaccessible host. Dead-server proof requires the same local Linux host and
# boot, positive kernel PID absence, and an owned socket path with a native
# absent-server result. A live socket or PID reuse never licenses replacement.
fm_backend_tmux_server_state() {
  local row err parent
  [ -n "${FM_TMUX_SOCKET:-}" ] || { printf legacy; return; }
  if [ -n "${FM_TMUX_REBOOT_BOOT_ID:-}" ]; then
    fm_backend_tmux_reboot_proven || { printf unreadable; return; }
  fi
  if [ -n "${FM_TMUX_HOST_ID:-}" ]; then
    [ "$(fm_run_timed 5 cat /etc/machine-id 2>/dev/null)" = "$FM_TMUX_HOST_ID" ] || { printf unreadable; return; }
    if [ -z "${FM_TMUX_REBOOT_BOOT_ID:-}" ]; then
      [ "$(fm_run_timed 5 cat /proc/sys/kernel/random/boot_id 2>/dev/null)" = "$FM_TMUX_BOOT_ID" ] \
        && [ "$(fm_run_timed 5 readlink /proc/self/ns/pid 2>/dev/null)" = "$FM_TMUX_PID_NAMESPACE" ] \
        || { printf unreadable; return; }
    fi
  fi
  [ ! -L "$FM_TMUX_SOCKET" ] || { printf unreadable; return; }
  if [ -e "$FM_TMUX_SOCKET" ] && { [ ! -S "$FM_TMUX_SOCKET" ] || [ ! -O "$FM_TMUX_SOCKET" ]; }; then
    printf unreadable; return
  fi
  if row=$(fm_run_timed 5 tmux -S "$FM_TMUX_SOCKET" display-message -p \
    '#{socket_path}|#{pid}|#{start_time}' 2>/dev/null); then
    if [ -n "${FM_TMUX_REBOOT_BOOT_ID:-}" ] \
      || [ "$row" != "$FM_TMUX_SOCKET|$FM_TMUX_SERVER_PID|${FM_TMUX_SERVER_START:-}" ] \
      || { [ -n "${FM_TMUX_PROCESS_IDENTITY:-}" ] \
        && [ "$(fm_tmux_pid_identity "$FM_TMUX_SERVER_PID" 2>/dev/null)" != "$FM_TMUX_PROCESS_IDENTITY" ]; }; then
      if fm_backend_tmux_successor "$FM_TMUX_META"; then printf successor; else printf unreadable; fi
    else
      printf alive
    fi
    return
  fi
  parent=${FM_TMUX_SOCKET%/*}
  [ -n "${FM_TMUX_HOST_ID:-}" ] && [ "$(uname -s)" = Linux ] \
    && [ -d /proc/self ] && [ -r /proc ] && [ -x /proc ] \
    && [ ! -e "/proc/$FM_TMUX_SERVER_PID" ] \
    && [ -d "$parent" ] && [ -O "$parent" ] && [ ! -L "$parent" ] \
    || { printf unreadable; return; }
  err=$(LC_ALL=C fm_run_timed 5 tmux -S "$FM_TMUX_SOCKET" display-message -p '#{pid}' 2>&1) \
    && { printf unreadable; return; }
  case "$err" in
    "no server running on $FM_TMUX_SOCKET"|"error connecting to $FM_TMUX_SOCKET (No such file or directory)"|"error connecting to $FM_TMUX_SOCKET (Connection refused)")
      printf gone ;;
    *) printf unreadable ;;
  esac
}

fm_backend_tmux_reboot_proven() {
  local boot launch now
  [ "$(fm_run_timed 5 cat /proc/sys/kernel/random/boot_id 2>/dev/null)" = "$FM_TMUX_REBOOT_BOOT_ID" ] \
    && [ "$(fm_run_timed 5 readlink /proc/self/ns/pid 2>/dev/null)" = "$FM_TMUX_REBOOT_PID_NAMESPACE" ] \
    && [ "$(fm_backend_meta_exact_value "$FM_TMUX_META" spawn_gen)" = "$FM_TMUX_REBOOT_SPAWN_GEN" ] || return 1
  # shellcheck disable=SC2016 # awk fields are not shell substitutions
  boot=$(fm_run_timed 5 awk '$1 == "btime" {print $2}' /proc/stat) || return 1
  [ "$boot" = "$FM_TMUX_REBOOT_BOOT_EPOCH" ] || return 1
  case "$FM_TMUX_REBOOT_SPAWN_GEN" in
    s*.*.*) launch=${FM_TMUX_REBOOT_SPAWN_GEN#s}; launch=${launch%%.*} ;;
    *) return 1 ;;
  esac
  case "$launch:$boot" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "${#launch}" -le 10 ] && [ "${#boot}" -le 10 ] || return 1
  now=$(date +%s) || return 1
  [ "$launch" -gt 0 ] && [ "$launch" -lt "$boot" ] && [ "$boot" -le "$now" ]
}

# Absence is proved only on the still-live recorded server, using its stable
# window id across every session. A renamed or moved window refuses rather
# than being replaced at its old label.
fm_backend_tmux_endpoint_absence_recheck() {  # <target> <meta>
  local target=$1 meta=$2 rows state
  fm_backend_tmux_bind_meta "$meta" 2>/dev/null || { printf 'unreadable'; return 0; }
  [ -n "${FM_TMUX_SOCKET:-}" ] || { printf 'legacy'; return 0; }
  case "$(fm_backend_tmux_server_state)" in
    gone) printf missing; return ;;
    alive) ;;
    *) printf unreadable; return ;;
  esac
  if [ "$FM_TMUX_SUCCESSOR" = 1 ]; then
    if fm_backend_tmux_target_exists "$target"; then printf unreadable; else printf missing; fi
    return
  fi
  rows=$(fm_tmux list-windows -a -F '#{window_id}') || { printf 'unreadable'; return 0; }
  if printf '%s\n' "$rows" | grep -Fqx -- "$FM_TMUX_WINDOW_ID"; then
    state=$(fm_backend_tmux_agent_state "$target")
    case "$state" in alive|dead) printf '%s' "$state" ;; *) printf 'unreadable' ;; esac
  elif fm_backend_tmux_target_exists "$target"; then
    printf 'unreadable'
  else
    printf 'missing'
  fi
}

# SAFETY: inspect current-user kernel processes for task markers even when an
# agent or validation job changed cwd, plus open worktree resources. Unreadable
# surviving processes and platforms without this evidence refuse recovery.
fm_backend_tmux_worktree_free() {  # <worktree> <meta> [idle-pane-pid]
  # shellcheck disable=SC2016 # the bounded child reads its exported probe inputs
  FM_TMUX_PROBE_LIB=$FM_BACKEND_LIB_DIR FM_TMUX_PROBE_WT=$1 FM_TMUX_PROBE_META=$2 \
    FM_TMUX_PROBE_ALLOWED=${3:-} fm_run_timed 15 bash -c \
    '. "$FM_TMUX_PROBE_LIB/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_worktree_free_probe "$FM_TMUX_PROBE_WT" "$FM_TMUX_PROBE_META" "$FM_TMUX_PROBE_ALLOWED"'
}

fm_backend_tmux_worktree_free_probe() {
  local wt=$1 meta=$2 allowed=${3:-} rows pid='' line path err proc token inbox
  [ "$(uname -s)" = Linux ] && [ -d /proc/self ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  wt=$(cd "$wt" && pwd -P) || return 1
  inbox=${meta%.meta}.inbox
  for proc in /proc/[0-9]*; do
    [ -O "$proc" ] || continue
    pid=${proc##*/}
    [ "$pid" != "$allowed" ] || continue
    if [ ! -r "$proc/environ" ] || [ ! -r "$proc/cmdline" ]; then
      [ ! -d "$proc" ] || return 1
      continue
    fi
    while IFS= read -r -d '' token; do
      [ "$token" != "FM_TASK_INBOX=$inbox" ] || return 1
    done < "$proc/environ" 2>/dev/null || { [ ! -d "$proc" ] || return 1; }
    while IFS= read -r -d '' token; do
      case "$token" in *"$wt"*|*"$inbox"*) return 1 ;; esac
    done < "$proc/cmdline" 2>/dev/null || { [ ! -d "$proc" ] || return 1; }
  done
  err=$(mktemp) || return 1
  if ! rows=$(fm_run_timed 10 lsof -n -a -u "$(id -u)" -F pn 2>"$err") || [ -s "$err" ]; then
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  [ -n "$rows" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        path=${line#n}
        case "$path/" in
          "$wt/"*)
            [ -n "$allowed" ] && [ "$pid" = "$allowed" ] || return 1
            ;;
        esac
        ;;
    esac
  done <<< "$rows"
}

fm_backend_tmux_validation_free() {  # <worktree> <meta>
  local wt=$1 meta=$2 overview selection ids run detail status branch
  [ "$(fm_meta_get "$meta" mode)" = no-mistakes ] || [ -e "$wt/.no-mistakes" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 1
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || return 1
  overview=$(fm_nm_run_checked "$wt" 10 axi) || return 1
  selection=$(fm_nm_select_run "$branch" "$overview" "$wt" 10) || return 1
  case "$selection" in
    absent) return 0 ;;
    selected\|*) ids=${selection##*|} ;;
    *) return 1 ;;
  esac
  [ -n "$ids" ] || return 1
  # SAFETY: reporting selects the newest run, but replacement must account for
  # every same-branch candidate, including an older still-running allocation.
  local -a candidates
  IFS=',' read -r -a candidates <<< "$ids"
  for run in "${candidates[@]}"; do
    run=$(fm_nm_trim "$run")
    [ -n "$run" ] || return 1
    detail=$(fm_nm_run_checked "$wt" 10 axi status --run "$run") || return 1
    [ "$(fm_nm_strip_quotes "$(fm_nm_field "$detail" branch)")" = "$branch" ] || return 1
    status=$(fm_nm_strip_quotes "$(fm_nm_field "$detail" status)")
    [ "$(fm_nm_run_status_class "$status")" = terminal ] || return 1
  done
}

fm_backend_tmux_idle_custody() {  # <meta> <target>
  local meta=$1 target=$2 pid wt
  [ -n "${FM_TMUX_SOCKET:-}" ] || return 0
  wt=$(fm_meta_get "$meta" worktree)
  [ "$(fm_backend_tmux_agent_state "$target")" = dead ] \
    && [ "$(fm_backend_tmux_current_path "$target")" = "$wt" ] || return 1
  pid=$(fm_tmux display-message -p -t "$target" '#{pane_pid}') || return 1
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  fm_backend_tmux_validation_free "$wt" "$meta" \
    && fm_backend_tmux_worktree_free "$wt" "$meta" "$pid"
}

# Recreate only the proven-dead recorded server, through the native spawn
# owner. This is never an ambient-server fallback or a socket namespace sweep.
fm_backend_tmux_recover_server() {  # <meta> <worktree> <session>
  local meta=$1 wt=$2 session=$3 tmp receipt_cmd home id old_socket
  fm_backend_tmux_bind_meta "$meta" || return 1
  fm_backend_tmux_worktree_free "$wt" "$meta" \
    && fm_backend_tmux_validation_free "$wt" "$meta" || return 1
  if [ "$FM_TMUX_SUCCESSOR" != 1 ]; then
    [ "$(fm_backend_tmux_server_state)" = gone ] || return 1
    home=${meta%/state/*}
    id=${meta##*/}; id=${id%.meta}
    [ "$home/state/$id.meta" = "$meta" ] && [ -d "$home/data/$id" ] || return 1
    tmp=$(mktemp -d "$home/data/$id/tmux-start.XXXXXX") || return 1
    cp -p "$meta" "$tmp/meta-prior" || return 1
    old_socket=$FM_TMUX_SOCKET
    receipt_cmd="bash -c "
    # shellcheck disable=SC2016 # the native startup child expands these inputs
    receipt_cmd="$receipt_cmd$(fm_tmux_quote \
      '. "$1/fm-path-lib.sh"; process=$(fm_pid_identity "$3") || exit 1; printf "%s\n" "tmux_socket=$2" "tmux_server_pid=$3" "tmux_server_start=$4" "tmux_host_id=$(cat /etc/machine-id)" "tmux_boot_id=$(cat /proc/sys/kernel/random/boot_id)" "tmux_pid_namespace=$(readlink /proc/self/ns/pid)" "tmux_process_identity=$process"')"
    receipt_cmd="$receipt_cmd bash $(fm_tmux_quote "$FM_BACKEND_LIB_DIR")"
    receipt_cmd="$receipt_cmd '#{socket_path}' '#{pid}' '#{start_time}' > $(fm_tmux_quote "$tmp/identity")"
    {
      printf 'set-option -g exit-empty off\n'
      printf 'run-shell %s\n' "$(fm_tmux_quote "$receipt_cmd")"
    } > "$tmp/init.conf"
  # SAFETY: startup configuration runs only in a server this invocation starts.
  # A raced live server ignores it and leaves no native startup receipt; it is
  # never asked to create a session or endpoint.
    fm_run_timed 10 tmux -S "$old_socket" -f "$tmp/init.conf" start-server || return 1
    [ -s "$tmp/identity" ] || return 1
    fm_backend_tmux_apply_successor "$meta" || return 1
  fi
  fm_tmux has-session -t "=$session" 2>/dev/null \
    || fm_tmux new-session -d -s "$session" -n recovery -c /tmp || return 1
  fm_tmux set-option -g exit-empty on
}

fm_backend_tmux_composer_state() { fm_tmux_composer_state "$@"; }

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  fm_tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  fm_tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_visible_capture: the visible viewport only. `-S -0` starts at
# the first line of the pane rather than in its history, so nothing scrolled out
# of view can appear in the result - the guarantee a trust-dialog predicate
# needs, which the scrollback-bounded capture above cannot give.
fm_backend_tmux_visible_capture() {  # <target>
  fm_tmux capture-pane -p -t "$1" -S -0
}

# fm_backend_tmux_send_key: one named key. Tmux can prefix-match a gone target
# to a live neighbor, so require exact membership before sending the key.
fm_backend_tmux_send_key() {  # <target> <key>
  fm_backend_tmux_target_exists "$1" || return 1
  fm_tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_own_session: print the name of the tmux session this process
# was started in. An untargeted display-message picks the most recently used
# member of a session group, and so does a pane target, so an external client
# attached through a grouped session (`new-session -t <session>`) would be
# named instead. The third field of $TMUX is the id of the session the pane was
# created in, which stays unambiguous across the group; fall back to the
# untargeted lookup when it is absent, malformed, or stale (tmux answers a
# killed session's id with empty output and exit 0).
fm_backend_tmux_own_session() {
  local sid=${TMUX##*,} name=
  case "$sid" in
  ''|*[!0-9]*) ;;
  *) name=$(fm_tmux display-message -p -t "\$$sid" '#S' 2>/dev/null) ;;
  esac
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
  else
    fm_tmux display-message -p '#S'
  fi
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    fm_backend_tmux_own_session
  else
    fm_tmux has-session -t firstmate 2>/dev/null || fm_tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if fm_tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(fm_tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  fm_tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  fm_tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  fm_tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  fm_tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  fm_tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_window_inventory: <session-target>'s window names, one per
# line on stdout, together with a verdict on the READ ITSELF, which is what
# every caller that must not guess depends on:
#   0 - the inventory was read; its lines are that session's windows.
#   2 - tmux answered definitively that the session, or its whole server, is
#       absent, so no window of that session exists.
#   1 - the read could not be made at all, and proves nothing either way. A
#       transient tmux problem, or a tmux that is not even on PATH, must never
#       be read as an absent endpoint: that mistake launches a duplicate agent
#       for fm_backend_tmux_agent_state and reports a live window as closed for
#       fm_backend_tmux_kill.
# The target is passed through exactly as the caller means it, so a caller that
# requires the exact recorded session asks for `=session` and still gets the
# same classification.
fm_backend_tmux_window_inventory() {  # <session-target>
  local windows
  if windows=$(LC_ALL=C fm_tmux list-windows -t "$1" -F '#{window_name}' 2>&1); then
    printf '%s\n' "$windows"
    return 0
  fi
  case "$windows" in
    *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
      return 2
      ;;
  esac
  return 1
}

# Resolve one exact window selector in one exact session to its stable id.
# The shared dispatcher header owns the accepted target grammar.
fm_backend_tmux_window_id() {  # <session-name> <window-name|index|@id>
  local session=$1 selector=$2 rows window_id window_index window_name
  rows=$(LC_ALL=C fm_tmux list-windows -t "=$session" \
    -F '#{window_id}|#{window_index}|#{window_name}' 2>/dev/null) || return 1
  while IFS='|' read -r window_id window_index window_name; do
    case "$selector" in
      @*) [ "$window_id" = "$selector" ] || continue ;;
      *[!0-9]*) [ "$window_name" = "$selector" ] || continue ;;
      *) [ "$window_index" = "$selector" ] || continue ;;
    esac
    printf '%s\n' "$window_id"
    return 0
  done <<EOF
$rows
EOF
  return 1
}

# Adapter-owned tmux endpoint membership. Every comparison is literal and
# session-scoped where the target names a session, so tmux never gets a chance
# to satisfy the predicate through its prefix, pattern, or active-window
# fallbacks.
fm_backend_tmux_target_exists() {  # <target>
  local target=${1:-} session selector windows base pane_index window_id
  [ -n "$target" ] || return 1
  case "$target" in
    %*)
      fm_tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -Fqx -- "$target"
      ;;
    @*)
      fm_tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -Fqx -- "$target"
      ;;
    *:*:*)
      return 1
      ;;
    *:*)
      session=${target%%:*}
      selector=${target#*:}
      case "$session" in =*) session=${session#=} ;; esac
      case "$selector" in =*) selector=${selector#=} ;; esac
      [ -n "$session" ] && [ -n "$selector" ] || return 1

      case "$selector" in
        @*) fm_backend_tmux_window_id "$session" "$selector" >/dev/null ; return ;;
        *[!0-9]*) ;;
        *) fm_backend_tmux_window_id "$session" "$selector" >/dev/null ; return ;;
      esac

      windows=$(fm_backend_tmux_window_inventory "=$session") || return 1
      if printf '%s\n' "$windows" | grep -Fqx -- "$selector"; then
        return 0
      fi

      case "$selector" in
        *.*)
          base=${selector%.*}
          pane_index=${selector##*.}
          [ -n "$base" ] && [ -n "$pane_index" ] || return 1
          case "$base" in *[!0-9]*) return 1 ;; esac
          case "$pane_index" in *[!0-9]*) return 1 ;; esac
          window_id=$(fm_backend_tmux_window_id "$session" "$base") || return 1
          fm_tmux list-panes -t "$window_id" -F '#{pane_index}' 2>/dev/null \
            | grep -Fqx -- "$pane_index"
          ;;
        *) return 1 ;;
      esac
      ;;
    *)
      session=$target
      case "$session" in =*) session=${session#=} ;; esac
      [ -n "$session" ] || return 1
      fm_tmux has-session -t "=$session" 2>/dev/null
      ;;
  esac
}

# fm_backend_tmux_kill: remove one explicitly named task window.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
#
# A close that did not succeed is resolved, never assumed: `kill-window` fails
# for the ordinary already-exited window exactly as it does for a window that
# is still there, so its status alone cannot tell a benign cleanup from a
# stranded endpoint. The re-read below settles which one happened, under the
# window's EXACT recorded identity (`=session` plus a whole-line name match -
# never a prefix, which would read a neighbor as this window's survivor).
# Only a read that actually happened can settle it, so the same classification
# fm_backend_tmux_agent_state uses applies here: a window still present is the
# kill failing to do its job, a definitively absent session or server is the
# silent success, and an inventory that could not be read refuses rather than
# calling a window it never saw closed. An already-gone window, and a whole
# server that is already gone, stay silent successes. Verified against real
# tmux 3.7c: killing a live window, re-killing the same gone window, and
# killing into a dead session all return 0 here
# (docs/verification/runtime-backends.md "Endpoint close").
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window windows inventory_status
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  fm_tmux kill-window -t "=$session:=$window" 2>/dev/null && return 0
  windows=$(fm_backend_tmux_window_inventory "=$session")
  inventory_status=$?
  if [ "$inventory_status" -eq 2 ]; then
    return 0
  fi
  if [ "$inventory_status" -ne 0 ]; then
    echo "error: fm_tmux window $session:$window could not be read after its close, so whether it survived is unknown" >&2
    return 1
  fi
  printf '%s\n' "$windows" | grep -qxF -- "$window" || return 0
  echo "error: fm_tmux window $session:$window is still present after its close" >&2
  return 1
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  fm_tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# The process-name classifier every liveness signal below feeds
# (fm_agent_process_classify_name) is owned by bin/fm-agent-process-lib.sh,
# shared with the Herdr adapter so both backends mean the same thing by
# `agent`, `shell`, and `other`.

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command this is a RAW pane read: tmux answers an
# absent target from the client's active window rather than failing, so callers
# must confirm exact window membership first, exactly as the classifier below
# does, or they will describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(fm_tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

# The foreground group's full command lines. Needed because a node-bundle
# harness carries its identity in argv[1] rather than in its command name or
# argv[0]; bin/fm-gemini-lib.sh owns what counts as evidence inside one.
fm_backend_tmux_foreground_args() {  # <target>
  local target=$1 tty pid pgid tpgid comm args
  tty=$(fm_tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        [ -n "$args" ] && printf '%s\n' "$args"
      done
}

fm_backend_tmux_foreground_pids() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(fm_tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$pid"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(fm_tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
# fm_backend_tmux_window_inventory above owns that read classification, shared
# with fm_backend_tmux_kill so both mean the same thing by an absent session.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  local foreground argv0s name pid fg_seen=0 fg_shell=0 fg_other=0
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  windows=$(fm_backend_tmux_window_inventory "$session")
  inventory_status=$?
  if [ "$inventory_status" -ne 0 ]; then
    if [ "$inventory_status" -eq 2 ]; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi
  if [ -n "${FM_TMUX_WINDOW_ID:-}" ] \
    && [ "$(fm_backend_tmux_window_id "$session" "$window")" != "$FM_TMUX_WINDOW_ID" ]; then
    printf 'ambiguous'
    return 0
  fi

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_agent_process_classify_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_agent_process_classify_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  # Preserve argv boundaries where the platform exposes them. This is needed
  # when the Gemini script path contains whitespace, which flattened ps output
  # cannot represent unambiguously.
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if fm_gemini_pid_is_gemini "$pid"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_pids "$target")
EOF

  # Fall back to flattened arguments on platforms without /proc. Positive
  # evidence only - a bare interpreter still reaches the negative verdicts.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if fm_gemini_args_are_gemini "$name"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_args "$target")
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_agent_process_classify_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_agent_process_classify_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
