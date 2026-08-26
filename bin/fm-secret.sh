#!/usr/bin/env bash
# fm-secret.sh - the ONE owner of the secret path: at-rest storage under
# $FM_HOME/state/secrets, injection into a child process's environment, and
# the permission discipline both depend on. No other script writes into
# state/secrets/ or prints a secret's value.
#
# Usage:
#   fm-secret.sh put <name>                  read the value from stdin
#   fm-secret.sh with <name>... -- <cmd...>  export $SECRET_<NAME> per name,
#                                             then exec <cmd...>
#   fm-secret.sh list                        names and ages only, never values
#   fm-secret.sh rm <name>
#   fm-secret.sh --help
#
# File contract (this header is the single owner):
#   $FM_HOME/state/secrets/            directory, mode 0700
#   $FM_HOME/state/secrets/<name>      file, mode 0600, the exact secret bytes
#                                       as read from stdin (a single trailing
#                                       newline, if any, is stripped by the
#                                       shell's stdin capture - the same
#                                       convention `pass`/git credential
#                                       helpers use)
#   <name> is restricted to [A-Za-z0-9_-]+ (no '/', no '.') so it is always a
#   safe bare filename and a safe SECRET_<NAME> suffix; this also forecloses
#   path traversal out of the secrets directory.
#
# `put` REFUSES a value given as a CLI argument (anything after <name>): argv
# is readable by every user on the machine via `ps` or /proc/<pid>/cmdline -
# a process-title leak. The value is accepted ONLY on stdin. Writes are
# atomic (mktemp in the secrets dir itself, chmod 0600, then rename) and the
# secrets directory is (re-)chmod'd to 0700 on every write so a looser mode
# from a manual `mkdir` never lingers.
#
# `with` reads each named secret's file directly into a shell variable
# ($SECRET_<NAME_UPPERCASED_WITH_DASHES_AS_UNDERSCORES>), exports it, and
# execs the given command in this same process - the value is never written
# to a temp file, never appears in argv, and this script never forks a
# subshell that could inherit the value some other way.
#
# `list` prints only <name> and age; it never reads a value into anything a
# human eye or a log could see. `rm` deletes one secret file.
#
# Nothing here ever touches /tmp or any path outside $FM_HOME/state/secrets,
# and no subcommand ever writes a secret value to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECRETS_DIR="$STATE/secrets"

usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

name_valid() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

env_suffix_for() { # env_suffix_for <name> -> SECRET_<NAME> variable name
  local s="${1//-/_}"
  printf 'SECRET_%s' "${s^^}"
}

secure_secrets_dir() { # create (if absent) and lock down the secrets dir
  (umask 077; mkdir -p "$SECRETS_DIR") || die "failed to create secrets directory: $SECRETS_DIR"
  chmod 0700 "$SECRETS_DIR" || die "failed to secure secrets directory to 0700: $SECRETS_DIR"
}

file_age_seconds() { # file_age_seconds <path> -> whole seconds since mtime
  local mtime now
  mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  printf '%s' "$((now - mtime))"
}

cmd="${1:-}"
case "$cmd" in
  put)
    shift
    name="${1:-}"
    [ -n "$name" ] || die "put requires a secret name"
    if [ $# -gt 1 ]; then
      die "refused: secret value must never be passed as a CLI argument -" \
        "argv is readable by every user on this machine via 'ps' and" \
        "/proc/<pid>/cmdline (process-title leak). Pipe it on stdin instead:" \
        "printf '%s' '<value>' | fm-secret.sh put $name"
    fi
    name_valid "$name" || die "invalid secret name '$name' (allowed: A-Za-z0-9_-)"
    value="$(cat)" || die "failed to read secret value from stdin"
    [ -n "$value" ] || die "refused: empty secret value"
    secure_secrets_dir
    tmp="$(umask 177; mktemp "$SECRETS_DIR/.$name.XXXXXX")" || die "failed to create temp file for secret: $name"
    if ! printf '%s' "$value" > "$tmp"; then
      rm -f "$tmp"
      die "failed to write secret: $name"
    fi
    chmod 0600 "$tmp" || { rm -f "$tmp"; die "failed to secure secret file to 0600: $name"; }
    mv -f "$tmp" "$SECRETS_DIR/$name" || die "failed to finalize secret: $name"
    echo "put: $name"
    ;;
  with)
    shift
    names=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
      names+=("$1")
      shift
    done
    [ "${1:-}" = "--" ] || die "with requires '--' before the command"
    shift
    [ $# -gt 0 ] || die "with requires a command after '--'"
    [ ${#names[@]} -gt 0 ] || die "with requires at least one secret name"
    for n in "${names[@]}"; do
      name_valid "$n" || die "invalid secret name '$n' (allowed: A-Za-z0-9_-)"
      f="$SECRETS_DIR/$n"
      [ -f "$f" ] || die "no such secret: $n (put it first: fm-secret.sh put $n)"
      val="$(cat "$f")" || die "failed to read secret: $n"
      export "$(env_suffix_for "$n")=$val"
    done
    exec "$@"
    ;;
  list)
    if [ -d "$SECRETS_DIR" ]; then
      for f in "$SECRETS_DIR"/*; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"
        age="$(file_age_seconds "$f")" || age="?"
        printf '%s\tage=%ss\n' "$n" "$age"
      done
    fi
    ;;
  rm)
    shift
    name="${1:-}"
    [ -n "$name" ] || die "rm requires a secret name"
    name_valid "$name" || die "invalid secret name '$name' (allowed: A-Za-z0-9_-)"
    f="$SECRETS_DIR/$name"
    [ -f "$f" ] || die "no such secret: $name"
    rm -f "$f" || die "failed to remove secret: $name"
    echo "rm: $name"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
