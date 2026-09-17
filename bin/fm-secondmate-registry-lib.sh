#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared parser for data/secondmates.md records.
#
# A generated local record ends with this explicit structured suffix:
#   (home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# A remote record adds its host placement before the existing fields:
#   (host: ...; root: ...; home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# Summary text and scope text are natural language and may contain parentheses
# and semicolons, so field boundaries are anchored to the suffix markers rather
# than to the first incidental punctuation.

SECONDMATE_REGISTRY_ID=
SECONDMATE_REGISTRY_SUMMARY=
SECONDMATE_REGISTRY_HOST=
SECONDMATE_REGISTRY_ROOT=
SECONDMATE_REGISTRY_HOME=
SECONDMATE_REGISTRY_SCOPE=
SECONDMATE_REGISTRY_PROJECTS=
SECONDMATE_REGISTRY_ADDED=
SECONDMATE_REGISTRY_REMOTE=0
SECONDMATE_REGISTRY_LINE=
SECONDMATE_REGISTRY_MATCH_HOST=
SECONDMATE_REGISTRY_MATCH_ROOT=
SECONDMATE_REGISTRY_MATCH_HOME=
SECONDMATE_REGISTRY_MATCH_HOME_KEY=
SECONDMATE_REGISTRY_MATCH_PROJECTS=
SECONDMATE_REGISTRY_MATCH_REMOTE=0
SECONDMATE_REGISTRY_ERROR=

secondmate_registry_lock_path() { printf '%s/.secondmate-registry.lock\n' "$1"; }
secondmate_reply_lifecycle_lock_path() { printf '%s/.remote-reply-lifecycle-%s.lock\n' "$1" "$2"; }

secondmate_registry_parse_line() {
  local line=$1
  local local_re='^- ([A-Za-z0-9._-]+) - (.+) \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  local remote_re='^- ([A-Za-z0-9._-]+) - (.+) \(host:[[:space:]]*([^;)]*);[[:space:]]*root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  SECONDMATE_REGISTRY_ID=
  SECONDMATE_REGISTRY_SUMMARY=
  SECONDMATE_REGISTRY_HOST=
  SECONDMATE_REGISTRY_ROOT=
  SECONDMATE_REGISTRY_HOME=
  SECONDMATE_REGISTRY_SCOPE=
  SECONDMATE_REGISTRY_PROJECTS=
  SECONDMATE_REGISTRY_ADDED=
  SECONDMATE_REGISTRY_REMOTE=0
  # Parse the legacy local form first so summary prose that happens to mention
  # remote field names cannot change an existing route's placement semantics.
  if [[ "$line" =~ $local_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[6]}
  elif [[ "$line" =~ $remote_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_HOST=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_ROOT=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[6]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[7]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[8]}
    SECONDMATE_REGISTRY_REMOTE=1
  else
    return 1
  fi
  [ -n "$SECONDMATE_REGISTRY_HOME" ] || return 1
  [ -n "$SECONDMATE_REGISTRY_SCOPE" ] || return 1
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    [ -n "$SECONDMATE_REGISTRY_HOST" ] || return 1
    [ -n "$SECONDMATE_REGISTRY_ROOT" ] || return 1
  fi
  return 0
}

secondmate_registry_line_for_id() {
  local reg=$1 id=$2 line count=0
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "- $id" ] || case "$line" in "- $id "*) ;; *) continue ;; esac
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    SECONDMATE_REGISTRY_LINE=$line
  done < "$reg"
  [ "$count" -eq 1 ] || return 1
  secondmate_registry_parse_line "$SECONDMATE_REGISTRY_LINE"
}

secondmate_registry_field() {
  local reg=$1 id=$2 key=$3
  secondmate_registry_line_for_id "$reg" "$id" || return 1
  case "$key" in
    host) printf '%s\n' "$SECONDMATE_REGISTRY_HOST" ;;
    root) printf '%s\n' "$SECONDMATE_REGISTRY_ROOT" ;;
    home) printf '%s\n' "$SECONDMATE_REGISTRY_HOME" ;;
    scope) printf '%s\n' "$SECONDMATE_REGISTRY_SCOPE" ;;
    projects) printf '%s\n' "$SECONDMATE_REGISTRY_PROJECTS" ;;
    remote) printf '%s\n' "$SECONDMATE_REGISTRY_REMOTE" ;;
    *) return 1 ;;
  esac
}

