# shellcheck shell=bash
# Shared git transport recovery for firstmate spawn, fleet-sync, seed, and review paths.
#
# Usage: . bin/fm-git-transport-lib.sh   (after FM_ROOT / FM_HOME are set when available)
#
# Operator fault this owns:
#   A dead or missing ssh-agent (common with a stale wezterm SSH_AUTH_SOCK) makes every
#   git@ / ssh:// remote fail even when HTTPS + a credential helper still works.
#   Sandboxed agent shells can also break getpwuid and git's own DNS while Python still
#   resolves hosts. Prefer HTTPS remotes authenticated by gh/tea/credential-helper (or a
#   one-shot FM_GITEA_TOKEN / config/gitea-token read) over embedding tokens in stored
#   remotes or writing a second at-rest copy into global git config.
#
# Operator fix when ssh-agent is dead:
#   1. Confirm: `ssh-add -l` prints "Error connecting to agent" (not "The agent has no
#      identities").
#   2. Restart the agent and export a live socket, e.g. `eval "$(ssh-agent -s)"` then
#      `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` (or your key).
#   3. If WezTerm owns the agent, restart WezTerm (or clear a stale
#      ~/.local/share/wezterm/agent.* socket) so SSH_AUTH_SOCK points at a live listener.
#   4. Prefer durable HTTPS: `gh auth login` (GitHub) and/or a home-local
#      config/gitea-token / FM_GITEA_TOKEN for private-git hosts - never a second copy in
#      ~/.gitconfig. Firstmate will fall back to HTTPS automatically when the agent is
#      dead; fixing the agent restores plain git@ without further config.
#
# Contract:
#   - Never rewrite stored remotes or global git config.
#   - Never write tokens to disk; read FM_GITEA_TOKEN or $FM_HOME/config/gitea-token only
#     for a one-shot process-local credential helper.
#   - Try the caller's native git command first; fall back to HTTPS only on SSH-shaped
#     failure or a known-dead agent + SSH remote.
#   - Fail closed to the original git exit code when no HTTPS fallback is available.
#   - FM_GIT_LAST_OUTPUT holds the combined stdout+stderr of the last attempt.
#   - Portable on bash 3.2 (no nameref, no associative arrays).

# --- detection --------------------------------------------------------------

# fm_git_ssh_agent_dead: 0 when SSH cannot use an agent (unset/missing/dead socket, or
# ssh-add cannot connect). 1 when an agent answers - including "no identities", which is
# a live agent with an empty key list, not a dead one.
fm_git_ssh_agent_dead() {
  local sock out
  sock=${SSH_AUTH_SOCK-}
  if [ -z "$sock" ]; then
    return 0
  fi
  if [ ! -S "$sock" ] && [ ! -e "$sock" ]; then
    return 0
  fi
  # A dangling symlink or non-socket path is dead for agent use.
  if [ -e "$sock" ] && [ ! -S "$sock" ]; then
    return 0
  fi
  if ! command -v ssh-add >/dev/null 2>&1; then
    # No probe tool: treat a present socket as live rather than force HTTPS.
    return 1
  fi
  out=$(ssh-add -l 2>&1) || true
  case "$out" in
    *"Error connecting to agent"*|*"Could not open a connection to your authentication agent"*|*"No such file or directory"*|*"Connection refused"*)
      return 0
      ;;
  esac
  return 1
}

# fm_git_url_is_ssh <url>: 0 when the URL is an SSH form git will dial via ssh.
fm_git_url_is_ssh() {
  local url=$1
  case "$url" in
    git@*:*|ssh://*) return 0 ;;
  esac
  return 1
}

# Cluster-internal Gitea HTTP is often rewritten on this workstation to git@ via
# global insteadOf, so it inherits the same dead-agent failure mode.
fm_git_url_is_cluster_http() {
  local url=$1
  case "$url" in
    *gitea-http.gitea.svc.cluster.local*) return 0 ;;
  esac
  return 1
}

