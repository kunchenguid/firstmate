#!/usr/bin/env bash
# Provision and verify the isolated no-mistakes registration used only for fork
# integration pull requests.
#
# Usage:
#   fm-fork-integration.sh plan <fork-url> <upstream-url>
#   fm-fork-integration.sh ensure <fork-url> <upstream-url> --confirm
#   fm-fork-integration.sh check <fork-url> <upstream-url>
#
# The ordinary Firstmate registration must already name upstream-url as its
# remote and fork-url as its fork. This script never initializes, refreshes, or
# reconfigures that live registration. The private integration clone lives at
# $FM_HOME/data/fork-integration by default, has origin=fork and
# upstream=official, and gets a separate plain no-mistakes registration whose
# upstream is therefore the fork.
#
# ensure snapshots the ordinary registration's remote/fork facts before doing
# anything and proves they are byte-identical afterwards. An existing private
# clone or registration with any different fact is refused rather than repaired.
# A no-mistakes daemon error is reported and never triggers init retry, daemon
# restart, or tool update. FM_FORK_INTEGRATION_DIR may override the private path
# for tests and controlled provisioning.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
INTEGRATION_DIR=${FM_FORK_INTEGRATION_DIR:-$FM_HOME/data/fork-integration}
MODE=${1:-}
[ "$#" -eq 0 ] || shift

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-fork-integration: %s\n' "$*" >&2
  exit 1
}

quote_arg() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
FORK_URL=$1
UPSTREAM_URL=$2
shift 2
[ -n "$FORK_URL" ] && [ -n "$UPSTREAM_URL" ] && [ "$FORK_URL" != "$UPSTREAM_URL" ] \
  || die "fork and upstream URLs must be non-empty and distinct"
case "$FORK_URL$UPSTREAM_URL" in
  *$'\n'*) die "remote URLs must not contain newlines" ;;
esac

integration_real_parent=$(cd "$(dirname "$INTEGRATION_DIR")" 2>/dev/null && pwd -P) \
  || die "integration clone parent is unavailable: $(dirname "$INTEGRATION_DIR")"
INTEGRATION_DIR="$integration_real_parent/$(basename "$INTEGRATION_DIR")"
root_real=$(cd "$FM_ROOT" && pwd -P)
home_real=$(cd "$FM_HOME" && pwd -P)
case "$INTEGRATION_DIR" in
  "$root_real") die "integration clone cannot replace the tracked Firstmate checkout" ;;
  "$root_real"/*)
    case "$INTEGRATION_DIR" in
      "$home_real/data"/*) ;;
      *) die "integration clone inside the tracked Firstmate checkout must stay under the private home data directory" ;;
    esac
    ;;
esac

nm_status() { # <repo> <output>
  local repo=$1 output=$2
  (cd "$repo" && no-mistakes status) > "$output" 2>&1 \
    || die "no-mistakes status failed in $repo; shared service left untouched"
}

nm_field() { # <file> <field>
  awk -v key="$2:" '
    $1 == key {
      sub(/^[^:]*:[[:space:]]*/, "")
      print
      exit
    }
  ' "$1"
}

registration_facts() { # <repo> <out>
  local repo=$1 out=$2 status remote fork
  status=$(mktemp "${TMPDIR:-/tmp}/fm-fork-nm-status.XXXXXX") || die "cannot create temporary status"
  nm_status "$repo" "$status"
  remote=$(nm_field "$status" remote)
  fork=$(nm_field "$status" fork)
  rm -f "$status"
  {
    printf 'remote=%s\n' "$remote"
    printf 'fork=%s\n' "$fork"
  } > "$out"
}

require_primary_registration() { # <facts-file>
  local remote fork
  [ "$(git -C "$FM_ROOT" remote get-url --all origin 2>/dev/null || true)" = "$FORK_URL" ] \
    || die "operating checkout origin is not the expected personal fork"
  [ "$(git -C "$FM_ROOT" remote get-url --all upstream 2>/dev/null || true)" = "$UPSTREAM_URL" ] \
    || die "operating checkout upstream is not the expected official repository"
  "$SCRIPT_DIR/fm-fork-remotes.sh" check "$FM_ROOT" >/dev/null \
    || die "operating checkout fork topology is not validated"
  remote=$(sed -n 's/^remote=//p' "$1")
  fork=$(sed -n 's/^fork=//p' "$1")
  [ "$remote" = "$UPSTREAM_URL" ] \
    || die "ordinary no-mistakes registration remote is '$remote', expected official upstream; refusing reconfiguration"
  [ "$fork" = "$FORK_URL" ] \
    || die "ordinary no-mistakes registration fork is '$fork', expected personal fork; refusing reconfiguration"
}

