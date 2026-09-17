#!/usr/bin/env bash
# Validate a project origin URL that one home hands to another.
#
# Firstmate supplies a project's origin instead of discovering it from a local
# clone, and the receiving host re-validates whatever reached it, so this file
# is the single owner of which origins are accepted. Nothing here discovers an
# origin, so no caller has to create a local clone just to learn one. It is
# sourced by both the sending parent (bin/fm-remote-home-seed.sh) and the
# receiving host (bin/fm-remote-home-provision.sh), so an unsafe value is
# refused at each end rather than trusted because the other end already looked
# at it.
#
# Validation is STRUCTURE AND SAFETY ONLY, never the forge or the domain.
# Firstmate is a shared template, so any host must be able to serve a project:
# GitHub, GitHub Enterprise on a private domain, GitLab hosted or self-hosted,
# Bitbucket, Gitea, Codeberg, sr.ht, a bare IP, an SSH config alias, or a plain
# server nobody else has heard of. There is no host, domain, or forge allowlist
# here, and there must never be one.
#
# Accepted forms:
#   https://[userinfo@]host[:port]/path, http://…, ssh://…, git://…
#                                 a non-option-shaped plain host or bracketed
#                                 IPv6 literal, an optional numeric port, and
#                                 any path
#   file:///path                  a repository this host can reach as a file
#   [user@]host:path              scp-like syntax; host may be a name, an SSH
#                                 config alias, an IPv4 address, or a bracketed
#                                 IPv6 literal such as [2001:db8::1]
#   /absolute/path                a repository on the cloning host's filesystem
#
# Refused:
#   remote-helper transports such as "ext::<command>", which git executes as a
#   command whenever the cloning host's protocol configuration permits it, and
#   the sending home cannot see that configuration
#   any other unknown scheme
#   option-shaped values a later command line could absorb as a flag
#   whitespace and control characters, including embedded newlines
#   relative paths, which resolve against whatever directory git happens to
#   be in on the other machine
#   "/../" traversal inside a local or file: path
fm_project_origin_safe() { # <url>; 0 when the URL is an accepted clone URL
  local url=${1-} rest authority userpart hostpart port inner host path

  case $url in
    '' | -*) return 1 ;;
  esac
  case $url in
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac

  case $url in
    https://?* | http://?* | ssh://?* | git://?*)
      rest=${url#*://}
      authority=${rest%%/*}
      case $authority in
        '') return 1 ;;
      esac

      hostpart=$authority
      case $authority in
        *@*)
          userpart=${authority%@*}
          hostpart=${authority##*@}
          case $userpart in
            '' | -* | *'['* | *']'*) return 1 ;;
          esac
          ;;
      esac

      case $hostpart in
        '['*)
          case $hostpart in
            *']'*) ;;
            *) return 1 ;;
          esac
          host=${hostpart%%']'*}']'
          port=${hostpart#"$host"}
          inner=${host#'['}
          inner=${inner%']'}
          case $inner in
            *:*) ;;
            *) return 1 ;;
          esac
          case $inner in
            *[!0-9A-Fa-f:.%]*) return 1 ;;
          esac
          case $port in
            '') ;;
            :?*)
              port=${port#:}
              case $port in
                *[!0-9]*) return 1 ;;
              esac
              ;;
            *) return 1 ;;
          esac
          ;;
        *)
          case $hostpart in
            *'['* | *']'*) return 1 ;;
          esac
          host=${hostpart%%:*}
          case $host in
            '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
          esac
          if [[ $hostpart == *:* ]]; then
            port=${hostpart#*:}
            case $port in
              '' | *[!0-9]*) return 1 ;;
            esac
          fi
          ;;
      esac
      return 0
      ;;
    file:///?*)
      case "/${url#file://}/" in
        */../*) return 1 ;;
      esac
      return 0
      ;;
    /?*)
      case "/$url/" in
        */../*) return 1 ;;
      esac
      return 0
      ;;
    *://*) return 1 ;;
  esac

  # scp-like [user@]host:path. Strip the user only when its "@" really precedes
  # the host, so a path that merely contains "@" keeps its own colon boundary.
  rest=$url
  case $url in
    *@*)
      userpart=${url%%@*}
      case $userpart in
        *:*) ;;
        *) rest=${url#*@} ;;
      esac
      ;;
  esac

  case $rest in
    '['*)
      hostpart=${rest%%']'*}']'
      path=${rest#"$hostpart"}
      case $path in
        :?*) path=${path#:} ;;
        *) return 1 ;;
      esac
      inner=${hostpart#'['}
      inner=${inner%']'}
      # A bracketed host is only meaningful as an IPv6 literal, so require its
      # colon rather than accepting brackets around an arbitrary string.
      case $inner in
        *:*) ;;
        *) return 1 ;;
      esac
      case $inner in
        *[!0-9A-Fa-f:.%]*) return 1 ;;
      esac
      return 0
      ;;
  esac

  case $rest in
    *:*) ;;
    *) return 1 ;;
  esac
  host=${rest%%:*}
  path=${rest#*:}
  case $host in
    '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case $path in
    '' | :*) return 1 ;;
  esac
  return 0
}

# Forge routing is deliberately separate from clone-URL validation above.
# A clone URL is not enough to prove which forge owns an arbitrary host, so
# GitHub is recognized only by github.com and a self-hosted GitLab host is
# recognized only when glab has configured or authenticated that exact host.
# Callers use the result only to render worker instructions; no TLS setting is
# changed and no forge is guessed from a repository name.
FM_PROJECT_FORGE=
FM_PROJECT_FORGE_HOST=
FM_PROJECT_FORGE_ERROR=

fm_project_origin_host() { # <origin>; prints bare host, or local for local origins
  local url=${1-} rest authority hostpart host
  fm_project_origin_safe "$url" || return 1
  case "$url" in
    /?*|file:///?*)
      printf '%s\n' local
      return 0
      ;;
    https://?*|http://?*|ssh://?*|git://?*)
      rest=${url#*://}
      authority=${rest%%/*}
      hostpart=${authority##*@}
      case "$hostpart" in
        '['*']'*)
          host=${hostpart%%']'*}']'
          host=${host#'['}
          host=${host%']'}
          ;;
        *)
          host=${hostpart%%:*}
          ;;
      esac
      ;;
    *)
      rest=${url%%:*}
      case "$rest" in
        *@*) rest=${rest##*@} ;;
      esac
      host=$rest
      ;;
  esac
  [ -n "${host:-}" ] || return 1
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]'
}

fm_project_origin_endpoint() { # <origin>; prints host plus a relevant port
  local url=${1-} rest authority hostpart host port scheme bracketed=0 default_port
  fm_project_origin_safe "$url" || return 1
  case "$url" in
    /?*|file:///?*)
      printf '%s\n' local
      return 0
      ;;
    https://?*|http://?*|ssh://?*|git://?*)
      scheme=${url%%://*}
      rest=${url#*://}
      authority=${rest%%/*}
      hostpart=${authority##*@}
      case "$hostpart" in
        '['*']'*)
          bracketed=1
          host=${hostpart%%']'*}']'
          host=${host#'['}
          host=${host%']'}
          port=${hostpart#*']'}
          port=${port#:}
          ;;
        *)
          host=${hostpart%%:*}
          port=
          case "$hostpart" in
            *:*) port=${hostpart#*:} ;;
          esac
          ;;
      esac
      case "$scheme" in
        https) default_port=443 ;;
        http) default_port=80 ;;
        ssh) default_port=22 ;;
        git) default_port=9418 ;;
        *) default_port= ;;
      esac
      if [ -n "$port" ] && [ "$port" != "$default_port" ]; then
        if [ "$bracketed" -eq 1 ]; then
          host="[$host]:$port"
        else
          host="$host:$port"
        fi
      fi
      ;;
    *)
      host=$(fm_project_origin_host "$url") || return 1
      ;;
  esac
  [ -n "${host:-}" ] || return 1
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]'
}

fm_project_gh_config_has_host() { # <host>; local evidence only
  local host=$1 home=${HOME:-} xdg=${XDG_CONFIG_HOME:-} file
  local -a files
  files=()
  [ -n "${GH_CONFIG_DIR:-}" ] && files+=("$GH_CONFIG_DIR/hosts.yml")
  [ -n "$xdg" ] && files+=("$xdg/gh/hosts.yml")
  [ -n "$home" ] && files+=("$home/.config/gh/hosts.yml")
  [ -n "$home" ] && files+=("$home/Library/Application Support/gh/hosts.yml")
  for file in "${files[@]}"; do
    [ -f "$file" ] && [ -r "$file" ] || continue
    awk -v target="$host" '
      /^[^[:space:]#][^:]*:[[:space:]]*$/ {
        key=$0
        sub(/:.*/, "", key)
        gsub(/[[:space:]]/, "", key)
        if (key == target) found=1
      }
      END { exit !found }
    ' "$file" && return 0
  done
  return 1
}

