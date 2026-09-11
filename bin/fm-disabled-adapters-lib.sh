# shellcheck shell=bash
# Shared reader for the tracked, one-name-per-line disabled-adapters policy.
# Callers set FM_DISABLED_ADAPTERS_CONFIG to their effective config path before
# sourcing this file.

fm_disabled_adapter_matches() {  # <requested-name> <configured-name>
  case "$1:$2" in
    cursor-agent:cursor|cursor:cursor-agent) return 0 ;;
    *) [ "$1" = "$2" ] ;;
  esac
}

# fm_disabled_adapter: returns 0 when <name> is disabled, 1 when it is not, and
# 2 when the policy file cannot be safely read.
fm_disabled_adapter() {  # <name>
  local name=$1 line config=${FM_DISABLED_ADAPTERS_CONFIG:-} matched=1
  [ -n "$config" ] || return 1
  [ -e "$config" ] || return 1
  if [ ! -f "$config" ] || [ -L "$config" ]; then
    printf 'error: disabled adapters config must be a regular file: %s\n' "$config" >&2
    return 2
  fi
  [ -r "$config" ] || {
    printf 'error: cannot read disabled adapters config: %s\n' "$config" >&2
    return 2
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      *[!a-z0-9-]*)
        printf 'error: invalid disabled adapter in %s: %s\n' "$config" "$line" >&2
        return 2
        ;;
    esac
    if fm_disabled_adapter_matches "$name" "$line"; then
      matched=0
      break
    fi
  done < "$config"
  return "$matched"
}
