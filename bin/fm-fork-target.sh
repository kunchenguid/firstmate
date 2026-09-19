#!/usr/bin/env bash
# fm-fork-target.sh - resolve this home's writable push target for a clone, and
# initialize the no-mistakes gate against it.
#
# Why this exists: the no-mistakes gate pushes a validated branch to the repo
# the gate was initialized against, which `no-mistakes init` takes from the
# clone's `origin`. When this home's authenticated forge account has only read
# access to that repo - the ordinary contributor shape CONTRIBUTING.md already
# documents - every run reaches its `push` step with a 403 and the whole run is
# recorded failed, although the code validated. `no-mistakes init --fork-url` is
# the supported fix, and this script is the ONE owner of which url firstmate
# passes there, so a clone is never initialized against a target this home
# cannot write and no worker has to rediscover the fork by hand.
#
# Usage:
#   fm-fork-target.sh resolve <dir>   print the fork push url for <dir>, or
#                                     nothing when this home pushes to origin
#   fm-fork-target.sh matches <dir>   succeed when the registered fork target
#                                     matches the current local declaration
#   fm-fork-target.sh init <dir>      run `no-mistakes init` against the
#                                     resolved target, then `no-mistakes doctor`
#
# `init` exit status, which callers are expected to discriminate:
#   0  the gate is initialized against the resolved target
#   1  something is wrong and the caller must stop: resolution errored, the
#      declaration is unusable, or a DECLARED fork url could not be initialized,
#      including when `no-mistakes` itself is not installed
#   4  ADVISORY - no fork url is declared here, so the target is origin, and
#      preparing that gate failed, `no-mistakes` being absent included. The
#      declared-target guarantee is not at stake, so a caller whose own work is
#      not a push may warn and continue.
#      The guard against pushing to an unwritable target lives at push time, in
#      the generated worker instructions and in `no-mistakes init` itself; this
#      status only says the gate was not freshly prepared here.
#
# Resolution uses only the local config/fork-url declaration:
#   1. config/fork-url - a complete push url used verbatim and inherited by
#      secondmate homes.
#   2. Nothing - the maintainer shape, where origin itself is writable. The
#      gate is then initialized exactly as it was before this script existed.
# A configured and usable target is printed with exit 0. No declaration prints
# nothing with exit 0. An unusable declaration or internal error prints nothing
# on stdout, names the problem on stderr, and exits non-zero; non-zero never
# means no fork.
# config/fork-url must contain EXACTLY ONE line, whether or not that line carries
# a terminating newline; a second line makes the declaration unusable rather than
# silently ignored. Its value accepts https/http/ssh/git+ssh/file URLs with a
# host and path, or a standard user@host:path push URL; accepted values are never
# rewritten.
#
# `no-mistakes init` refreshes an existing registration, so `init` is also the
# repair path for a home whose gate was already initialized against an
# unwritable origin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  echo "usage: fm-fork-target.sh resolve|matches|init <dir>" >&2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

fork_url_invalid_reason() {  # <url>
  case "$1" in
    '') printf 'it is empty' ;;
    *[[:space:]]*) printf 'it contains whitespace' ;;
    *://*) printf 'it uses an unsupported scheme' ;;
    *) printf 'it is not an absolute remote URL or scp-like push URL' ;;
  esac
}

config_token() {  # <name>
  local path="$CONFIG/$1" label="config/$1" state raw_status
  config_path_state "$label" "$CONFIG"; state=$?
  case "$state" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  [ -d "$CONFIG" ] || { config_observe_error "$label" "$CONFIG" "path is not a directory"; return 2; }
  [ ! -L "$CONFIG" ] || { config_observe_error "$label" "$CONFIG" "configuration directory is a symlink"; return 2; }
  [ -r "$CONFIG" ] || { config_observe_error "$label" "$CONFIG" "configuration directory is not readable"; return 2; }
  [ -x "$CONFIG" ] || { config_observe_error "$label" "$CONFIG" "configuration directory is not searchable"; return 2; }
  config_path_state "$label" "$path"; state=$?
  case "$state" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  [ -f "$path" ] || { config_observe_error "$label" "$path" "path is not a regular file"; return 2; }
  [ ! -L "$path" ] || { config_observe_error "$label" "$path" "declaration is a symlink"; return 2; }
  [ -r "$path" ] || { config_observe_error "$label" "$path" "declaration is not readable"; return 2; }
  perl -e '
    my ($label, $path) = @ARGV;
    sub observe_error {
      my ($reason) = @_;
      printf STDERR "error: could not observe %s at %s: %s\n", $label, $path, $reason;
      exit 2;
    }
    open my $fh, "<:raw", $path or observe_error("read failed: $!");
    local $/;
    my $bytes = <$fh>;
    defined $bytes or observe_error("read failed");
    close $fh or observe_error("read failed: $!");
    my $raw_bytes = $bytes;
    sub hex_render {
      my ($bytes) = @_;
      my $limit = 4096;
      my $truncated = length($bytes) > $limit;
      my $shown = $truncated ? substr($bytes, 0, $limit) : $bytes;
      my $hex = unpack("H*", $shown);
      return $truncated ? "$hex... (truncated)" : $hex;
    }
    if ($bytes =~ /[\x00-\x09\x0B-\x1F\x7F]/) {
      printf STDERR "error: %s value (hex: %s) is unusable: it contains a NUL or control byte\n", $label, hex_render($bytes);
      exit 4;
    }
    $bytes =~ s/\n\z//;
    if ($bytes =~ /\n/) {
      printf STDERR "error: %s value (hex: %s) is unusable: it must contain exactly one line\n", $label, hex_render($raw_bytes);
      exit 3;
    }
    print $bytes;
  ' -- "$label" "$path"
  raw_status=$?
  case "$raw_status" in
    0|3|4) return "$raw_status" ;;
    *) return 2 ;;
  esac
}

