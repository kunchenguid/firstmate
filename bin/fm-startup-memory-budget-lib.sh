# shellcheck shell=bash
# Startup-memory budget primitives.
# Usage: . bin/fm-startup-memory-budget-lib.sh
#
# The local, primary-authoritative config/startup-memory-budget setting is one
# strictly formatted positive decimal value followed by one newline.  The
# locked primary bootstrap owns first materialization.  This library owns safe
# parsing, default publication, and the portable prompt-memory estimate used by
# bin/fm-startup-memory-budget.sh and the internal /stow skill.

FM_STARTUP_MEMORY_BUDGET_FILE="startup-memory-budget"
FM_STARTUP_MEMORY_BUDGET_DEFAULT="7500"
FM_STARTUP_MEMORY_BUDGET_ERROR=""
FM_STARTUP_MEMORY_BUDGET_VALUE=""
FM_STARTUP_MEMORY_MEASURE_BYTES=""
FM_STARTUP_MEMORY_MEASURE_TOKENS=""
FM_STARTUP_MEMORY_MEASURE_PRESENCE=""

fm_startup_memory_budget_fail() {
  FM_STARTUP_MEMORY_BUDGET_ERROR=$1
  return 1
}

fm_startup_memory_budget_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# fm_startup_memory_budget_resolve <path>
# Prints <path> with every symlink resolved, so the safety checks below apply
# to the real target rather than to the link.  A symlink is a legitimate local
# layout (an operator may keep private config in a separate tree and link it
# into the home); the property worth enforcing is that whatever the name finally
# names is an ordinary, single-linked, well-formed artifact.  Fails on a broken
# or cyclic chain.  BSD and GNU userlands disagree about `realpath` and
# `readlink -f`, so the chain is walked here instead of shelling out to either.
fm_startup_memory_budget_resolve() {
  local path=$1 depth=0 target parent base
  while [ -L "$path" ]; do
    if [ "$depth" -ge 40 ]; then
      return 1
    fi
    target=$(readlink "$path") || return 1
    case "$target" in
      /*) path=$target ;;
      *) path="$(dirname -- "$path")/$target" ;;
    esac
    depth=$((depth + 1))
  done
  parent=$(dirname -- "$path")
  base=$(basename -- "$path")
  parent=$(cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  case "$parent" in
    */) printf '%s%s\n' "$parent" "$base" ;;
    *) printf '%s/%s\n' "$parent" "$base" ;;
  esac
}

fm_startup_memory_budget_config_dir_safe() {
  local dir=$1 resolved
  resolved=$(fm_startup_memory_budget_resolve "$dir") || {
    fm_startup_memory_budget_fail "config directory link could not be resolved"
    return 1
  }
  if [ ! -d "$resolved" ]; then
    fm_startup_memory_budget_fail "config directory is not a directory"
    return 1
  fi
  return 0
}

# fm_startup_memory_budget_file_valid <path>
# Sets FM_STARTUP_MEMORY_BUDGET_VALUE only when <path> finally names a regular,
# single-linked file containing exactly one positive decimal value and one
# terminating newline.  Symlinks are resolved first and every check applies to
# the resolved target; the hardlink-count check below is the anti-substitution
# guard, and it is strictly stronger than refusing the link itself.
fm_startup_memory_budget_file_valid() {
  local path=$1 resolved links value
  FM_STARTUP_MEMORY_BUDGET_VALUE=""
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    fm_startup_memory_budget_fail "file is absent"
    return 1
  fi
  resolved=$(fm_startup_memory_budget_resolve "$path") || {
    fm_startup_memory_budget_fail "file link could not be resolved"
    return 1
  }
  if [ ! -e "$resolved" ]; then
    fm_startup_memory_budget_fail "file is absent"
    return 1
  fi
  if [ ! -f "$resolved" ]; then
    fm_startup_memory_budget_fail "file is not a regular file"
    return 1
  fi
  links=$(fm_startup_memory_budget_link_count "$resolved") || {
    fm_startup_memory_budget_fail "could not inspect file link count"
    return 1
  }
  if [ "$links" != 1 ]; then
    fm_startup_memory_budget_fail "file is hardlinked"
    return 1
  fi
  value=$(<"$resolved") || {
    fm_startup_memory_budget_fail "could not read file"
    return 1
  }
  case "$value" in
    ''|0|*[!0-9]*|0*)
      fm_startup_memory_budget_fail "value must be one positive decimal integer"
      return 1
      ;;
  esac
  if ! printf '%s\n' "$value" | cmp -s "$resolved" -; then
    fm_startup_memory_budget_fail "file must contain exactly one value followed by one newline"
    return 1
  fi
  FM_STARTUP_MEMORY_BUDGET_VALUE=$value
  return 0
}

# fm_startup_memory_budget_read <config-dir>
# Prints the validated decimal value.  It never treats an absent or unsafe file
# as an implicit default because callers need a visible, auditable setting.
fm_startup_memory_budget_read() {
  local config_dir=$1 path
  fm_startup_memory_budget_config_dir_safe "$config_dir" || return 1
  path="$config_dir/$FM_STARTUP_MEMORY_BUDGET_FILE"
  fm_startup_memory_budget_file_valid "$path" || return 1
  printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_VALUE"
}