# fm_git_output_looks_like_ssh_failure <text>: 0 when git/ssh stderr indicates an
# SSH-transport failure worth an HTTPS retry.
fm_git_output_looks_like_ssh_failure() {
  local text=$1
  case "$text" in
    *"Permission denied (publickey)"*|*"Permission denied (keyboard-interactive,publickey)"*)
      return 0
      ;;
    *"Could not read from remote repository"*|*"Connection refused"*|*"Error connecting to agent"*)
      return 0
      ;;
    *"No user exists for uid"*|*"Could not resolve hostname"*|*"Host key verification failed"*)
      return 0
      ;;
    *"correct access rights"*|*"Authentication failed"*|*"kex_exchange_identification"*)
      return 0
      ;;
  esac
  return 1
}

# True when a failed attempt against <url> with <output> should try HTTPS next.
fm_git_should_retry_https() {
  local url=$1 output=$2
  if fm_git_url_is_ssh "$url" || fm_git_url_is_cluster_http "$url"; then
    return 0
  fi
  if fm_git_output_looks_like_ssh_failure "$output"; then
    return 0
  fi
  return 1
}

# --- URL conversion ---------------------------------------------------------

# fm_git_ssh_to_https <url>: convert git@host:path and ssh://git@host[:port]/path to
# https://host/path (optional .git suffix preserved). Non-SSH URLs echo unchanged.
# Prints the URL; returns 0 always for pure conversion.
fm_git_ssh_to_https() {
  local url=$1 host path
  case "$url" in
    git@*:*)
      host=${url#git@}
      host=${host%%:*}
      path=${url#*:}
      path=${path#/}
      printf 'https://%s/%s\n' "$host" "$path"
      return 0
      ;;
    ssh://*)
      # ssh://[user@]host[:port]/path
      host=${url#ssh://}
      host=${host#*@}
      path=${host#*/}
      host=${host%%/*}
      case "$host" in
        *:*)
          host=${host%:*}
          ;;
      esac
      printf 'https://%s/%s\n' "$host" "$path"
      return 0
      ;;
    *)
      printf '%s\n' "$url"
      return 0
      ;;
  esac
}

# fm_git_https_host <url>: echo the host of an https:// URL, or empty.
fm_git_https_host() {
  local url=$1 rest host
  case "$url" in
    https://*)
      rest=${url#https://}
      rest=${rest#*@}
      host=${rest%%/*}
      host=${host%%:*}
      printf '%s\n' "$host"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

# Cluster-internal Gitea HTTP -> public HTTPS host used on this workstation.
# fm_git_cluster_http_to_https <url>
fm_git_cluster_http_to_https() {
  local url=$1
  case "$url" in
    http://gitea-http.gitea.svc.cluster.local:3000/*)
      printf 'https://private-git.ocin.cloud/%s\n' "${url#http://gitea-http.gitea.svc.cluster.local:3000/}"
      ;;
    https://gitea-http.gitea.svc.cluster.local:3000/*)
      printf 'https://private-git.ocin.cloud/%s\n' "${url#https://gitea-http.gitea.svc.cluster.local:3000/}"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

# fm_git_prefer_https_url <url>: SSH or cluster-HTTP -> public HTTPS; else unchanged.
fm_git_prefer_https_url() {
  local url=$1
  url=$(fm_git_cluster_http_to_https "$url")
  if fm_git_url_is_ssh "$url"; then
    fm_git_ssh_to_https "$url"
    return 0
  fi
  printf '%s\n' "$url"
}

# --- credentials (process-local only) ---------------------------------------

# fm_git_gitea_token: print a Gitea token for private-git HTTPS auth.
# Order: FM_GITEA_TOKEN, FM_GITEA_TOKEN_FILE, $FM_HOME/config/gitea-token,
# $FM_ROOT/config/gitea-token. Never writes. Never caches across calls. Returns 1
# when none found.
fm_git_gitea_token() {
  local f token
  if [ -n "${FM_GITEA_TOKEN-}" ]; then
    printf '%s' "$FM_GITEA_TOKEN"
    return 0
  fi
  for f in \
    "${FM_GITEA_TOKEN_FILE-}" \
    "${FM_HOME-}/config/gitea-token" \
    "${FM_ROOT-}/config/gitea-token"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    token=$(sed -n '1p' "$f" | tr -d '\r\n')
    if [ -n "$token" ]; then
      printf '%s' "$token"
      return 0
    fi
  done
  return 1
}

# fm_git_resolve_host_ip <host>: print an A/AAAA via Python (works when git's
# libcurl resolver is broken). Empty + non-zero on failure.
fm_git_resolve_host_ip() {
  local host=$1 ip
  [ -n "$host" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  ip=$(python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$host" 2>/dev/null) || return 1
  [ -n "$ip" ] || return 1
  printf '%s\n' "$ip"
}

# fm_git_https_extra_config <https-url>: print git -c key=value lines (one per
# line) for a one-shot HTTPS fetch/clone: curloptResolve when resolvable, and a
# host-appropriate credential helper. Never embeds the token in a stored remote.
fm_git_https_extra_config() {
  local url=$1 host ip token helper
  host=$(fm_git_https_host "$url")
  [ -n "$host" ] || return 0
  if ip=$(fm_git_resolve_host_ip "$host"); then
    printf 'http.curloptResolve=%s:443:%s\n' "$host" "$ip"
  fi
  case "$host" in
    github.com|*.github.com)
      if command -v gh >/dev/null 2>&1; then
        printf 'credential.helper=\n'
        printf 'credential.helper=!gh auth git-credential\n'
      fi
      ;;
    *)
      # Private hosts (Gitea and similar): one-shot helper from env/file token.
      if token=$(fm_git_gitea_token); then
        # Password is expanded when this function runs; the helper body itself is
        # single-quoted to git so shell metacharacters in the token stay literal.
        # shellcheck disable=SC2016 # $1 is for the credential-helper protocol, not bash.
        helper=$(printf '!f() { test \"$1\" = get || exit 0; echo username=oauth2; echo password=%s; }; f' "$token")
        printf 'credential.helper=\n'
        printf 'credential.helper=%s\n' "$helper"
      fi
      ;;
  esac
}

# --- fetch / clone / submodule ----------------------------------------------

FM_GIT_LAST_OUTPUT=""

# fm_git_remote_url <dir> <remote>: print the configured remote URL.
fm_git_remote_url() {
  local dir=$1 remote=$2
  git -C "$dir" remote get-url "$remote" 2>/dev/null
}

# Internal: run `git -C dir "$@"` capturing combined output into FM_GIT_LAST_OUTPUT.
fm_git_capture() {
  local dir=$1
  shift
  local out rc
  set +e
  out=$(git -C "$dir" "$@" 2>&1)
  rc=$?
  set -e
  FM_GIT_LAST_OUTPUT=$out
  return "$rc"
}

# fm_git_capture_with_https_config <dir> <https_url> <git-args...>:
# Like fm_git_capture, but prefixes process-local -c pairs for <https_url>.
# Safe under bash 3.2 set -u when no config is produced (no empty-array expand).
fm_git_capture_with_https_config() {
  local dir=$1 url=$2
  shift 2
  local line
  local -a args=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    args+=(-c "$line")
  done < <(fm_git_https_extra_config "$url")

  if [ "${#args[@]}" -gt 0 ]; then
    fm_git_capture "$dir" "${args[@]}" "$@"
  else
    fm_git_capture "$dir" "$@"
  fi
}

# fm_git_fetch_with_fallback <dir> <remote> [git fetch args...]:
# Try the stored remote first (same pattern as packed-refs recovery). On
# SSH-shaped failure - or when the remote is SSH/cluster-HTTP - retry once
# against a process-local HTTPS URL + credential helper.
# Does not rewrite remotes. Sets FM_GIT_LAST_OUTPUT; returns git rc.
fm_git_fetch_with_fallback() {
  local dir=$1 remote=$2
  shift 2
  local url https_url

  url=$(fm_git_remote_url "$dir" "$remote") || url=""

  # Native attempt first - preserves packed-refs and ordinary happy-path behavior.
  if fm_git_capture "$dir" fetch "$remote" "$@"; then
    return 0
  fi

  if [ -z "$url" ]; then
    return 1
  fi
  if ! fm_git_should_retry_https "$url" "$FM_GIT_LAST_OUTPUT"; then
    return 1
  fi

  https_url=$(fm_git_prefer_https_url "$url")
  case "$https_url" in
    https://*) ;;
    *) return 1 ;;
  esac

  if fm_git_capture_with_https_config "$dir" "$https_url" fetch "$https_url" "$@"; then
    return 0
  fi
  return 1
}

# fm_git_clone_with_fallback <url> <dest> [git clone args...]:
# Clone url into dest. On SSH/agent failure, retry with HTTPS + credential helper.
# Destination must not already exist after a failed first attempt (same as git).
# Sets FM_GIT_LAST_OUTPUT.
fm_git_clone_with_fallback() {
  local url=$1 dest=$2
  shift 2
  local https_url rc line
  local -a args=()

  set +e
  FM_GIT_LAST_OUTPUT=$(git clone "$@" "$url" "$dest" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && return 0

  if ! fm_git_should_retry_https "$url" "$FM_GIT_LAST_OUTPUT"; then
    return "$rc"
  fi

  https_url=$(fm_git_prefer_https_url "$url")
  case "$https_url" in
    https://*) ;;
    *) return "$rc" ;;
  esac

  # If dest was partially created, refuse rather than clobber.
  if [ -e "$dest" ]; then
    return "$rc"
  fi

  args=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    args+=(-c "$line")
  done < <(fm_git_https_extra_config "$https_url")

  set +e
  if [ "${#args[@]}" -gt 0 ]; then
    FM_GIT_LAST_OUTPUT=$(git "${args[@]}" clone "$@" "$https_url" "$dest" 2>&1)
  else
    FM_GIT_LAST_OUTPUT=$(git clone "$@" "$https_url" "$dest" 2>&1)
  fi
  rc=$?
  set -e
  return "$rc"
}

# fm_git_submodule_update_with_fallback <dir> [git submodule update args...]:
# Run submodule update in <dir>. On failure with a dead agent / SSH signature,
# retry with process-local insteadOf rewrites from cluster-HTTP and git@ to the
# public HTTPS host, plus credential helper. Does not persist URL rewrites.
fm_git_submodule_update_with_fallback() {
  local dir=$1
  shift
  local host=private-git.ocin.cloud https_base line
  local -a args=()

  if fm_git_capture "$dir" submodule update "$@"; then
    return 0
  fi
  if ! fm_git_ssh_agent_dead && ! fm_git_output_looks_like_ssh_failure "$FM_GIT_LAST_OUTPUT"; then
    return 1
  fi

  https_base="https://${host}/OpenCloud/"
  args=(
    -c "url.${https_base}.insteadOf=http://gitea-http.gitea.svc.cluster.local:3000/OpenCloud/"
    -c "url.${https_base}.insteadOf=git@${host}:OpenCloud/"
    -c "url.${https_base}.insteadOf=ssh://git@${host}/OpenCloud/"
  )
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    args+=(-c "$line")
  done < <(fm_git_https_extra_config "https://${host}/OpenCloud/core.git")

  if [ "${#args[@]}" -gt 0 ]; then
    fm_git_capture "$dir" "${args[@]}" submodule update "$@"
  else
    fm_git_capture "$dir" submodule update "$@"
  fi
}
