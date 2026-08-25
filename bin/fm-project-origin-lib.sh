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