fm_project_glab_config_has_host() { # <host>; local evidence only
  local host=$1 home=${HOME:-} xdg=${XDG_CONFIG_HOME:-} file
  local -a files
  files=()
  [ -n "${GLAB_CONFIG_DIR:-}" ] && files+=("$GLAB_CONFIG_DIR/config.yml")
  [ -n "$xdg" ] && files+=("$xdg/glab-cli/config.yml")
  [ -n "$home" ] && files+=("$home/.config/glab-cli/config.yml")
  [ -n "$home" ] && files+=("$home/Library/Application Support/glab-cli/config.yml")
  [ -n "$home" ] && files+=("$home/Library/Preferences/glab-cli/config.yml")
  for file in "${files[@]}"; do
    [ -f "$file" ] && [ -r "$file" ] || continue
    awk -v target="$host" '
      /^hosts:[[:space:]]*$/ { in_hosts=1; next }
      in_hosts && /^[^[:space:]#]/ { in_hosts=0 }
      in_hosts && substr($0, 1, 4) == "    " {
        key=substr($0, 5)
        sub(/:.*/, "", key)
        gsub(/[[:space:]]/, "", key)
        if (key == target) found=1
      }
      END { exit !found }
    ' "$file" && return 0
  done
  return 1
}

fm_project_forge_from_origin() { # <origin>; sets FM_PROJECT_FORGE[_HOST]
  local origin=${1-} host endpoint evidence_host gitlab_host
  FM_PROJECT_FORGE=
  FM_PROJECT_FORGE_HOST=
  FM_PROJECT_FORGE_ERROR=
  host=$(fm_project_origin_host "$origin" 2>/dev/null) || {
    FM_PROJECT_FORGE_ERROR="origin is not an accepted clone URL: ${origin:-<empty>}"
    return 1
  }
  endpoint=$(fm_project_origin_endpoint "$origin" 2>/dev/null) || {
    FM_PROJECT_FORGE_ERROR="origin endpoint could not be established: ${origin:-<empty>}"
    return 1
  }
  FM_PROJECT_FORGE_HOST=$endpoint
  case "$endpoint" in
    local)
      FM_PROJECT_FORGE=local
      return 0
      ;;
    github.com)
      FM_PROJECT_FORGE=github
      return 0
      ;;
    gitlab.com)
      FM_PROJECT_FORGE=gitlab
      return 0
      ;;
  esac
  # A non-default port is part of the forge identity. Authentication evidence
  # must name that exact endpoint rather than proving only that another service
  # on the same hostname is configured.
  evidence_host=$endpoint
  local gh_evidence=0 glab_evidence=0
  if fm_project_gh_config_has_host "$evidence_host" ||
    { command -v gh >/dev/null 2>&1 && gh auth status --hostname "$evidence_host" >/dev/null 2>&1; }; then
    gh_evidence=1
  fi
  gitlab_host=${GITLAB_HOST:-}
  gitlab_host=$(printf '%s' "$gitlab_host" | tr '[:upper:]' '[:lower:]')
  if fm_project_glab_config_has_host "$evidence_host" ||
    { [ -n "$gitlab_host" ] && [ "$gitlab_host" = "$evidence_host" ]; } ||
    { command -v glab >/dev/null 2>&1 && glab auth status --hostname "$evidence_host" >/dev/null 2>&1; }; then
    glab_evidence=1
  fi
  if [ "$gh_evidence" -eq 1 ] && [ "$glab_evidence" -eq 1 ]; then
    FM_PROJECT_FORGE_ERROR="origin host '$endpoint' is configured as both GitHub and GitLab; the forge is ambiguous"
    return 1
  fi
  if [ "$gh_evidence" -eq 1 ]; then
    FM_PROJECT_FORGE=github
    return 0
  fi
  if [ "$glab_evidence" -eq 1 ]; then
    FM_PROJECT_FORGE=gitlab
    return 0
  fi
  FM_PROJECT_FORGE_ERROR="origin host '$endpoint' is not recognized as GitHub or an authenticated GitLab instance"
  return 1
}

