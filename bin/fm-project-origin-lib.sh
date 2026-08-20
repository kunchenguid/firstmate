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
# Because it owns the accepted forms, it also owns the questions a caller holding
# a clone of its own asks about that clone's origin: whether the origin is spelled
# as a path at all, and whether a spelling already anchored on THIS machine names a
# folder a landing may follow. Those are answered at the bottom of this file and
# are deliberately separate from the transport rules below, which apply only to a
# value one host hands to another.
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

# An origin a caller has ALREADY ANCHORED against the clone it belongs to is a path
# on THIS machine, so it is judged on what a local filesystem path has to be rather
# than on the transport rules fm_project_origin_safe applies to a value bound for
# another host: it must be absolute, must carry no control character, and must not
# walk through a ".." segment. A space is ordinary in a local path - a folder named
# "Job Search" sits in plenty of home directories - so it and every other ordinary
# path character are accepted here even though a transported origin may not carry
# them. NEVER ask this about a value that will be handed to another host; that
# boundary belongs to fm_project_origin_safe alone.
fm_project_origin_anchored_local_fault() { # <anchored origin>; prints what stops it being followed, nothing when nothing does
  local url=${1-}
  case $url in
    file:///?*) url=${url#file://} ;;
  esac
  case $url in
    /?*) ;;
    *) printf '%s\n' 'it does not name an absolute path' ; return 0 ;;
  esac
  case $url in
    *[[:cntrl:]]*) printf '%s\n' 'it carries a control character' ; return 0 ;;
  esac
  case "$url/" in
    */../*) printf '%s\n' 'it walks through a ".." segment' ; return 0 ;;
  esac
  return 0
}

fm_project_origin_anchored_local_path() { # <anchored origin>; prints the filesystem path, or 1 when it may not be followed
  local url=${1-}
  [ -z "$(fm_project_origin_anchored_local_fault "$url")" ] || return 1
  case $url in
    file:///?*) url=${url#file://} ;;
  esac
  printf '%s\n' "$url"
}

# A clone can name a filesystem origin the way a person types a path: relative to
# the clone, or spelled with a leading tilde. Neither is a value fm_project_origin_safe
# may accept, because a transported origin must resolve the same way on every
# machine, but a caller holding the clone the origin belongs to CAN anchor such a
# spelling before asking. This answers "is this origin spelled as a path at all",
# for both that caller (bin/fm-merge-local.sh) and the home seeding that anchors
# an origin it seeds from (normalize_origin_url in bin/fm-home-seed.sh): a colon
# only makes an origin scp-like when it precedes the first slash.
fm_project_origin_is_path_form() { # <url>; 0 when the origin names a filesystem path
  local url=${1-} prefix
  case $url in
    '') return 1 ;;
    file://*) return 0 ;;
    *://*) return 1 ;;
  esac
  case $url in
    *:*)
      prefix=${url%%:*}
      case $prefix in
        */*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 0
}
