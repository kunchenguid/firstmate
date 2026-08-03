#!/usr/bin/env bash
# fm-forge-lib.sh — thin Firstmate forge provider boundary (bootstrap slice).
#
# Derives bootstrap CLI/auth requirements from registered project checkouts
# so GitLab-only homes do not require gh/gh-axi/gh auth, and GitHub-only
# homes do not require glab. Deliberately does NOT implement merge, teardown,
# head-SHA, or review-diff parity — no-mistakes owns those for no-mistakes
# delivery mode via glab/gh.
#
#
# Exit contract (subset actually used by the operations below):
#   0 = success, normalized output on stdout
#   1 = provider CLI / auth / network failure — no positive state may be inferred
#   2 = invalid/unsafe input — caller error
#   5 = capability unsupported by this provider/topology (used for "local"/"unknown")

set -u

# fm_forge_detect_provider <path-to-checkout>
# Resolves a project checkout's `origin` remote to a provider. Does not
# guess: unknown/missing remotes are reported as "unknown", never silently
# defaulted to github or gitlab.
#
# Output: one line, one of: github gitlab local unknown
# Exit: 0 always (the classification itself is the result; "unknown" is not
#       a script failure)
fm_forge_gitlab_hosts() {
  local host
  printf '%s\n' "${FM_GITLAB_HOSTS:-gitlab.com}" \
    | tr ',' '\n' \
    | while IFS= read -r host; do
        host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$host" ] && printf '%s\n' "$host"
      done
}

fm_forge_host_is_gitlab() {
  local host=${1:-}
  [ -n "$host" ] || return 1
  fm_forge_gitlab_hosts | grep -F -x -q -- "$host"
}

fm_forge_checkout_remote() {
  local checkout=${1:-} remote
  [ -d "$checkout" ] || return 1
  remote=$(git -C "$checkout" remote get-url origin 2>/dev/null) && {
    printf '%s\n' "$remote"
    return 0
  }
  return 1
}

fm_forge_detect_provider() {
  local checkout=${1:-} remote_url host

  if [ -z "$checkout" ] || [ ! -d "$checkout" ]; then
    echo "unknown"
    return 0
  fi
  if ! git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "local"
    return 0
  fi
  remote_url=$(fm_forge_checkout_remote "$checkout") || {
    echo "local"
    return 0
  }
  case "$remote_url" in
    file://*|/*|./*|../*)
      echo "local"
      return 0
      ;;
    *://*|*:*) ;;
    *)
      echo "local"
      return 0
      ;;
  esac
  host=$(fm_forge_resolve_host "$remote_url" 2>/dev/null) || host=""
  case "$host" in
    github.com) echo "github" ;;
    gitlab.com) echo "gitlab" ;;
    *)
      if fm_forge_host_is_gitlab "$host"; then
        echo "gitlab"
      else
        echo "unknown"
      fi
      ;;
  esac
}

