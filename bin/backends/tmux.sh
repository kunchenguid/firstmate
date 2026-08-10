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
#
# Every tmux invocation below goes through fm_tmux, which names the fleet's
# socket explicitly (`tmux -S <socket>`) instead of inheriting a server from the
# ambient environment. bin/fm-tmux-lib.sh owns that socket contract and the
# incident behind it; this adapter only calls it.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

# Shared home-tag derivation, used ONLY by the container's collision fallback
# below (fm_backend_tmux_container_ensure). Same file zellij and cmux use for
# their shared-namespace tab/workspace titles; see its header for why tmux
# passes FM_HOME rather than FM_ROOT as the discriminating path.
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-backend-hometag-lib.sh"

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

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  fm_tmux display-message -p -t "$1" '#{pane_id}' >/dev/null
  fm_tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

FM_BACKEND_TMUX_HOME_OPT=@firstmate-home

# fm_backend_tmux_session_owner: the @firstmate-home stamp of <session>, or
# empty when the session has no stamp or cannot be read.
fm_backend_tmux_session_owner() {  # <session>
  fm_tmux show-options -t "$1" -v "$FM_BACKEND_TMUX_HOME_OPT" 2>/dev/null
}

# fm_backend_tmux_session_exists: is <session> a live session on the fleet
# socket? Exact-match, so "firstmate" never matches "firstmate-life".
fm_backend_tmux_session_exists() {  # <session>
  fm_tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Fqx "$1"
}

# fm_backend_tmux_claim_session: try to make <session> THIS home's container.
# Creates it when absent, claims it when present but unstamped (the historical
# unstamped `firstmate` session and its existing windows stay valid), and
# leaves an already-stamped session untouched - a session stamped by another
# home is never restamped, renamed, or reused. Returns:
#   0 - the session is now stamped for <home>; use it.
#   1 - another home owns it; its stamp is printed on stdout.
#   2 - it could not be created, or exists but could not be stamped; nothing
#       is printed. Distinct from 1 so the caller does not report a tmux
#       failure as if some other home were holding the name.
fm_backend_tmux_claim_session() {  # <session> <home>
  local session=$1 home=$2 owner
  if ! fm_backend_tmux_session_exists "$session"; then
    # Creation keeps a31df6e's exact shape: a successful new-session is taken
    # at its word, and the re-listing is the tie-break for a LOST race (another
    # process created the same name first, so new-session returns non-zero but
    # the session is there and claimable). Re-listing unconditionally instead
    # would add a second failure mode to a path that has none today.
    fm_tmux new-session -d -s "$session" 2>/dev/null \
      || fm_backend_tmux_session_exists "$session" \
      || return 2
  fi
  owner=$(fm_backend_tmux_session_owner "$session") || owner=
  if [ -z "$owner" ]; then
    fm_tmux set-option -o -t "$session" "$FM_BACKEND_TMUX_HOME_OPT" "$home" 2>/dev/null || true
    owner=$(fm_backend_tmux_session_owner "$session") || owner=
  fi
  [ "$owner" = "$home" ] && return 0
  [ -n "$owner" ] || return 2
  printf '%s' "$owner"
  return 1
}

