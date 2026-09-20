#!/usr/bin/env bash
# fm-parent-route-lib.sh - the private parent-route directory shape inside a
# remote secondmate home.
#
# ONE owner of that shape. A remote secondmate home keeps the parent's control
# plane in its own private subdirectories so the home's ordinary state/ and
# data/ stay reserved for the workers that secondmate supervises:
#   <home>/state/parent-route   the mate's endpoint record and steering inbox
#   <home>/data/.parent-route   the mate's parent-owned task records
#
# bin/fm-remote-secondmate-control.sh consumes these on the remote host, where
# it is the local control plane. bin/fm-remote-home-seed.sh consumes them on the
# parent host, where it must name the remote-host inbox in the charter it
# publishes; the parent's own path names nothing on that filesystem.
# The <task>.inbox layout under a state directory stays owned by
# bin/fm-task-inbox-lib.sh, which these paths feed as its <state-dir>.

fm_parent_route_state_dir() {  # <secondmate-home>
  printf '%s/state/parent-route' "$1"
}

fm_parent_route_data_dir() {  # <secondmate-home>
  printf '%s/data/.parent-route' "$1"
}