# fm_forge_resolve_host <remote-url-or-ssh-alias>
# Resolves a git remote URL (scp-like SSH syntax, ssh:// URL, or https:// URL)
# to its real hostname, following `~/.ssh/config` Host aliases via `ssh -G`
# so aliases for self-managed GitLab instances classify by their real hostname.
#
# Output: one line, the resolved lowercase hostname, or empty on failure
# Exit: 0 if resolved, 1 if the remote URL could not be parsed at all
fm_forge_resolve_host() {
  local remote_url=${1:-} host="" resolve_ssh=0

  [ -n "$remote_url" ] || return 1

  case "$remote_url" in
    ssh://*)
      resolve_ssh=1
      host=${remote_url#ssh://}
      host=${host#*@}
      host=${host%%/*}
      host=${host%%:*}
      ;;
    https://*|http://*)
      host=${remote_url#*://}
      host=${host%%/*}
      host=${host##*@}
      case "$host" in
        \[*\]*) host=${host#\[}; host=${host%%\]*} ;;
        *:*) host=${host%%:*} ;;
      esac
      ;;
    *:*)
      resolve_ssh=1
      host=${remote_url%%:*}
      host=${host##*@}
      ;;
    *)
      return 1
      ;;
  esac

  [ -n "$host" ] || return 1

  # Follow SSH config aliases when possible. If ssh cannot resolve the alias,
  # retain the parsed host; provider classification will fail closed unless
  # it is explicitly listed in FM_GITLAB_HOSTS.
  local resolved
  if [ "$resolve_ssh" -eq 1 ] && command -v ssh >/dev/null 2>&1; then
    resolved=$(ssh -G -- "$host" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')
    [ -n "$resolved" ] && host=$resolved
  fi

  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]'
  return 0
}

# fm_forge_require_cli <provider>
# Validates that the CLI tools required for this provider are on PATH.
# Does not check auth (see fm_forge_check_auth) — only binary presence.
#
# Output: one MISSING line per absent tool (same shape as fm-bootstrap.sh's
#         existing missing_tool_diagnostic lines), nothing when all present
# Exit: 0 if all required tools present, 1 if any are missing
fm_forge_require_cli() {
  local provider=${1:-} missing=0 tool

  case "$provider" in
    github)
      for tool in gh gh-axi; do
        command -v "$tool" >/dev/null 2>&1 || { echo "MISSING: $tool"; missing=1; }
      done
      ;;
    gitlab)
      if ! command -v glab >/dev/null 2>&1; then
        echo "MISSING: glab"
        missing=1
      fi
      ;;
    local)
      : # no forge CLI required
      ;;
    unknown)
      echo "FORGE_UNSUPPORTED"
      return 1
      ;;
    *)
      return 2
      ;;
  esac

  return "$missing"
}

# fm_forge_check_auth <provider> <host>
# Checks forge authentication, scoped to the specific host (never an
# unscoped "--all" check — a single stale unrelated credential must not
# fail an otherwise-healthy host).
#
# Output: nothing on success; one diagnostic line on failure, matching the
#         existing NEEDS_GH_AUTH convention so fm-session-start.sh's existing
#         consumers keep working without modification
# Exit: 0 authenticated, 1 not authenticated / check failed
fm_forge_check_auth() {
  local provider=${1:-} host=${2:-}

  case "$provider" in
    github)
      if [ -n "$host" ]; then
        gh auth status --hostname "$host" >/dev/null 2>&1 || { echo "NEEDS_GH_AUTH"; return 1; }
      else
        gh auth status >/dev/null 2>&1 || { echo "NEEDS_GH_AUTH"; return 1; }
      fi
      ;;
    gitlab)
      # Missing CLI is already reported by fm-bootstrap.sh; do not emit a
      # misleading auth diagnostic for an unavailable binary.
      command -v glab >/dev/null 2>&1 || return 1
      if [ -n "$host" ]; then
        glab auth status --hostname "$host" >/dev/null 2>&1 || { echo "NEEDS_GLAB_AUTH: $host"; return 1; }
      else
        glab auth status >/dev/null 2>&1 || { echo "NEEDS_GLAB_AUTH"; return 1; }
      fi
      ;;
    local)
      return 0
      ;;
    unknown)
      echo "FORGE_UNSUPPORTED"
      return 1
      ;;
    *)
      return 2
      ;;
  esac

  return 0
}

# fm_forge_scan_registered_projects <projects-dir>
# Scans every symlinked/real project checkout directly under the given
# projects directory (matches $FM_HOME/projects layout) and prints one
# "<project-id> <provider> <host>" line per entry. Used by fm-bootstrap.sh
# to compute the required tool/auth union across the actual registry
# instead of the previous unconditional GitHub-only assumption.
#
# Output: "<project-id> <provider> <host>" per line (host empty for
#         local/unknown)
# Exit: 0 always (per-project detection failures are reported inline via
#       provider=unknown, not a fatal scan error)
fm_forge_scan_registered_projects() {
  local projects_dir=${1:-} entry project_id provider remote_url host

  [ -n "$projects_dir" ] && [ -d "$projects_dir" ] || return 0

  for entry in "$projects_dir"/*/; do
    [ -e "$entry" ] || continue
    project_id=$(basename "$entry")
    provider=$(fm_forge_detect_provider "$entry")
    host=""
    remote_url=$(fm_forge_checkout_remote "$entry" 2>/dev/null) || remote_url=""
    [ -n "$remote_url" ] && host=$(fm_forge_resolve_host "$remote_url" 2>/dev/null || true)
    printf '%s %s %s\n' "$project_id" "$provider" "${host:-}"
  done
}
