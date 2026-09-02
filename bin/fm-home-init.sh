#!/usr/bin/env bash
# Initialize one canonical primary Firstmate operational home before SessionStart.
#
# Usage: fm-home-init.sh <home>
#
# The target may be the tracked Firstmate root or a separate operational home.
# Its immediate parent must already exist.
# The command binds that physical parent as its working directory, serializes
# same-target initializers through the existing parent-local
# `.firstmate-provision-locks` plus `fm_lock_acquire_wait` contract, and creates
# the home name directly with `mkdir` before creating `data/`, `state/`,
# `config/`, and `projects/` inside it.
# This deliberately exposes an initializing directory instead of pretending
# portable shell can atomically publish a pre-populated directory without
# replacement on both Linux and macOS.
# Concurrent canonical calls converge: one creates the home and later callers
# accept the completed shape.
# A separately located existing home is accepted only when it is already
# complete or contains no entries beyond empty canonical directories, so this
# explicit initializer never adopts populated private data by adding `state/`.
# The tracked root is recognized by physical identity and may retain its normal
# repository contents while missing operational directories are created.
# Symlinked homes or operational directories and an absent parent are refused.
# SessionStart never invokes this command and remains unable to initialize a
# home; run `fm-session-start.sh` only after this command reports success.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_ROOT="$(cd "$FM_ROOT" && pwd -P)" || {
  printf 'error: cannot resolve the Firstmate root\n' >&2
  exit 1
}

usage() {
  printf 'usage: fm-home-init.sh <home>\n' >&2
}

