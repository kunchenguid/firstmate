#!/usr/bin/env bash
# fm-reboot-sweep.sh - versioned boot recovery scan and primary wake-up.
#
# Usage:
#   fm-reboot-sweep.sh
#   fm-reboot-sweep.sh --recover
#   fm-reboot-sweep.sh --classify-authority
#
# The default mode is a read-only checklist for the primary after a reboot.
# It reports duplicate primary panes, watcher health, Bizmate liveness, and the
# autonomy footer of every registered Claude secondmate.
#
# --recover is the narrow systemd-timer path.
# It starts the dedicated watcher backstop when this home's verified watcher is
# stale, starts the separate Bizmate review session when absent, and injects one
# marked operational nudge into the restored primary pane per Linux boot id.
# It never exits, kills, sends input to, or respawns a secondmate.
# Authority repair remains a primary decision using the explicit backend target
# printed by the default checklist.
#
# --classify-authority reads a plain pane capture from stdin and prints one of:
#   healthy:bypass-permissions
#   broken:accept-edits
#   broken:auto-mode
#   broken:manual-mode
#   broken:plan-mode
#   unknown:no-mode-line
# The last recognized rendered mode wins so stale scrollback cannot overrule the
# current footer.
set -u

fm_reboot_authority_classify() {
  awk '
    {
      line = tolower($0)
      if (index(line, "bypass permissions on")) {
        result = "healthy:bypass-permissions"
      } else if (index(line, "accept edits on")) {
        result = "broken:accept-edits"
      } else if (index(line, "auto mode")) {
        result = "broken:auto-mode"
      } else if (index(line, "manual mode")) {
        result = "broken:manual-mode"
      } else if (index(line, "plan mode on")) {
        result = "broken:plan-mode"
      }
    }
    END {
      if (result == "") result = "unknown:no-mode-line"
      print result
    }
  '
}

if [ "${1:-}" = --classify-authority ]; then
  [ "$#" -eq 1 ] || {
    printf 'fm-reboot-sweep: --classify-authority accepts no arguments\n' >&2
    exit 2
  }
  fm_reboot_authority_classify
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=${1:-scan}
case "$MODE" in
  scan) [ "$#" -eq 0 ] || { printf 'fm-reboot-sweep: unexpected arguments\n' >&2; exit 2; } ;;
  --recover) [ "$#" -eq 1 ] || { printf 'fm-reboot-sweep: --recover accepts no arguments\n' >&2; exit 2; } ;;
  -h|--help)
    sed -n '2,28{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    printf 'fm-reboot-sweep: usage: fm-reboot-sweep.sh [--recover|--classify-authority]\n' >&2
    exit 2
    ;;
esac

HERDR_SESSION=${FM_REBOOT_HERDR_SESSION:-default}
HERDR_BIN=${FM_REBOOT_HERDR:-herdr}
HERDR_LAB_HELPER=${FM_REBOOT_HERDR_LAB_HELPER:-}
TMUX_BIN=${FM_REBOOT_TMUX:-tmux}
SYSTEMCTL_BIN=${FM_REBOOT_SYSTEMCTL:-systemctl}
WATCHER_UNIT=${FM_REBOOT_WATCHER_UNIT:-fm-boot-watcher.service}
WATCHER_GRACE=${FM_REBOOT_WATCHER_GRACE:-${FM_GUARD_GRACE:-300}}
WATCHER_CONFIRM=${FM_REBOOT_WATCHER_CONFIRM:-10}
BIZMATE_SESSION=${FM_REBOOT_BIZMATE_SESSION:-bizmate}
BIZMATE_START=${FM_REBOOT_BIZMATE_START:-$HOME/.local/bin/bizmate-start}
BOOT_ID_FILE=${FM_REBOOT_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
RECOVERY_STATE=${FM_REBOOT_STATE_DIR:-$STATE/.boot-recovery}
RECOVERY_LOCK="$RECOVERY_STATE/recovery.lock"
NUDGE_MARKER="$RECOVERY_STATE/last-nudged-boot-id"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"

case "$WATCHER_GRACE" in ''|*[!0-9]*|0) WATCHER_GRACE=300 ;; esac
case "$WATCHER_CONFIRM" in ''|*[!0-9]*) WATCHER_CONFIRM=10 ;; esac

