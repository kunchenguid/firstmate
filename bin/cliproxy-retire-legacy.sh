#!/usr/bin/env bash
# cliproxy-retire-legacy.sh - Step 2 of the CLIProxyAPI refresh investigation:
# stop the retired ccflare access-sync unit and archive the retired credential
# copies. It never deletes a credential and never touches a live one.
#
# Usage:
#   cliproxy-retire-legacy.sh [plan]   report what would change, change nothing
#   cliproxy-retire-legacy.sh apply    disable the timer and archive the copies
#   cliproxy-retire-legacy.sh --help   print this help
#
# WHY EACH PIECE GOES. `fm-ccflare-access-sync.timer` runs every 120 s and copies
# access tokens out of the retired better-ccflare database into CLIProxyAPI auth
# files. Its keys no longer match the renamed auth files, so it is a permanent
# no-op today, and if it ever matched again it would abort on a refresh-token
# rotation race: two refreshers on one token family is exactly how the previous
# wave lost accounts early. Disabled is the safe end state, and it is not
# repaired here because nothing should depend on it.
#
# The `disabled/` subdirectory and stray `*.bak` copies in the auth dir are
# retired credentials that no current build loads. They are ARCHIVED, never
# deleted, into <archive-root>/<date>/ outside the auth dir, so a future build
# that walks subdirectories cannot load them and a wrong retirement stays
# reversible by moving one file back.
#
# The archive root is ~/.cli-proxy-api-archive, or FM_CLIPROXY_ARCHIVE_ROOT.
# Applied idempotently: a second `apply` finds the unit already disabled and the
# copies already archived and changes nothing.
#
# Exit status: 0 when the requested state already holds or was reached, 1 when
# some step could not be completed (each failure is named on its own line).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/cliproxy-creds-lib.sh
. "$SCRIPT_DIR/cliproxy-creds-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

ACTION=plan
case "${1:-plan}" in
  plan|--plan) ACTION=plan ;;
  apply) ACTION=apply ;;
  -h|--help|help) usage; exit 0 ;;
  *) printf 'cliproxy-retire-legacy: unknown argument: %s (see --help)\n' "$1" >&2; exit 2 ;;
esac

TIMER=${FM_CLIPROXY_CCFLARE_TIMER:-fm-ccflare-access-sync.timer}
AUTH_DIR=$(cliproxy_auth_dir)
ARCHIVE_ROOT=$(cliproxy_archive_root)
DATE=$(date -u +%Y-%m-%d)
failures=0

say() { printf '%s\n' "$*"; }
note_failure() { say "  NOT DONE: $*"; failures=$((failures + 1)); }

timer_state() {
  local state
  command -v systemctl >/dev/null 2>&1 || { printf 'unsupported\n'; return 0; }
  state=$(systemctl --user is-enabled "$TIMER" 2>/dev/null)
  case "$state" in
    '' ) printf 'absent\n' ;;
    *disabled*) printf 'disabled\n' ;;
    *) printf 'enabled\n' ;;
  esac
}

retire_timer() {
  local state
  state=$(timer_state)
  case "$state" in
    unsupported)
      say "systemd user units: systemctl is not available on this host, so $TIMER is not a condition here"
      return 0
      ;;
    absent)
      say "systemd user unit $TIMER is not installed on this host; nothing to disable"
      return 0
      ;;
    disabled)
      say "systemd user unit $TIMER is already disabled"
      if [ "$(command -v systemctl >/dev/null 2>&1 && systemctl --user is-active "$TIMER" 2>/dev/null)" = active ]; then
        say "  it is still running"
        [ "$ACTION" = apply ] || { say "  would stop it"; return 0; }
        systemctl --user stop "$TIMER" || note_failure "could not stop $TIMER"
      fi
      return 0
      ;;
  esac
  say "systemd user unit $TIMER is enabled (a permanent no-op that would race on a rotation)"
  if [ "$ACTION" = plan ]; then
    say "  would run: systemctl --user disable --now $TIMER"
    return 0
  fi
  if systemctl --user disable --now "$TIMER"; then
    say "  disabled and stopped $TIMER"
  else
    note_failure "systemctl --user disable --now $TIMER failed"
    return 1
  fi
  if [ "$(timer_state)" = disabled ]; then
    say "  verified: $(systemctl --user is-enabled "$TIMER" 2>/dev/null)"
  else
    note_failure "$TIMER did not read as disabled afterwards"
  fi
}

archive_candidates() {
  local path
  if [ -d "$AUTH_DIR/disabled" ]; then
    while IFS= read -r path; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      printf '%s\n' "$path"
    done < <(find "$AUTH_DIR/disabled" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' "$path"
  done < <(find "$AUTH_DIR" -mindepth 1 -maxdepth 1 -name '*.bak' 2>/dev/null | LC_ALL=C sort)
}

retire_copies() {
  local path dest found=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    found=1
    if [ "$ACTION" = plan ]; then
      say "retired copy: $(basename -- "$path") -> would move to $ARCHIVE_ROOT/$DATE/"
      continue
    fi
    if dest=$(cliproxy_archive_move "$path"); then
      say "archived $(basename -- "$path") -> $dest"
    else
      note_failure "could not archive $path (left in place)"
    fi
  done < <(archive_candidates)
  [ "$found" = 1 ] || say "retired credential copies: none present in $AUTH_DIR"
}

say "CLIProxyAPI legacy retirement ($ACTION): auth dir $AUTH_DIR, archive $ARCHIVE_ROOT"
retire_timer
retire_copies
if [ "$ACTION" = plan ]; then
  say "plan only: nothing was changed. Run '$(basename -- "$0") apply' to carry it out."
fi
[ "$failures" -eq 0 ] || { say "$failures step(s) did not complete."; exit 1; }
exit 0
