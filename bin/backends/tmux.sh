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
fm_backend_tmux_send_key() {  # <target> <key>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null
  tmux send-keys -t "$1" "$2"
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
#
# The probe asks for "=firstmate" - the same exact form every consumer of the
# returned name then targets. A bare -t falls back to prefix and then fnmatch,
# so a live look-alike (firstmate-lab, firstmate2) would answer for a session
# that does not exist, and the name handed back would address nothing.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t "=firstmate" 2>/dev/null || tmux new-session -d -s firstmate
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
#
# The session is targeted as "=<name>": tmux's bare -t <session> falls back to
# prefix and then fnmatch resolution, so a recorded session name that no longer
# exists would silently resolve to an unrelated live session whose name merely
# starts with it, and the duplicate check would then be answered by - and the
# window created in - that other session.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "=$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "=$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# Recreate an authoritatively missing task endpoint at its recorded address.
# The caller retains the existing worktree and task record; this function only
# creates the shell endpoint that can host the replacement agent. The recorded
# session is looked up as "=<name>" so an unrelated live session that merely
# shares its prefix can never absorb the replacement window; when the recorded
# session is genuinely gone, a session of exactly that name is started instead.
fm_backend_tmux_recreate_task() {  # <session:window> <worktree> -> prints window id
  local target=$1 worktree=$2 session window state wid
  case "$target" in
    *:*:*)
      echo "error: tmux task endpoint '$target' is malformed" >&2
      return 1
      ;;
    *:*) ;;
    *)
      echo "error: tmux task endpoint '$target' is malformed" >&2
      return 1
      ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  [ -n "$session" ] && [ -n "$window" ] || {
    echo "error: tmux task endpoint '$target' is malformed" >&2
    return 1
  }
  state=$(fm_backend_tmux_agent_state "$target")
  [ "$state" = missing ] || {
    echo "error: tmux task endpoint '$target' reads '$state', not missing; refusing to create a duplicate endpoint" >&2
    return 1
  }
  if tmux has-session -t "=$session" 2>/dev/null; then
    fm_backend_tmux_create_task "$session" "$window" "$worktree"
    return
  fi
  wid=$(tmux new-session -dP -F '#{window_id}' -s "$session" -n "$window" -c "$worktree") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# Recreate an authoritatively missing task endpoint at its recorded address.
# The caller retains the existing worktree and task record; this function only
# creates the shell endpoint that can host the replacement agent.
fm_backend_tmux_recreate_task() {  # <session:window> <worktree> -> prints window id
  local target=$1 worktree=$2 session window state wid
  case "$target" in
    *:*:*)
      echo "error: tmux task endpoint '$target' is malformed" >&2
      return 1
      ;;
    *:*) ;;
    *)
      echo "error: tmux task endpoint '$target' is malformed" >&2
      return 1
      ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  [ -n "$session" ] && [ -n "$window" ] || {
    echo "error: tmux task endpoint '$target' is malformed" >&2
    return 1
  }
  state=$(fm_backend_tmux_agent_state "$target")
  [ "$state" = missing ] || {
    echo "error: tmux task endpoint '$target' reads '$state', not missing; refusing to create a duplicate endpoint" >&2
    return 1
  }
  if tmux has-session -t "$session" 2>/dev/null; then
    fm_backend_tmux_create_task "$session" "$window" "$worktree"
    return
  fi
  wid=$(tmux new-session -dP -F '#{window_id}' -s "$session" -n "$window" -c "$worktree") || return 1
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
fm_backend_tmux_classify_process_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
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
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
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