SWEEP_REPORT=
SWEEP_PRIMARY_COUNT=0
SWEEP_PRIMARY_PANE=
SWEEP_BROKEN_SUMMARY=
SWEEP_UNKNOWN_SUMMARY=
SWEEP_WATCHER=unknown
SWEEP_BIZMATE=unknown

fm_reboot_append_report() {
  if [ -n "$SWEEP_REPORT" ]; then
    SWEEP_REPORT="$SWEEP_REPORT
$1"
  else
    SWEEP_REPORT=$1
  fi
}

fm_reboot_summary_append() {
  local current=$1 value=$2 result_var=$3
  if [ -n "$current" ]; then
    printf -v "$result_var" '%s,%s' "$current" "$value"
  else
    printf -v "$result_var" '%s' "$value"
  fi
}

fm_reboot_meta_get() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_reboot_herdr_cli() {
  local session=$1
  shift
  if [ -n "$HERDR_LAB_HELPER" ]; then
    [ "$session" = "$HERDR_SESSION" ] || {
      printf 'fm-reboot-sweep: lab helper refuses cross-session target %s\n' "$session" >&2
      return 1
    }
    "$HERDR_LAB_HELPER" run "$session" "$@"
  else
    "$HERDR_BIN" "$@" --session "$session"
  fi
}

fm_reboot_snapshot() {
  command -v jq >/dev/null 2>&1 || return 1
  fm_reboot_herdr_cli "$HERDR_SESSION" api snapshot
}

fm_reboot_scan_primary() {
  local snapshot panes
  if ! snapshot=$(fm_reboot_snapshot 2>/dev/null); then
    fm_reboot_append_report 'REBOOT_SWEEP: primary panes=unreadable'
    return 0
  fi
  panes=$(printf '%s' "$snapshot" | jq -r --arg cwd "$FM_HOME" '
    [.result.snapshot.agents[]?
      | select(.cwd == $cwd)
      | select(
          .agent == "claude" or .agent == "codex" or .agent == "opencode"
          or .agent == "pi" or .agent == "pi-signed" or .agent == "grok"
          or .agent == "kimi"
        )]
    | sort_by((.focused | not), .pane_id)
    | .[]?.pane_id
  ' 2>/dev/null) || panes=
  SWEEP_PRIMARY_COUNT=$(printf '%s\n' "$panes" | awk 'NF { count += 1 } END { print count + 0 }')
  SWEEP_PRIMARY_PANE=$(printf '%s\n' "$panes" | awk 'NF { print; exit }')
  case "$SWEEP_PRIMARY_COUNT" in
    0) fm_reboot_append_report 'REBOOT_SWEEP: primary panes=0 (restored primary not found)' ;;
    1) fm_reboot_append_report "REBOOT_SWEEP: primary panes=1 selected=$SWEEP_PRIMARY_PANE" ;;
    *) fm_reboot_append_report "REBOOT_SWEEP: primary panes=$SWEEP_PRIMARY_COUNT duplicate=YES selected=$SWEEP_PRIMARY_PANE" ;;
  esac
}

fm_reboot_capture_target() {
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ "$pane" != "$target" ] && [ -n "$pane" ] || return 1
      fm_reboot_herdr_cli "$session" pane read "$pane" --source recent --lines 80 --format text
      ;;
    tmux)
      "$TMUX_BIN" capture-pane -p -t "$target" -S -80
      ;;
    *) return 1 ;;
  esac
}