print_help() {
  sed -n '2,/^set -eu$/p' "$SCRIPT_DIR/fm-home-init.sh" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    print_help
    exit 0
    ;;
esac
[ "$#" -eq 1 ] || { usage; exit 2; }

CALLER_PWD=$(pwd -P 2>/dev/null) || die "cannot resolve the caller working directory"
REQUESTED_HOME=$1
case "$REQUESTED_HOME" in
  /*) HOME_INPUT=$REQUESTED_HOME ;;
  *) HOME_INPUT="$CALLER_PWD/$REQUESTED_HOME" ;;
esac
while [ "$HOME_INPUT" != / ] && [ "${HOME_INPUT%/}" != "$HOME_INPUT" ]; do
  HOME_INPUT=${HOME_INPUT%/}
done
[ "$HOME_INPUT" != / ] || die "the filesystem root cannot be a Firstmate home"
HOME_PARENT_INPUT=$(dirname "$HOME_INPUT") || die "cannot resolve the home parent"
HOME_BASENAME=$(basename "$HOME_INPUT") || die "cannot resolve the home basename"
case "$HOME_BASENAME" in ''|.|..) die "the home basename is invalid" ;; esac

CDPATH='' cd -P -- "$HOME_PARENT_INPUT" 2>/dev/null \
  || die "home parent does not exist: $HOME_PARENT_INPUT"
HOME_PARENT_PHYSICAL=$(pwd -P 2>/dev/null) || die "cannot bind the physical home parent"
HOME_REL="./$HOME_BASENAME"
HOME_PHYSICAL="$HOME_PARENT_PHYSICAL/$HOME_BASENAME"
LOCK_ROOT=./.firstmate-provision-locks
if [ -e "$LOCK_ROOT" ] || [ -L "$LOCK_ROOT" ]; then
  [ -d "$LOCK_ROOT" ] && [ ! -L "$LOCK_ROOT" ] \
    || die "home initialization lock root is unsafe: $HOME_PARENT_PHYSICAL/.firstmate-provision-locks"
else
  mkdir "$LOCK_ROOT" 2>/dev/null || true
  [ -d "$LOCK_ROOT" ] && [ ! -L "$LOCK_ROOT" ] \
    || die "cannot create the home initialization lock root"
fi

if command -v shasum >/dev/null 2>&1; then
  HOME_LOCK_KEY=$(printf '%s' "$HOME_PHYSICAL" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  HOME_LOCK_KEY=$(printf '%s' "$HOME_PHYSICAL" | sha256sum | awk '{print $1}')
else
  die "no SHA-256 tool is available for home initialization serialization"
fi

FM_STATE_OVERRIDE=$LOCK_ROOT
STATE=$LOCK_ROOT
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
INIT_LOCK="$STATE/.primary-home-init-$HOME_LOCK_KEY.lock"
INIT_LOCK_HELD=0
release_init_lock() {
  if [ "$INIT_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$INIT_LOCK"
    INIT_LOCK_HELD=0
  fi
}
trap release_init_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$INIT_LOCK" || die "cannot acquire the home initialization lock"
INIT_LOCK_HELD=1

initialize_home() (
  set -eu
  CREATED_HOME=0
  CREATED_DATA=0
  CREATED_STATE=0
  CREATED_CONFIG=0
  CREATED_PROJECTS=0
  IN_HOME=0
  COMMITTED=0

  # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
  rollback_home() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$COMMITTED" -eq 0 ]; then
      if [ "$IN_HOME" -eq 1 ]; then
        [ "$CREATED_PROJECTS" -eq 0 ] || rmdir projects 2>/dev/null || true
        [ "$CREATED_CONFIG" -eq 0 ] || rmdir config 2>/dev/null || true
        [ "$CREATED_STATE" -eq 0 ] || rmdir state 2>/dev/null || true
        [ "$CREATED_DATA" -eq 0 ] || rmdir data 2>/dev/null || true
        if [ "$CREATED_HOME" -eq 1 ] && [ -d "../$HOME_BASENAME" ] \
          && [ "../$HOME_BASENAME" -ef . ]; then
          rmdir "../$HOME_BASENAME" 2>/dev/null || true
        fi
      elif [ "$CREATED_HOME" -eq 1 ]; then
        rmdir "$HOME_REL" 2>/dev/null || true
      fi
    fi
    exit "$status"
  }
  trap rollback_home EXIT
  trap 'exit 1' HUP INT TERM

  if [ -e "$HOME_REL" ] || [ -L "$HOME_REL" ]; then
    [ -d "$HOME_REL" ] && [ ! -L "$HOME_REL" ] \
      || die "home exists but is not a safe directory: $HOME_PHYSICAL"
  else
    mkdir "$HOME_REL" || die "cannot create home: $HOME_PHYSICAL"
    CREATED_HOME=1
  fi

  CDPATH='' cd -P -- "$HOME_REL" 2>/dev/null \
    || die "cannot bind the initialized home: $HOME_PHYSICAL"
  IN_HOME=1
  [ -d "../$HOME_BASENAME" ] && [ ! -L "../$HOME_BASENAME" ] \
    && [ "../$HOME_BASENAME" -ef . ] \
    || die "home identity changed during initialization: $HOME_PHYSICAL"

  IS_TRACKED_ROOT=0
  if [ "$FM_ROOT" -ef . ]; then
    [ -f AGENTS.md ] && [ ! -L AGENTS.md ] && [ -d bin ] && [ ! -L bin ] \
      || die "tracked Firstmate root shape is unsafe: $FM_ROOT"
    IS_TRACKED_ROOT=1
  fi

  READY=1
  POPULATED=0
  for name in data state config projects; do
    if [ -e "$name" ] || [ -L "$name" ]; then
      [ -d "$name" ] && [ ! -L "$name" ] \
        || die "home has unsafe operational directory: $name"
      if find -P "$name" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        POPULATED=1
      fi
    else
      READY=0
    fi
  done

  if [ "$READY" -eq 1 ]; then
    HOME_READY=$(pwd -P 2>/dev/null) || die "cannot resolve the ready home"
    COMMITTED=1
    printf 'home ready: %s\n' "$HOME_READY"
    exit 0
  fi

  if [ "$IS_TRACKED_ROOT" -eq 0 ]; then
    for entry in ./* ./.[!.]* ./..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry#./}
      case "$name" in
        data|state|config|projects) ;;
        *) POPULATED=1 ;;
      esac
    done
    [ "$POPULATED" -eq 0 ] \
      || die "refusing to adopt populated incomplete home: $HOME_PHYSICAL"
  fi

  for name in data state config projects; do
    if [ ! -e "$name" ] && [ ! -L "$name" ]; then
      mkdir "$name" || die "cannot create operational directory: $name"
      case "$name" in
        data) CREATED_DATA=1 ;;
        state) CREATED_STATE=1 ;;
        config) CREATED_CONFIG=1 ;;
        projects) CREATED_PROJECTS=1 ;;
      esac
    fi
  done
  for name in data state config projects; do
    [ -d "$name" ] && [ ! -L "$name" ] \
      || die "home initialization verification failed for: $name"
  done
  [ -d "../$HOME_BASENAME" ] && [ ! -L "../$HOME_BASENAME" ] \
    && [ "../$HOME_BASENAME" -ef . ] \
    || die "home identity changed during initialization: $HOME_PHYSICAL"
  HOME_READY=$(pwd -P 2>/dev/null) || die "cannot resolve the initialized home"
  COMMITTED=1
  printf 'home initialized: %s\n' "$HOME_READY"
)

initialize_home
release_init_lock
trap - EXIT
