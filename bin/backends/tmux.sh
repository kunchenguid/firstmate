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
  # A dot in the window name makes the endpoint unaddressable, so refuse to
  # create one at all rather than hand back a target tmux cannot reach. tmux
  # splits a target at the dot and treats the tail as a PANE selector: with
  # windows `fm-task` and `fm-task.a` both present, `-t sess:fm-task.a`
  # resolves to `fm-task` (verified on tmux 3.6b). Every read and write on the
  # recorded target then addresses the wrong window - a steer would be typed
  # into another worker's pane - and fm_backend_tmux_target_presence reports
  # `unreadable` because it cannot confirm the identity it asked for. Task ids
  # may legally contain a dot (fm_task_id_path_safe in bin/fm-pr-lib.sh permits
  # one), so this is the boundary that keeps such an id from ever reaching a
  # tmux window name. Same refusal shape as the duplicate-name check below.
  case "$wname" in
    *.*)
      echo "error: tmux window name '$wname' contains a dot, which tmux parses as a pane selector; use a task id without a dot on the tmux backend" >&2
      return 1
      ;;
  esac
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

# fm_backend_tmux_target_presence: the ONE owner of tmux target resolution for
# this repo. Prints `present`, `missing`, or `unreadable` for any recorded
# target, and every other tmux liveness read goes through it rather than
# re-deriving its own approximation - the cheap probe in bin/fm-backend.sh, the
# recovery-grade classifier below, and bin/fm-crew-state.sh's pane_readable.
# Three separate approximations were the root cause of a family of defects:
# each one parsed some target shape differently from tmux itself.
#
# It RESOLVES the target through tmux and then VERIFIES what came back, rather
# than reimplementing tmux's own precedence rules in shell. That direction is
# the whole design: tmux resolves a target it cannot find by silently falling
# back (to the session's active window, or to the active pane), so a raw read
# describes some other pane while reporting success. Asking tmux to echo the
# identity it actually reached, then checking that identity against what was
# requested, catches every one of those fallbacks without the parser having to
# know the rules. Verified on tmux 3.6b, all with exit status 0:
#   session:absent-name  -> the session's active window
#   session:absent-index -> the session's active window
#   session:window.9     -> the window's active pane
#   prefix:window        -> the LONGER session that prefix uniquely matches
#   session:a:b          -> the session's active window
#
# Two rules matter beyond the fallback:
#
#   1. The session component is anchored with tmux's `=` exact-match form,
#      because tmux otherwise accepts a unique session-name PREFIX: with only
#      `alphalong` present, `-t alpha:win` resolves against it, while
#      `-t =alpha:win` does not resolve at all. This mirrors the anchored kill
#      target `-t "=$session:=$window"` in fm_backend_tmux_kill above, the
#      established local precedent for refusing a prefix match. `=` is only
#      valid on a session component, so a bare `%pane` or `@window` id is
#      passed through unanchored.
#   2. Window INDEX beats window NAME, and this parser must not invert that.
#      Verified with index 0 named `zero` and index 1 named `0`: tmux resolves
#      `amb:0` to INDEX 0. Verifying the resolved identity rather than
#      searching an inventory preserves that automatically, so the answer is
#      always about the window every other tmux call will actually reach. A
#      name-first parser would be confidently wrong about a DIFFERENT window,
#      which is worse than the fallback it set out to fix.
#
# The `missing` versus `unreadable` split is deliberate and load-bearing:
# `missing` means authoritatively absent, `unreadable` means the target could
# not be judged, and only the former may license recovery. Anything ambiguous
# is therefore `unreadable`, never `missing` - see the trailing-dot rule below.
fm_backend_tmux_target_presence() {  # <target> -> present|missing|unreadable
  local target=${1#=} anchored resolved status sep
  local r_session r_windex r_wname r_pindex r_pid r_wid
  local session rest wpart ppart

  [ -n "$target" ] || { printf 'unreadable'; return 0; }
  case "$target" in
    *:*:*|:*|*:) printf 'unreadable'; return 0 ;;
    [%@]*) anchored=$target ;;
    *:*) anchored="=$target" ;;
    # A bare string with no session component and no id sigil is ambiguous:
    # tmux would answer it from whatever session happens to be current, so it
    # names no specific endpoint and is never authoritative.
    *) printf 'unreadable'; return 0 ;;
  esac

  sep=$(printf '\037')
  if resolved=$(tmux display-message -p -t "$anchored" \
      "#{session_name}$sep#{window_index}$sep#{window_name}$sep#{pane_index}$sep#{pane_id}$sep#{window_id}" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    case "$resolved" in
      *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
        printf 'missing'
        ;;
      *)
        printf 'unreadable'
        ;;
    esac
    return 0
  fi

  IFS=$sep read -r r_session r_windex r_wname r_pindex r_pid r_wid <<EOF
