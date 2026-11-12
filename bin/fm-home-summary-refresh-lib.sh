# shellcheck shell=bash
# fm-home-summary-refresh-lib.sh - fire-and-forget home-summary republication helpers.
#
# Usage: . bin/fm-home-summary-refresh-lib.sh
#
# fm_home_summary_refresh_on_backlog_write_detached [<refresh-script>] republishes
# state/home-summary.json for the caller's FM_HOME without waiting, through
# <refresh-script> when given (another home's own entrypoint) and this code root's
# bin/fm-home-summary-refresh.sh otherwise. The refresh waits its turn on the home's
# refresh lock inside bin/fm-home-summary-refresh.sh rather than skipping when another
# refresh holds it, so a write that lands while an earlier refresh is running is still
# published. It runs in its own process group, so a caller whose supervisor waits on
# that caller's process group (a remote job worker) is not held open by it.
fm_home_summary_refresh_on_backlog_write_detached() {
  local script_dir refresh_script monitor_was_on=0
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  refresh_script=${1:-$script_dir/fm-home-summary-refresh.sh}
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_HOME_SUMMARY_REFRESH_BIN:-}" ]; then
    refresh_script=$FM_TEST_HOME_SUMMARY_REFRESH_BIN
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  FM_HOME_SUMMARY_IF_IDLE=0 \
    FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}}" \
    "$refresh_script" --best-effort </dev/null >/dev/null 2>&1 &
  [ "$monitor_was_on" -eq 1 ] || set +m
}
