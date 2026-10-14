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
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
# FALLBACK IS NOT AN IDENTITY: firstmate:0 is a last-resort constant, not a
# discovered operator session (it routinely resolves to a crew/login shell).
# Callers must NOT arm pane delivery on it - when every provider below comes
# back empty the verdict is UNAVAILABLE, not "firstmate:0 by default"
# (kunchenguid/firstmate#1506). discover_supervisor_* still return the constant
# purely so pre-existing callers keep printing a value with their warning;
# fm_supervisor_resolve is the resolver every delivery path must use.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

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
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
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
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
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

# --- operator-session binding record (state/.supervisor-session) ------------
# Env discovery reads whatever context the away daemon happens to run in; the
# daemon's own terminal is not necessarily the operator's (the 3.16-day
# undelivered-escalation incident, kunchenguid/firstmate#1506, armed on a
# context with no TMUX_PANE and silently aimed firstmate:0). The truthful
# moment to learn the operator session is when the primary session starts and
# holds the fleet lock: bin/fm-session-start.sh records this home's operator
# session then, and every delivery path re-checks the binding still names the
# same LIVE session before it is used.
#
# One TSV line: <backend>\t<target>\t<verifier>\t<alarm_tty>
#   tmux            <pane-id>     verifier=pane_pid:<pid>        alarm_tty below
#   herdr           <sess>:<pane> verifier empty (the backend's exact-id
#                                 existence check is the re-check)
#   tty             </dev/...>    verifier=<dev>:<ps-short>:<sid>
#   explicit env    <target>      verifier empty (captain-declared)
# alarm_tty is the bound session's controlling terminal as
# <dev>:<ps-short>:<session-leader-pid>, recorded for every backend where a
# controlling terminal exists: it is the wedge alarm's pane-independent second
# exit and has no pane, composer, or status-line in its path. Empty when the
# session had no capturable terminal, and on tty records (their target already
# is that terminal).
FM_SUPERVISOR_SESSION_NAME=".supervisor-session"

fm_supervisor_session_file() {  # <state>
  printf '%s/%s' "$1" "$FM_SUPERVISOR_SESSION_NAME"
}

# A <dev>:<ps-short>:<pid> triple still names the same live session when the
# recorded pid is alive, its controlling terminal still reads <ps-short>, and
# <dev> is writable. Any drift - dead pid, recycled tty, closed device - fails
# closed rather than delivering to a terminal that is no longer the operator's.
fm_supervisor_tty_triple_verify() {  # <dev>:<short>:<pid>
  local triple=$1 dev short pid cur
  dev=${triple%%:*}
  [ -n "$dev" ] && [ "$dev" != "$triple" ] || return 1
  short=${triple#*:}; short=${short%%:*}
  pid=${triple##*:}
  [ -n "$short" ] && [ -n "$pid" ] && [ "$pid" != "$triple" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  cur=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  [ -n "$cur" ] && [ "$cur" = "$short" ] || return 1
  [ -w "$dev" ]
}

fm_supervisor_session_read() {  # <state> -> raw record line
  local file line
  file=$(fm_supervisor_session_file "$1")
  [ -f "$file" ] || return 1
  IFS= read -r line < "$file" 2>/dev/null || return 1
  printf '%s' "$line" | awk -F '\t' 'NF >= 3 && $1 != "" && $2 != "" && NF <= 4' >/dev/null 2>&1 || return 1
  printf '%s\n' "$line"
}

# Split a record line into the globals named by the caller. Never evals and
# never `read`s with IFS=$'\t': tab is IFS whitespace, so an empty field
# (verifier-less herdr record carrying an alarm terminal) would collapse and
# shift the terminal into the verifier slot. Positional expansion preserves
# empty fields exactly.
fm_supervisor_session_fields() {  # <line> <backend-var> <target-var> <verifier-var> <alarmtty-var>
  local line=$1 rest
  local _b _t _v _a
  _b=${line%%$'\t'*}
  rest=${line#*$'\t'}
  _t=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  _v=${rest%%$'\t'*}
  case "$rest" in
    *$'\t'*) _a=${rest#*$'\t'} ;;
    *) _a= ;;
  esac
  printf -v "$2" '%s' "$_b"
  printf -v "$3" '%s' "$_t"
  printf -v "$4" '%s' "$_v"
  printf -v "$5" '%s' "$_a"
  [ -n "$_b" ] && [ -n "$_t" ]
}

# Verify the bound record still names the same live session and print
# "<backend>\t<target>". tmux re-checks #{pane_pid} (a rebuilt or hijacked pane
# id fails instead of delivering to whoever owns it now); tty re-checks the
# recorded session leader's controlling terminal; herdr and explicit records
# carry no same-session verifier, so the caller's existence check is the check.
fm_supervisor_session_verify() {  # <state>
  local line backend target verifier alarm_tty pid
  line=$(fm_supervisor_session_read "$1") || return 1
  fm_supervisor_session_fields "$line" backend target verifier alarm_tty || return 1
  case "$backend" in
    tmux)
      case "$verifier" in pane_pid:*) ;; *) return 1 ;; esac
      pid=${verifier#pane_pid:}
      [ "$pid" != "$verifier" ] && [ -n "$pid" ] || return 1
      [ "$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null)" = "$pid" ] || return 1
      ;;
    tty)
      fm_supervisor_tty_triple_verify "$verifier" || return 1
      [ "$target" = "${verifier%%:*}" ] || return 1
      ;;
    *) ;;
  esac
  printf '%s\t%s' "$backend" "$target"
}