# fm_backend_tmux_container_ensure: resolve THIS home's tmux session, creating
# it when needed, and print its name. Two candidate names are tried in order:
#
#   1. FM_HOME's basename - the readable default that keeps
#      `tmux attach -t <home-basename>` practical, and the ONLY name any home
#      used before this fallback existed.
#   2. The shared home tag (bin/fm-backend-hometag-lib.sh): "firstmate-<hash>"
#      for a primary home, "2ndmate-<id>-<hash>" for a secondmate home, hashed
#      over the resolved FM_HOME so it is unique per home and stable across
#      callers.
#
# Candidate 2 exists because equal basenames are not a corner case: a
# secondmate home leased from the firstmate repo (a treehouse lease, say
# ~/.treehouse/firstmate-<x>/3/firstmate) ALWAYS has basename "firstmate", the
# same basename the primary home usually has, so under candidate 1 alone such
# a home could never open a session at all and could never dispatch. Every
# home leased that way hits it.
#
# The @firstmate-home stamp still decides ownership and still refuses: a
# candidate stamped with a DIFFERENT physical FM_HOME is skipped, never
# reused, never renamed, and never restamped - the fallback moves THIS home
# aside, it does not move the other home's session. With both candidates
# blocked, this fails closed with both owners named.
#
# An already-stamped-ours session is adopted before any new one is created
# (the first loop), so a home that once fell back to candidate 2 keeps using
# that session even if candidate 1 later frees up; otherwise a home's live
# crew windows would be stranded in a session nothing addresses any more.
fm_backend_tmux_container_ensure() {
  local home basename_session tag_session candidate owner rc reason
  local candidates=() blocked=()
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || {
    echo "error: tmux backend cannot resolve FM_HOME '$FM_HOME'" >&2
    return 1
  }
  basename_session=${home##*/}
  if [ -z "$basename_session" ]; then
    echo "error: tmux backend cannot derive a session name from FM_HOME '$home'" >&2
    return 1
  fi
  candidates=("$basename_session")
  # tmux rewrites '.' and ':' in a session name to '_' rather than refusing the
  # name, so a tag built from a secondmate id containing either would be printed
  # under a name that does not exist (verified, tmux 3.3a: `new-session -s a.b`
  # and `-s a:b` both produce the session `a_b`, while space, '/', '@' and '%'
  # pass through unchanged). Apply the same mapping up front so the name this
  # prints is always the name tmux actually created.
  tag_session=$(fm_backend_hometag_for "$home" "$home" | tr '.:' '__')
  # Equal only if a home's basename already looks like its own tag; keep the
  # list deduplicated so the error below cannot name the same session twice.
  if [ -n "$tag_session" ] && [ "$tag_session" != "$basename_session" ]; then
    candidates+=("$tag_session")
  fi

  for candidate in "${candidates[@]}"; do
    if fm_backend_tmux_session_exists "$candidate" \
      && [ "$(fm_backend_tmux_session_owner "$candidate")" = "$home" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  for candidate in "${candidates[@]}"; do
    owner=$(fm_backend_tmux_claim_session "$candidate" "$home")
    rc=$?
    case "$rc" in
      0)
        printf '%s' "$candidate"
        return 0
        ;;
      1)
        blocked+=("'$candidate' belongs to FM_HOME '$owner', not '$home'; refusing to reuse it")
        ;;
      *)
        blocked+=("'$candidate' could not be created or stamped on the fleet's tmux server")
        ;;
    esac
  done

  {
    printf "error: tmux backend cannot open a session for FM_HOME '%s'" "$home"
    for reason in "${blocked[@]}"; do
      printf '\n  tmux session %s' "$reason"
    done
    printf '\n'
  } >&2
  return 1
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
# Pane ENVIRONMENT (`new-window -e`, tmux 3.0+) is how a crew pane gets its
# private tmux namespace. It is set when the window is created rather than typed
# into the pane afterwards, so there is no sent line for a shell-startup prompt
# to swallow - a silently unsandboxed pane would be holding the fleet's own tmux
# server with nothing to show for it. Verified on tmux 3.3a, 2026-07-28: a pane
# created with `-e TMUX_TMPDIR=<dir> -e TMUX=` reports an empty $TMUX, keeps its
# own $TMUX_PANE, and its bare `tmux new-session` / `tmux kill-server` act on a
# server under <dir> while the fleet's windows are untouched.
#
# `-e TMUX=` sets it EMPTY rather than truly unsetting it (tmux's -e has no unset
# form), which is equivalent everywhere it matters: tmux itself treats the empty
# value as "not inside a server" (the nested `new-session` above returned 0), and
# every firstmate reader tests $TMUX for non-empty.
#
# Callers ask fm_backend_tmux_pane_env_supported whether the flag was usable, and
# never a variable set inside fm_backend_tmux_create_task: that function's output
# is consumed through a command substitution, so anything it assigns dies with the
# subshell and would report "not applied" on every single spawn.

