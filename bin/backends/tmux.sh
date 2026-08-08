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
# already live in bin/fm-tmux-lib.sh, shared with the terminal-backed away-mode
# compatibility path; this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

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

# fm_backend_tmux_target_exists: the ONE reliable "does this target still
# resolve?" primitive for the tmux backend. Every existence and identity
# decision in this adapter goes through it.
#
# WHY THIS IS NOT `display-message`: `tmux display-message -p -t <target>` is
# NOT an existence check. When the WINDOW component of a target does not
# resolve, tmux silently falls back to the session's CURRENT window and still
# exits 0. Verified live on tmux 3.7b, against a window that was created and
# then killed - the exact teardown scenario:
#
#   $ tmux kill-window -t 'S:fm-doomed'
#   $ tmux display-message -p -t 'S:fm-doomed' '#{pane_id}'
#   %0                     # exit 0, the OTHER window's pane, no error
#   $ tmux has-session -t 'S:fm-doomed'
#   can't find window: fm-doomed        # exit 1, correct
#
# A deliberately bogus window name returns the same successful output as a
# real-but-gone one, so a display-message probe reports every gone tmux window
# as still alive for as long as its SESSION exists. That false positive is what
# made fm_backend_target_state always answer `present`, which in turn made
# bin/fm-teardown.sh refuse to ever release a completed tmux-backed task
# ("endpoint is still alive; retaining metadata"), leaking its worktree lease
# and metadata permanently. `--force` does not help, because the ordinary
# safety proof itself is what false-positives.
#
# `capture-pane -t` and `send-keys -t` were checked the same way and do NOT
# share the quirk (both exit 1 with "can't find window"); display-message is
# uniquely broken here, which is why only its uses needed replacing.
#
# Target shapes, each verified in both directions (live target -> exists,
# gone/bogus target -> does not exist) by
# tests/fm-backend-tmux-target-exists.test.sh:
#   session:window, session:window.pane, @window-id, %pane-id, session-only
#     -> `has-session -t` runs tmux's own target parser over the FULL target and
#        fails on a missing session, window, OR pane, so it is correct for all
#        of them, and it never starts a server (no server => exit 1 => gone).
#   bare selector (no ':', '@' or '%')
#     -> tmux would parse a bare target as a SESSION name, so `has-session`
#        would answer the wrong question. In firstmate a bare selector is a
#        WINDOW name (fm-<id>) - see fm_backend_tmux_resolve_bare_selector - so
#        it is matched against the live window list instead. A bare selector
#        that names only a session is therefore reported gone; that direction is
#        a safe, visible false negative, never the false positive that leaks.
fm_backend_tmux_target_exists() {  # <target>
  local target=$1
  [ -n "$target" ] || return 1
  case "$target" in
    *:*|@*|%*) tmux has-session -t "$target" >/dev/null 2>&1 ;;
    *) tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qxF -- "$target" ;;
  esac
}

# fm_backend_tmux_exact_window_exists: does <session> hold a window named
# EXACTLY <window> (optionally down to <pane-suffix>, e.g. ".0")? Uses tmux's
# own exact-match target syntax ("=session:=window"), which suppresses the
# fnmatch/alternative matching a bare name would otherwise be subject to, so
# `fm-foo` can never resolve to `fm-foobar`. Verified in both directions on
# tmux 3.7b, including a bogus pane index. With no session the window is matched
# against the live window list instead, since tmux would read a bare target as a
# session name.
fm_backend_tmux_exact_window_exists() {  # <session> <window> [pane-suffix]
  local session=$1 window=$2 pane_suffix=${3:-}
  [ -n "$window" ] || return 1
  if [ -n "$session" ]; then
    tmux has-session -t "=$session:=$window$pane_suffix" >/dev/null 2>&1
  else
    tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qxF -- "$window"
  fi
}

# fm_backend_tmux_split_target: split <target> into the session, window name and
# pane suffix it addresses, published in FM_TMUX_TARGET_SESSION,
# FM_TMUX_TARGET_WINDOW and FM_TMUX_TARGET_PANE. A trailing ".<digits>" is
# treated as tmux's pane index; any other dot is left inside the window name, so
# a window whose own name contains a dot is not truncated.
# Fixed output names rather than caller-named variables: this adapter is sourced
# under zsh as well as bash (tests/fm-backend.test.sh covers both shells), and
# bash's `printf -v` indirect assignment does not exist there.
fm_backend_tmux_split_target() {  # <target>
  local target=$1 suffix
  FM_TMUX_TARGET_SESSION=''
  FM_TMUX_TARGET_WINDOW=''
  FM_TMUX_TARGET_PANE=''
  case "$target" in
    *:*) FM_TMUX_TARGET_SESSION=${target%%:*}; FM_TMUX_TARGET_WINDOW=${target#*:} ;;
    *) FM_TMUX_TARGET_WINDOW=$target ;;
  esac
  case "$FM_TMUX_TARGET_WINDOW" in
    *.*)
      suffix=${FM_TMUX_TARGET_WINDOW##*.}
      case "$suffix" in
        ''|*[!0-9]*) ;;
        *)
          FM_TMUX_TARGET_PANE=".$suffix"
          FM_TMUX_TARGET_WINDOW=${FM_TMUX_TARGET_WINDOW%.*}
          ;;
      esac
      ;;
  esac
}

