#!/usr/bin/env bash
# fm-name.sh - the readable crew name for a task id.
#
# WHY THIS HOLDS NO STATE
# A name is DERIVED from the task id, never assigned and stored. The same id
# always yields the same name, on any machine, in any home, forever. That buys
# every property a name registry would have to work for: a name survives a
# restart, a recovery, a teardown and a re-spawn; two homes reading the same id
# agree without coordinating; there is no file to corrupt, no lock to take, no
# migration when the fleet changes, and nothing to clean up. A registry could
# only do worse.
#
# WHAT A NAME IS FOR
# Task ids are precise and unmemorable ("herdr-sm-spaces-k4"). A name is a
# human handle for chat and for glancing at a busy screen: "brisk-halyard".
# It is NOT an identity. Every lookup, endpoint record, tab label, recovery
# path and status line keeps using the task id. Nothing may key off a name, and
# no code should ever parse one back into an id.
#
# COLLISIONS ARE COSMETIC, AND RARE
# 32 adjectives x 40 nouns = 1280 combinations, so a fleet of ten live tasks has
# roughly a 3% chance that two share a name. When that happens the two tasks are
# still wholly distinct everywhere it matters, because the id never stopped
# being the identity. Widening either word list changes existing names, so treat
# the lists as append-only if that ever matters more than the collision rate.
#
# Usage:
#   fm-name.sh <task-id>        print that task's crew name
#   fm-name.sh --help
set -u

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

# "${1---help}" not "${1:---help}": only an ABSENT argument means "show help".
# An explicitly empty one is a caller bug and must be refused below, not
# silently answered with the help text.
case "${1---help}" in
  --help|-h|help) usage; exit 0 ;;
esac

[ $# -eq 1 ] || { echo "fm-name: exactly one task id expected" >&2; exit 1; }
id=$1
[ -n "$id" ] || { echo "fm-name: task id required" >&2; exit 1; }

# Two independent word slots. Keep both lists append-only: reordering or
# removing an entry silently renames every task that mapped past it.
ADJECTIVES="brisk calm bold deep swift steady keen quiet bright salt north east \
west south high low long first last true free wide dark pale red grey green blue \
iron oak storm tide"
NOUNS="halyard mizzen jib keel mast prow stern helm rudder anchor beacon cable \
capstan compass cutter davit ensign fathom galley gunwale hatch hawser jetty \
ketch lantern lookout mainsail marlin oar pennant quay reef rigging sextant \
sloop spinnaker tiller topsail windlass yardarm"

# cksum is POSIX and present everywhere firstmate runs, unlike sha1sum/md5sum
# whose names and output shapes differ across platforms. Its exact algorithm
# does not matter here; only that it is stable for a given input, which the
# standard requires.
sum=$(printf '%s' "$id" | cksum | awk '{print $1}')
case "$sum" in
  ''|*[!0-9]*) echo "fm-name: could not derive a name for '$id'" >&2; exit 1 ;;
esac

# shellcheck disable=SC2086 # deliberate word splitting: the lists are literals
set -- $ADJECTIVES
nadj=$#
adj=$(eval "printf '%s' \"\${$(( sum % nadj + 1 ))}\"")

# shellcheck disable=SC2086
set -- $NOUNS
nnoun=$#
# Divide by nadj first so the two slots do not both track the low-order bits of
# the same number, which would leave most combinations unreachable.
noun=$(eval "printf '%s' \"\${$(( sum / nadj % nnoun + 1 ))}\"")

printf '%s-%s\n' "$adj" "$noun"