# fm_backend_tmux_pane_env_supported: 0 when the installed tmux accepts
# `new-window -e`, i.e. tmux 3.0 or newer. Older builds fall back to the caller
# typing the environment into the pane.
fm_backend_tmux_pane_env_supported() {
  local raw major
  raw=$(tmux -V 2>/dev/null) || return 1
  major=${raw#tmux }
  major=${major#next-}
  major=${major%%.*}
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$major" -ge 3 ]
}

fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> [VAR=VALUE...] -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid assignment
  shift 3
  local env_args=()
  if [ "$#" -gt 0 ] && fm_backend_tmux_pane_env_supported; then
    for assignment in "$@"; do
      env_args+=(-e "$assignment")
    done
  fi
  if fm_tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(fm_tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs" \
    ${env_args[@]+"${env_args[@]}"}) || return 1
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

# fm_backend_tmux_target_exists: does <target> still name a live endpoint on the
# fleet socket? Read-only, and it never starts a server (tmux exits non-zero with
# "error connecting to <socket>" when none is running).
#
# `display-message` CANNOT answer this, which is the bug this function exists to
# fix. Verified on tmux 3.3a, 2026-07-28, against a private socket:
#
#   $ tmux -S "$S" display-message -p -t 'totally:bogus' '#{pane_id}'
#   rc=0 out=[]
#   # then, with session `sess` live and its window `fm-x` killed:
#   $ tmux -S "$S" display-message -p -t 'sess:fm-x' '#{pane_id}'
#   rc=0 out=[%0]        <- the session's CURRENT pane, not the asked-for window
#
# tmux resolves an unknown target against the current client/session rather than
# failing, so the exit code is always 0 and the output is either empty or - once
# the session part still resolves - some OTHER window's pane. The old caller in
# bin/fm-backend.sh tested only the exit code, so as long as any tmux server was
# reachable, every long-dead window read back as alive; that is what the
# session-start fleet digest reported for the whole fleet after the 2026-07-28
# incident wiped it (issue #1130).
#
# The only reliable answer is enumeration: list every live pane in every one of
# the addressable forms firstmate uses and require an exact match. One tmux call
# covers pane ids (%N), window ids (@N), bare session names, and session:window
# by name or index, with or without a .pane suffix.
fm_backend_tmux_target_exists() {  # <target>
  local target=$1
  [ -n "$target" ] || return 1
  fm_tmux list-panes -a -F '#{pane_id}
#{window_id}
#{session_name}
#{session_name}:#{window_name}
#{session_name}:#{window_index}
#{session_name}:#{window_name}.#{pane_index}
#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
    | grep -Fqx -- "$target"
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

# fm_backend_tmux_kill: remove the task's window, best-effort. Mirrors
# fm-teardown.sh's `tmux kill-window -t "$T" 2>/dev/null || true`.
fm_backend_tmux_kill() {  # <target>
  fm_tmux kill-window -t "$1" 2>/dev/null || true
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

# fm_backend_tmux_agent_alive: CONFIDENT liveness of a live harness-agent
# PROCESS in <target>'s pane, distinct from fm_backend_target_exists's
# pane-PRESENCE-only check (a pane that still exists but is sitting at a bare
# idle shell passes THAT check as "alive" - the secondmate-liveness gap
# AGENTS.md's session-start guarantee closes). See docs/tmux-backend.md
# "Agent liveness probe" for the empirical basis. Prints one of:
#   alive   - the foreground command is one of the verified harness binaries
#             (claude, codex, opencode, grok - each confirmed to run as its
#             own process name, never wrapped by a generic interpreter).
#   dead    - the foreground command is a bare shell: nothing is running in
#             the pane, so a prior agent process has exited.
#   unknown - anything else, INCLUDING a bare "node"/"python" interpreter
#             name (pi's own launcher execs into a generic "node" process
#             with no reliable way to attribute it back to pi from outside
#             the pane - docs/tmux-backend.md "Known gaps"), or an unreadable
#             pane. Callers must never treat unknown as a confirmed-dead
#             signal (bin/fm-bootstrap.sh's secondmate-liveness sweep gates a
#             respawn on `dead` only).
fm_backend_tmux_agent_alive() {  # <target>
  local target=$1 comm
  comm=$(fm_backend_tmux_current_command "$target") || { printf 'unknown'; return 0; }
  case "${comm#-}" in
    '') printf 'unknown' ;;
    # traex is matched EXACTLY, never a *trae* glob: on a box that kept the TRAE
    # CLI 1.0 install, the names traecli/trae-cli/trae-agent (coco 1.0) would match
    # *trae* and a live coco pane would be misread as a live traex agent. tmux
    # pane_current_command reports the bare command name, so exact `traex` is right.
    traex) printf 'alive' ;;
    *claude*|*codex*|*opencode*|*grok*) printf 'alive' ;;
    *) if fm_is_login_shell_name "$comm"; then printf 'dead'; else printf 'unknown'; fi ;;
  esac
}