# fm_backend_tmux_inspect_endpoint: the one owner of how a recorded
# "<session>:<window>" endpoint is looked up - the target-shape parse, the
# exact-session inventory read, and the reading of tmux's own refusals. The
# liveness verdict and the recovery grade below are both derived from this
# single observation, so they cannot drift into disagreeing about what was
# asked of tmux or what tmux answered.
#
# The session is targeted as "=<name>": a bare -t <session> resolves by exact
# match, then prefix, then fnmatch, so an unrelated live session sharing the
# recorded name's prefix would otherwise answer in its place.
#
# Sets FM_BACKEND_TMUX_INSPECT_RESULT to one of:
#   malformed       the target is not a single <session>:<window> pair
#   listed          a reachable server's session inventory names the window
#   window-absent   a reachable server's session inventory omits the window
#   session-absent  a reachable server reports the recorded session is gone
#   unreachable     no server could be reached on the socket at all
#   unreadable      tmux failed for some other reason
# plus FM_BACKEND_TMUX_INSPECT_SOCKET (the socket tmux itself named, whenever it
# named one) and FM_BACKEND_TMUX_INSPECT_RESPONSE (tmux's own first line, or a
# description of what the inventory showed).
FM_BACKEND_TMUX_INSPECT_RESULT=
FM_BACKEND_TMUX_INSPECT_SOCKET=
FM_BACKEND_TMUX_INSPECT_RESPONSE=
fm_backend_tmux_inspect_endpoint() {  # <target>
  local target=$1 session window windows inventory_status rest
  FM_BACKEND_TMUX_INSPECT_RESULT=malformed
  FM_BACKEND_TMUX_INSPECT_SOCKET=
  FM_BACKEND_TMUX_INSPECT_RESPONSE=
  case "$target" in
    *:*:*|'':*|*:'') FM_BACKEND_TMUX_INSPECT_RESPONSE="endpoint '$target' is malformed"; return 0 ;;
    *:*) ;;
    *) FM_BACKEND_TMUX_INSPECT_RESPONSE="endpoint '$target' is malformed"; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if windows=$(LC_ALL=C tmux list-windows -t "=$session" -F '#{window_name}' 2>&1); then
    inventory_status=0
  else
    inventory_status=$?
  fi
  if [ "$inventory_status" -eq 0 ]; then
    FM_BACKEND_TMUX_INSPECT_SOCKET=$(tmux display-message -p '#{socket_path}' 2>/dev/null) || true
    if printf '%s\n' "$windows" | grep -Fqx "$window"; then
      FM_BACKEND_TMUX_INSPECT_RESULT=listed
      FM_BACKEND_TMUX_INSPECT_RESPONSE="session inventory read; it lists $window, so the endpoint is present"
    else
      FM_BACKEND_TMUX_INSPECT_RESULT='window-absent'
      FM_BACKEND_TMUX_INSPECT_RESPONSE="session inventory read; it does not list $window"
    fi
    return 0
  fi
  FM_BACKEND_TMUX_INSPECT_RESPONSE=$(printf '%s\n' "$windows" | head -n 1)
  [ -n "$FM_BACKEND_TMUX_INSPECT_RESPONSE" ] \
    || FM_BACKEND_TMUX_INSPECT_RESPONSE="tmux list-windows exited $inventory_status with no message"
  case "$windows" in
    *"can't find session:"*)
      FM_BACKEND_TMUX_INSPECT_RESULT='session-absent'
      FM_BACKEND_TMUX_INSPECT_SOCKET=$(tmux display-message -p '#{socket_path}' 2>/dev/null) || true
      ;;
    *"no server running on "*)
      FM_BACKEND_TMUX_INSPECT_RESULT=unreachable
      rest=${windows#*"no server running on "}
      FM_BACKEND_TMUX_INSPECT_SOCKET=${rest%%$'\n'*}
      ;;
    *"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
      FM_BACKEND_TMUX_INSPECT_RESULT=unreachable
      rest=${windows#*"error connecting to "}
      rest=${rest%%$'\n'*}
      FM_BACKEND_TMUX_INSPECT_SOCKET=${rest% (*}
      ;;
    *"error connecting to "*)
      FM_BACKEND_TMUX_INSPECT_RESULT=unreadable
      rest=${windows#*"error connecting to "}
      rest=${rest%%$'\n'*}
      FM_BACKEND_TMUX_INSPECT_SOCKET=${rest% (*}
      ;;
    *)
      FM_BACKEND_TMUX_INSPECT_RESULT=unreadable
      ;;
  esac
  return 0
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
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm
  local foreground argv0s name fg_seen=0 fg_shell=0 fg_other=0
  fm_backend_tmux_inspect_endpoint "$target"
  case "$FM_BACKEND_TMUX_INSPECT_RESULT" in
    listed) ;;
    window-absent|session-absent|unreachable) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_backend_tmux_classify_process_name "$name")" in
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
    if [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ]; then
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
  if [ "$(fm_backend_tmux_classify_process_name "$comm")" = agent ]; then
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
  case "$(fm_backend_tmux_classify_process_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# fm_backend_tmux_missing_grade: how much a `missing` verdict actually proves.
# See bin/fm-backend.sh's fm_backend_missing_grade for the shared grade
# vocabulary. Two very different observations both read `missing` above:
#
#   strong     a REACHABLE server answered about the recorded session - either a
#              successful inventory that omits the recorded window, or "can't
#              find session", which only a live server can say. The window is
#              gone from the server that would host it, so nothing can still be
#              running there.
#   ambiguous  anything else. The server or its socket could not be reached at
#              all, which cannot distinguish a wiped runtime from a server this
#              process is simply not looking at (a different TMUX_TMPDIR, socket
#              name, or user) - or the inventory came back and DOES list the
#              window, which contradicts the missing verdict outright, since the
#              two are separate reads and the endpoint can be restored between
#              them.
#
# Strong is therefore reachable only from an observation that positively
# accounts for the exact recorded window, never from a read that merely
# succeeded. Sets FM_BACKEND_TMUX_MISSING_GRADE, plus the socket tmux itself
# named and the response it gave, so a caller can put the concrete evidence in
# front of a human instead of a bare verdict.
FM_BACKEND_TMUX_MISSING_GRADE=
FM_BACKEND_TMUX_MISSING_SOCKET=
FM_BACKEND_TMUX_MISSING_RESPONSE=
# shellcheck disable=SC2034 # Read by callers after fm_backend_tmux_missing_grade returns.
fm_backend_tmux_missing_grade() {  # <target>
  fm_backend_tmux_inspect_endpoint "$1"
  FM_BACKEND_TMUX_MISSING_SOCKET=$FM_BACKEND_TMUX_INSPECT_SOCKET
  FM_BACKEND_TMUX_MISSING_RESPONSE=$FM_BACKEND_TMUX_INSPECT_RESPONSE
  case "$FM_BACKEND_TMUX_INSPECT_RESULT" in
    window-absent|session-absent) FM_BACKEND_TMUX_MISSING_GRADE=strong ;;
    *) FM_BACKEND_TMUX_MISSING_GRADE=ambiguous ;;
  esac
  return 0
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