# fm_backend_tmux_expected_label_matches: identity guard - does <target> still
# resolve, and is the thing it resolves to the window this task actually owns?
# Returns success only when the target exists AND its live session/window
# identity matches what the caller recorded; with neither expectation supplied
# there is nothing to verify, so it defers to the caller's own existence check.
#
# This guard used to short-circuit to success for every target that was not a
# @window-id, which meant it passed unconditionally for the `session:window`
# shape that fm-spawn.sh actually records - it never guarded the fleet's real
# targets at all, and it returned PASS even when the expected label flatly
# disagreed with the live window name. A guard that fails OPEN is worse than no
# guard, because callers trust it. The identity read below is now gated on
# fm_backend_tmux_target_exists first, because display-message would otherwise
# hand back the session's CURRENT window's identity for a window that is gone.
fm_backend_tmux_expected_label_matches() {  # <target> [expected-label] [recorded-scoped-target]
  # Every local is given an explicit empty value, never bare `local x`. Callers
  # run under `set -u`, and bash 4.4+ leaves a bare `local x` genuinely unset, so
  # reading it aborts the whole calling script - while bash 3.2 (macOS) reads it
  # as empty and hides the fault entirely.
  local target=$1 expected_label=${2:-} recorded_scoped_target=${3:-} expected_session=''
  local FM_TMUX_TARGET_SESSION='' FM_TMUX_TARGET_WINDOW='' FM_TMUX_TARGET_PANE=''
  local actual_session='' actual_label=''
  [ -n "$expected_label" ] || [ -n "$recorded_scoped_target" ] || return 0
  if [ -n "$recorded_scoped_target" ]; then
    case "$recorded_scoped_target" in
      *:*) expected_session=${recorded_scoped_target%%:*} ;;
      *) return 1 ;;
    esac
  fi
  case "$target" in
    @*|%*)
      # A stable window/pane id does NOT carry the task's label, so the only way
      # to know what it points at is to read the identity back from tmux. That
      # read is gated on existence first: display-message answers for the
      # session's current window once the id is gone, and with a two-field
      # format its output is non-empty (a bare separator) even then, so the
      # old non-empty check could not tell a live id from a dead one.
      fm_backend_tmux_target_exists "$target" || return 1
      # The two identity fields are read SEPARATELY rather than joined by a tab
      # in one format string. A tab-joined read is not portable: tmux 3.4
      # renders a literal TAB inside a format as "_", so
      # '#{session_name}<TAB>#{window_name}' comes back as "S_fm-live" and can
      # never be split into its two fields again - which silently made the
      # identity of every @window-id unverifiable there.
      actual_session=$(tmux display-message -p -t "$target" '#{session_name}' 2>/dev/null) || return 1
      actual_label=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null) || return 1
      [ -n "$actual_session" ] && [ -n "$actual_label" ] || return 1
      [ -z "$expected_label" ] || [ "$actual_label" = "$expected_label" ] || return 1
      [ -z "$expected_session" ] || [ "$actual_session" = "$expected_session" ]
      ;;
    *)
      # A session:window target NAMES the window it addresses, so its identity
      # is settled by comparing the target itself against what the task
      # recorded, and then resolving that name EXACTLY. No display-message is
      # involved, which is what makes this reliable: the guard used to short
      # circuit to success for exactly this shape - the one fm-spawn.sh actually
      # records - so it never guarded the fleet's real targets, and it passed
      # even when the expected label plainly disagreed with the target.
      fm_backend_tmux_split_target "$target"
      [ -n "$FM_TMUX_TARGET_WINDOW" ] || return 1
      [ -z "$expected_label" ] || [ "$FM_TMUX_TARGET_WINDOW" = "$expected_label" ] || return 1
      [ -z "$expected_session" ] || [ -z "$FM_TMUX_TARGET_SESSION" ] \
        || [ "$FM_TMUX_TARGET_SESSION" = "$expected_session" ] || return 1
      fm_backend_tmux_exact_window_exists \
        "${FM_TMUX_TARGET_SESSION:-$expected_session}" "$FM_TMUX_TARGET_WINDOW" "$FM_TMUX_TARGET_PANE"
      ;;
  esac
}

