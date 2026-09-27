#!/usr/bin/env bash
# bin/fm-herdr-launch-env-lib.sh - the SINGLE owner of the environment the two
# `env -i` herdr server launches are given.
#
# A herdr server outlives its launcher and hands its OWN startup environment to
# every pane it ever opens, so both of those launches
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
# A THIRD long-lived server launch exists and is deliberately exempt:
# bin/fm-remote-herdr-guard.sh's `exec "$HERDR_BIN" server --session
# "$SESSION"`. It is not routed through this helper because launchd starts it
# from the Aqua login-shell environment rather than from a task shell, and that
# gui/<uid> domain - not the environment this library would build - is what
# grants its panes the audit session and login-keychain access. Scrubbing it to
# this allowlist would take that away.
#
# SHELL always comes from the EFFECTIVE UID's own passwd entry, never from the
# caller even when the caller has one. Herdr's default_shell is empty, which
# `herdr --default-config` documents as "$SHELL, then /bin/sh", so a
# non-interactive launcher with no SHELL gave every pane a non-login /bin/sh
# with no startup config. PATH is a stable source-defined baseline for the same
# reason: a launcher's truncated PATH left /usr/bin/core_perl (shasum)
# unreachable in every pane. Both values are launcher contamination, so neither
# is ever preserved. The baseline PATH must be self-sufficient rather than a
# floor a profile later tops up: herdr 0.9.1 starts a pane's shell interactive
# but NOT login, so only the shell's per-interactive-shell file runs and
# /etc/profile.d never does.
#
# HOME, XDG_CONFIG_HOME and HERDR_CONFIG_PATH ARE preserved, because they are
# caller-environment settings rather than task-scoped overrides, and because on
# the installed herdr 0.9.1 the first two relocate where herdr keeps its api
# socket, its sessions directory and its log. Measured 2026-09-26 against that
# 0.9.1: a server started with XDG_CONFIG_HOME pointed at a scratch directory
# reported "api socket: /tmp/hct42205/herdr/sessions/sct/herdr.sock" in its own
# startup output. Refusing them would give the adapter two different config
# roots - one for the launch, another for every ordinary call - and let it
# report a server that its own caller can never reach.
# bin/fm-remote-job-lib.sh launches its worker under an explicitly assigned
# HOME and depends on that one coherent root.
#
# The older recorded observation that "On Herdr 0.7.3 the API socket is not
# relocatable by HERDR_CONFIG_PATH, XDG_CONFIG_HOME, or HOME" is scoped to
# 0.7.3 and is superseded by the 0.9.1 measurement above.
#
# Config selection is therefore CALLER-CONTROLLED, whole stop, and the passwd
# login shell below is the DEFAULT this launch computes rather than an
# override-proof guarantee: a caller that deliberately points the server at a
# config.toml carrying default_shell governs that server's panes for the
# server's whole life, because absolute config isolation is impossible while
# caller-selected config roots must be preserved. What this boundary does
# deliver is unchanged by that: the long-lived server no longer inherits
# task-scoped overrides, and panes get the passwd login shell whenever the
# caller has not deliberately chosen otherwise - which is exactly the measured
# 2026-09-26 incident, an empty config plus no SHELL.
#
# SSH_AUTH_SOCK, DISPLAY, WAYLAND_DISPLAY, XAUTHORITY, XDG_RUNTIME_DIR and
# XDG_SESSION_TYPE are the one group here that are NOT host facts: they are
# handles owned by a login session, and they can go stale the moment that
# session ends, on a server that outlives it. A pane's login shell does not
# correct them - nothing in a profile resets SSH_AUTH_SOCK, and nothing resets
# a forwarded DISPLAY. Concretely: a server born from an SSH shell keeps that
# connection's agent socket for its whole life, so an agent's `git push` in
# any of its panes silently loses agent-backed authentication and falls back
# to on-disk keys. They are forwarded anyway, because a pane needs a display
# and a runtime directory to be useful and absent handles break more workflows
# today than stale ones do. That is a deliberate trade, not a closed hazard.
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
      # spawn, so the read happens only under perl's alarm, which is part of
      # the darwin base system. On a darwin host with no perl the read is
      # skipped and panes fall back to /bin/sh with the warning below: losing
      # the operator's real shell there is the hang-safe answer, and an
      # unbounded dscl read is not an acceptable alternative.
      if command -v perl >/dev/null 2>&1; then
        raw=$(perl -e '$SIG{ALRM} = sub { exit 124 }; alarm 2; exec @ARGV' \
          dscl . -read "/Users/$login" UserShell NFSHomeDirectory 2>/dev/null || true)
      fi
      pw_shell=$(printf '%s\n' "$raw" | sed -n 's/^UserShell: //p' | head -1)
      pw_home=$(printf '%s\n' "$raw" | sed -n 's/^NFSHomeDirectory: //p' | head -1)
    fi
  fi
  if [ -z "$pw_shell" ] || [ ! -x "$pw_shell" ]; then
    echo "warning: uid '${uid:-unknown}' has no usable passwd login shell; herdr panes fall back to /bin/sh" >&2
    pw_shell=/bin/sh
  fi
  # ONE home decides both values. It is the caller's whenever the caller has
  # one, exactly like the enumerated names below; the passwd home - checked for
  # existence the same way pw_shell is checked with -x - is consulted only as
  # the floor for a caller that carries none, so the server always has some
  # home to resolve its config under. Deciding HOME and the baseline PATH's
  # home entry from two different sources would hand the server a PATH naming
  # some other account's ~/.local/bin.
  if [ -n "${HOME:-}" ]; then
    launch_home=$HOME
  elif [ -n "$pw_home" ] && [ -d "$pw_home" ]; then
    launch_home=$pw_home
  else
    launch_home=/
    echo "warning: uid '${uid:-unknown}' has neither a caller HOME nor a usable passwd home directory; the herdr server's HOME and baseline PATH fall back to '/'" >&2
  fi
  # The perl script directories come LAST, after every standard system
  # directory, and they are here because herdr 0.9.1 starts a pane's shell
  # interactive but NOT login (measured 2026-09-27: argv0 /usr/bin/bash, no
  # -l, `shopt -q login_shell` false), so /etc/profile.d/perlbin.sh never
  # runs and nothing else re-adds them. Neither the frozen config file nor
  # herdr's shell start mode can be changed, so this baseline has to carry
  # them or no pane can resolve shasum - the 127 exits measured 2026-09-26.
  # Directories that do not exist are inert on PATH, so hosts without them
  # are unaffected.
  launch_path="$launch_home/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl"

  FM_HERDR_LAUNCH_ENV=(
    "HOME=$launch_home"
    "SHELL=$pw_shell"
    "PATH=$launch_path"
    "HERDR_SESSION=$session"
  )
  if [ -n "$login" ]; then
    FM_HERDR_LAUNCH_ENV+=("USER=$login" "LOGNAME=$login")
  fi
  # Enumerated one name at a time on purpose: a HERDR_* or LC_* wildcard here
  # would recreate exactly the rot that killed the old unset list.
  for name in XDG_CONFIG_HOME HERDR_CONFIG_PATH TMPDIR TERM COLORTERM LANG LC_ALL LC_CTYPE TZ \
    DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_SESSION_TYPE \
    SSH_AUTH_SOCK; do
    if [ -n "${!name:-}" ]; then
      FM_HERDR_LAUNCH_ENV+=("$name=${!name}")
    fi
  done
}
