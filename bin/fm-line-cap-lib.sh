# shellcheck shell=bash
# Shared per-line cap for agent-facing digest lines.
# Usage: . bin/fm-line-cap-lib.sh; fm_cap_line "<line>" [<max>]
#
# ONE OWNER for the bounded-line shape agent-facing digests use. The wake
# digest's OPEN DECISIONS section (bin/fm-wake-drain.sh) renders an
# agent-written status line into a size-bounded view. Every caller must show
# one truncation marker, and the caps must not drift apart, so the cut and its
# marker live here. Session-start fleet rows are never cut and do not use it.
#
# Callers keep their own composite policy: fm-wake-drain.sh still owns the
# OPEN DECISIONS global byte cap and its "N more omitted" disclosure. This
# file owns only the per-line cut.
#
# The cap counts characters, so a plain-ASCII line - what status lines are in
# practice - is bounded to the same number of bytes, and a multibyte character
# is never cut in half into an invalid sequence.
# Truncation stays recoverable because every OPEN DECISIONS entry begins with
# the task id that identifies its durable state/<id>.status source.

FM_LINE_CAP_DEFAULT=220
FM_LINE_CAP_SUFFIX=' [truncated]'

# fm_cap_line_var <line> [<max>]: put <line> in FM_LINE_CAP_LINE, cut to <max>
# characters with FM_LINE_CAP_SUFFIX in place of the tail when it is longer. A
# line at or under the cap is kept unchanged, marker and all bytes intact.
# This is the rule itself. It assigns rather than prints so a caller that needs
# the value - the wake digest builds its section in a variable to weigh each
# item against a global budget - never pays a command substitution per item on
# a path that runs at the top of every wake-handling turn.
fm_cap_line_var() {
  local line=$1 max=${2:-$FM_LINE_CAP_DEFAULT} keep
  if [ "${#line}" -le "$max" ]; then
    FM_LINE_CAP_LINE=$line
    return 0
  fi
  keep=$((max - ${#FM_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  FM_LINE_CAP_LINE="${line:0:$keep}$FM_LINE_CAP_SUFFIX"
}

# fm_cap_line <line> [<max>]: the same cut, printed on stdout, for a caller that
# is streaming lines rather than accumulating them.
fm_cap_line() {
  fm_cap_line_var "$@"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}
