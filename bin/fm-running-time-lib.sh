# shellcheck shell=bash
# Worker running time: the single owner of the opt-in rule for the elapsed-time
# surface in fleet state.
#
# Usage: . bin/fm-running-time-lib.sh   (no FM_* setup required)
#
# The local, gitignored config/worker-running-time presence flag turns the
# surface on for one home. Absent, bin/fm-fleet-snapshot.sh emits no runtime
# fields and bin/fm-bearings-snapshot.sh renders no running column, so an
# unconfigured home reads exactly as it did before the surface existed. Only the
# file's presence is read; its contents are ignored.
#
# Both producers consult this one function rather than testing the path
# themselves, because the bearings TOON encoder takes its column set from the
# first Underway row: a producer that disagreed with the projection about the
# flag would silently render rows against the wrong columns.
#
# See docs/configuration.md "Worker running time (config/worker-running-time)".

# True when <config-dir> opts this home into the running-time surface.
fm_running_time_enabled() {  # <config-dir>
  [ -n "${1:-}" ] && [ -e "$1/worker-running-time" ]
}
