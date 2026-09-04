#!/usr/bin/env bash
# fm-forge-lib.sh - thin Firstmate forge provider boundary (bootstrap slice).
#
# Derives bootstrap CLI/auth requirements from registered project checkouts
# so GitLab-only homes do not require gh/gh-axi/gh auth, and GitHub-only
# homes do not require glab. Deliberately does NOT implement merge, teardown,
# head-SHA, or review-diff parity - no-mistakes owns those for no-mistakes
# delivery mode via glab/gh.
#
#
# Exit contract (subset actually used by the operations below):
#   0 = success, normalized output on stdout
#   1 = provider CLI / auth / network failure - no positive state may be inferred
#   2 = invalid/unsafe input - caller error
#   5 = capability unsupported by this provider/topology (used for "local"/"unknown")

set -u

fm_forge_normalize_host() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[.]*$//'
}

# fm_forge_detect_provider <path-to-checkout>
# Resolves a project checkout's `origin` remote to a provider. Does not
# guess: unknown/missing remotes are reported as "unknown", never silently
# defaulted to github or gitlab.
#
# Output: one line, one of: github gitlab local unknown
# Exit: 0 always (the classification itself is the result; "unknown" is not
#       a script failure)
fm_forge_github_hosts() {
  printf '%s\n' "${FM_GITHUB_HOSTS:-github.com}" \
    | tr ',' '\n' \
    | while IFS= read -r host; do
        host=$(fm_forge_normalize_host "$host")
        [ -n "$host" ] && printf '%s\n' "$host"
      done
}

fm_forge_host_is_github() {
  local host=${1:-}
  [ -n "$host" ] || return 1
  fm_forge_github_hosts | grep -F -x -q -- "$host"
}

fm_forge_gitlab_hosts() {
  local host
  printf '%s\n' "${FM_GITLAB_HOSTS:-gitlab.com}" \
    | tr ',' '\n' \
    | while IFS= read -r host; do
        host=$(fm_forge_normalize_host "$host")
        [ -n "$host" ] && printf '%s\n' "$host"
      done
}

fm_forge_host_is_gitlab() {
  local host=${1:-}
  [ -n "$host" ] || return 1
  fm_forge_gitlab_hosts | grep -F -x -q -- "$host"
}

fm_forge_safe_ssh_config() {
  local config
  for config in "${HOME:-}/.ssh/config" /etc/ssh/ssh_config; do
    fm_forge_safe_ssh_config_file "$config" 0
  done
}

