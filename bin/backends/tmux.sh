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
# shellcheck source=bin/fm-cursor-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-cursor-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key> [expected-label] [recorded-harness] [raw-launch] [explicit-target]
  local target=$1 key=$2 recorded_harness=${4:-} raw_launch=${5:-}
  tmux display-message -p -t "$target" '#{pane_id}' >/dev/null || return 1
  if [ -n "$recorded_harness" ] && [ "$raw_launch" != 1 ] \
    && command -v fm_backend_endpoint_allows >/dev/null 2>&1 \
    && ! fm_backend_endpoint_allows tmux "$target" "$recorded_harness" "$raw_launch"; then
    return 1
  fi
  tmux send-keys -t "$target" "$key"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
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
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove one explicitly named task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window
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
  tmux kill-window -t "=$session:=$window" 2>/dev/null || true
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
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_classify_process_name: the single owner of the process-name
# vocabulary shared by every liveness signal below - `agent` for a verified
# harness, `shell` for an idle login/interactive shell, `other` for anything
# else. Keeping one classifier means the two independent name sources can never
# drift into disagreeing about what a given name means.
fm_backend_tmux_classify_process_name() {  # <path> [argv0] [executable] [script] -> agent|shell|other
  local path=$1 argv0=${2:-} executable=${3:-} script=${4:-} base
  base=${path##*/}
  base=${base#-}
  if fm_harness_omp_process_matches "$path" "$argv0" "$executable" "$script"; then
    printf 'agent'
    return 0
  fi
  case "$base" in
    muse|muse-bin-*)
      if fm_harness_muse_executable_matches "$executable"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers above fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

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
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C "${FM_TMUX_PS_BIN:-ps}" -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

fm_backend_tmux_process_executable() {  # <pid>
  fm_harness_process_executable "$1" "${FM_TMUX_PS_BIN:-ps}"
}

fm_backend_tmux_foreground_process_records() {  # <target> -> comm<TAB>args<TAB>executable<TAB>script
  local target=$1 tty pid pgid tpgid comm args executable script
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C "${FM_TMUX_PS_BIN:-ps}" -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C "${FM_TMUX_PS_BIN:-ps}" -p "$pid" -o args= 2>/dev/null) || args=
        executable=$(fm_backend_tmux_process_executable "$pid" 2>/dev/null || true)
        script=
        if [ -n "$executable" ] && [ "$(basename -- "$executable")" = bun ]; then
          script=$(fm_harness_omp_script_from_args "$args" 2>/dev/null || true)
        fi
        printf '%s\t%s\t%s\t%s\n' "$comm" "$args" "$executable" "$script"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C "${FM_TMUX_PS_BIN:-ps}" -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C "${FM_TMUX_PS_BIN:-ps}" -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

fm_backend_tmux_foreground_omp_identity() {  # <target>
  [ "$(fm_backend_tmux_process_identity "$1")" = omp ]
}

fm_backend_tmux_foreground_process_identity() {  # <target> -> harness|shell|other|unknown
  local target=$1 name args executable script identity current_identity= shell_seen=0 omp_seen=0 other_seen=0
  while IFS=$'\t' read -r name args executable script; do
    [ -n "$name" ] || continue
    identity=$(fm_harness_process_identity "$name" "$args" "$executable" "$script")
    case "$identity" in
      omp) omp_seen=1 ;;
      shell) shell_seen=1 ;;
      *)
        if fm_harness_identity_supported "$identity"; then
          if [ -z "$current_identity" ]; then
            current_identity=$identity
          elif ! fm_harness_identity_matches "$current_identity" "$identity"; then
            printf 'unknown'
            return 0
          fi
        else
          case "${name##*/}" in
            bun) : ;;
            *) other_seen=1 ;;
          esac
        fi
        ;;
    esac
  done < <(fm_backend_tmux_foreground_process_records "$target")
  name=$(fm_backend_tmux_current_command "$target") || {
    printf 'unknown'
    return 0
  }
  identity=$(fm_harness_process_identity "$name" "$name")
  case "$identity" in
    omp) omp_seen=1 ;;
    shell) shell_seen=1 ;;
    *)
      if fm_harness_identity_supported "$identity"; then
        if [ -z "$current_identity" ]; then
          current_identity=$identity
        elif ! fm_harness_identity_matches "$current_identity" "$identity"; then
          printf 'unknown'
          return 0
        fi
      else
        if [ "$omp_seen" -eq 0 ]; then
          case "${name##*/}" in
            bun) : ;;
            *) other_seen=1 ;;
          esac
        fi
      fi
      ;;
  esac
  if [ "$omp_seen" -eq 1 ]; then
    if [ -n "$current_identity" ] || [ "$shell_seen" -eq 1 ] || [ "$other_seen" -eq 1 ]; then
      printf 'unknown'
    else
      printf 'omp'
    fi
  elif [ -n "$current_identity" ]; then
    printf '%s' "$current_identity"
  elif [ "$shell_seen" -eq 1 ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

fm_backend_tmux_process_identity() {  # <target> -> harness|shell|other|unknown
  fm_backend_tmux_foreground_process_identity "$1"
}

fm_backend_tmux_target_inventory_state() {  # <target> -> present|missing|unreadable
  local target=${1:-} session window windows
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if windows=$(LC_ALL=C tmux list-windows -t "$session" -F '#{window_name}' 2>&1); then
    if printf '%s\n' "$windows" | grep -Fqx "$window"; then
      printf 'present'
    else
      printf 'missing'
    fi
    return 0
  fi
  case "$windows" in
    *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
      printf 'missing'
      ;;
    *) printf 'unreadable' ;;
  esac
}

