#!/usr/bin/env bash
# Deterministic home-binding and stable-tab placement coverage for Herdr.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-home-binding.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

export FM_ROOT_OVERRIDE=$ROOT
export FM_HOME="$TMP_ROOT/primary"
mkdir -p "$FM_HOME/state"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

FAKE_PRESENCE=present
FAKE_LAUNCHER_WORKSPACE=w-primary
FAKE_FIND_WORKSPACE=
FAKE_LOG="$TMP_ROOT/herdr.log"
: > "$FAKE_LOG"

fm_backend_herdr_presentation_session_socket_path() { printf '/tmp/herdr-%s.sock' "$1"; }
fm_backend_herdr_workspace_presence_state() { printf '%s' "$FAKE_PRESENCE"; }
fm_backend_herdr_workspace_find_all() { [ -n "$FAKE_FIND_WORKSPACE" ] && printf '%s\n' "$FAKE_FIND_WORKSPACE"; }
fm_backend_herdr_launcher_identity() {
  FM_BACKEND_HERDR_LAUNCHER_TAB_ID="$FAKE_LAUNCHER_WORKSPACE:t1"
  FM_BACKEND_HERDR_LAUNCHER_PANE_ID="$FAKE_LAUNCHER_WORKSPACE:p1"
  FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID="$FAKE_LAUNCHER_WORKSPACE"
  return 0
}
fm_backend_herdr_cli() {
  printf '%s\n' "$*" >> "$FAKE_LOG"
  case "$*" in
    *'tab list'*) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    *'tab create'*) printf '%s\n' '{"result":{"tab":{"tab_id":"w-primary:t-worker"},"root_pane":{"pane_id":"w-primary:p-worker"}}}' ;;
    *) printf '%s\n' '{"result":{}}' ;;
  esac
}

assert_eq() { [ "$1" = "$2" ] || { echo "assertion failed: expected '$2', got '$1'" >&2; exit 1; }; }
assert_file_contains() { grep -F "$2" "$1" >/dev/null || { echo "missing '$2' in $1" >&2; exit 1; }; }
pass() { printf 'pass: %s\n' "$1"; }

home_binding_path() { printf '%s/state/herdr-workspace' "$1"; }

# Primary direct worker claims the exact launcher workspace and reuses it by id.
rm -f "$(home_binding_path "$FM_HOME")"
FAKE_LAUNCHER_WORKSPACE=w-primary
fm_backend_herdr_workspace_ensure default /tmp/project launcher-home >/dev/null
assert_file_contains "$(home_binding_path "$FM_HOME")" 'workspace_id=w-primary'
FAKE_LAUNCHER_WORKSPACE=w-wrong
if fm_backend_herdr_workspace_ensure default /tmp/project launcher-home >/dev/null 2>&1; then
  echo 'contradictory primary launcher binding was accepted' >&2; exit 1
fi
pass 'primary direct spawn is bound to the exact primary workspace'

# Direct SecondMate workers use the same binding contract in their own home.
for name in surveilo ai-web-training; do
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$name" > "$home/.fm-secondmate-home"
  FM_HOME="$home"
  FAKE_LAUNCHER_WORKSPACE="w-$name"
  FAKE_PRESENCE=present
  rm -f "$(home_binding_path "$home")"
  fm_backend_herdr_workspace_ensure default /tmp/project launcher-home >/dev/null
  assert_file_contains "$(home_binding_path "$home")" "workspace_id=w-$name"
  pass "direct $name SecondMate spawn uses its own exact workspace"
done

# Primary-mediated provisioning is the only initial label discovery path; the
# discovered id is persisted, and later calls ignore a competing same-label id.
FM_HOME="$TMP_ROOT/provisioned"
mkdir -p "$FM_HOME/state"
printf '%s\n' ai-web-training > "$FM_HOME/.fm-secondmate-home"
FAKE_FIND_WORKSPACE=w-provisioned
FAKE_LAUNCHER_WORKSPACE=w-primary
rm -f "$(home_binding_path "$FM_HOME")"
fm_backend_herdr_workspace_ensure default /tmp/project other-home >/dev/null
assert_file_contains "$(home_binding_path "$FM_HOME")" 'workspace_id=w-provisioned'
FAKE_FIND_WORKSPACE=w-competing
fm_backend_herdr_workspace_ensure default /tmp/project other-home >/dev/null
assert_file_contains "$(home_binding_path "$FM_HOME")" 'workspace_id=w-provisioned'
pass 'persistent SecondMate provisioning persists exact workspace identity'

# Missing, stale, and contradictory bindings refuse rather than guessing.
FM_HOME="$TMP_ROOT/stale"
mkdir -p "$FM_HOME/state"
printf '%s\n' surveilo > "$FM_HOME/.fm-secondmate-home"
FAKE_LAUNCHER_WORKSPACE=w-stale
fm_backend_herdr_home_binding_write default w-stale w-stale:t1 w-stale:p1
FAKE_PRESENCE=dead
if fm_backend_herdr_workspace_ensure default /tmp/project launcher-home >/dev/null 2>&1; then
  echo 'stale binding was silently replaced' >&2; exit 1
fi
FAKE_PRESENCE=present
printf 'version=1\nhome=/wrong\nsession=default\nsocket=/tmp/herdr-default.sock\nworkspace_id=w-stale\nowner_kind=secondmate\ngeneration=1\nanchor_tab_id=\nanchor_pane_id=\n' > "$(home_binding_path "$FM_HOME")"
if fm_backend_herdr_workspace_ensure default /tmp/project launcher-home >/dev/null 2>&1; then
  echo 'contradictory home binding was accepted' >&2; exit 1
fi
pass 'missing/stale/contradictory ownership refuses safely'

# Ordinary placement is a tab create in the bound workspace and never a
# disposable workspace create or workspace move.
FM_HOME="$TMP_ROOT/primary"
FAKE_PRESENCE=present
FAKE_LAUNCHER_WORKSPACE=w-primary
: > "$FAKE_LOG"
ids=$(fm_backend_herdr_create_task 'default:w-primary' 'fm-worker' /tmp/project '')
assert_eq "$ids" 'w-primary:t-worker w-primary:p-worker'
assert_file_contains "$FAKE_LOG" 'tab create --workspace w-primary'
if grep -E 'workspace (create|move)' "$FAKE_LOG" >/dev/null; then
  echo 'ordinary tab placement used workspace create/move' >&2; exit 1
fi
pass 'ordinary placement creates only a tab in the exact owner workspace'

echo 'all Herdr home-binding tests passed'
