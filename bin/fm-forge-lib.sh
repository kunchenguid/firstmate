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
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\.$//'
}

# fm_forge_detect_provider <path-to-checkout>
# Resolves a project checkout's `origin` remote to a provider. Does not
# guess: unknown/missing remotes are reported as "unknown", never silently
# defaulted to github or gitlab.
#
# Output: one line, one of: github gitlab gerrit forgejo external local unknown
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
  local config config_index=0
  for config in "${HOME:-}/.ssh/config" /etc/ssh/ssh_config; do
    if [ "$config_index" -eq 1 ]; then
      # Each top-level file starts a fresh OpenSSH scope. Keep the user's
      # first-value precedence while preventing a trailing user Host/Match
      # block from suppressing global directives in the system file.
      printf '%s\n' 'Host *'
    fi
    fm_forge_safe_ssh_config_file "$config" 0 || return 1
    config_index=$((config_index + 1))
  done
}

# Expand Include directives ourselves so ssh -G receives only inert Host and
# HostName directives. Passing the original config to ssh would also evaluate
# Match exec commands while resolving a remote's provider alias.
fm_forge_safe_ssh_include_patterns() {
  local input=${1:-} token= quote= escaped=0 i char

  for ((i = 0; i < ${#input}; i++)); do
    char=${input:i:1}
    if [ "$escaped" -eq 1 ]; then
      token+=$char
      escaped=0
      continue
    fi
    case "$char" in
      '\\') escaped=1 ;;
      "'"|'"')
        if [ -z "$quote" ]; then
          quote=$char
        elif [ "$quote" = "$char" ]; then
          quote=
        else
          token+=$char
        fi
        ;;
      [[:space:]])
        [ -z "$quote" ] || { token+=$char; continue; }
        if [ -n "$token" ]; then
          printf '%s\n' "$token"
          token=
        fi
        ;;
      *) token+=$char ;;
    esac
  done
  [ "$escaped" -eq 0 ] && [ -z "$quote" ] || return 1
  [ -z "$token" ] || printf '%s\n' "$token"
}

fm_forge_safe_ssh_config_file() {
  local config=${1:-} depth=${2:-0} dir line key rest pattern condition candidate included
  local -a conditions
  local in_match=0 match_safe=1

  [ -e "$config" ] || return 0
  [ -r "$config" ] || return 1
  [ "$depth" -lt 16 ] || return 1
  dir=$(dirname "$config")
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
    esac
    if [[ "$line" =~ ^([^[:space:]=]+)([[:space:]]*=[[:space:]]*|[[:space:]]+)(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      rest=${BASH_REMATCH[3]}
    else
      key=$line
      rest=
    fi
    key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
    case "$key" in
      host)
        in_match=0
        match_safe=1
        printf '%s\n' "$line"
        ;;
      match)
        in_match=1
        match_safe=1
        for pattern in $rest; do
          IFS=',' read -ra conditions <<< "$pattern"
          for condition in "${conditions[@]}"; do
            condition=${condition#\!}
            condition=$(printf '%s' "$condition" | tr '[:upper:]' '[:lower:]')
            case "$condition" in
              exec|exec=*) return 1 ;;
            esac
          done
        done
        printf '%s\n' "$line"
        ;;
      hostname)
        printf '%s\n' "$line"
        ;;
      include)
        [ "$in_match" -eq 0 ] || [ "$match_safe" -eq 1 ] || return 1
        local patterns
        patterns=$(fm_forge_safe_ssh_include_patterns "$rest") || return 1
        while IFS= read -r pattern; do
          [ -n "$pattern" ] || continue
          case "$pattern" in
            "~/"*) candidate="${HOME:-}/${pattern:2}" ;;
            /*) candidate=$pattern ;;
            *) candidate="$dir/$pattern" ;;
          esac
          included=$(compgen -G "$candidate" || true)
          if [ -n "$included" ]; then
            while IFS= read -r included; do
              [ -n "$included" ] || continue
              fm_forge_safe_ssh_config_file "$included" $((depth + 1)) || return 1
            done <<< "$included"
          fi
        done <<< "$patterns"
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

fm_forge_effective_ssh_command() {
  local checkout=${1:-} command

  if [ -n "${GIT_SSH_COMMAND:-}" ]; then
    printf '%s\n' "$GIT_SSH_COMMAND"
  elif [ -n "$checkout" ] \
    && command=$(command git -C "$checkout" config --get core.sshCommand 2>/dev/null); then
    printf '%s\n' "$command"
  elif [ -n "${GIT_SSH:-}" ]; then
    printf '%s\n' "$GIT_SSH"
  else
    printf '%s\n' ssh
  fi
}

fm_forge_ssh_command_executable() {
  local command=${1:-} first ssh_path
  local -a argv

  read -r -a argv <<< "$command"
  [ "${#argv[@]}" -gt 0 ] || return 1
  first=${argv[0]}
  case "$first" in
    ~/*) first="${HOME:-}/${first#~/}" ;;
  esac
  ssh_path=$(command -v ssh 2>/dev/null) || return 1
  case "$ssh_path" in
    /bin/ssh|/usr/bin/ssh)
      [ -x "$ssh_path" ] || return 1
      ;;
    *) return 1 ;;
  esac
  case "$first" in
    ssh)
      printf '%s\n' "$ssh_path"
      ;;
    /*)
      case "$first" in
        /bin/ssh|/usr/bin/ssh) ;;
        *) return 1 ;;
      esac
      [ -x "$first" ] || return 1
      printf '%s\n' "$first"
      ;;
    *) return 1 ;;
  esac
}

fm_forge_ssh_command_config() {
  local command=${1:-} token first config= i
  local -a argv

  case "$command" in
    *$'\n'*) return 2 ;;
  esac
  read -r -a argv <<< "$command"
  [ "${#argv[@]}" -gt 0 ] || return 2
  first=${argv[0]}
  case "$first" in
    ssh|*/ssh) ;;
    *) return 2 ;;
  esac
  i=1
  while [ "$i" -lt "${#argv[@]}" ]; do
    token=${argv[$i]}
    case "$token" in
      -F)
        i=$((i + 1))
        [ "$i" -lt "${#argv[@]}" ] || return 2
        [ -z "$config" ] || return 2
        config=${argv[$i]}
        ;;
      -F?*)
        [ -z "$config" ] || return 2
        config=${token#-F}
        ;;
      *) return 2 ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$config"
}