fm_backend_tmux_classify_process_name_raw() {  # <path> [argv0] -> agent|shell|other
  local path=${1:-} argv0=${2:-}
  case "${path##*/}" in
    omp) printf 'other'; return 0 ;;
  esac
  case "${argv0##*/}" in
    omp) printf 'other'; return 0 ;;
  esac
  fm_backend_tmux_classify_process_name "$path" "$argv0"
}

fm_backend_tmux_omp_terminal_stop_observed() {  # <target>
  local target=${1:-} window id state generation run_token marker
  case "$target" in
    *:fm-*) ;;
    *) return 1 ;;
  esac
  window=${target#*:}
  id=${window#fm-}
  [ -n "$id" ] || return 1
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  generation=$(fm_harness_read_regular_nofollow "$state/$id.busy-gen" 2>/dev/null) || return 1
  run_token=$(fm_harness_read_regular_nofollow "$state/$id.omp-session-run" 2>/dev/null) || return 1
  marker=$(fm_harness_read_regular_nofollow "$state/$id.omp-session-stop" 2>/dev/null) || return 1
  case "$generation:$run_token:$marker" in
    *[!A-Za-z0-9._:-]*|:*) return 1 ;;
  esac
  case "$run_token" in
    "$generation".*) ;;
    *) return 1 ;;
  esac
  [ "$run_token" = "$marker" ]
}

fm_backend_tmux_omp_exited_to_shell() {
  local target=$1 name current count=0
  fm_backend_tmux_omp_terminal_stop_observed "$target" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    [ "$(fm_harness_process_identity "$name" "$name")" = shell ] || return 1
  done < <(fm_backend_tmux_foreground_comms "$target")
  [ "$count" -eq 1 ] || return 1
  current=$(fm_backend_tmux_current_command "$target") || return 1
  [ "$(fm_harness_process_identity "$current" "$current")" = shell ]
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
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target> [recorded-harness] [raw-launch]
  local target=$1 recorded_harness=${2:-} raw_launch=${3:-} comm comm_state inventory_status process_identity
  if [ "$recorded_harness" = 1 ] && [ -z "$raw_launch" ]; then
    raw_launch=1
    recorded_harness=
  fi
  local foreground argv0s name fg_seen=0 fg_shell=0 fg_other=0
  inventory_status=$(fm_backend_tmux_target_inventory_state "$target")
  case "$inventory_status" in
    present) ;;
    missing) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  if [ -n "$recorded_harness" ] && [ "$recorded_harness" != omp ] \
    && [ "$recorded_harness" != unknown ] && [ "$raw_launch" != 1 ]; then
    process_identity=$(fm_backend_tmux_process_identity "$target")
    case "$process_identity" in
      claude|codex|opencode|grok|kimi|muse|pi|pi-signed)
        fm_harness_identity_matches "$recorded_harness" "$process_identity" || {
          printf 'ambiguous'
          return 0
        }
        ;;
      *) printf 'ambiguous'; return 0 ;;
    esac
  fi
  if [ "$recorded_harness" = omp ] && [ "$raw_launch" != 1 ]; then
    process_identity=$(fm_backend_tmux_process_identity "$target")
    if [ "$process_identity" != omp ]; then
      case "$process_identity" in
        shell)
          fm_backend_tmux_omp_exited_to_shell "$target" || {
            printf 'ambiguous'
            return 0
          }
          ;;
        *) printf 'ambiguous'; return 0 ;;
      esac
    fi
  fi

  while IFS=$'\t' read -r name args executable script; do
    [ -n "$name" ] || continue
    process_identity=$(fm_harness_process_identity "$name" "$args" "$executable" "$script")
    if [ "$raw_launch" != 1 ] && fm_harness_identity_supported "$process_identity"; then
      printf 'alive'
      return 0
    fi
  done < <(fm_backend_tmux_foreground_process_records "$target")

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    if [ "$raw_launch" = 1 ]; then
      case "$(fm_backend_tmux_classify_process_name_raw "$name")" in
        agent) printf 'alive'; return 0 ;;
        shell) fg_shell=1 ;;
        *) fg_other=1 ;;
      esac
    else
      case "$(fm_backend_tmux_classify_process_name "$name")" in
        agent) printf 'alive'; return 0 ;;
        shell) fg_shell=1 ;;
        *) fg_other=1 ;;
      esac
    fi
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$raw_launch" = 1 ]; then
      if [ "$(fm_backend_tmux_classify_process_name_raw '' "$name")" = agent ]; then
        printf 'alive'
        return 0
      fi
    elif [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$raw_launch" = 1 ]; then
    comm_state=$(fm_backend_tmux_classify_process_name_raw "$comm")
  else
    comm_state=$(fm_backend_tmux_classify_process_name "$comm")
  fi
  if [ "$comm_state" = agent ]; then
    printf 'alive'
    return 0
  fi

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
  case "$comm_state" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target> [recorded-harness] [raw-launch]
  case "$(fm_backend_tmux_agent_state "$1" "${2:-}" "${3:-}")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