fm_reboot_scan_secondmates() {
  local meta id kind harness backend target capture classification authority mode item
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_reboot_meta_get "$meta" kind)
    [ "$kind" = secondmate ] || continue
    id=$(basename "$meta" .meta)
    harness=$(fm_reboot_meta_get "$meta" harness)
    backend=$(fm_reboot_meta_get "$meta" backend)
    target=$(fm_reboot_meta_get "$meta" window)
    [ -n "$backend" ] || backend=tmux
    if [ "$harness" != claude ]; then
      fm_reboot_append_report "REBOOT_SWEEP: secondmate $id authority=not-applicable harness=${harness:-unknown} target=${target:-missing}"
      continue
    fi
    if [ -z "$target" ] || ! capture=$(fm_reboot_capture_target "$backend" "$target" 2>/dev/null); then
      item="$id(${target:-missing}=unreadable)"
      fm_reboot_summary_append "$SWEEP_UNKNOWN_SUMMARY" "$item" SWEEP_UNKNOWN_SUMMARY
      fm_reboot_append_report "REBOOT_SWEEP: secondmate $id authority=unknown mode=unreadable target=${target:-missing}"
      continue
    fi
    classification=$(printf '%s\n' "$capture" | fm_reboot_authority_classify)
    authority=${classification%%:*}
    mode=${classification#*:}
    case "$authority" in
      healthy)
        fm_reboot_append_report "REBOOT_SWEEP: secondmate $id authority=healthy mode=$mode target=$target"
        ;;
      broken)
        item="$id($target=$mode)"
        fm_reboot_summary_append "$SWEEP_BROKEN_SUMMARY" "$item" SWEEP_BROKEN_SUMMARY
        fm_reboot_append_report "REBOOT_SWEEP: secondmate $id authority=BROKEN mode=$mode target=$target"
        fm_reboot_append_report "REBOOT_SWEEP_ACTION: FM_HOME=$FM_HOME bin/fm-send.sh $target /exit; confirm exit; bin/fm-spawn.sh $id --secondmate"
        ;;
      *)
        item="$id($target=$mode)"
        fm_reboot_summary_append "$SWEEP_UNKNOWN_SUMMARY" "$item" SWEEP_UNKNOWN_SUMMARY
        fm_reboot_append_report "REBOOT_SWEEP: secondmate $id authority=unknown mode=$mode target=$target"
        ;;
    esac
  done
}

fm_reboot_watcher_healthy() {
  fm_watcher_healthy "$STATE" "$WATCH_PATH" "$WATCHER_GRACE" "$FM_HOME"
}

fm_reboot_scan_watcher() {
  if fm_reboot_watcher_healthy; then
    SWEEP_WATCHER="healthy(pid=$FM_WATCHER_HEALTHY_PID)"
  else
    SWEEP_WATCHER=stale
  fi
  fm_reboot_append_report "REBOOT_SWEEP: watcher=$SWEEP_WATCHER"
}

fm_reboot_bizmate_running() {
  "$TMUX_BIN" has-session -t "=$BIZMATE_SESSION" >/dev/null 2>&1
}

fm_reboot_scan_bizmate() {
  if fm_reboot_bizmate_running; then
    SWEEP_BIZMATE=running
  else
    SWEEP_BIZMATE=missing
  fi
  fm_reboot_append_report "REBOOT_SWEEP: bizmate=$SWEEP_BIZMATE"
}

fm_reboot_scan_all() {
  SWEEP_REPORT=
  SWEEP_BROKEN_SUMMARY=
  SWEEP_UNKNOWN_SUMMARY=
  fm_reboot_scan_primary
  fm_reboot_scan_watcher
  fm_reboot_scan_bizmate
  fm_reboot_scan_secondmates
}

fm_reboot_start_watcher_backstop() {
  local deadline
  if fm_reboot_watcher_healthy; then
    printf 'healthy(pid=%s)' "$FM_WATCHER_HEALTHY_PID"
    return 0
  fi
  if ! "$SYSTEMCTL_BIN" --user start --no-block "$WATCHER_UNIT" >/dev/null 2>&1; then
    printf 'start-failed'
    return 1
  fi
  deadline=$(( $(date +%s) + WATCHER_CONFIRM ))
  while [ "$WATCHER_CONFIRM" -gt 0 ] && [ "$(date +%s)" -le "$deadline" ]; do
    if fm_reboot_watcher_healthy; then
      printf 'started(pid=%s)' "$FM_WATCHER_HEALTHY_PID"
      return 0
    fi
    sleep 0.2
  done
  if "$SYSTEMCTL_BIN" --user is-failed "$WATCHER_UNIT" >/dev/null 2>&1; then
    printf 'start-failed'
    return 1
  fi
  printf 'start-requested'
  return 0
}