$resolved
EOF
  # A target tmux cannot resolve at all still exits 0, printing empty fields.
  [ -n "$r_pid" ] || { printf 'missing'; return 0; }

  case "$target" in
    %*)
      [ "$target" = "$r_pid" ] && { printf 'present'; return 0; }
      ;;
    @*)
      [ "$target" = "$r_wid" ] && { printf 'present'; return 0; }
      ;;
    *:*)
      session=${target%%:*}
      rest=${target#*:}
      [ "$session" = "$r_session" ] || { printf 'missing'; return 0; }
      if [ "$rest" = "$r_windex" ] || [ "$rest" = "$r_wname" ]; then
        printf 'present'
        return 0
      fi
      # Only NOW consider a trailing `.suffix` a pane selector, and only when
      # it cannot also be part of a window name. tmux splits at the dot itself:
      # `session:fm-task.a` reaches window `fm-task` even when a window named
      # `fm-task.a` exists alongside it, so blindly stripping at the last dot
      # confirms presence about the wrong window. A pane selector is an index
      # or a `%id`; anything else leaves the target ambiguous, which is
      # `unreadable` rather than `missing` so it can never license a duplicate.
      #
      # KNOWN LIMIT, and why it is bounded rather than open: a window whose own
      # NAME contains a dot can be confirmed only while no window is named by
      # its dot-prefix. Verified on tmux 3.6b: with `fm-task.a` alone the target
      # resolves to itself and reads `present`; add a window named `fm-task` and
      # the same target resolves to `fm-task`, so this reads `unreadable` and
      # the dotted endpoint can never be confirmed alive - it is also invisible
      # to stale detection, since that keys on a confirmed-gone endpoint. The
      # limit is contained at the source: fm_backend_tmux_create_task above
      # refuses to create a dotted window name at all, so no tmux task endpoint
      # can enter this state. Do not "fix" this by preferring the prefix window,
      # which would confirm liveness about a different worker's pane.
      case "$rest" in
        *.*)
          wpart=${rest%.*}
          ppart=${rest##*.}
          case "$ppart" in
            ''|*[!0-9]*)
              case "$ppart" in
                %[0-9]*) ;;
                *) printf 'unreadable'; return 0 ;;
              esac
              ;;
          esac
          if { [ "$wpart" = "$r_windex" ] || [ "$wpart" = "$r_wname" ]; } \
            && { [ "$ppart" = "$r_pindex" ] || [ "$ppart" = "$r_pid" ]; }; then
            printf 'present'
            return 0
          fi
          ;;
      esac
      ;;
  esac
  printf 'missing'
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back when a target does not resolve,
# so the target must be proven to reach the exact recorded endpoint before its
# foreground command can be trusted; fm_backend_tmux_target_presence above owns
# that resolution and its missing-versus-unreadable split, and every pane read
# below addresses the same string tmux just resolved.
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
  case "$(fm_backend_tmux_target_presence "$target")" in
    present) ;;
    missing) printf 'missing'; return 0 ;;
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

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
