#!/usr/bin/env bash
# Host-local lifecycle control for the remote secondmate home selected by fm-on.
#
# Usage:
#   fm-remote-secondmate-control.sh launch <id> <harness> <model|-> <effort|-> <backend|-> [traceparent]
#   fm-remote-secondmate-control.sh state <id>
#   fm-remote-secondmate-control.sh send <id> <message>
#   fm-remote-secondmate-control.sh key <id> <key>
#   fm-remote-secondmate-control.sh capture <id> [lines]
#   fm-remote-secondmate-control.sh observe <id>
#   fm-remote-secondmate-control.sh sync <id>
#   fm-remote-secondmate-control.sh update <id>
#   fm-remote-secondmate-control.sh retire <id> [--force]
#
# Remote placement ends here. The home still chooses its ordinary local runtime
# backend through its own config/backend, and fm-spawn/fm-send/fm-teardown keep
# owning those local endpoint mechanics. A private parent-route state directory
# stores only the remote secondmate agent's endpoint record; the home's own
# state/*.meta remains reserved for workers the secondmate supervises.
#
# The optional launch traceparent is the per-task W3C trace-context carrier the
# PARENT home resolved for this secondmate; this host only delivers it to the
# pane, and fm-spawn validates it (bin/fm-trace-context-lib.sh). Omitting it is
# the default-off path. print_route echoes the carrier the endpoint actually
# holds, including for an already-alive endpoint that was not relaunched, so the
# parent records the identity the agent really received rather than an intent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
CONTROL_STATE="$TARGET_HOME/state/parent-route"
CONTROL_DATA="$TARGET_HOME/data/.parent-route"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac; }

validate_home() { # <id> [allow-absent]
  local id=$1 allow_absent=${2:-no} marker
  if [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] && [ "$allow_absent" = yes ]; then return 2; fi
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "remote secondmate home is unavailable or unsafe"
  [ -f "$TARGET_HOME/.fm-secondmate-home" ] && [ ! -L "$TARGET_HOME/.fm-secondmate-home" ] \
    || die "remote home is not a seeded secondmate home"
  marker=$(cat "$TARGET_HOME/.fm-secondmate-home")
  [ "$marker" = "$id" ] || die "remote home belongs to $marker, not $id"
  [ -f "$TARGET_HOME/AGENTS.md" ] && [ -d "$TARGET_HOME/bin" ] || die "remote home is not a Firstmate checkout"
}

meta_path() { printf '%s/%s.meta\n' "$CONTROL_STATE" "$1"; }

state_value() { # <id>; prints recovery-grade state
  local id=$1 meta backend target
  meta=$(meta_path "$id")
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf 'missing\n'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'unreadable\n'; return 0; }
  fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable\n'
}

print_route() { # <id>
  local meta=$1 backend target harness traceparent
  meta=$(meta_path "$meta")
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  traceparent=$(fm_meta_get "$meta" traceparent)
  printf 'schema=fm-remote-secondmate-control.v1\n'
  printf 'backend=%s\n' "$backend"
  printf 'target=%s\n' "$target"
  printf 'harness=%s\n' "$harness"
  [ -z "$traceparent" ] || printf 'traceparent=%s\n' "$traceparent"
}

cmd_launch() {
  local id=$1 harness=$2 model=$3 effort=$4 selected_backend=$5 traceparent=${6:-}
  local current meta out backend target

  validate_id "$id"
  validate_home "$id"
  case "$harness" in claude|codex|opencode|pi|pi-signed|grok|kimi) ;; *) die "unverified remote secondmate harness: $harness" ;; esac
  case "$effort" in -|low|medium|high|xhigh|max) ;; *) die "invalid remote secondmate effort: $effort" ;; esac
  mkdir -p "$CONTROL_STATE" "$CONTROL_DATA"
  meta=$(meta_path "$id")
  if [ -f "$meta" ]; then
    current=$(state_value "$id")
    case "$current" in
      alive) print_route "$id"; return 0 ;;
      dead)
        backend=$(fm_backend_of_meta "$meta")
        target=$(fm_backend_target_of_meta "$meta")
        fm_backend_kill "$backend" "$target" 2>/dev/null || die "could not remove the confirmed agent-less endpoint"
        ;;
      missing) ;;
      *) die "remote endpoint state is $current; refusing duplicate launch" ;;
    esac
  fi
  ARGS=("$id" "$TARGET_HOME" --secondmate --harness "$harness")
  [ "$model" = - ] || ARGS+=(--model "$model")
  [ "$effort" = - ] || ARGS+=(--effort "$effort")
  [ "$selected_backend" = - ] || ARGS+=(--backend "$selected_backend")
  [ -z "$traceparent" ] || ARGS+=(--traceparent "$traceparent")
  if ! out=$(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1 \
    "$SCRIPT_DIR/fm-spawn.sh" "${ARGS[@]}" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "remote host-local secondmate launch failed"
  fi
  [ -f "$meta" ] || die "remote launch returned without endpoint metadata"
  print_route "$id"
}

