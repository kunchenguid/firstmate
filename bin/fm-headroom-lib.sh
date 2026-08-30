# shellcheck shell=bash
# fm-headroom-lib.sh - the single owner of what an UNMEASURABLE headroom reading
# looks like, wherever it is emitted.
# Usage: . bin/fm-headroom-lib.sh
#
# Three surfaces print this shape: bin/fm-usage-wall.sh when it could not read
# the gauge, and bin/fm-fleet-view.sh and bin/fm-session-start.sh when they could
# not run that command at all. Written out per caller, the copies drifted - one
# said "treat it as unproven", the others "treat every provider as unproven" -
# and the two fallbacks emitted two of the four lines, so a reader scanning for
# `HEADROOM_SUMMARY: verdict=` found no verdict on exactly the paths where the
# gauge could not be read. A bounded-read failure and a gauge failure are the
# same fact to a reader, so they get the same four lines from one owner here.
#
#   fm_headroom_build_note <build-state>
#       The build label carried by the summary line. Four states, kept apart:
#       `ok` says nothing, `below-floor` is a version that was READ and found
#       older than the floor, `unknown` is a version that could not be read at
#       all, and `unavailable` is no gauge to read.
#
#   fm_headroom_unmeasurable_text <reason> <advice> [<version>] [<build-state>]
#       The four-line unknown reading. There is deliberately no path from here
#       to `ok`.

# The floor constant belongs to bin/fm-quota-axi-lib.sh, which every caller that
# can produce a `below-floor` state already sources. A caller that cannot reach
# that state never reads the constant, so it is defaulted rather than required.
fm_headroom_build_note() {  # <build-state>
  case "$1" in
    below-floor) printf ' build=below-floor(%s)' "${FM_QUOTA_AXI_MIN:-unknown}" ;;
    unknown) printf ' build=unknown' ;;
    unavailable) printf ' build=unavailable' ;;
  esac
}

fm_headroom_unmeasurable_text() {  # <reason> <advice> [<version>] [<build-state>]
  local reason=$1 advice=$2 version=${3:-unavailable} build=${4:-unavailable} note root
  note=$(fm_headroom_build_note "$build")
  root=${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  printf 'HEADROOM: (all providers) unknown reason=%s\n' "$reason"
  printf 'HEADROOM_SUMMARY: verdict=unknown measured=0 tight=0 wall=0 unknown=1 source=quota-axi/%s%s\n' \
    "$version" "$note"
  printf 'HEADROOM_NOTE: headroom is UNMEASURED, not healthy - %s.\n' "$advice"
  printf 'HEADROOM_NEXT: %s/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.\n' "$root"
}