# Expand Include directives ourselves so ssh -G receives only inert Host and
# HostName directives. Passing the original config to ssh would also evaluate
# Match exec commands while resolving a remote's provider alias.
fm_forge_safe_ssh_config_file() {
  local config=${1:-} depth=${2:-0} dir line key rest pattern candidate included
  local in_host=0 in_match=0

  [ -r "$config" ] || return 0
  [ "$depth" -lt 16 ] || return 0
  dir=$(dirname "$config")
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
    esac
    read -r key rest <<< "$line"
    key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
    case "$key" in
      host)
        in_host=1
        in_match=0
        printf '%s\n' "$line"
        ;;
      match)
        in_match=1
        ;;
      hostname)
        [ "$in_host" -eq 1 ] && [ "$in_match" -eq 0 ] || continue
        printf '%s\n' "$line"
        ;;
      include)
        [ "$in_match" -eq 0 ] || continue
        for pattern in $rest; do
          case "$pattern" in
            ~/*) candidate="${HOME:-}/${pattern#~/}" ;;
            /*) candidate=$pattern ;;
            *) candidate="$dir/$pattern" ;;
          esac
          while IFS= read -r included; do
            [ -n "$included" ] || continue
            fm_forge_safe_ssh_config_file "$included" $((depth + 1))
          done < <(compgen -G "$candidate" || true)
        done
        ;;
    esac
  done < "$config"
}

fm_forge_checkout_remote() {
  local checkout=${1:-} remote
  [ -d "$checkout" ] || return 1
  remote=$(command git -C "$checkout" remote get-url origin 2>/dev/null) && {
    printf '%s\n' "$remote"
    return 0
  }
  return 1
}

fm_forge_detect_provider() {
  local checkout=${1:-} remote_url raw_host host

  if [ -z "$checkout" ] || [ ! -d "$checkout" ]; then
    echo "unknown"
    return 0
  fi
  if ! command git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "local"
    return 0
  fi
  remote_url=$(fm_forge_checkout_remote "$checkout") || {
    echo "local"
    return 0
  }
  case "$remote_url" in
    file://*|git+file://*|/*|./*|../*)
      echo "local"
      return 0
      ;;
    *://*|*:*) ;;
    *)
      echo "local"
      return 0
      ;;
  esac
  raw_host=$(fm_forge_resolve_host "$remote_url" 0 2>/dev/null) || raw_host=""
  host=$(fm_forge_resolve_host "$remote_url" 1 2>/dev/null) || host=""
  if fm_forge_host_is_github "$raw_host" || fm_forge_host_is_github "$host"; then
    echo "github"
  elif fm_forge_host_is_gitlab "$raw_host" || fm_forge_host_is_gitlab "$host"; then
    echo "gitlab"
  else
    echo "unknown"
  fi
}

# fm_forge_resolve_host <remote-url-or-ssh-alias> [resolve-ssh]
# Resolves HTTPS, Git, and SSH remote URLs to a lowercase hostname.
fm_forge_resolve_host() {
  local remote_url=${1:-} host="" resolve_ssh=0 resolve_requested=${2:-1}

  [ -n "$remote_url" ] || return 1
  case "$resolve_requested" in
    0|1) ;;
    *) return 2 ;;
  esac
  case "$remote_url" in
    ssh://*|git+ssh://*)
      host=${remote_url#*://}
      host=${host#*@}
      host=${host%%/*}
      host=${host%%:*}
      ;;
    https://*|http://*|git://*|git+https://*|git+http://*)
      host=${remote_url#*://}
      host=${host%%/*}
      host=${host##*@}
      case "$host" in
        \[*\]*) host=${host#\[}; host=${host%%\]*} ;;
        *:*) host=${host%%:*} ;;
      esac
      ;;
    *:*)
      host=${remote_url%%:*}
      host=${host##*@}
      ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  # SSH config can rewrite aliases only for SSH transports. Applying it to an
  # HTTPS origin could classify the origin from an unrelated SSH alias and send
  # authentication to the wrong forge host.
  case "$remote_url" in
    ssh://*|git+ssh://*) resolve_ssh=$resolve_requested ;;
    *://*) ;;
    *:*) resolve_ssh=$resolve_requested ;;
  esac
  if [ "$resolve_ssh" -eq 1 ] && [ "$resolve_requested" -eq 1 ] \
    && command -v ssh >/dev/null 2>&1; then
    local resolved
    resolved=$(fm_forge_safe_ssh_config | ssh -G -F /dev/stdin -- "$host" 2>/dev/null \
      | awk '$1=="hostname"{print $2; exit}')
    [ -n "$resolved" ] && host=$resolved
  fi
  # A fully-qualified DNS name may carry its optional root label (for
  # example, github.com.).  Forge host policy stores canonical names without
  # that label, so normalize it before provider classification and auth.
  fm_forge_normalize_host "$host"
}


# fm_forge_provider_tools <provider>
# Emits the provider-specific CLI tools required by the bootstrap contract.
# Bootstrap owns the universal/backend checks; this function is the single
# provider-to-CLI policy owner used to build that contract.
#
# Output: one tool name per line. Exit 0 for known providers, 5 for local or
# unknown topologies, and 2 for an invalid provider name.
fm_forge_provider_tools() {
  case "${1:-}" in
    github)
      printf '%s\n' gh gh-axi
      ;;
    gitlab)
      printf '%s\n' glab
      ;;
    local|unknown)
      return 5
      ;;
    *)
      return 2
      ;;
  esac
}

# fm_forge_check_auth <provider> <host>
# Checks forge authentication, scoped to the specific host. Output is empty on
# success and one actionable diagnostic on failure.
fm_forge_check_auth() {
  local provider=${1:-} host=${2:-}

  # Keep the auth boundary canonical even when called directly rather than via
  # fm_forge_scan_registered_projects, which also normalizes its records.
  host=$(fm_forge_normalize_host "$host")

  case "$provider" in
    github)
      if ! command -v gh >/dev/null 2>&1; then
        if [ -n "$host" ]; then
          echo "NEEDS_GH_AUTH: $host"
        else
          echo "NEEDS_GH_AUTH"
        fi
        return 1
      fi
      if [ -n "$host" ]; then
        gh auth status --hostname "$host" >/dev/null 2>&1 || { echo "NEEDS_GH_AUTH: $host"; return 1; }
      else
        gh auth status >/dev/null 2>&1 || { echo "NEEDS_GH_AUTH"; return 1; }
      fi
      ;;
    gitlab)
      if ! command -v glab >/dev/null 2>&1; then
        if [ -n "$host" ]; then
          echo "NEEDS_GLAB_AUTH: $host"
        else
          echo "NEEDS_GLAB_AUTH"
        fi
        return 1
      fi
      if [ -n "$host" ]; then
        glab auth status --hostname "$host" >/dev/null 2>&1 || { echo "NEEDS_GLAB_AUTH: $host"; return 1; }
      else
        glab auth status >/dev/null 2>&1 || { echo "NEEDS_GLAB_AUTH"; return 1; }
      fi
      ;;
    local) return 0 ;;
    unknown)
      echo "FORGE_UNSUPPORTED"
      return 1
      ;;
    *) return 2 ;;
  esac
}


# fm_forge_scan_registered_projects <projects-dir>
# Scans every registered checkout and emits tab-delimited records:
# <project-id>\t<provider>\t<host>. Tabs cannot occur in normal Git checkout
# directory names, so the record remains lossless for spaces in project IDs.
fm_forge_scan_registered_projects() {
  local projects_dir=${1:-} entry project_id provider remote_url host raw_host

  [ -n "$projects_dir" ] && [ -d "$projects_dir" ] || return 0
  for entry in "$projects_dir"/*/; do
    [ -e "$entry" ] || continue
    project_id=$(basename "$entry")
    provider=$(fm_forge_detect_provider "$entry")
    host=""
    remote_url=$(fm_forge_checkout_remote "$entry" 2>/dev/null) || remote_url=""
    if [ -n "$remote_url" ]; then
      raw_host=$(fm_forge_resolve_host "$remote_url" 0 2>/dev/null || true)
      host=$(fm_forge_resolve_host "$remote_url" 1 2>/dev/null || true)
      if fm_forge_host_is_github "$raw_host" || fm_forge_host_is_gitlab "$raw_host"; then
        host=$raw_host
      fi
    fi
    printf '%s\t%s\t%s\n' "$project_id" "$provider" "${host:-}"
  done
}
