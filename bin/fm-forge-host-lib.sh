#!/usr/bin/env bash
# Resolve a supplied origin's authentication host without making a forge request.
# fm_forge_origin_host <url> [gitlab] prints the lowercased host, or returns 1
# for a local path or unsafe authority. SSH origins use ssh -G's HostName when
# available, with hostname canonicalization disabled to keep this a local read.
# A host explicitly configured in glab remains its login/configuration key even
# when SSH connects to a different transport address.
# fm_forge_glab_config_file and fm_forge_glab_config_lists_host own the local
# glab host-key lookup shared by intake proposals and bootstrap authentication.

fm_forge_glab_config_file() {
  if [ -n "${GLAB_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$GLAB_CONFIG_DIR/config.yml"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/glab-cli/config.yml"
  fi
}

fm_forge_glab_config_lists_host() {  # <file> <host>
  [ -f "$1" ] && [ -r "$1" ] || return 1
  awk -v want="$2" '
    /^hosts:[[:space:]]*$/ { inside = 1; indent = ""; next }
    inside && /^[^[:space:]#]/ { exit }
    inside && /^[[:space:]]+[^[:space:]#]/ {
      match($0, /^[[:space:]]+/)
      lead = substr($0, 1, RLENGTH)
      if (indent == "") indent = lead
      if (lead != indent) next
      key = substr($0, RLENGTH + 1)
      sub(/:.*$/, "", key)
      gsub(/^["\047]|["\047]$/, "", key)
      if (tolower(key) == want) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

fm_forge_origin_host() {  # <url> [gitlab]
  local url=$1 forge=${2:-} authority target host port='' resolved ssh_origin=0
  case "$url" in
    ''|*[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
    ssh://*) authority=${url#ssh://}; authority=${authority%%/*}; ssh_origin=1 ;;
    *://*) authority=${url#*://}; authority=${authority%%/*} ;;
    /*|.*) return 1 ;;
    *:*) authority=${url%%:*}; case "$authority" in */*) return 1 ;; esac; ssh_origin=1 ;;
    *) return 1 ;;
  esac
  target=$authority
  host=${authority##*@}
  case "$host" in
    *:*) port=${host#*:}; host=${host%%:*}; target=${authority%:*} ;;
  esac
  case "$host" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ "$ssh_origin" = 1 ]; then
    case "$target" in -*|*[!A-Za-z0-9._@-]*) return 1 ;; esac
  fi
  case "$port" in *[!0-9]*) return 1 ;; esac
  host=$(printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]')
  if [ "$forge" = gitlab ] && fm_forge_glab_config_lists_host "$(fm_forge_glab_config_file)" "$host"; then
    printf '%s\n' "$host"
    return 0
  fi
  if [ "$ssh_origin" = 1 ] && command -v ssh >/dev/null 2>&1; then
    local -a ssh_args=(-G -o CanonicalizeHostname=no -o BatchMode=yes)
    [ -z "$port" ] || ssh_args+=(-p "$port")
    resolved=$(ssh "${ssh_args[@]}" -- "$target" 2>/dev/null | awk 'tolower($1) == "hostname" { print tolower($2); exit }') || resolved=''
    case "$resolved" in
      ''|-*|*[!a-z0-9._-]*) ;;
      *) host=$resolved ;;
    esac
  fi
  printf '%s\n' "$host"
}