secondmate_registry_path_key() {
  local path=$1 parent base
  case "$path" in /*) ;; *) return 1 ;; esac
  if [ -d "$path" ]; then
    cd "$path" && pwd -P
  else
    parent=$(dirname "$path")
    base=$(basename "$path")
    cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base"
  fi
}

secondmate_registry_validate_bindings() {
  local reg=$1 resolver=$2 expected_id=${3:-} expected_home=${4:-}
  local tmp snapshot bindings line id host root home home_key duplicate_homes duplicate_ids overlaps expected_home_key
  SECONDMATE_REGISTRY_MATCH_HOST=
  SECONDMATE_REGISTRY_MATCH_ROOT=
  SECONDMATE_REGISTRY_MATCH_HOME=
  SECONDMATE_REGISTRY_MATCH_HOME_KEY=
  SECONDMATE_REGISTRY_MATCH_PROJECTS=
  SECONDMATE_REGISTRY_MATCH_REMOTE=0
  SECONDMATE_REGISTRY_ERROR=
  case "$expected_id" in *[!A-Za-z0-9._-]*) SECONDMATE_REGISTRY_ERROR="invalid secondmate id: $expected_id"; return 1 ;; esac
  if [ ! -f "$reg" ] || [ -L "$reg" ]; then
    SECONDMATE_REGISTRY_ERROR="secondmate registry is unavailable or unsafe: $reg"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-registry.XXXXXX") || {
    SECONDMATE_REGISTRY_ERROR="could not create secondmate registry validation state"
    return 1
  }
  snapshot="$tmp/registry"
  bindings="$tmp/bindings"
  if ! cat "$reg" > "$snapshot" 2>/dev/null || ! : > "$bindings"; then
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="secondmate registry is unavailable or unsafe: $reg"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        if ! secondmate_registry_parse_line "$line"; then
          rm -rf -- "$tmp"
          SECONDMATE_REGISTRY_ERROR="malformed secondmate registry entry: $line"
          return 1
        fi
        id=$SECONDMATE_REGISTRY_ID
        host=$SECONDMATE_REGISTRY_HOST
        root=$SECONDMATE_REGISTRY_ROOT
        home=$SECONDMATE_REGISTRY_HOME
        case "$home" in
          /*) ;;
          *)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe non-absolute secondmate home for $id: $home"
            return 1
            ;;
        esac
        case "$home$host$root" in
          *$'\t'*|*$'\n'*|*$'\r'*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe secondmate route for $id"
            return 1
            ;;
        esac
        if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
          case "$host" in ''|-*|*[!A-Za-z0-9._-]*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe SSH host alias for $id: $host"
            return 1
            ;;
          esac
          case "$root" in /*) ;; *)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unsafe non-absolute remote root for $id: $root"
            return 1
            ;;
          esac
          case "/$root/" in */../*|*/./*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote code root contains traversal components for $id: $root"
            return 1
            ;;
          esac
          case "/$home/" in */../*|*/./*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote home contains traversal components for $id: $home"
            return 1
            ;;
          esac
          case "$root$home" in *'//'*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote route contains an empty path component for $id"
            return 1
            ;;
          esac
          if [ "$root" = "$home" ]; then
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="overlapping remote root and home for $id: $root"
            return 1
          fi
          case "$home/" in "$root/"*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote home for $id is inside its code root: $home"
            return 1
            ;;
          esac
          case "$root/" in "$home/"*)
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="remote code root for $id is inside its home: $root"
            return 1
            ;;
          esac
          home_key="ssh:$host:$home"
        else
          home_key=$("$resolver" "$home" 2>/dev/null || true)
          if [ -z "$home_key" ]; then
            rm -rf -- "$tmp"
            SECONDMATE_REGISTRY_ERROR="unresolvable secondmate home for $id: $home"
            return 1
          fi
          home_key="local:$home_key"
        fi
        printf '%s\t%s\n' "$home_key" "$id" >> "$bindings"
        if [ -n "$expected_id" ] && [ "$id" = "$expected_id" ]; then
          SECONDMATE_REGISTRY_MATCH_HOST=$host
          SECONDMATE_REGISTRY_MATCH_ROOT=$root
          SECONDMATE_REGISTRY_MATCH_HOME=$home
          SECONDMATE_REGISTRY_MATCH_HOME_KEY=$home_key
          SECONDMATE_REGISTRY_MATCH_PROJECTS=$SECONDMATE_REGISTRY_PROJECTS
          SECONDMATE_REGISTRY_MATCH_REMOTE=$SECONDMATE_REGISTRY_REMOTE
        fi
        ;;
    esac
  done < "$snapshot"
  duplicate_homes=$(awk -F '\t' '
    {
      if ($1 in owner) {
        print $1 ": " owner[$1] ", " $2
        bad=1
      } else {
        owner[$1]=$2
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="duplicate secondmate home assignment: $duplicate_homes"
    return 1
  }
  duplicate_ids=$(awk -F '\t' '
    {
      if ($2 in home) {
        print $2 ": " home[$2] ", " $1
        bad=1
      } else {
        home[$2]=$1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="duplicate secondmate id assignment: $duplicate_ids"
    return 1
  }
  overlaps=$(awk -F '\t' '
    function ancestor(a, b) { return a != b && index(b, a "/") == 1 }
    {
      for (i = 1; i <= count; i++) {
        if (ancestor($1, path[i])) {
          print $1 " (" $2 ") contains " path[i] " (" id[i] ")"
          bad=1
        } else if (ancestor(path[i], $1)) {
          print path[i] " (" id[i] ") contains " $1 " (" $2 ")"
          bad=1
        }
      }
      count++
      path[count]=$1
      id[count]=$2
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    SECONDMATE_REGISTRY_ERROR="overlapping secondmate home assignment: $overlaps"
    return 1
  }
  rm -rf -- "$tmp"
  if [ -n "$expected_id" ] && [ -z "$SECONDMATE_REGISTRY_MATCH_HOME" ]; then
    SECONDMATE_REGISTRY_ERROR="no registry binding for secondmate $expected_id"
    return 1
  fi
  if [ -n "$expected_home" ]; then
    if [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" -eq 1 ]; then
      expected_home_key="ssh:$SECONDMATE_REGISTRY_MATCH_HOST:$expected_home"
    else
      expected_home_key=$("$resolver" "$expected_home" 2>/dev/null || true)
      [ -z "$expected_home_key" ] || expected_home_key="local:$expected_home_key"
    fi
    if [ -z "$expected_home_key" ] || [ "$expected_home_key" != "$SECONDMATE_REGISTRY_MATCH_HOME_KEY" ]; then
      SECONDMATE_REGISTRY_ERROR="secondmate $expected_id is registered at $SECONDMATE_REGISTRY_MATCH_HOME, not $expected_home"
      return 1
    fi
  fi
  return 0
}
