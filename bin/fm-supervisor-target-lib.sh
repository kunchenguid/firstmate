#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux. It is the LAST resort only, used
# when FM_HOME cannot be resolved; supervisor_target_default below scopes the
# real fallback to this home so a shared tmux server cannot map a bare
# "firstmate:0" onto another home's pane (incident afk-crosshome-inject-leak).
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# The tmux session option that a31df6e ("isolate sessions by firstmate home")
# stamps each home's session with: the home's physical FM_HOME path. The
# supervisor-injection ownership guard below reads the SAME stamp to prove a
# target pane belongs to THIS home before injecting, giving supervisor injection
# the home-ownership guard crew sessions already have.
FM_SUPERVISOR_HOME_OPT="@firstmate-home"

# supervisor_home_physical: this home's canonical physical path - the value the
# ownership stamp stores and the guard compares against. Prints nothing and
# returns 1 when FM_HOME cannot be resolved.
supervisor_home_physical() {
  [ -n "${FM_HOME:-}" ] || return 1
  ( cd "$FM_HOME" 2>/dev/null && pwd -P ) || return 1
}

# supervisor_target_default: the tmux fallback target, SCOPED to this home. On a
# shared tmux server a bare "firstmate:0" resolves to whichever home owns that
# name, which is exactly how one home's away daemon injected into another home's
# pane. Naming the fallback session after FM_HOME's basename - the SAME session
# name a31df6e's fm_backend_tmux_container_ensure uses - keeps the fallback inside
# this home. Falls back to the legacy literal only when FM_HOME is unresolvable.
supervisor_target_default() {
  local home base
  home=$(supervisor_home_physical) || { printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"; return; }
  base=${home##*/}
  [ -n "$base" ] || { printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"; return; }
  printf '%s:0' "$base"
}

# supervisor_tmux_session_home: print the @firstmate-home stamp of the tmux
# session that owns <target> (a pane id or session:window). A pane target
# resolves the session option for that pane's session. Prints nothing and
# returns 1 when the target is unreadable or the stamp is unset.
supervisor_tmux_session_home() {  # <target>
  local target=$1 owner
  owner=$(tmux display-message -p -t "$target" "#{$FM_SUPERVISOR_HOME_OPT}" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  printf '%s' "$owner"
}

# supervisor_tmux_stamp_own: claim-if-unset the target session's @firstmate-home
# to this home's physical path, mirroring a31df6e's claim-if-unset. Call ONLY
# with a target resolved from a first-party signal ($TMUX_PANE or an explicit
# captured FM_SUPERVISOR_TARGET), never a home-agnostic fallback, so the claim is
# always legitimate. `set-option -o` never overwrites an existing stamp, so a
# session already owned by another home stays that home's and the ownership guard
# then refuses - fail closed rather than steal ownership. Best-effort: a tmux
# failure leaves the session unstamped and the guard simply refuses later.
supervisor_tmux_stamp_own() {  # <target>
  local target=$1 home session
  home=$(supervisor_home_physical) || return 1
  session=$(tmux display-message -p -t "$target" '#{session_name}' 2>/dev/null) || return 1
  [ -n "$session" ] || return 1
  tmux set-option -o -t "$session" "$FM_SUPERVISOR_HOME_OPT" "$home" 2>/dev/null || true
}

# supervisor_target_home_ok: the injection hard floor. Returns 0 ONLY when the
# target pane is provably owned by THIS home; refuses (return 1) on any mismatch,
# missing stamp, or unreadable target - never inject on doubt.
#   tmux  : compare the target session's @firstmate-home stamp against this home's
#           physical path. A shared tmux server is the leak surface, so this is
#           enforced strictly.
#   herdr : herdr targets are only ever resolved from a first-party $HERDR_PANE_ID
#           (discover_supervisor_target has NO home-agnostic herdr fallback) and
#           herdr sessions are per-home, so a herdr target is owned by
#           construction. Allowed.
#   other : the daemon refuses unsupported supervisor backends at startup, so this
#           is unreachable in production; refuse defensively.
supervisor_target_home_ok() {  # <backend> <target>
  local backend=$1 target=$2 mine theirs
  case "$backend" in
    tmux)
      mine=$(supervisor_home_physical) || return 1
      theirs=$(supervisor_tmux_session_home "$target") || return 1
      [ "$theirs" = "$mine" ]
      ;;
    herdr)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. supervisor_target_default - home-scoped tmux fallback ("<FM_HOME basename>:0",
#      the same session name a31df6e's crew container uses), so a shared tmux
#      server cannot map the fallback onto another home. Returns 1 so the caller
#      can warn; the injection ownership guard is the real backstop when this
#      fallback still resolves to a foreign pane.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$(supervisor_target_default)"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