# The bound operator controlling terminal that still names the same live
# session, as a writable device path - for a tty record it IS the target, for a
# pane record it is the recorded alarm_tty side-channel. Returns 1 when no
# verified terminal exists.
fm_supervisor_session_tty_device() {  # <state>
  local line backend target verifier alarm_tty
  line=$(fm_supervisor_session_read "$1") || return 1
  fm_supervisor_session_fields "$line" backend target verifier alarm_tty || return 1
  if [ "$backend" = tty ]; then
    fm_supervisor_tty_triple_verify "$verifier" || return 1
    printf '%s' "$target"
    return 0
  fi
  [ -n "$alarm_tty" ] || return 1
  fm_supervisor_tty_triple_verify "$alarm_tty" || return 1
  printf '%s' "${alarm_tty%%:*}"
}

# Capture this session's operator identity into the record. Called by
# bin/fm-session-start.sh while the fleet lock is held - that is the one
# context guaranteed to run inside the operator session with truthful env, so
# the pane id / herdr id / controlling tty it sees is the real operator
# session, not whatever shell a later daemon launch inherits. A read-only or
# lock-refused session must not write (it is not the supervisor's owner).
fm_supervisor_session_write() {  # <state>
  local state=$1 file pending backend target verifier alarm_tty
  local sid short dev ppid pty
  file=$(fm_supervisor_session_file "$state")
  # The operator terminal side-channel: session-leader pid + ps tty shortname.
  sid=$(ps -o sid= -p $$ 2>/dev/null | tr -d '[:space:]')
  short=$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')
  case "$short" in ''|'?'|'??'|*[!A-Za-z0-9/._-]*) short= ;; esac
  dev=
  if [ -n "$sid" ] && [ -n "$short" ]; then
    for dev in "/dev/$short" "/dev/tty$short"; do
      [ -w "$dev" ] && break
      dev=
    done
  fi
  backend=; target=; verifier=; alarm_tty=
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    backend=${FM_SUPERVISOR_BACKEND:-}
    if [ -z "$backend" ]; then
      backend=$(discover_supervisor_backend) || backend=$FM_SUPERVISOR_BACKEND_DEFAULT
    fi
    target=$FM_SUPERVISOR_TARGET
  elif [ -n "${TMUX_PANE:-}" ]; then
    backend=tmux
    target=$TMUX_PANE
    ppid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null) || ppid=
    # A pane record without its pid cannot prove it still names the same
    # session, so it binds nothing rather than weakening the re-check.
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    verifier="pane_pid:$ppid"
    # tmux knows the pane's own device exactly - prefer it over ps probing.
    pty=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null) || pty=
    if [ -n "$pty" ] && [ -n "$sid" ] && [ -n "$short" ]; then
      alarm_tty="$pty:$short:$sid"
    fi
  elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    backend=herdr
    target="${HERDR_SESSION:-default}:$HERDR_PANE_ID"
  elif [ -n "$dev" ]; then
    backend="tty"
    target=$dev
    verifier="$dev:$short:$sid"
    dev=   # a tty record's target already is that terminal; no side-channel
  fi
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  [ -z "$alarm_tty" ] && [ -n "$dev" ] && alarm_tty="$dev:$short:$sid"
  mkdir -p "$state" 2>/dev/null || return 1
  pending=$(mktemp "$state/.supervisor-session.pending.XXXXXX" 2>/dev/null) || return 1
  printf '%s\t%s\t%s\t%s\n' "$backend" "$target" "$verifier" "$alarm_tty" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$file" || { rm -f "$pending"; return 1; }
}

# fm_supervisor_resolve: the resolver every delivery path must use. Prints
# "<backend>\t<target>\t<source>" on success, "\t\tUNAVAILABLE" with rc 1 when
# no operator-session identity exists anywhere. Also sets the global
# FM_SUPERVISOR_RECORD_STATE (absent|verified|stale) when run unshelled so the
# caller can log whether a bound record helped or silently rotted. Priority:
#   1. FM_SUPERVISOR_TARGET (explicit captain declaration; backend pairs from
#      FM_SUPERVISOR_BACKEND, then env discovery, then the tmux default -
#      identical to what discover_supervisor_backend produced).
#   2. state/.supervisor-session bound at session start AND still naming the
#      same live session (fm_supervisor_session_verify).
#   3. $TMUX_PANE (tmux) / $HERDR_ENV=1+$HERDR_PANE_ID (herdr).
#   4. UNAVAILABLE - never the firstmate:0 constant: absence is reported as
#      absence, not dressed up as a discovered pane (kunchenguid/firstmate#1506).
fm_supervisor_resolve() {  # <state>
  local state=$1 line backend target verifier alarm_tty
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_SUPERVISOR_RECORD_STATE=absent
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    backend=${FM_SUPERVISOR_BACKEND:-}
    if [ -z "$backend" ]; then
      backend=$(discover_supervisor_backend) || backend=$FM_SUPERVISOR_BACKEND_DEFAULT
    fi
    printf '%s\t%s\tFM_SUPERVISOR_TARGET\n' "$backend" "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  line=$(fm_supervisor_session_read "$state" 2>/dev/null) || line=
  if [ -n "$line" ]; then
    if fm_supervisor_session_verify "$state" >/dev/null 2>&1; then
      FM_SUPERVISOR_RECORD_STATE=verified
      fm_supervisor_session_fields "$line" backend target verifier alarm_tty
      printf '%s\t%s\tBOUND(%s)\n' "$backend" "$target" "$FM_SUPERVISOR_SESSION_NAME"
      return 0
    fi
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_SUPERVISOR_RECORD_STATE=stale
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux\t%s\tTMUX_PANE\n' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr\t%s:%s\tHERDR_ENV(HERDR_PANE_ID)\n' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '\t\tUNAVAILABLE\n'
  return 1
}
