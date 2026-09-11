#!/usr/bin/env bash
# Usage: fm-claude-stop-log.sh <hook> <pid> <epoch> <exit> <decision> <arm-result> <reason>
# Append one TSV record per completed Stop participant to state/.claude-autoarm.log.
# Guard and async auto-arm are independent invocations: guard_exit is unknown on
# auto-arm records, never borrowed from a different Stop. No payload text is kept.
# Diagnostic only: bounded locking and 256 KiB / 1000-line retention cannot
# change the hook verdict. SIGKILL cannot run an EXIT trap and leaves no record.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
[ "$#" -eq 7 ] && [ -d "$STATE" ] || exit 0
log="$STATE/.claude-autoarm.log"
lock="$STATE/.claude-autoarm-log.lock"
i=0
while ! fm_lock_try_acquire "$lock"; do
  [ "$i" -lt 20 ] || exit 0
  sleep 0.02
  i=$((i + 1))
done
trap 'fm_lock_release "$lock"' EXIT
clean() {
  local value=${1:0:512}
  value=${value//$'\t'/ }
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  printf '%s' "$value"
}
guard_exit=unknown
[ "$1" != guard ] || guard_exit=$4
printf 'at=%s\thook=%s\tepoch=%s\tpid=%s\tcwd=%s\tFM_HOME=%s\tguard_exit=%s\texit=%s\tdecision=%s\tarm_result=%s\treason=%s\n' \
  "$(date +%s)" "$(clean "$1")" "$(clean "$3")" "$(clean "$2")" \
  "$(clean "$PWD")" "$(clean "$FM_HOME")" "$(clean "$guard_exit")" "$(clean "$4")" \
  "$(clean "$5")" "$(clean "$6")" "$(clean "$7")" >> "$log" 2>/dev/null || exit 0
size=$(wc -c < "$log" | tr -d '[:space:]')
if [ "$size" -ge 262144 ]; then
  tmp="$log.tmp.$$"
  tail -n 1000 "$log" | tail -c 262144 | awk 'NR > 1 || /^at=/' > "$tmp" \
    && mv -f "$tmp" "$log"
  rm -f "$tmp"
fi
exit 0