# fm_startup_memory_budget_materialize <config-dir>
# Atomically publishes the visible default only when the file is absent.  A
# concurrent valid creator is accepted; every unsafe or malformed existing
# artifact is rejected without replacement.
fm_startup_memory_budget_materialize() {
  local config_dir=$1 path tmp
  if [ -e "$config_dir" ] || [ -L "$config_dir" ]; then
    fm_startup_memory_budget_config_dir_safe "$config_dir" || return 1
  else
    mkdir -p "$config_dir" 2>/dev/null || {
      fm_startup_memory_budget_fail "could not create config directory"
      return 1
    }
    fm_startup_memory_budget_config_dir_safe "$config_dir" || return 1
  fi

  path="$config_dir/$FM_STARTUP_MEMORY_BUDGET_FILE"
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_startup_memory_budget_read "$config_dir" >/dev/null || return 1
    return 0
  fi

  tmp=$(umask 077; mktemp "$config_dir/.startup-memory-budget.XXXXXX" 2>/dev/null) || {
    fm_startup_memory_budget_fail "could not create default temporary file"
    return 1
  }
  if ! printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_DEFAULT" > "$tmp" \
    || ! fm_startup_memory_budget_file_valid "$tmp"; then
    rm -f "$tmp"
    [ -n "$FM_STARTUP_MEMORY_BUDGET_ERROR" ] \
      || fm_startup_memory_budget_fail "could not write default value"
    return 1
  fi

  # link(2) gives no-clobber publication in this directory.  Removing the
  # temporary name leaves the published file with exactly one link.
  if ln "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    fm_startup_memory_budget_read "$config_dir" >/dev/null || return 1
    return 0
  fi
  rm -f "$tmp"
  # Another actor may have created the file.  Accept it only if it now meets
  # the same safe, exact format - never replace or guess at it.
  fm_startup_memory_budget_read "$config_dir" >/dev/null
}

# fm_startup_memory_estimated_tokens_for_bytes <non-negative bytes>
# The estimate is ceil(UTF-8 bytes / 3): stable, dependency-free, and
# deliberately conservative for ordinary prompt text without claiming provider
# exactness.
fm_startup_memory_estimated_tokens_for_bytes() {
  local bytes=$1 tokens
  case "$bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  tokens=$((bytes / 3))
  if [ $((bytes % 3)) -ne 0 ]; then
    tokens=$((tokens + 1))
  fi
  printf '%s\n' "$tokens"
}

# fm_startup_memory_measure_file <path>
# Prints "<bytes> <estimated-tokens> <present|absent>".  Symlinks are resolved
# first and the resolved target must be an ordinary regular file, so a
# measurement still never reads a special file, a directory, or a broken link,
# while a memory file legitimately linked into the home is measured normally.
fm_startup_memory_measure_file() {
  local path=$1 resolved bytes tokens
  FM_STARTUP_MEMORY_MEASURE_BYTES=""
  FM_STARTUP_MEMORY_MEASURE_TOKENS=""
  FM_STARTUP_MEMORY_MEASURE_PRESENCE=""
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    FM_STARTUP_MEMORY_MEASURE_BYTES=0
    FM_STARTUP_MEMORY_MEASURE_TOKENS=0
    FM_STARTUP_MEMORY_MEASURE_PRESENCE=absent
    printf '0 0 absent\n'
    return 0
  fi
  resolved=$(fm_startup_memory_budget_resolve "$path") || {
    fm_startup_memory_budget_fail "memory file link could not be resolved: $path"
    return 1
  }
  if [ ! -f "$resolved" ]; then
    fm_startup_memory_budget_fail "memory file is not an ordinary regular file: $path"
    return 1
  fi
  bytes=$(LC_ALL=C wc -c < "$resolved" 2>/dev/null | tr -d '[:space:]') || {
    fm_startup_memory_budget_fail "could not measure memory file: $path"
    return 1
  }
  case "$bytes" in
    ''|*[!0-9]*)
      fm_startup_memory_budget_fail "invalid byte count for memory file: $path"
      return 1
      ;;
  esac
  tokens=$(fm_startup_memory_estimated_tokens_for_bytes "$bytes") || {
    fm_startup_memory_budget_fail "could not estimate memory tokens for: $path"
    return 1
  }
  # shellcheck disable=SC2034 # Public measurement result consumed by the caller after sourcing.
  FM_STARTUP_MEMORY_MEASURE_BYTES=$bytes
  # shellcheck disable=SC2034 # Public measurement result consumed by the caller after sourcing.
  FM_STARTUP_MEMORY_MEASURE_TOKENS=$tokens
  # shellcheck disable=SC2034 # Public measurement result consumed by the caller after sourcing.
  FM_STARTUP_MEMORY_MEASURE_PRESENCE=present
  printf '%s %s present\n' "$bytes" "$tokens"
}

# fm_startup_memory_decimal_le <left> <right>
# Decimal comparison without shell arithmetic overflow.  Inputs are normalized
# non-negative decimal strings.
fm_startup_memory_decimal_le() {
  local left=$1 right=$2 left_len right_len
  case "$left:$right" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  left_len=${#left}
  right_len=${#right}
  if [ "$left_len" -lt "$right_len" ]; then
    return 0
  fi
  if [ "$left_len" -gt "$right_len" ]; then
    return 1
  fi
  [ "$left" = "$right" ] && return 0
  [[ "$left" < "$right" ]]
}