fm_forge_safe_ssh_config_for_checkout() {
  local checkout=${1:-} command config checkout_root

  command=$(fm_forge_effective_ssh_command "$checkout") || return 1
  fm_forge_ssh_command_executable "$command" >/dev/null || return 1
  config=$(fm_forge_ssh_command_config "$command") || return 1
  if [ -z "$config" ]; then
    fm_forge_safe_ssh_config || return 1
    return 0
  fi
  case "$config" in
    "~/"*) config="${HOME:-}/${config:2}" ;;
    /*) ;;
    *)
      checkout_root=$(cd "$checkout" 2>/dev/null && pwd -P) || return 1
      config="$checkout_root/$config"
      ;;
  esac
  [ "$config" != /dev/stdin ] && [ -r "$config" ] || return 1
  fm_forge_safe_ssh_config_file "$config" 0 || return 1
  printf '%s\n' 'Host *'
  fm_forge_safe_ssh_config_file /etc/ssh/ssh_config 0 || return 1
}

fm_forge_registered_project_id() {
  local checkout=${1:-} entry projects

  [ -d "$checkout" ] || return 1
  projects=${FM_PROJECTS_OVERRIDE:-${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/projects}
  for entry in "$projects"/*/; do
    [ -e "$entry" ] || continue
    [ "$entry" -ef "$checkout" ] || continue
    basename "$entry"
    return 0
  done
  return 1
}

fm_forge_registered_binding() {
  local checkout=${1:-} project_id root home data forge

  [ -d "$checkout" ] || return 1
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  home=${FM_HOME:-$root}
  data=${FM_DATA_OVERRIDE:-$home/data}
  project_id=$(fm_forge_registered_project_id "$checkout") || return 1
  if forge=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$root/bin/fm-project-mode.sh" --forge "$project_id" 2>/dev/null); then
    case "$forge" in
      gerrit|forgejo|external) ;;
      *) return 1 ;;
    esac
    printf '%s\n' "$forge"
    return 0
  fi
  return 2
}