cmd_send() {
  local id=$1 message=$2 meta backend target
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  [ -f "$meta" ] || die "remote secondmate has no endpoint metadata"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || die "remote secondmate endpoint is unreadable"
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    "$SCRIPT_DIR/fm-send.sh" "$target" "$message"
}

cmd_key() {
  local id=$1 key=$2 meta target
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  [ -f "$meta" ] || die "remote secondmate has no endpoint metadata"
  target=$(fm_backend_target_of_meta "$meta")
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    "$SCRIPT_DIR/fm-send.sh" "$target" --key "$key"
}

cmd_capture() {
  local id=$1 lines=${2:-20} meta backend target
  validate_id "$id"
  validate_home "$id"
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  meta=$(meta_path "$id")
  [ -f "$meta" ] || die "remote secondmate has no endpoint metadata"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_capture "$backend" "$target" "$lines" "fm-$id" | head -c 65536
}

cmd_observe() {
  local id=$1 meta backend target harness
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  [ -f "$meta" ] || die "remote secondmate has no endpoint metadata"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  [ -n "$target" ] || die "remote secondmate endpoint is unreadable"
  fm_pending_reply_backend_observation "$backend" "$target" "fm-$id" "$harness"
  printf '\n'
}

cmd_sync() {
  local id=$1 target dirty head current
  validate_id "$id"
  validate_home "$id"
  target=$TARGET_HOME
  dirty=$(git -C "$target" status --porcelain 2>/dev/null | awk '$0 != "?? .fm-secondmate-home" { print; exit }')
  [ -z "$dirty" ] || die "remote secondmate checkout is dirty; sync skipped"
  head=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) || die "remote code root HEAD is unreadable"
  current=$(git -C "$target" rev-parse HEAD 2>/dev/null) || die "remote home HEAD is unreadable"
  if [ "$current" = "$head" ]; then
    printf 'current: %s\n' "$head"
    return 0
  fi
  if ! git -C "$target" cat-file -e "$head^{commit}" 2>/dev/null; then
    git -C "$target" fetch --quiet --no-tags "$FM_ROOT" "$head" \
      || die "remote home could not import the code-root commit"
  fi
  git -C "$target" cat-file -e "$head^{commit}" 2>/dev/null || die "remote home does not contain the code-root commit"
  git -C "$target" merge-base --is-ancestor HEAD "$head" || die "remote secondmate checkout is not a fast-forward"
  git -C "$target" checkout --detach -q "$head" || die "remote secondmate fast-forward failed"
  printf 'synced: %s\n' "$head"
}

cmd_update() {
  local id=$1 update_out root_status
  validate_id "$id"
  validate_home "$id"
  if ! update_out=$(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-update.sh" 2>&1); then
    [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
    die "remote code root update failed"
  fi
  root_status=$(printf '%s\n' "$update_out" | grep '^firstmate:' | tail -1)
  case "$root_status" in
    'firstmate: updated '*|'firstmate: already current'*) ;;
    *)
      [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
      die "remote code root did not complete a safe origin update"
      ;;
  esac
  cmd_sync "$id"
}

cmd_retire() {
  local id=$1 force=${2:-} rc
  validate_id "$id"
  validate_home "$id" yes || rc=$?
  if [ "${rc:-0}" -eq 2 ]; then
    printf 'already-retired: %s\n' "$id"
    return 0
  fi
  [ -z "$force" ] || [ "$force" = --force ] || usage
  [ -f "$(meta_path "$id")" ] || die "remote secondmate has no endpoint metadata to retire safely"
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" "$SCRIPT_DIR/fm-guard.sh" || true
  if [ -n "$force" ]; then
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id" --force
  else
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id"
  fi
}

case "${1:-}" in
  launch) shift; [ "$#" -ge 5 ] && [ "$#" -le 6 ] || usage; cmd_launch "$@" ;;
  state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; validate_home "$1"; state_value "$1" ;;
  send) shift; [ "$#" -eq 2 ] || usage; cmd_send "$@" ;;
  key) shift; [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  capture) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; cmd_observe "$@" ;;
  sync) shift; [ "$#" -eq 1 ] || usage; cmd_sync "$@" ;;
  update) shift; [ "$#" -eq 1 ] || usage; cmd_update "$@" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