config_path_state() {
  perl -MErrno=ENOENT -e '
    my ($label, $path) = @ARGV;
    if (lstat $path) {
      exit 0;
    }
    if ($! == ENOENT) {
      exit 1;
    }
    printf STDERR "error: could not observe %s at %s: %s\n", $label, $path, $!;
    exit 2;
  ' -- "$1" "$2"
}

config_observe_error() {
  printf 'error: could not observe %s at %s: %s\n' "$1" "$2" "$3" >&2
}

fork_url_validate() {  # <url>
  local url=${1:-} rest authority path user host
  case "$url" in *[[:space:]]*) return 1 ;; esac
  case "$url" in
    https://*|http://*|ssh://*|git+ssh://*)
      rest=${url#*://}
      case "$rest" in
        */*)
          authority=${rest%%/*}
          path=${rest#*/}
          host=${authority##*@}
          [ -n "$host" ] && [ -n "$path" ] || return 2
          case "$host" in :*) return 2 ;; esac
          return 0
          ;;
        *) return 2 ;;
      esac
      ;;
    file://*)
      rest=${url#file://}
      case "$rest" in
        /*) [ -n "$rest" ] || return 2; return 0 ;;
        */*)
          authority=${rest%%/*}
          path=${rest#*/}
          [ -n "$authority" ] && [ -n "$path" ] || return 2
          return 0
          ;;
        *) return 2 ;;
      esac
      ;;
    *@*:*)
      user=${url%%@*}
      rest=${url#*@}
      host=${rest%%:*}
      path=${rest#*:}
      [ -n "$user" ] && [ -n "$host" ] && [ -n "$path" ] || return 2
      case "$user" in */*) return 1 ;; esac
      case "$host" in */*) return 1 ;; esac
      return 0
      ;;
    *) return 1 ;;
  esac
}

resolve_fork_url() {  # <dir>
  local dir=$1 declared='' config_status safe_declared reason
  if declared=$(config_token fork-url); then
    config_status=0
    fork_url_validate "$declared" || config_status=$?
    safe_declared=$(printf '%q' "$declared")
    case "$config_status" in
      0) ;;
      1)
        reason=$(fork_url_invalid_reason "$declared")
        printf 'error: config/fork-url value %s is unusable: %s\n' "$safe_declared" "$reason" >&2
        return 3
        ;;
      *)
        printf 'error: config/fork-url value %s is unusable: its URL must include a host and path\n' "$safe_declared" >&2
        return 3
        ;;
    esac
    printf '%s\n' "$declared"
    return 0
  else
    config_status=$?
    [ "$config_status" -eq 1 ] && return 1
    case "$config_status" in
      2) ;;
      3) ;;
      4) ;;
      *)
        printf 'error: config/fork-url is unusable: its contents could not be classified\n' >&2
        ;;
    esac
    return 3
  fi
}

cmd_resolve() {  # <dir>
  local dir=$1 url status
  [ -d "$dir" ] || die "not a directory: $dir"
  status=0
  url=$(resolve_fork_url "$dir") || status=$?
  case "$status" in
    0) printf '%s\n' "$url" ;;
    1) ;;
    *) exit 1 ;;
  esac
}

has_existing_fork_registration() {  # <dir>
  local registered
  registered=$(registered_fork_url "$1") || return 1
  [ -n "$registered" ]
}

