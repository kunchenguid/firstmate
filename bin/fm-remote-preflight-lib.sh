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
# Test / override seams:
#   FM_SPAWN_SSH                  ssh binary (default: ssh)
#   FM_SPAWN_SSH_KNOWN_HOSTS      isolated known_hosts file; when set, adds
#                                 UserKnownHostsFile and GlobalKnownHostsFile=/dev/null
#   FM_SPAWN_SSH_CONNECT_TIMEOUT  ssh ConnectTimeout seconds (default 8)

# fm_remote_ssh_host <git-remote-url>: print the ssh host for an SSH remote and
# return 0; return 1 (printing nothing) for a non-SSH remote (https://, git://,
# http://, file://, or a local path), which has no host-key gate. Handles
# scp-like `[user@]host:path` and `ssh://[user@]host[:port]/path`.
fm_remote_ssh_host() {
  local url=$1 rest host
  case "$url" in
    ssh://*)
      rest=${url#ssh://}
      rest=${rest%%/*}        # drop /path
      rest=${rest#*@}         # drop user@
      host=${rest%%:*}        # drop :port
      ;;
    *://*) return 1 ;;        # any other scheme (https, git, http, file): no ssh gate
    /*|./*|../*|~/*) return 1 ;;   # local filesystem path
    *@*:*)
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
  printf '%s\n' "$host"
}

# fm_remote_preflight_ssh <host>: probe host-key trust non-interactively. Returns:
#   0  host key trusted, or the endpoint answered without a host-key error (a
#      fetch will not wedge on trust)
#   10 host key NOT trusted - git fetch would stop at the authenticity prompt
#   11 authentication refused (Permission denied) - fetch would fail on credentials
#   20 the probe could not run - caller proceeds (fail-safe, never a false block)
# StrictHostKeyChecking=yes makes an unknown host fail immediately instead of
# prompting and NEVER auto-accepts; BatchMode=yes suppresses passphrase/password
# prompts so the probe can never itself hang on input.
fm_remote_preflight_ssh() {
  local host=$1 ssh_bin timeout out rc
  [ -n "$host" ] || return 20
  ssh_bin=${FM_SPAWN_SSH:-ssh}
  command -v "$ssh_bin" >/dev/null 2>&1 || return 20
  timeout=${FM_SPAWN_SSH_CONNECT_TIMEOUT:-8}
  case "$timeout" in ''|*[!0-9]*) timeout=8 ;; esac
  if [ -n "${FM_SPAWN_SSH_KNOWN_HOSTS:-}" ]; then
    out=$("$ssh_bin" -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o "UserKnownHostsFile=$FM_SPAWN_SSH_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null \
      -o "ConnectTimeout=$timeout" -T -- "$host" true 2>&1)
    rc=$?
  else
    out=$("$ssh_bin" -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o "ConnectTimeout=$timeout" -T -- "$host" true 2>&1)
    rc=$?
  fi
  [ "$rc" -eq 0 ] && return 0
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
