#!/usr/bin/env bash
# bin/fm-herdr-launch-env-lib.sh - the SINGLE owner of the environment every
# long-lived herdr server is launched with.
#
# A herdr server outlives its launcher and hands its OWN startup environment to
# every pane it ever opens, so both launches in this repo
# (fm_backend_herdr_server_ensure and fm-herdr-lab.sh's provision) inherit
# nothing at all: they run through `/usr/bin/env -i` plus the explicit
# allowlist assembled here. A deny list cannot hold that boundary.
# FM_CREW_STATE_META_OVERRIDE, FM_CREW_STATE_STATUS_OVERRIDE and
# FM_SNAPSHOT_CACHE_DIR entered the codebase long after the old unset list and
# nobody extended it, so a server started from one task's shell made every
# later pane's worker-state read answer about THAT task instead of the task it
# was asked about (measured 2026-09-26). The allowlist lives here, once,
# because a second copy in the lab script is exactly that rot again.
#
# SHELL always comes from the EFFECTIVE UID's own passwd entry, never from the
# caller even when the caller has one. Herdr's default_shell is empty, which
# `herdr --default-config` documents as "$SHELL, then /bin/sh", so a
# non-interactive launcher with no SHELL gave every pane a non-login /bin/sh
# with no startup config. PATH is a stable source-defined baseline for the same
# reason: a launcher's truncated PATH left /usr/bin/core_perl (shasum)
# unreachable in every pane. Both values are launcher contamination, so neither
# is ever preserved; the operator's real login shell rebuilds the rest of the
# pane environment from its own startup files.
#
# HOME and XDG_CONFIG_HOME ARE preserved, because they are caller-environment
# settings rather than task-scoped overrides, and because on the installed
# herdr 0.9.1 they relocate where herdr keeps its api socket, its sessions
# directory and its log. Measured 2026-09-26 against that 0.9.1: a server
# started with XDG_CONFIG_HOME pointed at a scratch directory reported "api
# socket: /tmp/hct42205/herdr/sessions/sct/herdr.sock" in its own startup
# output. Refusing those two names would therefore give the adapter two
# different config roots - one for the launch, another for every ordinary
# call - and let it report a server that its own caller can never reach.
# bin/fm-remote-job-lib.sh launches its worker under an explicitly assigned
# HOME and depends on that one coherent root.
#
# The older recorded observation that "On Herdr 0.7.3 the API socket is not
# relocatable by HERDR_CONFIG_PATH, XDG_CONFIG_HOME, or HOME" is scoped to
# 0.7.3 and is superseded by the 0.9.1 measurement above; it does not make
# HERDR_CONFIG_PATH safe to forward.
#
# HERDR_CONFIG_PATH is the name that is refused, for a reason independent of
# socket location: it selects config.toml directly, so forwarding it would let
# a caller impose a persistent default_shell on a server that outlives it,
# which is the exact outcome this boundary exists to prevent.
#
# Only enumerated names are forwarded, never a glob. The HERDR_* names herdr
# injects per PANE (HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH) are the LAUNCHER's own pane identity and are deliberately
# dropped; HERDR_SESSION is set here from <session>.

# fm_herdr_launch_env: fill the FM_HERDR_LAUNCH_ENV array with the complete
# NAME=VALUE list a `/usr/bin/env -i` server launch is given, for <session>.
# Always succeeds: a host that exposes no usable passwd login shell or home
# gets the warned fallbacks below rather than an unstartable server.
fm_herdr_launch_env() {  # <session>
  local session=$1
  local uid login pw_line pw_shell pw_home raw launch_home launch_path name

  uid=$(id -u 2>/dev/null) || uid=""
  login=$(id -un 2>/dev/null) || login=""
  pw_shell=""
  pw_home=""
  raw=""
  if [ -n "$uid" ]; then
    pw_line=""
    if command -v getent >/dev/null 2>&1; then
      pw_line=$(getent passwd "$uid" 2>/dev/null | head -1)
    fi
    [ -n "$pw_line" ] || pw_line=$(awk -F: -v want="$uid" '$3 == want { print; exit }' /etc/passwd 2>/dev/null)
    if [ -n "$pw_line" ]; then
      pw_home=$(printf '%s\n' "$pw_line" | cut -d: -f6)
      pw_shell=$(printf '%s\n' "$pw_line" | cut -d: -f7)
    elif [ -n "$login" ] && command -v dscl >/dev/null 2>&1; then
      # darwin keeps only system accounts in /etc/passwd, so the real record
      # lives in Directory Services. A wedged directory service must not hang a
      # spawn, so the read happens ONLY under a bound that this host actually
      # has; with no bound available it is skipped entirely and the /bin/sh
      # warning below reports the miss.
      if command -v perl >/dev/null 2>&1; then
        raw=$(perl -e '$SIG{ALRM} = sub { exit 124 }; alarm 2; exec @ARGV' \
          dscl . -read "/Users/$login" UserShell NFSHomeDirectory 2>/dev/null || true)
      elif command -v gtimeout >/dev/null 2>&1; then
        raw=$(gtimeout 2 dscl . -read "/Users/$login" UserShell NFSHomeDirectory 2>/dev/null || true)
      elif command -v timeout >/dev/null 2>&1; then
        raw=$(timeout 2 dscl . -read "/Users/$login" UserShell NFSHomeDirectory 2>/dev/null || true)
      fi
      pw_shell=$(printf '%s\n' "$raw" | sed -n 's/^UserShell: //p' | head -1)
      pw_home=$(printf '%s\n' "$raw" | sed -n 's/^NFSHomeDirectory: //p' | head -1)
    fi
  fi
  if [ -z "$pw_shell" ] || [ ! -x "$pw_shell" ]; then
    echo "warning: uid '${uid:-unknown}' has no usable passwd login shell; herdr panes fall back to /bin/sh" >&2
    pw_shell=/bin/sh
  fi
  # Checked the same way pw_shell is: an unreadable or missing passwd home
  # would otherwise silently build a baseline PATH out of a directory that does
  # not exist.
  if [ -z "$pw_home" ] || [ ! -d "$pw_home" ]; then
    launch_home=${HOME:-/}
    echo "warning: uid '${uid:-unknown}' has no usable passwd home directory; herdr's baseline PATH falls back to '$launch_home'" >&2
  else
    launch_home=$pw_home
  fi
  launch_path="$launch_home/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

  # HOME is the caller's when it has one, exactly like the enumerated names
  # below; the passwd home is only the floor for a caller that carries none, so
  # the server always has some home to resolve its config under.
  FM_HERDR_LAUNCH_ENV=(
    "HOME=${HOME:-$launch_home}"
    "SHELL=$pw_shell"
    "PATH=$launch_path"
    "HERDR_SESSION=$session"
  )
  if [ -n "$login" ]; then
    FM_HERDR_LAUNCH_ENV+=("USER=$login" "LOGNAME=$login")
  fi
  # Enumerated one name at a time on purpose: a HERDR_* or LC_* wildcard here
  # would recreate exactly the rot that killed the old unset list.
  for name in XDG_CONFIG_HOME TMPDIR TERM COLORTERM LANG LC_ALL LC_CTYPE TZ \
    DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_SESSION_TYPE \
    SSH_AUTH_SOCK; do
    if [ -n "${!name:-}" ]; then
      FM_HERDR_LAUNCH_ENV+=("$name=${!name}")
    fi
  done
}
