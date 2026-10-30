#!/usr/bin/env bash
# fm-herdr-core-ci-cleanup.sh - bounded cleanup of CI-owned herdr-core lab
# sessions.
#
# Snapshot the lab session inventory before the real-herdr-core suite, then at
# job end only stop/remove session directories that:
#   1. match the guarded fm-hclab-* name pattern under the lab root,
#   2. were not present in the pre-suite snapshot (job-proven ownership).
#
# A herdr-core lab session is an owned directory holding scratch XDG roots plus
# one socket file under the lab socket dir (bin/fm-herdr-core-lab.sh owns the
# layout). Stopping runs `hc server stop` under that session's own pinned env,
# then the session directory and socket file are removed. Real user core state
# under ~/.local/state/herdr-core is never touched: it lives outside the lab
# root and no path this script computes can reach it.
#
# Missing herdr-core is a no-op (exit 0) so portable jobs can call this
# harmlessly; destructive failures for known lab leftovers exit non-zero.
#
# Usage:
#   fm-herdr-core-ci-cleanup.sh snapshot <path>
#   fm-herdr-core-ci-cleanup.sh teardown <snapshot-path>
set -eu

die() {
  printf 'fm-herdr-core-ci-cleanup.sh: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'fm-herdr-core-ci-cleanup.sh: %s\n' "$*" >&2
}

LAB_DIR=${FM_HC_LAB_DIR:-${TMPDIR:-/tmp}/fm-hc-lab-${UID}}
SOCK_DIR=${FM_HC_LAB_SOCK_DIR:-/tmp/fm-hc-lab-${UID}}

cmd=${1:-}
path=${2:-}
[ -n "$cmd" ] && [ -n "$path" ] || die "usage: fm-herdr-core-ci-cleanup.sh snapshot|teardown <path>"

is_lab_name() {
  local name=$1
  [[ "$name" =~ ^fm-hclab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

list_lab_names() {
  [ -d "$LAB_DIR" ] || return 0
  find "$LAB_DIR" -mindepth 1 -maxdepth 1 -type d -name 'fm-hclab-*' -exec basename {} + 2>/dev/null | LC_ALL=C sort
}

case "$cmd" in
  snapshot)
    list_lab_names >"$path" || die "failed to write lab session snapshot to $path"
    log "wrote lab session snapshot to $path ($(wc -l <"$path" | tr -d ' ') names)"
    ;;
  teardown)
    [ -f "$path" ] || die "snapshot file not found: $path"
    failed=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      is_lab_name "$name" || {
        log "refusing non-lab name from candidate set: $name"
        failed=1
        continue
      }
      if grep -qxF "$name" "$path"; then
        continue
      fi
      dir=$LAB_DIR/$name
      sock=$SOCK_DIR/$name.sock
      [ -e "$dir" ] || continue
      log "stopping job-owned lab core session $name"
      if [ -n "${FM_HC_BIN:-}" ] && [ -x "$FM_HC_BIN" ]; then
        ( unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET
          XDG_STATE_HOME="$dir/env/xdg-state" \
          XDG_CONFIG_HOME="$dir/env/xdg-config" \
          XDG_DATA_HOME="$dir/env/xdg-data" \
          HC_SESSION="$name" HC_SOCKET="$sock" \
          "$FM_HC_BIN" server stop --json </dev/null >/dev/null 2>&1 ) || true
      elif command -v herdr-core >/dev/null 2>&1; then
        ( unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET
          XDG_STATE_HOME="$dir/env/xdg-state" \
          XDG_CONFIG_HOME="$dir/env/xdg-config" \
          XDG_DATA_HOME="$dir/env/xdg-data" \
          HC_SESSION="$name" HC_SOCKET="$sock" \
          herdr-core server stop --json </dev/null >/dev/null 2>&1 ) || true
      fi
      sleep 0.3
      # `server stop` closes the listener but the session's serve/hold
      # daemons stay by design; sweep every process still carrying the
      # session's HC_SESSION env marker (same-uid env scan, macOS and Linux).
      for sig in TERM TERM KILL; do
        # shellcheck disable=SC2009 # the match is on the process ENVIRONMENT (HC_SESSION), which pgrep -f cannot read.
        pids=$(ps ewwax -o pid=,command= 2>/dev/null | grep -F "HC_SESSION=$name" | grep -v 'grep' | awk -v self="$$" '$1 != self { print $1 }')
        [ -z "$pids" ] && break
        printf '%s\n' "$pids" | while IFS= read -r p; do
          [ -n "$p" ] && kill -"$sig" "$p" 2>/dev/null || true
        done
        sleep 0.3
      done
      if rm -rf "$dir"; then
        rm -f "$sock" "$SOCK_DIR/$name".holder.*.sock 2>/dev/null || true
        log "removed job-owned lab core session $name"
      else
        log "failed to remove lab session dir $dir"
        failed=1
      fi
    done < <(list_lab_names)
    [ "$failed" -eq 0 ] || die "one or more job-owned lab sessions could not be cleaned"
    ;;
  *)
    die "unknown command: $cmd (use snapshot or teardown)"
    ;;
esac