# fm_backend_tmux_operation_target: resolve <target> for an operation, refusing
# it when the recorded identity does not line up with what the caller expects.
#
# No separate existence probe here on purpose. The operations this resolves for
# are capture-pane and send-keys, and BOTH already fail correctly on a target
# whose window is gone ("can't find window", exit 1) - verified alongside the
# display-message quirk. Only the display-message-based readers
# (fm_backend_tmux_current_path/current_command) need an explicit gate, and they
# carry their own; adding one here would just make every capture and send pay
# for a second tmux round-trip.
fm_backend_tmux_operation_target() {  # <target> [expected-label] [recorded-scoped-target]
  local target=$1 expected_label=${2:-} recorded_scoped_target=${3:-} recorded_session recorded_label
  if [ -n "$recorded_scoped_target" ]; then
    case "$recorded_scoped_target" in *:*) ;; *) return 1 ;; esac
    recorded_session=${recorded_scoped_target%%:*}
    recorded_label=${recorded_scoped_target#*:}
    [ -n "$recorded_session" ] && [ -n "$recorded_label" ] || return 1
    [ -z "$expected_label" ] || [ "$recorded_label" = "$expected_label" ] || return 1
    fm_backend_tmux_expected_label_matches "$target" "$expected_label" "$recorded_scoped_target" || return 1
    printf '%s\n' "$target"
    return 0
  fi
  fm_backend_tmux_expected_label_matches "$target" "$expected_label" || return 1
  printf '%s\n' "$target"
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines> [expected-label] [recorded-scoped-target]
  local target
  target=$(fm_backend_tmux_operation_target "$1" "${3:-}" "${4:-}") || return 1
  tmux capture-pane -p -t "$target" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path.
# The pre-send existence probe used to be a separate `tmux display-message -p
# -t "$T" '#{pane_id}' >/dev/null`, which exits 0 for a window that is gone
# (see fm_backend_tmux_target_exists) and whose status was discarded anyway, so
# it proved nothing. fm_backend_tmux_operation_target now performs that check
# for real and fails the send, so no separate preflight is needed here.
fm_backend_tmux_send_key() {  # <target> <key> [expected-label] [recorded-scoped-target]
  local target
  target=$(fm_backend_tmux_operation_target "$1" "${3:-}" "${4:-}") || return 1
  tmux send-keys -t "$target" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label] [recorded-scoped-target]
  local target
  target=$(fm_backend_tmux_operation_target "$1" "${6:-}" "${7:-}") || return 1
  fm_tmux_submit_core "$target" "$2" "$3" "$4" "$5"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    # stdout is discarded as well as stderr: this function's own stdout is the
    # resolved session name the caller captures, so a probe must not be able to
    # contribute a line to it.
    tmux has-session -t firstmate >/dev/null 2>&1 || tmux new-session -d -s firstmate >/dev/null
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
# Existence-gated: for a target whose window is gone, display-message reports
# the session's CURRENT window's cwd with exit 0, so fm-spawn.sh's worktree
# discovery would otherwise adopt an unrelated pane's directory as the task's
# worktree. Empty is the caller's "not readable yet" signal, so a gone target
# correctly yields nothing rather than someone else's path.
fm_backend_tmux_current_path() {  # <target>
  fm_backend_tmux_target_exists "$1" || return 0
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (the GOTMPDIR export and harness launch) that already ran this exact sequence
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

# fm_backend_tmux_kill: remove the task's window, best-effort. Mirrors
# fm-teardown.sh's `tmux kill-window -t "$T" 2>/dev/null || true`.
#
# The absent-target branch is load-bearing, not tidiness. fm_backend_kill's
# contract is that an already-gone target is NOT an error, and
# fm-teardown.sh's quiesce_task_endpoint turns any nonzero return into
# "failed to stop task endpoint; retaining metadata". Now that the identity
# guard correctly rejects a window that no longer resolves, an unqualified
# "guard failed -> return 1" would convert every already-closed window into a
# teardown refusal - reinstating the same leak from the other side. So: a target
# that does not exist has nothing to kill and is a no-op success; only a target
# that DOES exist but whose identity does not match is refused.
fm_backend_tmux_kill() {  # <target> [backend-id] [expected-label] [recorded-scoped-target]
  fm_backend_tmux_target_exists "$1" || return 0
  fm_backend_tmux_expected_label_matches "$1" "${3:-}" "${4:-}" || return 1
  tmux kill-window -t "$1" 2>/dev/null || true
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
# Existence-gated for the same reason as fm_backend_tmux_current_path: without
# it, a task whose window has closed reports whatever the session's CURRENT
# window happens to be running, so fm_backend_tmux_agent_alive could answer
# `alive` for a harness that exited long ago. Empty maps to `unknown` there,
# which is the correct not-provable answer for a target that is gone.
fm_backend_tmux_current_command() {  # <target>
  fm_backend_tmux_target_exists "$1" || return 0
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
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
fm_backend_tmux_agent_alive() {  # <target> [expected-label] [recorded-scoped-target]
  local target expected_label=${2:-} recorded_scoped_target=${3:-} comm
  target=$(fm_backend_tmux_operation_target "$1" "$expected_label" "$recorded_scoped_target") || { printf 'unknown'; return 0; }
  comm=$(fm_backend_tmux_current_command "$target") || { printf 'unknown'; return 0; }
  comm=${comm#-}
  case "$comm" in
    '') printf 'unknown' ;;
    *claude*|*codex*|*opencode*|*grok*) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
