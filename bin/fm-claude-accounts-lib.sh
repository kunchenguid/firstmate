# shellcheck shell=bash
# shellcheck disable=SC2034  # FM_CLAUDE_ACCOUNT_* results are read by the sourcing callers
# Claude account registry: the local, gitignored config/claude-accounts file
# maps an account name to the absolute Claude config directory that account is
# signed in under, so a crew-dispatch profile's optional "account" field and
# fm-spawn.sh's --account axis can place one Claude worker on a named
# subscription. docs/configuration.md "Claude accounts" owns the operator
# contract; this file owns the parse and the refusals.
# Usage: . bin/fm-claude-accounts-lib.sh
#
# File format: one "<name> <absolute-directory>" pair per line; blank lines and
# lines whose first non-blank character is # are ignored. The name is the
# first whitespace-delimited word and must match FM_CLAUDE_ACCOUNT_NAME_RE; the
# name `default` is reserved for the Claude config directory a worker with no
# account inherits, so a relaunch can name it to clear the account axis. The
# directory is the rest of the line with surrounding whitespace trimmed, so it
# may contain spaces. `~` and variables are not expanded.
#
# fm_claude_account_resolve <config-dir> <name>
#   On success sets FM_CLAUDE_ACCOUNT_DIR to the mapped directory and returns 0.
#   On any refusal sets FM_CLAUDE_ACCOUNT_ERROR to one reason line and returns
#   1: an invalid or reserved name, an absent or unreadable file, a malformed or duplicate
#   entry anywhere in the file, an unknown name, a relative directory, or a
#   directory that does not exist. The whole file is validated on every call,
#   so a broken entry refuses every account rather than only its own.

FM_CLAUDE_ACCOUNT_NAME_RE='^[a-z0-9]+(-[a-z0-9]+)*$'

fm_claude_account_resolve() { # <config-dir> <name>
  local file=$1/claude-accounts name=$2 parsed verdict dir
  FM_CLAUDE_ACCOUNT_DIR=
  FM_CLAUDE_ACCOUNT_ERROR=
  if ! [[ $name =~ $FM_CLAUDE_ACCOUNT_NAME_RE ]]; then
    FM_CLAUDE_ACCOUNT_ERROR="claude account '$name' is not a valid name (lowercase letters, digits, and single hyphens)"
    return 1
  fi
  if [ "$name" = default ]; then
    FM_CLAUDE_ACCOUNT_ERROR="claude account name 'default' is reserved for the default Claude config directory; omit the account to use it"
    return 1
  fi
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    FM_CLAUDE_ACCOUNT_ERROR="claude account '$name' is unknown: config/claude-accounts does not exist"
    return 1
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_CLAUDE_ACCOUNT_ERROR="config/claude-accounts must be a readable regular file"
    return 1
  fi
  # Prints "ok<TAB><dir>", "unknown", or "bad<TAB><reason>".
  parsed=$(awk -v want="$name" -v re="$FM_CLAUDE_ACCOUNT_NAME_RE" '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      key = line
      sub(/[[:space:]].*$/, "", key)
      dir = substr(line, length(key) + 1)
      sub(/^[[:space:]]+/, "", dir)
      if (key !~ re) reason = "invalid account name " key
      else if (key == "default") reason = "account name default is reserved for the default Claude config directory"
      else if (dir == "") reason = "account " key " has no directory"
      else if (key in seen) reason = "duplicate account " key
      if (reason != "") { printf "bad\tconfig/claude-accounts line %d: %s\n", NR, reason; bad = 1; exit }
      seen[key] = dir
    }
    END {
      if (bad) exit
      if (want in seen) printf "ok\t%s\n", seen[want]
      else print "unknown"
    }
  ' "$file" 2>/dev/null) || {
    FM_CLAUDE_ACCOUNT_ERROR="config/claude-accounts could not be read"
    return 1
  }
  verdict=$parsed
  case "$verdict" in
  ok$'\t'*) dir=${verdict#ok$'\t'} ;;
  bad$'\t'*)
    FM_CLAUDE_ACCOUNT_ERROR=${verdict#bad$'\t'}
    return 1
    ;;
  *)
    FM_CLAUDE_ACCOUNT_ERROR="claude account '$name' is unknown: config/claude-accounts has no entry for it"
    return 1
    ;;
  esac
  case "$dir" in
  /*) ;;
  *)
    FM_CLAUDE_ACCOUNT_ERROR="claude account '$name' maps to relative directory '$dir'; config/claude-accounts needs an absolute path"
    return 1
    ;;
  esac
  if [ ! -d "$dir" ]; then
    FM_CLAUDE_ACCOUNT_ERROR="claude account '$name' maps to '$dir', which is not an existing directory; sign that account in under it first"
    return 1
  fi
  FM_CLAUDE_ACCOUNT_DIR=$dir
  return 0
}
