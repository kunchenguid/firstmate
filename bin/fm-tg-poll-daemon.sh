#!/usr/bin/env bash
# Continuous Telegram poller — runs fm-tg-poll.sh every second
# Usage: start as a daemon: nohup bin/fm-tg-poll-daemon.sh &

FM_ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
export FM_ROOT

while true; do
  bash "$FM_ROOT/bin/fm-tg-poll.sh" 2>/dev/null
  sleep 1
done
