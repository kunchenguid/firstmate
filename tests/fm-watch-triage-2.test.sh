#!/usr/bin/env bash
# The second half of the fm-watch-triage.test.sh cases, run as its own serial
# shard; cases and fixtures stay in that file so the split never copies them.
FM_WATCH_TRIAGE_PART=2 exec bash "$(dirname "$0")/fm-watch-triage.test.sh" "$@"
