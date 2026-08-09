# shellcheck shell=bash
# Non-interactive SSH host-trust preflight for spawn. Usage: . bin/fm-remote-preflight-lib.sh
#
# bin/fm-spawn.sh runs `treehouse get` inside the freshly created crew pane, and
# treehouse get runs `git fetch origin`. On the FIRST SSH access to a host, git's
# ssh stops at the interactive "authenticity of host ... can't be established"
# prompt. firstmate never sees that prompt - it only polls the pane for a worktree
# cwd - and the task metadata is not written until AFTER the fetch, so the pane
# wedges with no recoverable endpoint and the spawn times out opaquely. Probing
# host trust BEFORE the crew terminal is created turns that wedge into an explicit,
# actionable blocker, and it NEVER auto-accepts an unknown host key.
#
# The probe is only allowed to block on a fact about the REMOTE. A local SSH
# environment this process cannot read is not such a fact, so it proceeds instead
# (see fm_remote_preflight_ssh's code 20).
#
# Test / override seams:
#   FM_SPAWN_SSH                  ssh binary (default: ssh)
#   FM_SPAWN_SSH_KNOWN_HOSTS      isolated known_hosts file; when set, adds
#                                 UserKnownHostsFile and GlobalKnownHostsFile=/dev/null
#   FM_SPAWN_SSH_CONNECT_TIMEOUT  ssh ConnectTimeout seconds (default 8)

# fm_remote_ssh_target <git-remote-url>: print the ssh target for an SSH remote as
# `[user@]host` and return 0; return 1 (printing nothing) for a non-SSH remote
# (https://, git://, http://, file://, or a local path), which has no host-key gate.
# Handles scp-like `[user@]host:path` and `ssh://[user@]host[:port]/path`.
#
# The user is PART of the target. git fetches `ssh://git@code.byted.org/...` as
# `git@code.byted.org`; probing a bare `code.byted.org` connects as the probing
# PROCESS's own login instead, which is a different SSH identity from the one the
# fetch will use, so its verdict is about the wrong connection.
fm_remote_ssh_target() {
  local url=$1 rest user='' hostport host
  case "$url" in
    ssh://*)
      rest=${url#ssh://}
      rest=${rest%%/*}        # drop /path
      case "$rest" in
        *@*) user=${rest%%@*}; hostport=${rest#*@} ;;
        *) hostport=$rest ;;
      esac
      host=${hostport%%:*}    # drop :port
      ;;
    *://*) return 1 ;;        # any other scheme (https, git, http, file): no ssh gate
    /*|./*|../*|~/*) return 1 ;;   # local filesystem path
    *@*:*)
      user=${url%%@*}
      rest=${url#*@}          # host:path
      host=${rest%%:*}
      case "$host" in */*) return 1 ;; esac   # slash before the colon => local path
      ;;
    *:*)
      host=${url%%:*}         # host:path (no user@)
      case "$host" in */*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  if [ -n "$user" ]; then
    printf '%s@%s\n' "$user" "$host"
  else
    printf '%s\n' "$host"
  fi
}

# fm_remote_ssh_host <git-remote-url>: print just the host of an SSH remote, with
# any user stripped, and return 0; return 1 for a non-SSH remote. A host key is a
# property of the host, so captain-facing trust wording names this, not the target.
fm_remote_ssh_host() {
  local target
  target=$(fm_remote_ssh_target "$1") || return 1
  printf '%s\n' "${target##*@}"
}

# fm_remote_ssh_local_read_failure <ssh-output>: return 0 when the probe's own
# output shows OpenSSH could not READ a local file it needs (a known_hosts store,
# a config file). That says nothing about the remote, so the run's verdict must
# not be reported as a remote-trust or credential problem.
#
# Evidence for the patterns, OpenSSH_9.2p1, 2026-08-09, probing a host whose key
# IS in a readable known_hosts elsewhere:
#   known_hosts unreadable (file mode 000, or its directory mode 000), `ssh -v`:
#     debug1: load_hostkeys: fopen /tmp/khtest/known_hosts: Permission denied
#     No ED25519 host key is known for code.byted.org and you have requested strict checking.
#     Host key verification failed.
#   ssh config unreadable, DEFAULT verbosity:
#     Can't open user config file /tmp/badcfg: Permission denied
# Without `-v` the first case is BYTE-IDENTICAL to a genuinely unknown host key,
# which is why fm_remote_preflight_ssh runs the probe verbose.
#
# `No such file or directory` is deliberately NOT a failure: a healthy run prints
# it for every store that simply does not exist (known_hosts2, the global files),
# and an absent known_hosts is exactly the genuine first-connection case.
# The auth refusal `git@host: Permission denied (publickey).` carries no open verb
# and so does not match.
fm_remote_ssh_local_read_failure() {
  printf '%s' "$1" | grep -qiE \
    '(fopen|can.t open|cannot open|could not open|unable to open|error opening).*permission denied|bad owner or permissions'
}

# fm_remote_preflight_ssh <target>: probe host-key trust non-interactively, where
# <target> is the `[user@]host` git itself would connect to. Returns:
#   0  host key trusted, or the endpoint answered without a host-key error (a
#      fetch will not wedge on trust)
#   10 host key NOT trusted - git fetch would stop at the authenticity prompt
#   11 authentication refused (Permission denied) - fetch would fail on credentials
#   20 the probe could not run, or ran but could not read THIS machine's own SSH
#      files, so its verdict is not about the remote - caller proceeds (fail-safe,
#      never a false block)
# StrictHostKeyChecking=yes makes an unknown host fail immediately instead of
# prompting and NEVER auto-accepts; BatchMode=yes suppresses passphrase/password
# prompts so the probe can never itself hang on input. -v is required for the
# code-20 evidence above and only adds stderr this function consumes itself.
fm_remote_preflight_ssh() {
  local target=$1 ssh_bin timeout out rc
  [ -n "$target" ] || return 20
  ssh_bin=${FM_SPAWN_SSH:-ssh}
  command -v "$ssh_bin" >/dev/null 2>&1 || return 20
  timeout=${FM_SPAWN_SSH_CONNECT_TIMEOUT:-8}
  case "$timeout" in ''|*[!0-9]*) timeout=8 ;; esac
  if [ -n "${FM_SPAWN_SSH_KNOWN_HOSTS:-}" ]; then
    out=$("$ssh_bin" -v -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o "UserKnownHostsFile=$FM_SPAWN_SSH_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null \
      -o "ConnectTimeout=$timeout" -T -- "$target" true 2>&1)
    rc=$?
  else
    out=$("$ssh_bin" -v -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o "ConnectTimeout=$timeout" -T -- "$target" true 2>&1)
    rc=$?
  fi
  [ "$rc" -eq 0 ] && return 0
  # Checked BEFORE the trust and auth patterns: a run that could not read its own
  # host-key store reports the SAME "no host key is known" text as a real unknown
  # host, and an unreadable config reports "Permission denied". Classifying either
  # as a remote problem blocks a spawn against a host that is in fact trusted and
  # points the captain at their own trust configuration.
  if fm_remote_ssh_local_read_failure "$out"; then
    return 20
  fi
  if printf '%s' "$out" | grep -qiE 'host key verification failed|no .*host key.* is known|key verification'; then
    return 10
  fi
  if printf '%s' "$out" | grep -qiE 'permission denied'; then
    return 11
  fi
  # Non-zero without a host-key or auth error: e.g. a git-only endpoint that
  # authenticated then refused a shell, or a transient network failure. Neither is
  # the trust wedge, so proceed and let treehouse surface any real fetch error.
  return 0
}