registered_fork_url() {  # <dir>
  local state
  state=$(registered_fork_state "$1") || return 1
  case "$state" in
    url$'\t'*) printf '%s\n' "${state#url$'\t'}" ;;
    *) return 1 ;;
  esac
}

registered_fork_state() {  # <dir>, emits url<TAB><url> or origin
  local status_output
  status_output=$(cd "$1" && no-mistakes status 2>/dev/null) || return 1
  printf '%s\n' "$status_output" | awk '
    /^[[:space:]]*repo:[[:space:]]/ { repo=1 }
    /^[[:space:]]*remote:[[:space:]]/ { remote=1 }
    /^[[:space:]]*gate:[[:space:]]/ { gate=1 }
    /^[[:space:]]*fork:[[:space:]]/ {
      fork_rows++
      value=$0
      sub(/^[[:space:]]*fork:[[:space:]]*/, "", value)
      fork=value
    }
    END {
      if (!repo || !remote || !gate || fork_rows > 1 || (fork_rows == 1 && fork == "")) exit 1
      if (fork_rows == 1) print "url\t" fork
      else print "origin"
    }
  '
}

fork_target_registration_matches() {  # <dir>
  local dir=$1 resolved_status=0 resolved registered_state registered
  resolved=$(resolve_fork_url "$dir" 2>/dev/null) || resolved_status=$?
  case "$resolved_status" in
    0) ;;
    1) resolved= ;;
    *) return 1 ;;
  esac
  registered_state=$(registered_fork_state "$dir") || return 1
  case "$registered_state" in
    origin) [ -z "$resolved" ] ;;
    url$'\t'*)
      registered=${registered_state#url$'\t'}
      [ -n "$resolved" ] && [ "$resolved" = "$registered" ]
      ;;
    *) return 1 ;;
  esac
}

cmd_init() {  # <dir>
  local dir=$1 url status
  [ -d "$dir" ] || die "not a directory: $dir"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $dir"
  # The tool-presence check runs AFTER resolution, and is classified exactly
  # like any other initialization failure. Resolution is pure local config
  # reading and needs no binary at all, so letting it run first loses nothing
  # and lets a missing `no-mistakes` be fatal only where a declared target is
  # actually at stake.
  status=0
  url=$(resolve_fork_url "$dir") || status=$?
  case "$status" in
    0)
      # A declared target that cannot be initialized is always fatal: the
      # operator named this url, so silently leaving the gate pointed somewhere
      # else is the exact failure this script exists to prevent.
      printf 'fork target: %s\n' "$url"
      command -v no-mistakes >/dev/null 2>&1 \
        || die "no-mistakes command not found, so declared fork url $url cannot be initialized"
      ( cd "$dir" && no-mistakes init --fork-url "$url" ) || die "no-mistakes init failed for $dir"
      ( cd "$dir" && no-mistakes doctor ) || die "no-mistakes doctor failed for $dir"
      return 0
      ;;
    1)
      # No declaration: this home pushes to origin, and preparing that gate is
      # advisory rather than fatal. The guard against pushing somewhere
      # unwritable belongs at push time, where the generated worker
      # instructions and no-mistakes' own init both still enforce it; a caller
      # that cannot start work on a failure here would be stopped by ordinary
      # gate trouble hours before any push exists.
      printf 'fork target: origin (no fork configured or resolvable for this home)\n'
      if ! command -v no-mistakes >/dev/null 2>&1; then
        printf 'warning: no-mistakes command not found and no fork url is declared in this home, so the gate keeps whatever target it already had\n' >&2
        return 4
      fi
      if ! ( cd "$dir" && no-mistakes init ); then
        printf 'warning: no-mistakes init failed for %s and no fork url is declared in this home, so the gate keeps whatever target it already had\n' "$dir" >&2
        return 4
      fi
      if ! ( cd "$dir" && no-mistakes doctor ); then
        printf 'warning: no-mistakes doctor failed for %s after initializing against origin\n' "$dir" >&2
        return 4
      fi
      return 0
      ;;
    2|3)
      if has_existing_fork_registration "$dir"; then
        printf 'error: fork-target resolution incomplete; preserving existing no-mistakes registration\n' >&2
      else
        printf 'error: fork-target resolution incomplete; no-mistakes registration unchanged\n' >&2
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

[ $# -eq 2 ] || { usage; exit 2; }
case "$1" in
  resolve) cmd_resolve "$2" ;;
  matches) fork_target_registration_matches "$2" ;;
  init)    cmd_init "$2" ;;
  *)       usage; exit 2 ;;
esac
