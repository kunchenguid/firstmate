#!/usr/bin/env bash
set -u
mkdir -p "$FM_HOME/state/.watch.lock"
printf '%s\n' "$$" >> "${FM_LAUNCH_LOG:?}"
printf '%s\n' "$$" > "$FM_HOME/state/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$FM_HOME/state/.watch.lock/fm-home"
printf '%s\n' "${FM_CANON_WATCH:?}" > "$FM_HOME/state/.watch.lock/watcher-path"
LC_ALL=C ps -p "$$" -o lstart= -o command= | sed 's/^[[:space:]]*//' > "$FM_HOME/state/.watch.lock/pid-identity"
touch "$FM_HOME/state/.last-watcher-beat"
/bin/sleep 300 &
printf '%s\n' "$!" >> "${FM_DESCENDANT_LOG:?}"
trap 'exit 0' TERM
wait
