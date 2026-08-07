#!/usr/bin/env bash
# Run one GitHub command with this home's PR-capable credential injected.
#
# Why this exists: a GitHub fine-grained personal access token is forbidden from the
# GraphQL createPullRequest mutation ("Resource not accessible by personal access
# token"), so `gh pr create` fails while ordinary REST calls succeed. When the ambient
# environment exports such a token, every tool that shells out to `gh` inherits the
# failure. This wrapper runs one command with a credential this home has configured
# for that mutation, and never prints the credential.
#
# Usage: fm-gh.sh <command> [args...]   e.g. fm-gh.sh gh pr create --fill
#        fm-gh.sh --check              report the configured prefix and resolved identity
#
# Configuration: config/gh-credential (LOCAL, gitignored; see docs/configuration.md).
# The file holds ONE command prefix line that injects the credential and then runs its
# trailing arguments, for example:
#
#   cred run GITHUB_TOKEN=vault/path --
#
# Only the first non-empty, non-comment line is read. The line is split on whitespace
# and executed directly, NOT through a shell, so quoting, globbing, redirection, and
# pipelines in that line are not interpreted. The prefix must end with whatever token
# its own runner needs before the command to run.
#
# When config/gh-credential is absent or blank this wrapper is a transparent
# pass-through: it execs the command unchanged, so a home with no special credential
# behaves exactly as if it had called the command directly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CREDENTIAL_FILE="$CONFIG/gh-credential"

# read_prefix: echo the configured prefix line, or nothing when unconfigured.
read_prefix() {
  [ -f "$CREDENTIAL_FILE" ] || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    # Trim surrounding whitespace; a blank remainder means unconfigured.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
    return 0
  done < "$CREDENTIAL_FILE"
}

PREFIX_LINE=$(read_prefix)
PREFIX=()
[ -n "$PREFIX_LINE" ] && read -r -a PREFIX <<< "$PREFIX_LINE"
# Expand the prefix as ${PREFIX[@]+"${PREFIX[@]}"} rather than "${PREFIX[@]}": under
# `set -u`, bash 3.2 (the system bash macOS still ships) treats an empty array's
# expansion as an unbound variable, which would break the unconfigured pass-through
# path that every home without config/gh-credential takes.

if [ "${1:-}" = "--check" ]; then
  if [ -n "$PREFIX_LINE" ]; then
    printf 'credential prefix: configured (%s)\n' "$CREDENTIAL_FILE"
  else
    printf 'credential prefix: none (%s absent or blank); commands run unchanged\n' \
      "$CREDENTIAL_FILE"
  fi
  # Report the identity the wrapper actually resolves. This is the decisive fact when
  # a PR lands under an unexpected account; it does not, and cannot, prove that the
  # credential is authorized for createPullRequest without opening a real pull request.
  if identity=$(${PREFIX[@]+"${PREFIX[@]}"} gh api user --jq .login 2> /dev/null); then
    printf 'identity: %s\n' "$identity"
  else
    printf 'identity: unresolved (gh api user failed)\n' >&2
    exit 1
  fi
  exit 0
fi

[ "$#" -ge 1 ] || {
  echo "usage: fm-gh.sh <command> [args...] | --check" >&2
  exit 2
}

exec ${PREFIX[@]+"${PREFIX[@]}"} "$@"