fm_reboot_start_bizmate() {
  if fm_reboot_bizmate_running; then
    printf 'running'
    return 0
  fi
  if [ -x "$BIZMATE_START" ] && "$BIZMATE_START" >/dev/null 2>&1; then
    printf 'restarted'
    return 0
  fi
  printf 'restart-failed'
  return 1
}

fm_reboot_boot_id() {
  local value
  value=$(tr -d '[:space:]' < "$BOOT_ID_FILE" 2>/dev/null || true)
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$value"
}

fm_reboot_nudge_primary() {
  local boot_id=$1 watcher_result=$2 bizmate_result=$3 last body message tmp
  last=$(cat "$NUDGE_MARKER" 2>/dev/null || true)
  if [ "$last" = "$boot_id" ]; then
    printf 'deduped'
    return 0
  fi
  [ -n "$SWEEP_PRIMARY_PANE" ] || {
    printf 'primary-missing'
    return 1
  }
  body="Reboot recovery detected boot=$boot_id. Run bin/fm-reboot-sweep.sh now. primary-panes=$SWEEP_PRIMARY_COUNT; watcher=$watcher_result; bizmate=$bizmate_result; broken-authority=${SWEEP_BROKEN_SUMMARY:-none}; authority-unknown=${SWEEP_UNKNOWN_SUMMARY:-none}. Timers detect only: repair each broken secondmate through its explicit target, then bin/fm-spawn.sh <id> --secondmate."
  message=$(printf '%s' "$body" | "$SCRIPT_DIR/fm-operational-input.sh" encode watcher) || {
    printf 'encode-failed'
    return 1
  }
  fm_reboot_herdr_cli "$HERDR_SESSION" pane send-text "$SWEEP_PRIMARY_PANE" "$message" >/dev/null 2>&1 \
    || { printf 'send-failed'; return 1; }
  fm_reboot_herdr_cli "$HERDR_SESSION" pane send-keys "$SWEEP_PRIMARY_PANE" enter >/dev/null 2>&1 \
    || { printf 'submit-failed'; return 1; }
  tmp=$(mktemp "$RECOVERY_STATE/.last-nudge.XXXXXX") || {
    printf 'marker-failed'
    return 1
  }
  printf '%s\n' "$boot_id" > "$tmp" || { rm -f "$tmp"; printf 'marker-failed'; return 1; }
  mv -f "$tmp" "$NUDGE_MARKER" || { rm -f "$tmp"; printf 'marker-failed'; return 1; }
  printf 'sent'
}

if [ "$MODE" = scan ]; then
  fm_reboot_scan_all
  printf '%s\n' "$SWEEP_REPORT"
  exit 0
fi

mkdir -p "$RECOVERY_STATE" || {
  printf 'fm-reboot-sweep: cannot create recovery state at %s\n' "$RECOVERY_STATE" >&2
  exit 1
}
if ! fm_lock_try_acquire "$RECOVERY_LOCK"; then
  printf 'REBOOT_RECOVERY: recovery=busy nudge=deduped\n'
  exit 0
fi
trap 'fm_lock_release "$RECOVERY_LOCK"' EXIT HUP INT TERM

watcher_result=$(fm_reboot_start_watcher_backstop) || watcher_status=$?
watcher_status=${watcher_status:-0}
bizmate_result=$(fm_reboot_start_bizmate) || bizmate_status=$?
bizmate_status=${bizmate_status:-0}
fm_reboot_scan_all
boot_id=$(fm_reboot_boot_id) || {
  printf '%s\n' "$SWEEP_REPORT"
  printf 'REBOOT_RECOVERY: watcher=%s bizmate=%s nudge=boot-id-unreadable\n' "$watcher_result" "$bizmate_result"
  exit 1
}
nudge_result=$(fm_reboot_nudge_primary "$boot_id" "$watcher_result" "$bizmate_result") || nudge_status=$?
nudge_status=${nudge_status:-0}
printf '%s\n' "$SWEEP_REPORT"
printf 'REBOOT_RECOVERY: watcher=%s bizmate=%s nudge=%s\n' "$watcher_result" "$bizmate_result" "$nudge_result"
if [ "$watcher_status" -ne 0 ] || [ "$bizmate_status" -ne 0 ] || [ "$nudge_status" -ne 0 ]; then
  exit 1
fi
exit 0