fm_forge_registry_refuses_local_only() {
  local project_id=${1:-} root home data refusal

  [ -n "$project_id" ] || return 1
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  home=${FM_HOME:-$root}
  data=${FM_DATA_OVERRIDE:-$home/data}
  refusal=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$root/bin/fm-project-mode.sh" "$project_id" 2>&1 >/dev/null || true)
  case "$refusal" in
    *"refused: $project_id is registered local-only with forge="*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_forge_clone_root() {
  local checkout=${1:-} proj_top proj_abs

  [ -d "$checkout" ] || return 1
  proj_top=$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) || return 1
  printf '%s\n' "$proj_top"
  proj_abs=$(cd "$checkout" && pwd -P) || return 2
  [ "$proj_top" -ef "$proj_abs" ] || return 2
}

fm_forge_detect_provider() {
  local checkout=${1:-} remote_url host binding project_id binding_status

  if [ -z "$checkout" ] || [ ! -d "$checkout" ]; then
    echo "unknown"
    return 0
  fi
  if ! command git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "local"
    return 0
  fi
  remote_url=$(fm_forge_checkout_remote "$checkout" 2>/dev/null || true)
  project_id=$(fm_forge_registered_project_id "$checkout" 2>/dev/null || true)
  if binding=$(fm_forge_registered_binding "$checkout"); then
    echo "$binding"
    return 0
  else
    binding_status=$?
    if [ "$binding_status" -eq 2 ] && [ -n "$project_id" ] && [ -z "$remote_url" ]; then
      echo registry-refused
      return 0
    fi
    if [ "$binding_status" -eq 2 ] \
      && [ -n "$project_id" ] \
      && fm_forge_registry_refuses_local_only "$project_id"; then
      echo registry-refused
      return 0
    fi
    if [ "$binding_status" -eq 2 ]; then
      echo unknown
      return 0
    fi
  fi
  if [ -z "$remote_url" ]; then
    echo "local"
    return 0
  fi
  case "$remote_url" in
    file://*|git+file://*|/*|./*|../*|[[:alpha:]]:[/\\]*)
      echo "local"
      return 0
      ;;
    *://*|*:*) ;;
    *)
      echo "local"
      return 0
      ;;
  esac
  host=$(fm_forge_resolve_host "$remote_url" 1 "$checkout" 2>/dev/null) || host=""
  if [ -z "$host" ]; then
    echo unknown
  elif fm_forge_host_is_github "$host"; then
    echo "github"
  elif fm_forge_host_is_gitlab "$host"; then
    echo "gitlab"
  else
    echo "unknown"
  fi
}

# fm_forge_resolve_host <remote-url-or-ssh-alias> [resolve-ssh]
# Resolves HTTPS, Git, and SSH remote URLs to a lowercase hostname.
fm_forge_resolve_host() {
  local remote_url=${1:-} host="" resolve_ssh=0 resolve_requested=${2:-1} checkout=${3:-}
  local ssh_command ssh_executable

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
  if [ "$resolve_ssh" -eq 1 ] && [ "$resolve_requested" -eq 1 ]; then
    local resolved ssh_config
    ssh_command=$(fm_forge_effective_ssh_command "$checkout") || return 1
    ssh_executable=$(fm_forge_ssh_command_executable "$ssh_command") || return 1
    ssh_config=$(fm_forge_safe_ssh_config_for_checkout "$checkout") || return 1
    resolved=$(printf '%s\n' "$ssh_config" | "$ssh_executable" -G -F /dev/stdin -- "$host" 2>/dev/null \
      | awk '$1=="hostname"{print $2; exit}') || return 1
    [ -n "$resolved" ] || return 1
    host=$resolved
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
    gerrit)
      printf '%s\n' gerrit-axi jq
      ;;
    forgejo)
      printf '%s\n' tea
      ;;
    external)
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
    gerrit|forgejo|external|local) return 0 ;;
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
  local projects_dir=${1:-} entry project_id provider remote_url host

  [ -n "$projects_dir" ] && [ -d "$projects_dir" ] || return 0
  for entry in "$projects_dir"/*/; do
    [ -e "$entry" ] || continue
    fm_forge_clone_root "$entry" >/dev/null 2>&1 || continue
    project_id=$(basename "$entry")
    provider=$(fm_forge_detect_provider "$entry")
    host=""
    remote_url=$(fm_forge_checkout_remote "$entry" 2>/dev/null) || remote_url=""
    if [ -n "$remote_url" ]; then
      host=$(fm_forge_resolve_host "$remote_url" 1 "$entry" 2>/dev/null || true)
    fi
    printf '%s\t%s\t%s\n' "$project_id" "$provider" "${host:-}"
  done
}
