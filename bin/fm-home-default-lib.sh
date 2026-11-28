#!/usr/bin/env bash
# fm-home-default-lib.sh - resolve FM_HOME for the steering entrypoints.
#
# fm-send.sh, fm-control.sh and fm-secondmate-restart.sh used to refuse an unset
# FM_HOME so a steer could not resolve against the wrong home. A caller that runs
# one of them by absolute path from a home's bin/ can only mean that home, so an
# unset or empty FM_HOME now defaults to the script's own root. A set FM_HOME is
# honored unchanged, which keeps a second home on a shared code root working.
#
# Usage: fm_home_default_from_root <fm-root>

fm_home_default_from_root() {
  if [ -z "${FM_HOME:-}" ]; then
    FM_HOME="$1"
    export FM_HOME
  fi
}
