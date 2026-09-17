#!/usr/bin/env bash
# Token-free plain-Pi process fixture for real terminal-backend launch tests.
# Install through a path whose basename is exactly `pi`.
set -eu

case " $* " in
  *' --help '*)
    printf '%s\n' '--model --thinking --tui-mode'
    exit 0
    ;;
esac

case "${FM_TASK_ID:-}" in
  abort-a|abort-b)
    exec -a codex bash -c 'while :; do sleep 60; done'
    ;;
esac

# Stable markers retained by older end-to-end assertions that now exercise the
# exact plain-Pi structural launch instead of an arbitrary raw shell command.
printf '%s\n' \
  autodetect-smoke-ok \
  launcher-ws-ok \
  primary-crew-ok \
  secondmate-launch-ok \
  sm-crew-ok

# Keep one foreground process with exact plain-Pi argv identity until the test
# closes its pane through the ordinary task cleanup path.
exec -a pi bash -c 'while :; do sleep 60; done'