fm_project_forge_from_repo() { # <repo>; sets FM_PROJECT_FORGE[_HOST]
  local repo=$1 url pushurl identity first_identity first_origin found=0
  FM_PROJECT_FORGE=
  FM_PROJECT_FORGE_HOST=
  FM_PROJECT_FORGE_ERROR=
  [ -d "$repo" ] || {
    FM_PROJECT_FORGE_ERROR="project directory is missing or unreadable: $repo"
    return 1
  }
  first_origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  [ -n "$first_origin" ] || {
    FM_PROJECT_FORGE_ERROR="project has no origin remote, so its forge cannot be established"
    return 1
  }
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    fm_project_forge_from_origin "$url" || return 1
    identity="$FM_PROJECT_FORGE:$FM_PROJECT_FORGE_HOST"
    if [ "$found" -eq 0 ]; then
      first_identity=$identity
      first_origin=$url
      found=1
    elif [ "$identity" != "$first_identity" ]; then
      FM_PROJECT_FORGE=
      FM_PROJECT_FORGE_HOST=
      FM_PROJECT_FORGE_ERROR="origin has conflicting forge routes; '$first_origin' and '$url' do not identify one forge"
      return 1
    fi
  done <<EOF
$(git -C "$repo" remote get-url --all origin 2>/dev/null || true)
EOF
  while IFS= read -r pushurl; do
    [ -n "$pushurl" ] || continue
    fm_project_forge_from_origin "$pushurl" || return 1
    identity="$FM_PROJECT_FORGE:$FM_PROJECT_FORGE_HOST"
    if [ "$identity" != "$first_identity" ]; then
      FM_PROJECT_FORGE=
      FM_PROJECT_FORGE_HOST=
      FM_PROJECT_FORGE_ERROR="origin and pushurl identify different forge routes; '$first_origin' and '$pushurl' are ambiguous"
      return 1
    fi
  done <<EOF
$(git -C "$repo" remote get-url --push --all origin 2>/dev/null || true)
EOF
  [ "$found" -eq 1 ] || {
    FM_PROJECT_FORGE_ERROR="project has no usable origin URL, so its forge cannot be established"
    return 1
  }
  # Re-assert the selected result because the pushurl loop's final successful
  # classification is otherwise allowed to overwrite only equivalent values.
  FM_PROJECT_FORGE=${first_identity%%:*}
  FM_PROJECT_FORGE_HOST=${first_identity#*:}
}

fm_project_forge_instructions() { # <resolved|ambiguous>; prints launch text
  local mode=${1:-resolved} error=${FM_PROJECT_FORGE_ERROR:-forge identity is unavailable} github_host_line=
  if [ "$mode" != resolved ] || [ -z "${FM_PROJECT_FORGE:-}" ]; then
    cat <<EOF
# Resolved forge operations
Forge identity is ambiguous or unavailable: $error.
Do not guess a forge CLI, disable TLS verification, publish a branch, or open a PR/MR from this route; stop and report this concrete ambiguity to firstmate.
EOF
    return 0
  fi
  case "$FM_PROJECT_FORGE" in
    github)
      if [ "$FM_PROJECT_FORGE_HOST" != github.com ]; then
        github_host_line="For GitHub Enterprise, pass \`--hostname $FM_PROJECT_FORGE_HOST\` to gh-axi commands; do not assume github.com."
      fi
      cat <<EOF
# Resolved forge operations
The project's origin identifies GitHub at $FM_PROJECT_FORGE_HOST.
Use \`gh-axi\` for GitHub operations and ordinary \`git push\` for branch publication.
$github_host_line
Do not use \`glab\` for this project.
EOF
      ;;
    gitlab)
      cat <<EOF
# Resolved forge operations
The project's origin identifies GitLab at $FM_PROJECT_FORGE_HOST.
Use authenticated \`glab\` for GitLab operations against $FM_PROJECT_FORGE_HOST and ordinary \`git push\` for branch publication; do not substitute gitlab.com.
Do not use \`gh-axi\` for this project, and never disable TLS certificate verification.
If glab authentication or the server certificate is not usable, stop and report that concrete blocker to firstmate.
EOF
      ;;
    local)
      cat <<EOF
# Resolved forge operations
The project's origin is a local repository at $FM_PROJECT_FORGE_HOST.
No forge CLI is available for this route; use ordinary \`git\` only when the delivery contract permits a local remote, and do not guess GitHub or GitLab.
EOF
      ;;
    *)
      FM_PROJECT_FORGE_ERROR="unsupported forge classification '$FM_PROJECT_FORGE'"
      fm_project_forge_instructions ambiguous
      ;;
  esac
}