require_integration_clone() {
  [ -d "$INTEGRATION_DIR" ] && [ ! -L "$INTEGRATION_DIR" ] || die "integration clone is absent or unsafe"
  git -C "$INTEGRATION_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "integration path is not a Git worktree"
  [ "$(git -C "$INTEGRATION_DIR" remote get-url --all origin 2>/dev/null || true)" = "$FORK_URL" ] \
    || die "integration clone origin does not match the fork"
  [ "$(git -C "$INTEGRATION_DIR" remote get-url --all upstream 2>/dev/null || true)" = "$UPSTREAM_URL" ] \
    || die "integration clone upstream does not match the official repository"
  "$SCRIPT_DIR/fm-fork-remotes.sh" check "$INTEGRATION_DIR" >/dev/null \
    || die "integration clone fork topology is not validated"
  git -C "$INTEGRATION_DIR" remote get-url no-mistakes >/dev/null 2>&1 \
    || die "integration clone has no isolated no-mistakes registration"
}

require_integration_registration() {
  local facts=$1 remote fork
  registration_facts "$INTEGRATION_DIR" "$facts"
  remote=$(sed -n 's/^remote=//p' "$facts")
  fork=$(sed -n 's/^fork=//p' "$facts")
  [ "$remote" = "$FORK_URL" ] \
    || die "integration no-mistakes registration targets '$remote', expected fork; refusing reconfiguration"
  [ -z "$fork" ] \
    || die "integration no-mistakes registration unexpectedly has a fork target '$fork'; refusing reconfiguration"
}

cmd_plan() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  printf 'integration-clone: %s\n' "$INTEGRATION_DIR"
  printf 'ordinary-registration: remote=%s fork=%s (must already exist and will not be reconfigured)\n' "$UPSTREAM_URL" "$FORK_URL"
  printf 'integration-registration: remote=%s fork=<none>\n' "$FORK_URL"
  printf 'ensure-command: '
  quote_arg "$FM_ROOT/bin/fm-fork-integration.sh"
  printf ' ensure '
  quote_arg "$FORK_URL"
  printf ' '
  quote_arg "$UPSTREAM_URL"
  printf ' --confirm\n'
}

cmd_check() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  local tmp primary integration
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-integration-check.XXXXXX") || die "cannot create temporary state"
  FM_FORK_INTEGRATION_TMP=$tmp
  trap 'rm -rf "$FM_FORK_INTEGRATION_TMP"' EXIT
  primary="$tmp/primary"
  integration="$tmp/integration"
  registration_facts "$FM_ROOT" "$primary"
  require_primary_registration "$primary"
  require_integration_clone
  require_integration_registration "$integration"
  printf 'integration-registration: isolated ordinary=%s fork-target=%s\n' "$UPSTREAM_URL" "$FORK_URL"
}

cmd_ensure() {
  [ "$#" -eq 1 ] && [ "$1" = --confirm ] || die "ensure requires the literal --confirm token"
  local tmp before after integration created=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-integration-ensure.XXXXXX") || die "cannot create temporary state"
  FM_FORK_INTEGRATION_TMP=$tmp
  trap 'rm -rf "$FM_FORK_INTEGRATION_TMP"' EXIT
  before="$tmp/primary-before"
  after="$tmp/primary-after"
  integration="$tmp/integration"
  registration_facts "$FM_ROOT" "$before"
  require_primary_registration "$before"

  if [ -e "$INTEGRATION_DIR" ] || [ -L "$INTEGRATION_DIR" ]; then
    require_integration_clone
    require_integration_registration "$integration"
  else
    mkdir -p "$(dirname "$INTEGRATION_DIR")"
    GIT_TERMINAL_PROMPT=0 git clone --quiet -- "$FORK_URL" "$INTEGRATION_DIR" \
      || die "could not clone the fork integration repository"
    created=1
    git -C "$INTEGRATION_DIR" remote add upstream "$UPSTREAM_URL" \
      || die "could not add official upstream to the integration clone"
    GIT_TERMINAL_PROMPT=0 git -C "$INTEGRATION_DIR" fetch --quiet --prune upstream \
      || die "could not fetch official upstream in the integration clone"
    git -C "$INTEGRATION_DIR" config rerere.enabled true
    git -C "$INTEGRATION_DIR" config rerere.autoupdate false
    if ! (cd "$INTEGRATION_DIR" && no-mistakes init); then
      registration_facts "$FM_ROOT" "$after"
      if ! cmp -s "$before" "$after"; then
        die "ordinary no-mistakes registration changed during failed integration init; stop and inspect rather than reconfigure it"
      fi
      die "no-mistakes init failed in the private integration clone; ordinary registration was not reconfigured; inspect $INTEGRATION_DIR before retrying"
    fi
  fi

  registration_facts "$FM_ROOT" "$after"
  if ! cmp -s "$before" "$after"; then
    die "ordinary no-mistakes registration changed while provisioning the integration clone; stop and inspect rather than reconfigure it"
  fi
  require_integration_clone
  require_integration_registration "$integration"
  printf 'integration-registration: ready at %s (created=%s)\n' "$INTEGRATION_DIR" "$created"
}

case "$MODE" in
  plan) cmd_plan "$@" ;;
  check) cmd_check "$@" ;;
  ensure) cmd_ensure "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
